#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# bin/app_setup.rb
#
# Takes an application from "kit installed" to "ready to schedule". The
# openspec-kit-init skill drives it with the person who owns the application.
#
#   ruby bin/app_setup.rb status [--json]
#   ruby bin/app_setup.rb add-repo <url> [--name NAME] [--branch BRANCH]
#   ruby bin/app_setup.rb repo <name> [--force]
#
# status    what is set up and what is left, in order, each with the command or
#           file that resolves it: the kit, the project's description (README.md,
#           ROADMAP.md, openspec/config.yaml), the child repositories, the settings
#           (bin/kit_config.rb check), the commits, the preflight and the schedules,
#           with this application's own crontab line.
# add-repo  adds a code repository as a git submodule under repos/ (its default
#           branch unless --branch), then does what repo does.
# repo      delivers the kit's templates to repos/<name>: repo.config.yaml from
#           config/templates/repo.yaml, with the stack, base branch, dev command and
#           gates it detects in the repository (package.json, Gemfile, pyproject.toml,
#           go.mod, Cargo.toml), and, when the repository pins a toolchain
#           (.ruby-version, .nvmrc, .tool-versions, ...), script/env.sh from
#           config/templates/repo_env.sh with env_script pointing at it. What it
#           cannot tell stays a {{...}} placeholder, which the gates skip. An
#           existing repo.config.yaml is kept unless --force.
# Nothing is committed here: the files are reviewed, then committed in the child
# repository and in the umbrella.
# ==============================================================================

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'yaml'
require_relative 'kit_config'

Encoding.default_external = Encoding::UTF_8

module AppSetup
  ROOT = File.expand_path('..', __dir__)
  TEMPLATE = File.join(ROOT, 'config', 'templates', 'repo.yaml')
  ENV_TEMPLATE = File.join(ROOT, 'config', 'templates', 'repo_env.sh')
  ENV_SCRIPT = 'script/env.sh'
  # Files that pin a toolchain version: the repository needs an env_script.
  PINS = %w[.ruby-version .nvmrc .node-version .python-version .tool-versions .mise.toml mise.toml].freeze
  NAME = /\A[a-z0-9][a-z0-9._-]{0,62}\z/

  class Error < StandardError; end

  module_function

  def sh(*cmd, chdir: ROOT)
    out, status = Open3.capture2e(*cmd, chdir: chdir)
    [out.rstrip, status.success?]
  rescue Errno::ENOENT # a missing command (no crontab here)
    ['', false]
  end

  def git(*args, chdir: ROOT)
    out, ok = sh('git', *args, chdir: chdir)
    ok ? out : nil
  end

  def rel(path) = path.delete_prefix("#{ROOT}/")

  def read(path) = File.exist?(path) ? File.read(path) : ''

  def placeholders(path) = read(path).scan(/\{\{[A-Z0-9_]+\}\}/).uniq

  def on_path?(cmd) = ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? { |d| File.executable?(File.join(d, cmd)) }

  # This application's base branch, base_branch of config/pipeline.yaml (bin/lib/settings.rb).
  def base_branch = OpenSpecSettings.get(ROOT, 'base_branch')

  # ------------------------------------------------------------------ detection

  def package_manager(has)
    return 'pnpm' if has.call('pnpm-lock.yaml')
    return 'yarn' if has.call('yarn.lock')
    return 'bun' if has.call('bun.lockb') || has.call('bun.lock')

    'npm'
  end

  def detect_node(dir, has, found)
    pkg = JSON.parse(read(File.join(dir, 'package.json')))
    scripts = pkg['scripts'] || {}
    deps = (pkg['dependencies'] || {}).merge(pkg['devDependencies'] || {})
    pm = package_manager(has)
    run = ->(script) { pm == 'npm' ? "npm run #{script}" : "#{pm} #{script}" }
    stack = if deps['next'] then 'nextjs'
            elsif deps['@nestjs/core'] then 'nestjs'
            elsif deps['vite'] then 'vite'
            else 'node'
            end
    typescript = deps.key?('typescript') || has.call('tsconfig.json')
    found['stack'] = typescript ? "#{stack}-typescript" : stack
    found['gates']['lint'] = run.call('lint') if scripts['lint']
    check = %w[typecheck type-check check-types tsc].find { |s| scripts[s] }
    exec = { 'npm' => 'npx', 'pnpm' => 'pnpm exec', 'yarn' => 'yarn', 'bun' => 'bunx' }.fetch(pm)
    found['gates']['typecheck'] = check ? run.call(check) : ("#{exec} tsc --noEmit" if typescript)
    found['gates']['test'] = run.call('test') if scripts['test'] && !scripts['test'].include?('no test specified')
    found['gates']['build'] = run.call('build') if scripts['build']
    dev = %w[dev start serve].find { |s| scripts[s] }
    found['dev_command'] = run.call(dev) if dev
    found['port'] = { 'nextjs' => '3000', 'vite' => '5173', 'nestjs' => '3000' }[stack]
  rescue JSON::ParserError
    found['stack'] = 'node'
  end

  def detect_ruby(dir, has, found)
    gems = read(File.join(dir, 'Gemfile')) + read(File.join(dir, 'Gemfile.lock'))
    rails = has.call('config/application.rb') || gems.match?(/^\s*gem ['"]rails['"]/)
    found['stack'] = rails ? 'rails' : 'ruby'
    found['gates']['lint'] = 'bundle exec rubocop' if gems.include?('rubocop')
    found['gates']['typecheck'] = 'bundle exec srb tc' if gems.include?('sorbet')
    found['gates']['test'] = if has.call('spec') && gems.include?('rspec') then 'bundle exec rspec'
                             elsif rails then 'bin/rails test'
                             elsif has.call('test') then 'bundle exec rake test'
                             end
    return unless rails

    found['dev_command'] = has.call('bin/dev') ? 'bin/dev' : 'bin/rails server'
    found['port'] = '3000'
    found['health_endpoint'] = 'http://localhost:3000/up' if read(File.join(dir, 'config/routes.rb')).include?('rails/health')
  end

  def detect_python(dir, has, found)
    text = %w[pyproject.toml requirements.txt requirements-dev.txt].sum('') { |f| read(File.join(dir, f)) }
    run = if has.call('uv.lock') then 'uv run '
          elsif has.call('poetry.lock') then 'poetry run '
          else ''
          end
    django = text.match?(/django/i) || has.call('manage.py')
    found['stack'] = if django then 'python-django'
                     elsif text.match?(/fastapi/i) then 'python-fastapi'
                     elsif text.match?(/flask/i) then 'python-flask'
                     else 'python'
                     end
    found['gates']['lint'] = "#{run}ruff check ." if text.include?('ruff')
    found['gates']['typecheck'] = "#{run}mypy ." if text.include?('mypy')
    found['gates']['test'] = if text.include?('pytest') then "#{run}pytest"
                             elsif django then "#{run}python manage.py test"
                             end
    return unless django

    found['dev_command'] = "#{run}python manage.py runserver"
    found['port'] = '8000'
  end

  # What the repository tells about itself; nil values stay placeholders.
  def detect(dir)
    has = ->(f) { File.exist?(File.join(dir, f)) }
    found = { 'stack' => nil, 'dev_command' => nil, 'port' => nil, 'health_endpoint' => nil, 'gates' => {},
              'pins' => PINS.select { |f| has.call(f) } }
    if has.call('package.json') then detect_node(dir, has, found)
    elsif has.call('Gemfile') then detect_ruby(dir, has, found)
    elsif has.call('pyproject.toml') || has.call('requirements.txt') then detect_python(dir, has, found)
    elsif has.call('go.mod')
      found['stack'] = 'go'
      found['gates'] = { 'lint' => has.call('.golangci.yml') || has.call('.golangci.yaml') ? 'golangci-lint run' : 'go vet ./...',
                         'test' => 'go test ./...', 'build' => 'go build ./...' }
    elsif has.call('Cargo.toml')
      found['stack'] = 'rust'
      found['gates'] = { 'lint' => 'cargo clippy -- -D warnings', 'typecheck' => 'cargo check', 'test' => 'cargo test',
                         'build' => 'cargo build' }
    end
    found['gates'] = found['gates'].compact
    found
  end

  # repo.config.yaml base_branch: the submodule's branch, then the remote's default, then the checkout's.
  def child_branch(rel_path)
    paths = git('config', '-f', '.gitmodules', '--get-regexp', '^submodule\..*\.path$').to_s.lines.map(&:split)
    key = paths.find { |_, path| path == rel_path }&.first
    branch = key && git('config', '-f', '.gitmodules', key.sub(/\.path\z/, '.branch'))
    return branch unless branch.to_s.empty?

    dir = File.join(ROOT, rel_path)
    remote = git('symbolic-ref', '--short', 'refs/remotes/origin/HEAD', chdir: dir)
    return remote.delete_prefix('origin/') if remote

    git('symbolic-ref', '--short', 'HEAD', chdir: dir)
  end

  # ------------------------------------------------------------------ repo

  # Replaces `from` with `to`, keeping the column of a trailing comment when there is room.
  def fill(text, from, to)
    text.sub(/#{Regexp.escape(from)}( *)(?=#)/) { "#{to}#{' ' * [Regexp.last_match(1).size + from.size - to.size, 1].max}" }
        .then { |t| t == text ? text.sub(from, to) : t }
  end

  def render(name, found, branch, env_script)
    values = {
      'REPO_NAME' => name, 'TECH_STACK' => found['stack'], 'BASE_BRANCH' => branch,
      'DEV_COMMAND' => found['dev_command'], 'DEV_PORT' => found['port'], 'HEALTH_ENDPOINT' => found['health_endpoint'],
      'LINT_COMMAND' => found['gates']['lint'], 'TYPECHECK_COMMAND' => found['gates']['typecheck'],
      'TEST_COMMAND' => found['gates']['test'], 'BUILD_COMMAND' => found['gates']['build']
    }
    text = File.read(TEMPLATE)
    values.each { |key, value| text = fill(text, "\"{{#{key}}}\"", value.to_json) unless value.to_s.empty? }
    text = fill(text, 'env_script: ""', "env_script: #{env_script.to_json}") if env_script
    YAML.safe_load(text) # the template stays valid YAML
    text
  end

  def repo(name, force: false)
    raise Error, "#{name.inspect} is not a repository name (a-z, 0-9, ., _, -)" unless name.match?(NAME)

    rel_path = "repos/#{name}"
    dir = File.join(ROOT, rel_path)
    raise Error, "#{rel_path} does not exist: ruby bin/app_setup.rb add-repo <url> --name #{name}" unless File.directory?(dir)

    unless KitConfig.child_paths.include?(rel_path)
      puts "warning: #{rel_path} is not a git submodule; the pipeline only works on the submodules under repos/"
    end
    found = detect(dir)
    branch = child_branch(rel_path)
    config = File.join(dir, 'repo.config.yaml')
    puts "#{rel_path}: stack #{found['stack'] || 'unknown'}, base branch #{branch || 'unknown'}, " \
         "pins #{found['pins'].empty? ? 'none' : found['pins'].join(', ')}"
    puts "  detected gates: #{found['gates'].empty? ? 'none' : found['gates'].map { |k, v| "#{k}=#{v}" }.join('; ')}"
    puts "  detected dev command: #{found['dev_command'] || 'none'}"

    env_script = nil
    if found['pins'].any?
      script = File.join(dir, ENV_SCRIPT)
      if !File.exist?(script)
        FileUtils.mkdir_p(File.dirname(script))
        FileUtils.cp(ENV_TEMPLATE, script)
        env_script = ENV_SCRIPT
        puts "  wrote #{rel_path}/#{ENV_SCRIPT} from config/templates/repo_env.sh (the toolchain is pinned)"
      elsif File.read(script) == File.read(ENV_TEMPLATE)
        env_script = ENV_SCRIPT
      else
        puts "  #{rel_path}/#{ENV_SCRIPT} exists and is not the kit's template: review it, or copy " \
             'config/templates/repo_env.sh to another path, then set env_script in repo.config.yaml'
      end
    end

    if File.exist?(config) && !force
      puts "  kept #{rel_path}/repo.config.yaml (--force rewrites it from the template); compare it with the detection above"
    else
      File.write(config, render(name, found, branch, env_script))
      puts "  wrote #{rel_path}/repo.config.yaml from config/templates/repo.yaml"
    end
    left = placeholders(config)
    puts "  to fill in repo.config.yaml: #{left.join(', ')} (the gates skip placeholders with a warning)" if left.any?
    gates = (YAML.safe_load_file(config) || {})['gates'].to_h
    if gates['secrets'].to_s.start_with?('gitleaks') && !on_path?('gitleaks')
      puts '  the secrets gate needs gitleaks (brew install gitleaks); install it or remove the gate'
    end
    puts 'next:'
    puts "  review repos/#{name}/repo.config.yaml#{env_script ? " and #{ENV_SCRIPT}" : ''} with the person who knows the repository"
    puts "  bash bin/repo_exec.sh #{name} true && bash bin/run_gates.sh --repo #{name}   # every gate must pass on #{branch || 'its base branch'}"
    files = ['repo.config.yaml', env_script].compact.join(' ')
    puts "  git -C #{rel_path} add #{files} && git -C #{rel_path} commit -m \"chore: OpenSpec kit settings\" " \
         "&& git -C #{rel_path} push origin #{branch || '<branch>'}"
    puts "  then commit the umbrella: git add .gitmodules #{rel_path}"
  end

  def add_repo(url, name: nil, branch: nil)
    name ||= File.basename(url.to_s.chomp('/'), '.git')
    raise Error, "#{name.inspect} is not a repository name: give --name" unless name.match?(NAME)

    rel_path = "repos/#{name}"
    raise Error, "#{rel_path} already exists: ruby bin/app_setup.rb repo #{name}" if File.exist?(File.join(ROOT, rel_path))

    local = !url.include?('://') && !url.match?(/\A[^\/]+@[^\/]+:/)
    file_ok = local ? ['-c', 'protocol.file.allow=always'] : []
    branch ||= git(*file_ok, 'ls-remote', '--symref', url, 'HEAD').to_s[%r{ref: refs/heads/(\S+)\s+HEAD}, 1] || 'main'
    out, ok = sh('git', *file_ok, 'submodule', 'add', '-b', branch, url, rel_path)
    raise Error, "git submodule add failed:\n#{out}" unless ok

    puts "added #{rel_path} (#{url}, branch #{branch})"
    repo(name)
  end

  # ------------------------------------------------------------------ status

  def item(state, what, fix = nil) = { 'state' => state, 'what' => what, 'fix' => fix }

  def seed_unchanged?(lock, file)
    sha = lock&.dig('files', file, 'sha256')
    sha && File.exist?(File.join(ROOT, file)) && Digest::SHA256.file(File.join(ROOT, file)).hexdigest == sha
  end

  def kit_items(lock)
    return [item('todo', 'the kit is not installed here', 'INSTALL.md: <release>/bin/install.sh init <app> --agents ...')] unless lock

    drift = KitConfig.kit_drift
    [drift ? item('todo', "kit v#{lock['version']}: files edited in place (#{drift})", 'bash bin/install.sh verify') :
             item('ok', "kit v#{lock['version']}, agents #{Array(lock['agents']).join(', ')}")]
  end

  def project_items(lock)
    items = %w[README.md ROADMAP.md].map do |file|
      left = placeholders(File.join(ROOT, file))
      left.empty? ? item('ok', "#{file} filled in") : item('todo', "#{file}: #{left.size} {{...}} placeholder(s) left", "fill #{file} in with the person")
    end
    context = begin
      (YAML.safe_load_file(File.join(ROOT, 'openspec', 'config.yaml')) || {})['context'].to_s.strip
    rescue Errno::ENOENT, Psych::Exception
      ''
    end
    items << (context.empty? ? item('todo', 'openspec/config.yaml has no context', 'add the constraints agents cannot infer from the code') :
                               item('ok', 'openspec/config.yaml has a context'))
    if seed_unchanged?(lock, 'config/exploration.yaml')
      items << item('todo', 'config/exploration.yaml still has the generic strategies',
                    "name the application's own modules, screens and flows in each directive (openspec-kit-config skill)")
    end
    items
  end

  def repo_items
    paths = KitConfig.child_paths
    return [item('todo', 'no child repository under repos/', 'ruby bin/app_setup.rb add-repo <url> [--name NAME]')] if paths.empty?

    paths.flat_map do |rel_path|
      name = File.basename(rel_path)
      dir = File.join(ROOT, rel_path)
      problems = KitConfig.repo_problems(rel_path)
      items = problems[:errors].map { |e| item('todo', "#{rel_path}: #{e}", "fix #{rel_path}/repo.config.yaml") }
      items += problems[:warnings].map do |w|
        fix = w.start_with?('no repo.config.yaml') ? "ruby bin/app_setup.rb repo #{name}" : "edit #{rel_path}/repo.config.yaml"
        item('todo', "#{rel_path}: #{w}", fix)
      end
      cfg_file = File.join(dir, 'repo.config.yaml')
      next items unless File.exist?(cfg_file)

      cfg = YAML.safe_load_file(cfg_file) || {}
      pins = PINS.select { |f| File.exist?(File.join(dir, f)) }
      if pins.any? && cfg['env_script'].to_s.strip.empty?
        items << item('todo', "#{rel_path}: pins #{pins.join(', ')} but has no env_script",
                      "copy config/templates/repo_env.sh into the repository and set env_script (ruby bin/app_setup.rb repo #{name} shows how)")
      end
      own = ['repo.config.yaml', cfg['env_script'].to_s.strip].reject(&:empty?)
      dirty = git('status', '--porcelain', '--', *own, chdir: dir).to_s
      branch = KitConfig.repo_view(rel_path)['base_branch'] || child_branch(rel_path)
      ahead = branch && git('rev-list', '--count', "origin/#{branch}..HEAD", chdir: dir).to_i
      if !dirty.empty?
        items << item('todo', "#{rel_path}: #{own.join(' and ')} not committed in the repository",
                      "git -C #{rel_path} add #{own.join(' ')} && git -C #{rel_path} commit -m \"chore: OpenSpec kit settings\"")
      elsif ahead.to_i.positive?
        items << item('todo', "#{rel_path}: #{ahead} commit(s) not pushed to origin/#{branch}", "git -C #{rel_path} push origin #{branch}")
      end
      items << item('ok', "#{rel_path}: configured") if items.empty?
      items
    end
  end

  def config_items
    files = KitConfig.check
    files.delete('application') # committing and the base branch are reported below
    files.reject! { |name, _| name.start_with?('repos/') }
    errors = files.values.sum { |r| r[:errors].size }
    # The roadmap's placeholders are already a project item.
    warnings = files.flat_map { |name, r| r[:warnings].reject { |w| w.start_with?('roadmap.file:') && w.include?('{{') }.map { |w| "#{name}: #{w}" } }
    items = []
    current = git('symbolic-ref', '--short', 'HEAD')
    if current && current != base_branch
      items << item('todo', "base_branch in config/pipeline.yaml is #{base_branch}, but this checkout is on #{current}",
                    "ruby bin/kit_config.rb set pipeline.base_branch #{current}   # or git switch #{base_branch}")
    end
    return items << item('todo', "settings: #{errors} error(s)", 'ruby bin/kit_config.rb check') if errors.positive?

    items + [item('ok', 'settings valid'), *warnings.map { |w| item('warn', w, 'ruby bin/kit_config.rb check') }]
  end

  def git_items
    return [item('todo', 'not a git repository', 'git init')] unless git('rev-parse', '--is-inside-work-tree')

    items = []
    dirty = git('status', '--porcelain', '--ignore-submodules=dirty').to_s
    if git('rev-parse', '--verify', '--quiet', 'HEAD').nil?
      items << item('todo', 'nothing committed yet', 'git add -A && git commit -m "chore: set up the OpenSpec kit"')
    elsif !dirty.empty?
      items << item('todo', "#{dirty.lines.size} uncommitted path(s) in the umbrella; a cycle pauses on any outside its write scope",
                    'git add -A && git commit -m "chore: set up the OpenSpec kit"')
    end
    if !git('remote').to_s.split.include?('origin')
      items << item('todo', 'no origin remote: the merger and the cycle push to it', "git remote add origin <url> && git push -u origin #{base_branch}")
    elsif git('rev-parse', '--verify', '--quiet', "origin/#{base_branch}").nil?
      items << item('todo', "origin has no branch #{base_branch}", "git push -u origin #{base_branch}")
    elsif (ahead = git('rev-list', '--count', "origin/#{base_branch}..HEAD").to_i).positive?
      items << item('todo', "#{ahead} commit(s) not pushed to origin/#{base_branch}", "git push origin #{base_branch}")
    end
    items << item('ok', "committed and pushed to origin/#{base_branch}") if items.none? { |i| i['state'] == 'todo' }
    items
  end

  def schedule
    {
      'crontab' => "0 * * * * cd #{ROOT} && mkdir -p log/cycle && /bin/bash bin/run_cycle.sh --detach >> log/cycle/cron.log 2>&1",
      'cycle_prompt' => '.agents/skills/openspec-kit-cycle/references/routine-prompt.md',
      'visual_prompt' => '.agents/skills/openspec-kit-visual-qa/references/routine-prompt.md'
    }
  end

  def schedule_items(cycle)
    crontab, = sh('crontab', '-l')
    cron = crontab.lines.any? { |l| l.include?(ROOT) && l.include?('run_cycle.sh') }
    ran = !Dir.glob(File.join(ROOT, 'log', 'cycle', 'cycle-*.log')).empty?
    logs = Dir.glob(File.join(ROOT, 'log', 'cycle', 'cycle-*.log')).max
    items = [if logs && File.read(logs).include?('preflight: OK') then item('ok', 'the last cycle passed its preflight')
             else item('todo', 'run the preflight', 'bash bin/check_ai_engines.sh   # must end with preflight: OK')
             end]
    items << if cron then item('ok', 'the cycle is in the crontab')
             elsif ran then item('ok', 'a cycle has run (scheduled from an agent app, or by hand)')
             else item('todo', 'the cycle is not scheduled', 'SCHEDULING.md, section 1: the crontab line below')
             end
    if cycle.dig('visual_qa', 'enabled') == true && Dir.glob(File.join(ROOT, 'log', 'cycle', 'reports', 'visual-*.md')).empty?
      items << item('todo', 'no visual QA session yet', 'SCHEDULING.md, section 3: a Claude app or Hermes task')
    end
    items
  end

  def status
    lock = KitConfig.read_json(File.join(ROOT, '.openspec-kit.lock'))
    cycle = (KitConfig.load_yaml('cycle') rescue nil) || {}
    sections = {
      'kit' => kit_items(lock),
      'project' => project_items(lock),
      'repositories' => repo_items,
      'settings' => config_items,
      'commit' => git_items,
      'run' => schedule_items(cycle)
    }
    { 'root' => ROOT, 'base_branch' => base_branch, 'sections' => sections, 'schedule' => schedule }
  end

  def status_text(report)
    lines = ["== Setup of #{File.basename(report['root'])} (base branch #{report['base_branch']})"]
    report['sections'].each do |section, items|
      lines << "#{section}:"
      items.each do |i|
        lines << "  [#{i['state']}]#{' ' * (5 - i['state'].size)}#{i['what']}"
        lines << "          #{i['fix']}" if i['fix'] && i['state'] != 'ok'
      end
    end
    first = report['sections'].values.flatten.find { |i| i['state'] == 'todo' }
    lines << "next: #{first ? "#{first['what']} -> #{first['fix']}" : 'nothing left; watch it with ruby bin/cycle_progress.rb'}"
    lines << "crontab line for this application: #{report['schedule']['crontab']}"
    lines.join("\n")
  end
end

if __FILE__ == $PROGRAM_NAME
  options = { json: false, force: false }
  args = OptionParser.new do |opts|
    opts.banner = "Usage: ruby bin/app_setup.rb status [--json]\n" \
                  "       ruby bin/app_setup.rb add-repo <url> [--name NAME] [--branch BRANCH]\n" \
                  '       ruby bin/app_setup.rb repo <name> [--force]'
    opts.on('--json', 'status: machine-readable output') { options[:json] = true }
    opts.on('--name NAME', 'add-repo: the directory under repos/ (default: from the URL)') { |v| options[:name] = v }
    opts.on('--branch BRANCH', "add-repo: the repository's base branch (default: its default branch)") { |v| options[:branch] = v }
    opts.on('--force', 'repo: rewrite an existing repo.config.yaml from the template') { options[:force] = true }
  end.parse!
  begin
    case args
    in ['status']
      report = AppSetup.status
      puts(options[:json] ? JSON.pretty_generate(report) : AppSetup.status_text(report))
    in ['add-repo', url] then AppSetup.add_repo(url, name: options[:name], branch: options[:branch])
    in ['repo', name] then AppSetup.repo(name, force: options[:force])
    else
      warn 'Usage: ruby bin/app_setup.rb status | add-repo <url> [--name NAME] [--branch BRANCH] | repo <name> [--force]'
      exit 2
    end
  rescue AppSetup::Error, KitConfig::Error, Psych::Exception => e
    warn "app_setup: #{e.message}"
    exit 1
  end
end
