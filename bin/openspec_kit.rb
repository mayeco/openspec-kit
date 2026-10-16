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
#   ruby bin/openspec_kit.rb init <app-dir> --source <release-dir> [--tools LIST]
#   ruby bin/openspec_kit.rb upgrade <app-dir> --source <release-dir> [--force]
#   ruby bin/openspec_kit.rb verify [<app-dir>]
#
# Kit files are replaced on upgrade and are never edited in the application.
# Seed files are created once and then belong to the application: a changed
# template arrives next to them as <file>.new. Dist files (install.sh,
# README.md) stay in the release.
# ==============================================================================

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'time'
require 'yaml'

# launchd and cron start without LANG; read every file and pipe as UTF-8.
Encoding.default_external = Encoding::UTF_8

module OpenSpecKit
  LOCK = '.openspec-kit.lock'
  MANIFEST = 'MANIFEST.json'
  GITIGNORE_LINES = ['.worktrees/', 'log/'].freeze
  DEFAULT_TOOLS = 'claude,hermes,opencode'

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

  def write_lock(target, manifest)
    lock = manifest.slice('name', 'version', 'source_commit', 'built_at', 'toolchain', 'files')
    lock['files'] = manifest['files'].reject { |_, f| f['class'] == 'dist' }
    write_json(File.join(target, LOCK), lock.merge('installed_at' => Time.now.utc.iso8601))
  end

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

  def init(source, target, tools:, force:)
    manifest = manifest!(source)
    FileUtils.mkdir_p(target)
    raise Error, "#{target} already has #{LOCK}: use upgrade" if File.exist?(File.join(target, LOCK))

    refuse_while_running!(target)
    taken = files(manifest, 'kit').keys.select do |rel|
      path = File.join(target, rel)
      File.exist?(path) && sha256(path) != manifest['files'][rel]['sha256']
    end
    raise Error, "kit files already exist with other content: #{taken.join(', ')} (use --force to replace them)" if taken.any? && !force

    files(manifest, 'kit').each_key { |rel| copy(source, target, rel) }
    seeded = files(manifest, 'seed').keys.reject { |rel| File.exist?(File.join(target, rel)) }
    seeded.each { |rel| copy(source, target, rel) }
    append_gitignore(target)
    # `openspec init` creates openspec/config.yaml: the project owns it. The framework's
    # authoring rules travel with the kit (templates/authoring_rules.md).
    unless Dir.exist?(File.join(target, 'openspec', 'specs'))
      out, status = Open3.capture2e('openspec', 'init', '--tools', tools, '--no-animation', '.', chdir: target)
      raise Error, "openspec init failed: #{out.strip}" unless status.success?
    end
    write_lock(target, manifest)
    puts "kit: installed v#{manifest['version']} into #{target} " \
         "(#{files(manifest, 'kit').size} kit files, #{seeded.size} seeds created)"
    puts 'next: fill the {{...}} placeholders in README.md and docs/README.md, describe the project in ' \
         'openspec/config.yaml, add child repos under repos/, commit, then schedule the cycle ' \
         '(.claude/skills/openspec-cycle/references/routine-prompt.md)'
  end

  def upgrade(source, target, force:)
    old = read_json(File.join(target, LOCK)) or raise Error, "#{target} has no #{LOCK}: use init"
    manifest = manifest!(source)
    refuse_while_running!(target)
    edited = drift(target, old)
    if old['version'] == manifest['version'] && edited.empty?
      puts "kit: already at v#{manifest['version']}; nothing to do"
      return
    end
    if edited.any? && !force
      raise Error, "kit files were edited in place: #{edited.map { |p, s| "#{p} (#{s})" }.join(', ')}. " \
                   'Move the edits upstream to the framework, or pass --force to discard them'
    end

    branch = "kit-upgrade-v#{manifest['version']}"
    if (git = git_repo?(target))
      raise Error, "#{target} has uncommitted changes; commit or stash them first" unless git(target, 'status', '--porcelain').empty?

      git(target, 'switch', '--quiet', '-c', branch)
    end

    kit = files(manifest, 'kit')
    kit.each_key { |rel| copy(source, target, rel) }
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
    write_lock(target, manifest)

    puts "kit: v#{old['version']} -> v#{manifest['version']}: #{kit.size} kit files, #{dropped.size} removed, " \
         "#{created.size} seeds created"
    proposed.each { |p| puts "  review #{p}: the template changed; merge what you need, then delete it" }
    (retired - edited_seeds).each { |rel| puts "  removed #{rel}: v#{manifest['version']} no longer ships it, and it was unchanged" }
    edited_seeds.each { |rel| puts "  review #{rel}: v#{manifest['version']} no longer ships it; kept because you edited it, so it is yours now" }
    return unless git

    git(target, 'add', '-A')
    git(target, 'commit', '--quiet', '-m', "chore(kit): upgrade the OpenSpec kit to v#{manifest['version']}")
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
  options = { source: nil, tools: OpenSpecKit::DEFAULT_TOOLS, force: false }
  parser = OptionParser.new do |opts|
    opts.banner = 'Usage: ruby bin/openspec_kit.rb init|upgrade|verify <app-dir> [options]'
    opts.on('--source DIR', 'Release of the deliverable (holds MANIFEST.json)') { |v| options[:source] = File.expand_path(v) }
    opts.on('--tools LIST', "openspec init --tools (default: #{OpenSpecKit::DEFAULT_TOOLS})") { |v| options[:tools] = v }
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

      if command == 'init'
        OpenSpecKit.init(options[:source], target, tools: options[:tools], force: options[:force])
      else
        OpenSpecKit.upgrade(options[:source], target, force: options[:force])
      end
    when 'verify'
      exit(OpenSpecKit.verify(target) ? 0 : 1)
    else
      warn parser.banner
      exit 2
    end
  rescue OpenSpecKit::Error => e
    warn "kit: #{e.message}"
    exit 1
  end
end
