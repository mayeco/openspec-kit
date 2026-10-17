#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# bin/openspec_kit.rb
#
# Installs, upgrades and verifies the OpenSpec orchestration kit in an
# application umbrella. A release of the deliverable carries MANIFEST.json:
# every file with its sha256 and its class. An installed umbrella keeps the
# same data in .openspec-kit.lock.
#
#   ruby bin/openspec_kit.rb init <app-dir> --source <release-dir> --agents LIST [--plan A --build A --cycle A]
#   ruby bin/openspec_kit.rb upgrade <app-dir> --source <release-dir> [--agents LIST ...] [--force]
#   ruby bin/openspec_kit.rb verify [<app-dir>]
#
# Kit files are replaced on upgrade and are never edited in the application.
# Skills ship once, in skills/<name>/, and are installed, as kit files,
# into the skills directory of each agent the application selected. The
# selection and the agent of each role are kept in config/agents.yaml, which
# the scripts read. Seed files are created once and then belong to the
# application: a changed template arrives next to them as <file>.new.
# bin/install.sh is the entry point; it ships with the rest of bin/.
# ==============================================================================

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'time'
require 'yaml'
require_relative 'lib/agents'

# launchd and cron start without LANG; read every file and pipe as UTF-8.
Encoding.default_external = Encoding::UTF_8

module OpenSpecKit
  LOCK = '.openspec-kit.lock'
  MANIFEST = 'MANIFEST.json'
  GITIGNORE_LINES = ['.worktrees/', 'log/'].freeze

  class Error < StandardError; end

  module_function

  def sha256(path) = Digest::SHA256.file(path).hexdigest

  def read_json(path)
    JSON.parse(File.read(path))
  rescue Errno::ENOENT
    nil
  end

  def write_json(path, obj) = File.write(path, "#{JSON.pretty_generate(obj)}\n")

  def manifest!(source)
    read_json(File.join(source, MANIFEST)) or
      raise Error, "#{source} has no #{MANIFEST}: point --source at a release of the deliverable"
  end

  def files(data, klass) = (data['files'] || {}).select { |_, f| f['class'] == klass }

  def copy(source, target, rel, to: rel)
    dst = File.join(target, to)
    FileUtils.mkdir_p(File.dirname(dst))
    FileUtils.cp(File.join(source, rel), dst, preserve: true)
  end

  def running?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  # The dispatcher and the merger read bin/ while they run: never swap it under them.
  def refuse_while_running!(target)
    %w[dispatcher merger].each do |name|
      lock = File.join(target, 'log', 'locks', "#{name}.lock")
      pid = File.exist?(lock) && File.read(lock)[/pid=(\d+)/, 1]
      raise Error, "the #{name} is running (pid #{pid}); stop it first" if pid && running?(pid.to_i)
    end
  end

  def git(target, *args)
    out, status = Open3.capture2e('git', *args, chdir: target)
    raise Error, "git #{args.join(' ')} failed in #{target}: #{out.strip}" unless status.success?

    out.strip
  end

  def git_repo?(target) = system('git', 'rev-parse', '--is-inside-work-tree', chdir: target, out: File::NULL, err: File::NULL)

  # Kit files that differ from the lock: { path => 'missing' | 'modified' }.
  def drift(target, lock)
    files(lock, 'kit').each_with_object({}) do |(rel, f), acc|
      path = File.join(target, rel)
      if !File.exist?(path) then acc[rel] = 'missing'
      elsif sha256(path) != f['sha256'] then acc[rel] = 'modified'
      end
    end
  end

  # Removes the directories that removing these files left empty, up to the target.
  def prune_empty_dirs(target, paths)
    paths.map { |rel| File.dirname(rel) }.uniq.each do |dir|
      until dir == '.'
        path = File.join(target, dir)
        break unless Dir.exist?(path) && Dir.empty?(path)

        Dir.rmdir(path)
        dir = File.dirname(dir)
      end
    end
  end

  # { path in the application => path in the release }: the kit files, and every
  # shipped skill in the skills directory of each selected agent.
  def kit_plan(manifest, agents)
    plan = files(manifest, 'kit').keys.to_h { |rel| [rel, rel] }
    files(manifest, 'skill').each_key do |rel|
      agents.each { |agent| plan[File.join(OpenSpecAgents.skills_dir(agent), rel.delete_prefix('skills/'))] = rel }
    end
    plan
  end

  # The agents whose skills a lock installed; locks before agent selection did not record them.
  def installed_agents(lock)
    lock['agents'] || OpenSpecAgents::SUPPORTED.keys.select do |agent|
      files(lock, 'kit').keys.any? { |rel| rel.start_with?("#{OpenSpecAgents.skills_dir(agent)}/") }
    end
  end

  def write_lock(target, manifest, plan, agents)
    lock = manifest.slice('name', 'version', 'source_commit', 'built_at', 'toolchain')
    installed = plan.to_h { |dest, from| [dest, { 'class' => 'kit', 'sha256' => manifest['files'][from]['sha256'] }] }
    lock['agents'] = agents
    lock['files'] = files(manifest, 'seed').merge(installed).sort.to_h
    write_json(File.join(target, LOCK), lock.merge('installed_at' => Time.now.utc.iso8601))
  end

  # The agents and the agent of each role: the options first, then config/agents.yaml.
  # One agent runs every role. With more, a role without an option keeps its current
  # agent, or is asked on a terminal; without a terminal it must be an option.
  def selection(target, agents_opt, roles_opt, input: $stdin, output: $stdout)
    current = OpenSpecAgents.load(target)
    list = agents_opt || current&.fetch('agents')&.join(',')
    raise Error, "pass --agents with the agents this application uses (#{OpenSpecAgents::SUPPORTED.keys.join(', ')})" if list.to_s.empty?

    agents = OpenSpecAgents.parse(list)
    roles = OpenSpecAgents::ROLES.to_h do |role, does|
      given = roles_opt[role]
      raise Error, "--#{role} #{given} is not one of the agents (#{agents.join(', ')})" if given && !agents.include?(given)

      kept = current&.dig('roles', role)
      choice = given || (agents.first if agents.size == 1) || (kept if agents.include?(kept))
      choice ||= input.tty? ? ask(role, does, agents, input, output) : nil
      raise Error, "--#{role} is required with more than one agent: choose one of #{agents.join(', ')}" unless choice

      [role, choice]
    end
    [agents, roles]
  end

  def ask(role, does, agents, input, output)
    output.puts "AGENT_ENGINE_#{role.upcase}: which agent #{does}?"
    agents.each_with_index { |agent, i| output.puts "  #{i + 1}) #{agent}" }
    loop do
      output.print "Choose 1-#{agents.size} [1]: "
      answer = input.gets or raise Error, "no agent chosen for #{role}"
      answer = answer.strip
      return agents.first if answer.empty?
      return agents[answer.to_i - 1] if answer.match?(/\A\d+\z/) && answer.to_i.between?(1, agents.size)
      return answer if agents.include?(answer)

      output.puts '  not one of the choices'
    end
  end

  # `openspec init` creates openspec/config.yaml, which the project owns, and adds the
  # OpenSpec skills of each agent; on an existing project it only adds what is missing.
  def openspec_init(target, agents)
    tools = agents.map { |agent| OpenSpecAgents.tool(agent) }.join(',')
    out, status = Open3.capture2e('openspec', 'init', '--tools', tools, '--no-animation', '--no-copilot-cloud', '.', chdir: target)
    raise Error, "openspec init failed: #{out.strip}" unless status.success?
  end

  def describe(agents, roles) = "#{agents.join(', ')} (#{roles.map { |role, agent| "#{role}: #{agent}" }.join(', ')})"

  def append_gitignore(target)
    path = File.join(target, '.gitignore')
    present = File.exist?(path) ? File.readlines(path, chomp: true) : []
    missing = GITIGNORE_LINES - present
    return if missing.empty?

    File.open(path, 'a') do |f|
      f.puts unless present.empty? || File.read(path).end_with?("\n")
      f.puts('# OpenSpec orchestration runtime state', *missing)
    end
  end

  def init(source, target, agents:, roles:, force:)
    manifest = manifest!(source)
    raise Error, "#{target} already has #{LOCK}: use upgrade" if File.exist?(File.join(target, LOCK))

    agents, roles = selection(target, agents, roles)
    FileUtils.mkdir_p(target)
    refuse_while_running!(target)
    plan = kit_plan(manifest, agents)
    taken = plan.keys.select do |dest|
      path = File.join(target, dest)
      File.exist?(path) && sha256(path) != manifest['files'][plan[dest]]['sha256']
    end
    raise Error, "kit files already exist with other content: #{taken.join(', ')} (use --force to replace them)" if taken.any? && !force

    plan.each { |dest, from| copy(source, target, from, to: dest) }
    seeded = files(manifest, 'seed').keys.reject { |rel| File.exist?(File.join(target, rel)) }
    seeded.each { |rel| copy(source, target, rel) }
    OpenSpecAgents.write(target, agents, roles)
    append_gitignore(target)
    # The framework's authoring rules travel with the kit (templates/authoring_rules.md).
    openspec_init(target, agents)
    write_lock(target, manifest, plan, agents)
    puts "kit: installed v#{manifest['version']} into #{target} " \
         "(#{plan.size} kit files, #{seeded.size} seeds created)"
    puts "agents: #{describe(agents, roles)}, in #{OpenSpecAgents::CONFIG}"
    puts 'next: fill the {{...}} placeholders in README.md and ROADMAP.md, describe the project in ' \
         'openspec/config.yaml, add child repos under repos/, commit, then schedule the headless cycle ' \
         "(crontab or an agent app: #{OpenSpecAgents.skills_dir(roles['cycle'])}/openspec-kit-cycle/references/routine-prompt.md) " \
         'and the visual QA session in an agent app with a browser ' \
         "(#{OpenSpecAgents.skills_dir(agents.first)}/openspec-kit-visual-qa/references/routine-prompt.md)"
  end

  def upgrade(source, target, agents:, roles:, force:)
    old = read_json(File.join(target, LOCK)) or raise Error, "#{target} has no #{LOCK}: use init"
    manifest = manifest!(source)
    refuse_while_running!(target)
    current = OpenSpecAgents.load(target)
    agents, roles = selection(target, agents, roles)
    previous = installed_agents(old)
    reselected = agents != previous || roles != current&.fetch('roles')
    edited = drift(target, old)
    if old['version'] == manifest['version'] && edited.empty? && !reselected
      puts "kit: already at v#{manifest['version']}; nothing to do"
      return
    end
    if edited.any? && !force
      raise Error, "kit files were edited in place: #{edited.map { |p, s| "#{p} (#{s})" }.join(', ')}. " \
                   'Move the edits upstream to the framework, or pass --force to discard them'
    end

    same_version = old['version'] == manifest['version']
    branch = same_version ? "kit-agents-#{agents.join('-')}" : "kit-upgrade-v#{manifest['version']}"
    if (git = git_repo?(target))
      raise Error, "#{target} has uncommitted changes; commit or stash them first" unless git(target, 'status', '--porcelain').empty?

      git(target, 'switch', '--quiet', '-c', branch)
    end

    kit = kit_plan(manifest, agents)
    kit.each { |dest, from| copy(source, target, from, to: dest) }
    dropped = files(old, 'kit').keys - kit.keys
    dropped.each { |rel| FileUtils.rm_f(File.join(target, rel)) }
    # Seeds this release no longer ships: an untouched one is still the old template, so it
    # goes; one the application edited is its data, so it stays and is reported.
    retired = files(old, 'seed').keys - files(manifest, 'seed').keys
    edited_seeds = retired.select do |rel|
      path = File.join(target, rel)
      File.exist?(path) && sha256(path) != old['files'][rel]['sha256']
    end
    (retired - edited_seeds).each { |rel| FileUtils.rm_f(File.join(target, rel)) }
    prune_empty_dirs(target, dropped + retired)
    created = []
    proposed = []
    files(manifest, 'seed').each do |rel, f|
      if !File.exist?(File.join(target, rel))
        copy(source, target, rel)
        created << rel
      elsif old.dig('files', rel, 'sha256') != f['sha256']
        copy(source, target, rel, to: "#{rel}.new")
        proposed << "#{rel}.new"
      end
    end
    if reselected
      OpenSpecAgents.write(target, agents, roles)
      openspec_init(target, agents)
    end
    write_lock(target, manifest, kit, agents)

    puts "kit: #{same_version ? "v#{old['version']}" : "v#{old['version']} -> v#{manifest['version']}"}: " \
         "#{kit.size} kit files, #{dropped.size} removed, #{created.size} seeds created"
    puts "agents: #{describe(agents, roles)}, in #{OpenSpecAgents::CONFIG}" if reselected
    (previous - agents).each do |agent|
      left = File.join(OpenSpecAgents.skills_dir(agent), '')
      note = Dir.exist?(File.join(target, left)) ? "; delete the OpenSpec skills left in #{left} if you do not need them" : ''
      puts "  #{agent} is no longer used: its kit skills were removed#{note}"
    end
    proposed.each { |p| puts "  review #{p}: the template changed; merge what you need, then delete it" }
    (retired - edited_seeds).each { |rel| puts "  removed #{rel}: v#{manifest['version']} no longer ships it, and it was unchanged" }
    edited_seeds.each { |rel| puts "  review #{rel}: v#{manifest['version']} no longer ships it; kept because you edited it, so it is yours now" }
    return unless git

    git(target, 'add', '-A')
    message = same_version ? "chore(kit): use the agents #{agents.join(', ')}" : "chore(kit): upgrade the OpenSpec kit to v#{manifest['version']}"
    git(target, 'commit', '--quiet', '-m', message)
    puts "committed on branch #{branch}: review it, then merge"
  end

  def tool_version(cmd)
    out, status = Open3.capture2e(*cmd)
    status.success? ? out[/\d+\.\d+\.\d+/] : 'missing'
  rescue Errno::ENOENT
    'missing'
  end

  # Installed tools against the toolchain the release was verified with.
  def toolchain_mismatches(target, recorded)
    current = {
      'openspec' => tool_version(%w[openspec --version]), 'git' => tool_version(%w[git --version]),
      'ruby' => RUBY_VERSION, 'jev' => tool_version(%w[jev --version])
    }
    policy = File.join(target, 'config', 'jev_policy.yaml')
    current['jev_model'] = (YAML.safe_load_file(policy) || {})['model'] if File.exist?(policy)
    (recorded || {}).filter_map do |tool, want|
      have = current[tool]
      "#{tool} #{have || 'unknown'} (release verified #{want})" if have && have != want
    end
  end

  def verify(target)
    lock = read_json(File.join(target, LOCK))
    unless lock
      puts "kit: no #{LOCK} (not installed with install.sh); not verified"
      return true
    end

    edited = drift(target, lock)
    selected = OpenSpecAgents.load(target)&.fetch('agents')
    if lock['agents'] && selected && selected != lock['agents']
      edited['config/agents.yaml'] = "lists #{selected.join(', ')}, skills installed for #{lock['agents'].join(', ')}: run bin/install.sh upgrade from the release"
    end
    mismatches = toolchain_mismatches(target, lock['toolchain'])
    strict = ENV['OPENSPEC_STRICT_TOOLCHAIN'] == '1'
    if edited.empty?
      puts "kit: OK (v#{lock['version']}, #{files(lock, 'kit').size} kit files match #{LOCK})"
    else
      puts "kit: DRIFT from v#{lock['version']}: #{edited.map { |p, s| "#{p} (#{s})" }.join(', ')}"
    end
    mismatches.each { |m| puts "kit: #{strict ? 'FAIL' : 'WARN'} toolchain #{m}" }
    edited.empty? && (mismatches.empty? || !strict)
  end
end

if __FILE__ == $PROGRAM_NAME
  options = { source: nil, agents: nil, roles: {}, force: false }
  parser = OptionParser.new do |opts|
    opts.banner = 'Usage: ruby bin/openspec_kit.rb init|upgrade|verify <app-dir> [options]'
    opts.on('--source DIR', 'Release of the deliverable (holds MANIFEST.json)') { |v| options[:source] = File.expand_path(v) }
    opts.on('--agents LIST', "Agents the application uses: #{OpenSpecAgents::SUPPORTED.keys.join(', ')}") { |v| options[:agents] = v }
    OpenSpecAgents::ROLES.each do |role, does|
      opts.on("--#{role} AGENT", "The agent that #{does}") { |v| options[:roles][role] = v }
    end
    opts.on('--force', 'init: replace existing kit files; upgrade: discard edits to kit files') { options[:force] = true }
  end
  args = parser.parse(ARGV)
  command = args.shift
  app = args.shift || (File.expand_path('..', __dir__) if command == 'verify')
  target = app && File.expand_path(app)
  begin
    case command
    when 'init', 'upgrade'
      raise OpenSpecKit::Error, "#{command} needs <app-dir> and --source" if args.any? || options[:source].nil? || target.nil?

      selection = { agents: options[:agents], roles: options[:roles], force: options[:force] }
      if command == 'init'
        OpenSpecKit.init(options[:source], target, **selection)
      else
        OpenSpecKit.upgrade(options[:source], target, **selection)
      end
    when 'verify'
      exit(OpenSpecKit.verify(target) ? 0 : 1)
    else
      warn parser.banner
      exit 2
    end
  rescue OpenSpecKit::Error, OpenSpecAgents::Error => e
    warn "kit: #{e.message}"
    exit 1
  end
end
