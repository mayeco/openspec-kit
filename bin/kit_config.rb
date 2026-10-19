#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# bin/kit_config.rb
#
# The application's settings in one place: what each one does, its value and
# default, which script reads it, and whether the files are valid. The
# openspec-kit-config skill reads it to explain the configuration and to change
# it safely.
#
#   ruby bin/kit_config.rb show [agents|pipeline|cycle|exploration|jev|repos|prompts|env] [--json]
#   ruby bin/kit_config.rb check [--json]
#   ruby bin/kit_config.rb set <file>.<key> <value> [--dry-run]
#
# show   the effective values, marking the ones left at their default, with the
#        script that reads each one; env lists the environment variables that
#        override a setting for one manual run; prompts lists the agents' prompts
#        (config/prompts/, the application's own) and the placeholders each one uses.
# check  validates config/agents.yaml, pipeline.yaml, cycle.yaml, exploration.yaml,
#        jev_policy.yaml, the backlog, the proposals, the prompts and every child
#        repository's repo.config.yaml, and reports what would stop the next cycle: kit files
#        edited in place, uncommitted edits outside the cycle's write scope (its
#        scope guard pauses the system), <file>.new left by an upgrade, a base
#        branch origin lacks, an environment variable overriding a setting.
#        Exit 1 on an error.
# set    changes one scalar setting in place, keeping the file's comments, and
#        writes only when the result parses to the intended value and passes check:
#          ruby bin/kit_config.rb set cycle.proposals.approval human
#          ruby bin/kit_config.rb set agents.roles.cycle hermes
#          ruby bin/kit_config.rb set pipeline.base_branch main
#          ruby bin/kit_config.rb set jev.gates.change_risk.mode enforce
#        Lists and texts (the agents, the strategies, Jev's thresholds) are edited
#        by hand, then checked. Nothing is committed here.
# ==============================================================================

require 'digest'
require 'json'
require 'open3'
require 'yaml'
require_relative 'lib/agents'
require_relative 'lib/memory'
require_relative 'lib/prompts'
require_relative 'lib/settings'
require_relative 'cycle_prompt'

Encoding.default_external = Encoding::UTF_8

module KitConfig
  ROOT = File.expand_path('..', __dir__)
  FILES = {
    'agents' => 'config/agents.yaml',
    'pipeline' => 'config/pipeline.yaml',
    'cycle' => 'config/cycle.yaml',
    'exploration' => 'config/exploration.yaml',
    'jev' => 'config/jev_policy.yaml'
  }.freeze
  ABOUT = {
    'agents' => 'the agents, the agent of each role and their permissions; written by install.sh, read on every agent call',
    'pipeline' => 'how the pipeline runs: base branch, parallelism, limits; read on every run',
    'cycle' => 'the scheduled cycle and the visual QA session; read on every cycle and session',
    'exploration' => 'the exploration strategies, one per cycle or visual session',
    'jev' => 'the Jev judgment gates; read on every gate'
  }.freeze
  # What the cycle's judgment and the visual session may write (bin/lib/record.sh).
  SCOPE = %w[MEMORY.md memory config/agent_backlog.json config/agent_proposals.json].freeze
  CHANGE_NAME = /\A[a-z0-9][a-z0-9-]{0,62}\z/
  KINDS = %w[defects improvements features].freeze
  MODES = %w[off advisory enforce].freeze
  PRIORITIES = %w[critical high normal low].freeze
  STATUSES = %w[proposed approved queued integrated rejected].freeze
  GATE_ORDER = %w[lint typecheck test build].freeze
  GATES = {
    'plan_review' => 'J1, bin/openspec_dispatcher.rb after openspec validate --strict: enforce sends failures back to the plan agent',
    'failure_triage' => 'J2, bin/openspec_dispatcher.rb when gates fail in BUILD: enforce re-runs a flaky gate once, escalates ambiguity',
    'repair_progress' => 'J2, bin/openspec_dispatcher.rb when gates fail again after a repair: enforce quarantines a change that is not converging (repair_stalled)',
    'scenario_coverage' => "J7, bin/openspec_dispatcher.rb after BUILD's gates pass: enforce sends scenarios without a real test back to the BUILD agent",
    'change_risk' => 'J3, bin/openspec_dispatcher.rb after BUILD: enforce quarantines a risky change as risk_review',
    'task_priority' => "J5, the cycle's judgment before it queues a backlog item",
    'proposal_review' => 'J6, bin/proposals.rb after each judgment when proposals.approval is jev: enforce queues what passes'
  }.freeze
  ROLE_READERS = {
    'plan' => 'bin/openspec_dispatcher.rb (PLAN)',
    'build' => 'bin/openspec_dispatcher.rb (BUILD)',
    'cycle' => "bin/run_cycle.sh (the cycle's judgment)"
  }.freeze

  # config/pipeline.yaml: what each key of bin/lib/settings.rb does, and who reads it.
  PIPELINE = {
    'base_branch' => ['the branch every change starts from and the merger publishes to, on origin',
                      'bin/openspec_dispatcher.rb, bin/openspec_merger.rb, bin/run_cycle.sh, bin/visual_qa.sh, bin/cycle_progress.rb'],
    'dispatch.workers' => ['changes one dispatch builds in parallel', 'bin/openspec_dispatcher.rb'],
    'dispatch.wait_seconds' => ["how long a cycle's dispatch waits while changes wait on merges", 'bin/openspec_dispatcher.rb'],
    'dispatch.merge_interval_seconds' => ['how often a watching merger looks for ready changes', 'bin/openspec_merger.rb'],
    'dispatch.conflict_rebuilds' => ['automatic rebuilds of a change whose code no longer rebases onto the base branch, before rebase_conflict; 0: none',
                                     'bin/openspec_dispatcher.rb, bin/openspec_merger.rb'],
    'dispatch.aging_hours' => ['every this many hours an item waits, it is ordered one priority higher; 0: off', 'bin/openspec_dispatcher.rb'],
    'limits.agent_seconds' => ['limit of one agent call', 'bin/agent_exec.sh, bin/openspec_dispatcher.rb'],
    'limits.agent_retries' => ['extra attempts with the same agent after a failure, before the next agent of the role (none after a usage limit); 0: none',
                               'bin/agent_exec.sh, bin/openspec_dispatcher.rb'],
    'limits.agent_retry_delay_seconds' => ['wait before trying the same agent again', 'bin/agent_exec.sh'],
    'limits.agent_budget_usd' => ["Claude Code's spending cap per call", 'bin/agent_exec.sh'],
    'limits.gate_seconds' => ["limit of one repository's gates", 'bin/openspec_dispatcher.rb, bin/openspec_merger.rb'],
    'limits.lease_seconds' => ["a change's lease is stale after this", 'bin/lib/openspec_orchestrator.rb']
  }.freeze

  def self.setting(key, type, default, means, read_by, values: nil, change: nil)
    { 'key' => key, 'type' => type, 'default' => default, 'values' => values, 'means' => means,
      'read_by' => read_by, 'change' => change }
  end

  SETTINGS = [
    setting('agents.agents', :list, nil, "the agent CLIs this application uses; each one has the kit's skills",
            'bin/install.sh; bin/check_ai_engines.sh pings each one',
            change: '<release>/bin/install.sh upgrade <app> --agents LIST, from a checkout of the release: it installs their skills'),
    *OpenSpecAgents::ROLES.map { |role, does| setting("agents.roles.#{role}", :agents, 'the first agent CLI on PATH', "#{does}; agents in order; one that fails is tried again limits.agent_retries times, then the next continues its work", ROLE_READERS.fetch(role)) },
    setting('agents.order', :enum, OpenSpecAgents::DEFAULT_ORDER,
            "how each call picks among a role's agents. fallback: the first listed, then the next when one fails; " \
            "random: any of them first, then the others in the order listed, spreading the calls over the agents' quotas; " \
            'spread: like random, among the agents the fewest running calls use, so changes built at once go to different agents (AGENT_ORDER overrides it for one run)',
            'bin/agent_exec.sh, on every agent call', values: OpenSpecAgents::ORDERS),
    setting('agents.permissions', :enum, OpenSpecAgents::DEFAULT_PERMISSIONS,
            'all: any command but the git commands only the scripts run; restricted: Claude Code on an allowlist, Codex and agy sandboxed, kilo and omp on their own approval settings, pi without project extensions (hermes, copilot, opencode, cline and crush ignore it)',
            'bin/agent_exec.sh, on every agent call', values: OpenSpecAgents::PERMISSIONS),
    *PIPELINE.map { |key, (means, read_by)| setting("pipeline.#{key}", :pipeline, OpenSpecSettings::KEYS.fetch(key)[1], "#{means} (#{OpenSpecSettings::KEYS.fetch(key)[0]} overrides it for one run)", read_by) },
    setting('cycle.qa_time_budget_minutes', :int, 45, 'minutes the judgment may spend verifying and exploring',
            "bin/cycle_prompt.rb, into the judgment's prompt"),
    setting('cycle.max_consecutive_failures', :int, 2,
            'cycles whose dispatch ended all blocked before the judgment stops queuing and asks for a human',
            "the cycle's judgment (openspec-kit-cycle skill)"),
    setting('cycle.exploration.minutes', :int, 15, 'minutes of the budget at least spent on the strategy of the cycle',
            'bin/cycle_prompt.rb'),
    setting('cycle.exploration.max_new_backlog_items_per_cycle', :int, 3,
            'findings queued or proposed per cycle or session; the rest stay in the report', 'bin/cycle_prompt.rb, bin/visual_qa.rb'),
    setting('cycle.roadmap.file', :path, nil, 'the features to build, in priority order; empty: no roadmap',
            'bin/cycle_prompt.rb, bin/proposals.rb, bin/cycle_progress.rb'),
    setting('cycle.roadmap.max_new_per_cycle', :int, 1, 'roadmap features proposed per cycle', 'bin/cycle_prompt.rb'),
    setting('cycle.roadmap.max_open', :int, 3, 'no roadmap proposal while this many are proposed, approved or queued',
            'bin/cycle_prompt.rb'),
    setting('cycle.proposals.approval', :enum, 'jev',
            'who approves proposals before they are queued: Jev (gate proposal_review; the rest waits for a human), a human, or nobody',
            'bin/proposals.rb after each judgment and visual session; bin/cycle_prompt.rb', values: %w[jev human auto]),
    setting('cycle.proposals.prompt_approval', :enum, 'human',
            "who approves a prompt proposal, an edit of config/prompts/ the cycle bases on evidence: a human (proposals.rb show, then approve), or nobody (the script applies it after the judgment)",
            'bin/proposals.rb after each judgment and visual session; bin/cycle_prompt.rb', values: %w[human auto]),
    setting('cycle.visual_qa.enabled', :bool, false,
            'a browser session in an agent app checks integrated changes and runs the strategies that need a browser',
            'bin/run_cycle.sh, bin/cycle_prompt.rb, bin/visual_qa.sh, bin/visual_qa.rb'),
    setting('cycle.visual_qa.minutes', :int, 40, 'time budget of one visual session; its lock expires 30 minutes after',
            'bin/visual_qa.sh, bin/visual_qa.rb'),
    setting('cycle.visual_qa.max_items_per_session', :int, 5, 'queued checks one visual session takes; the rest wait',
            'bin/visual_qa.rb'),
    setting('cycle.qa.skills', :list, [], "the application's own QA skills the cycle and the visual session use",
            "bin/visual_qa.rb, the cycle's judgment", change: 'edit config/cycle.yaml, for example skills: [browser-qa]'),
    setting('cycle.memory.max_chars', :int, OpenSpecMemory::DEFAULTS['max_chars'],
            'characters MEMORY.md may hold: every agent reads it on every call. Over it, the next cycle and visual session are told to trim it first; 0: the default',
            'bin/cycle_prompt.rb, bin/visual_qa.rb, check (bin/lib/memory.rb)'),
    setting('cycle.memory.scoped_max_chars', :int, OpenSpecMemory::DEFAULTS['scoped_max_chars'],
            'characters each lesson file of memory/ may hold (one repository or capability, read only by the changes that touch it); 0: the default',
            'bin/cycle_prompt.rb, bin/visual_qa.rb, check (bin/lib/memory.rb)'),
    setting('exploration.order', :enum, 'rotation', 'rotation: in file order; random: never one of the most recent half again',
            'bin/cycle_prompt.rb, bin/visual_qa.rb', values: %w[rotation random]),
    setting('exploration.strategies', :list, nil, 'slug, name, kind, directive, needs, enabled of each strategy',
            'bin/cycle_prompt.rb, bin/visual_qa.rb', change: 'edit config/exploration.yaml by hand, then run check'),
    setting('jev.model', :string, 'jev-latest', 'the pinned, versioned Jev model', 'bin/lib/openspec_orchestrator.rb, bin/check_ai_engines.sh'),
    setting('jev.timeout', :string, '30s', 'limit of one Jev attempt', 'bin/lib/openspec_orchestrator.rb'),
    setting('jev.max_retries', :int, 2, 'Jev retries per question', 'bin/lib/openspec_orchestrator.rb'),
    setting('jev.max_state_chars', :int, 24_000, 'every string sent to Jev is clipped to this', 'bin/lib/openspec_orchestrator.rb'),
    setting('jev.include_diffs', :bool, true, 'false: change_risk gets file lists and diffstats, never code', 'bin/openspec_dispatcher.rb'),
    setting('jev.abstain_band', :list, [0.4, 0.6], 'a score inside it is "cannot tell"; enforce still blocks on it',
            'bin/lib/openspec_orchestrator.rb', change: 'edit config/jev_policy.yaml by hand, then run check'),
    setting('jev.on_unavailable', :enum, 'skip', 'skip: a gate without Jev passes; block: an enforce gate quarantines and pauses',
            'bin/lib/openspec_orchestrator.rb', values: %w[skip block]),
    *GATES.map { |gate, reader| setting("jev.gates.#{gate}.mode", :enum, 'off', 'off | advisory (answers recorded) | enforce (answers decide)', reader, values: MODES) }
  ].freeze

  ENV_KNOBS = [
    *OpenSpecSettings::KEYS.map { |key, (var, _)| [var, nil, "overrides pipeline.#{key} of config/pipeline.yaml"] },
    ['OPENSPEC_PATH_PREFIX', '/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin', 'prepended to PATH by the scheduled scripts'],
    ['AGENT_ENGINE_PLAN, AGENT_ENGINE_BUILD, AGENT_ENGINE_CYCLE, AGENT_ENGINE', 'roles of config/agents.yaml', 'the agent of a role'],
    ['AGENT_ORDER', 'order of config/agents.yaml', 'fallback | random'],
    ['AGENT_PERMISSIONS', 'permissions of config/agents.yaml', 'all | restricted'],
    ['OPENSPEC_REMOTE', 'origin', 'the remote the scripts fetch from and push to'],
    ['OPENSPEC_WORKTREE_BASE', '.worktrees', 'where the worktrees of changes live'],
    ['OPENSPEC_PROTECTED_PATHS', 'repo.config.yaml .github .gitlab-ci.yml', "child paths a change may not touch, besides the repository's env_script"],
    ['OPENSPEC_STRICT_TOOLCHAIN', '0', '1: verify fails when a tool version differs from the release'],
    ['JEV_DISABLED', '0', '1: every Jev gate off'],
    ['JEV_REQUIRED', '0', '1: the preflight fails when Jev does not answer'],
    ['JEV_MODEL', 'model of config/jev_policy.yaml', 'the Jev model'],
    ['CLAUDE_ALLOWED_TOOLS, CLAUDE_DISALLOWED_TOOLS, COPILOT_DENIED_TOOLS', "the kit's lists (bin/agent_exec.sh)", 'tool lists of Claude Code and Copilot']
  ].freeze

  class Error < StandardError; end

  module_function

  def path(file) = File.join(ROOT, FILES.fetch(file))

  def load_yaml(file)
    full = path(file)
    return nil unless File.exist?(full)

    YAML.safe_load_file(full) || {}
  end

  def read_json(path)
    JSON.parse(File.read(path))
  rescue Errno::ENOENT, JSON::ParserError
    nil
  end

  def git(*args, chdir: ROOT)
    out, status = Open3.capture2e('git', *args, chdir: chdir)
    status.success? ? out.rstrip : nil
  end

  def find(key) = SETTINGS.find { |s| s['key'] == key }

  def keys_of(key) = key.split('.')

  def value_at(data, key)
    keys_of(key).drop(1).reduce(data) { |node, k| node.is_a?(Hash) ? node[k] : nil }
  end

  def placeholder?(value) = value.to_s.include?('{{')

  # Child repositories: the submodules under repos/.
  def child_paths
    out = git('config', '-f', '.gitmodules', '--get-regexp', '^submodule\..*\.path$')
    out.to_s.lines.map { |l| l.split[1] }.compact.select { |p| p.start_with?('repos/') }
  end

  # ------------------------------------------------------------------ show

  def describe(setting, data)
    value = value_at(data, setting['key'])
    var = setting['type'] == :pipeline ? OpenSpecSettings::KEYS.fetch(setting['key'].delete_prefix('pipeline.')).first : nil
    { 'key' => setting['key'], 'value' => value.nil? ? setting['default'] : value, 'default' => setting['default'],
      'set' => !value.nil?, 'values' => setting['values'], 'means' => setting['means'],
      'read_by' => setting['read_by'], 'change' => setting['change'],
      'overridden_by' => var && !ENV[var].to_s.empty? ? "#{var}=#{ENV[var]}" : nil }
  end

  def strategies_view(cycle)
    list = Array(load_yaml('exploration')&.fetch('strategies', nil)).select { |s| s.is_a?(Hash) }
    enabled = CyclePrompt.strategies(cycle)
    browser = enabled.select { |s| CyclePrompt.needs_browser?(s) }
    headless = CyclePrompt.headless(enabled, cycle)
    order = load_yaml('exploration')&.fetch('order', nil) || 'rotation'
    nxt = lambda do |pool, state|
      next nil if pool.empty?
      next 'random' if order == 'random'

      pool[(read_json(File.join(ROOT, 'log', 'cycle', state)) || {})['next'].to_i % pool.size]['slug']
    end
    {
      'next_cycle' => nxt.call(headless, 'strategy_state.json'),
      'next_visual' => CyclePrompt.visual_qa?(cycle) ? nxt.call(browser, 'visual_strategy_state.json') : nil,
      'strategies' => list.map do |s|
        { 'slug' => s['slug'], 'name' => s['name'], 'kind' => s['kind'], 'needs' => s['needs'],
          'enabled' => s['enabled'] != false,
          'runs_in' => if s['enabled'] == false then 'nowhere (disabled)'
                       elsif CyclePrompt.needs_browser?(s) && CyclePrompt.visual_qa?(cycle) then 'the visual session'
                       else 'the headless cycle'
                       end }
      end
    }
  end

  def repo_view(rel)
    dir = File.join(ROOT, rel)
    cfg_file = File.join(dir, 'repo.config.yaml')
    cfg = File.exist?(cfg_file) ? (YAML.safe_load_file(cfg_file) || {}) : nil
    gates = (cfg&.fetch('gates', nil) || {}).to_h
    {
      'repo' => rel, 'config' => cfg ? 'repo.config.yaml' : nil, 'kind' => cfg&.fetch('kind', nil),
      'base_branch' => cfg && !placeholder?(cfg['base_branch']) && cfg['base_branch'].to_s != '' ? cfg['base_branch'] : nil,
      'env_script' => cfg&.fetch('env_script', nil).to_s.strip,
      'dev_command' => cfg&.dig('service', 'dev_command'),
      'gates' => gates.transform_values { |c| c.to_s.strip.empty? || placeholder?(c) ? 'skipped' : c.to_s },
      'regression' => (cfg&.fetch('regression', nil) || {}).to_h.reject { |_, c| c.to_s.strip.empty? || placeholder?(c) }
    }
  rescue Psych::Exception => e
    { 'repo' => rel, 'error' => "repo.config.yaml is not valid YAML: #{e.message}" }
  end

  def env_view
    ENV_KNOBS.map do |names, default, means|
      set = names.split(', ').filter_map { |n| "#{n}=#{ENV[n]}" if ENV[n] }
      { 'variables' => names, 'default' => default, 'means' => means, 'set_now' => set }
    end
  end

  def show(topic)
    cycle = load_yaml('cycle') || {}
    out = {}
    FILES.each_key do |file|
      next unless topic.nil? || topic == file

      data = load_yaml(file)
      out[file] = { 'file' => FILES[file], 'about' => ABOUT[file], 'present' => !data.nil?,
                    'settings' => SETTINGS.select { |s| s['key'].start_with?("#{file}.") }.map { |s| describe(s, data || {}) } }
    end
    out['exploration'].merge!(strategies_view(cycle)) if out['exploration']
    if out['jev']
      out['jev']['jev_cli'] = system('command -v jev >/dev/null 2>&1') ? 'installed' : 'not installed'
      out['jev']['jev_disabled'] = ENV['JEV_DISABLED'] == '1'
    end
    out['repos'] = child_paths.map { |rel| repo_view(rel) } if topic.nil? || topic == 'repos'
    out['prompts'] = prompts_view if topic.nil? || topic == 'prompts'
    out['env'] = env_view if topic.nil? || topic == 'env'
    out
  end

  def format_value(value)
    case value
    when nil then '(none)'
    when Array
      if value.all?(Hash) && value.any? then "#{value.size} item(s)"
      elsif value.all?(String) then "[#{value.join(', ')}]"
      else value.to_json
      end
    when String then value.empty? ? '""' : value
    else value.to_json
    end
  end

  def show_text(view)
    lines = []
    FILES.each_key do |file|
      next unless (v = view[file])

      lines << "== #{v['file']}: #{v['about']}#{v['present'] ? '' : ' (MISSING)'}"
      v['settings'].each do |s|
        name = s['key'].delete_prefix("#{file}.")
        choices = s['values'] ? "  [#{s['values'].join(' | ')}]" : ''
        override = s['overridden_by'] ? "  (#{s['overridden_by']} overrides it in this shell)" : ''
        lines << "  #{name}: #{format_value(s['value'])}#{s['set'] ? '' : ' (default)'}#{choices}#{override}"
        lines << "      #{s['means']}; read by #{s['read_by']}"
        lines << "      change: #{s['change']}" if s['change']
      end
      next unless file == 'exploration'

      lines << "  next strategy: cycle #{v['next_cycle'] || 'none'}, visual session #{v['next_visual'] || 'none'}"
      width = v['strategies'].map { |s| s['slug'].to_s.size }.max.to_i
      v['strategies'].each do |s|
        lines << "    #{s['slug'].to_s.ljust(width)}  #{s['kind'].to_s.ljust(12)}  #{s['runs_in']}: #{s['name']}"
      end
    end
    if view['jev']
      lines << "  jev CLI: #{view['jev']['jev_cli']}#{view['jev']['jev_disabled'] ? '; JEV_DISABLED=1: every gate off' : ''}"
    end
    if view['repos']
      lines << '== repos/<name>/repo.config.yaml: each child repository, in its own repository'
      lines << '  no child repository yet (the openspec-kit-init skill adds them)' if view['repos'].empty?
      view['repos'].each do |r|
        if r['error']
          lines << "  #{r['repo']}: #{r['error']}"
        elsif r['config'].nil?
          lines << "  #{r['repo']}: no repo.config.yaml (no gates; base branch from .gitmodules or main)"
        else
          gates = r['gates'].map { |name, cmd| cmd == 'skipped' ? "#{name} (skipped)" : name }.join(', ')
          lines << "  #{r['repo']} (#{r['kind'] || 'kind unset'}): base #{r['base_branch'] || '(from .gitmodules or main)'}, env_script " \
                   "#{r['env_script'].empty? ? 'none' : r['env_script']}, dev #{format_value(r['dev_command'])}, " \
                   "gates #{gates.empty? ? 'none' : gates}, regression #{r['regression'].empty? ? 'the gates' : r['regression'].keys.join(', ')}"
        end
      end
    end
    if view['prompts']
      lines << "== #{OpenSpecPrompts::DIR}/: the agents' prompts, this application's own (edit, then commit)"
      view['prompts'].each do |p|
        uses = if !p['present'] then 'MISSING'
               elsif p['placeholders'].empty? then 'no placeholders'
               else p['placeholders'].map { |x| "{{#{x}}}" }.join(', ')
               end
        lines << "  #{p['file']}: #{uses}#{p['edited'] ? ' (edited)' : ''}"
        lines << "    #{p['for']}"
      end
    end
    if view['env']
      lines << '== Environment: overrides for one manual run, never in a scheduled command'
      view['env'].each do |e|
        now = e['set_now'].empty? ? '' : "  NOW: #{e['set_now'].join(' ')}"
        lines << "  #{e['variables']}#{e['default'] ? " (default #{e['default']})" : ''}: #{e['means']}#{now}"
      end
    end
    lines.join("\n")
  end

  PROMPT_ROLES = {
    'plan' => 'the PLAN agent: writes the OpenSpec change of each backlog item (bin/openspec_dispatcher.rb)',
    'build' => 'the BUILD agent: implements its tasks in the child repositories (bin/openspec_dispatcher.rb)',
    'cycle' => "the cycle's judgment; bin/cycle_prompt.rb appends \"This cycle\" (bin/run_cycle.sh)"
  }.freeze

  # Each prompt, the placeholders it uses and whether it differs from what the kit installed.
  def prompts_view
    lock = (JSON.parse(File.read(File.join(ROOT, '.openspec-kit.lock'))) rescue {})
    OpenSpecPrompts::PLACEHOLDERS.keys.map do |name|
      rel = "#{OpenSpecPrompts::DIR}/#{name}.md"
      path = File.join(ROOT, rel)
      present = File.file?(path)
      sha = lock.dig('files', rel, 'sha256')
      { 'file' => rel, 'for' => PROMPT_ROLES.fetch(name), 'present' => present,
        'placeholders' => present ? OpenSpecPrompts.placeholders(ROOT, name) : [],
        'edited' => present && !sha.nil? && Digest::SHA256.file(path).hexdigest != sha }
    end
  end

  # ------------------------------------------------------------------ check

  def type_problem(setting, value)
    case setting['type']
    when :int then 'must be a whole number >= 0' unless value.is_a?(Integer) && value >= 0
    when :bool then 'must be true or false' unless [true, false].include?(value)
    when :enum
      return if setting['values'].include?(value)

      quote = [true, false].include?(value) ? ' (YAML reads off, on, yes and no as true or false: quote it, "off")' : ''
      "must be one of #{setting['values'].join(', ')}#{quote}"
    when :agents
      list = OpenSpecAgents.names(value)
      "must list agents among #{OpenSpecAgents::SUPPORTED.keys.join(', ')}" if list.empty? || (list - OpenSpecAgents::SUPPORTED.keys).any?
    when :string, :path then 'must be text' unless value.is_a?(String)
    when :list then 'must be a list' unless value.is_a?(Array)
    when :pipeline
      key = setting['key'].delete_prefix('pipeline.')
      "must be #{OpenSpecSettings.expected(key)}" if OpenSpecSettings.parse(key, value).nil?
    end
  end

  # Leaf keys of a mapping, as dotted paths; lists and their items count as leaves.
  def leaf_keys(data, prefix)
    return [prefix] unless data.is_a?(Hash) && !data.empty?

    data.flat_map { |k, v| leaf_keys(v, "#{prefix}.#{k}") }
  end

  def check_settings(file, data, report)
    SETTINGS.select { |s| s['key'].start_with?("#{file}.") }.each do |s|
      value = value_at(data, s['key'])
      next if value.nil?

      problem = type_problem(s, value)
      report[:errors] << "#{s['key'].delete_prefix("#{file}.")}: #{problem} (is #{value.inspect})" if problem
    end
    return unless %w[agents pipeline cycle].include?(file)

    known = SETTINGS.map { |s| s['key'] }
    leaf_keys(data, file).each do |key|
      next if known.include?(key) || known.any? { |k| key.start_with?("#{k}.") || k.start_with?("#{key}.") }

      report[:warnings] << "#{key.delete_prefix("#{file}.")}: no script reads it (a typo?)"
    end
  end

  def check_agents(data, report)
    agents = Array(data['agents']).map(&:to_s)
    report[:errors] << 'agents: none listed' if agents.empty?
    unknown = agents - OpenSpecAgents::SUPPORTED.keys
    report[:errors] << "agents: unknown #{unknown.join(', ')}" if unknown.any?
    OpenSpecAgents::ROLES.each_key do |role|
      list = OpenSpecAgents.names(data.dig('roles', role))
      if list.empty?
        report[:warnings] << "roles.#{role}: not set; the first agent CLI on PATH runs it"
        next
      end
      outside = (list & OpenSpecAgents::SUPPORTED.keys) - agents
      next if outside.empty?

      report[:warnings] << "roles.#{role}: #{outside.join(', ')} not among the agents, so without skills here: " \
                           '<release>/bin/install.sh upgrade <app> --agents ... adds it'
    end
  end

  def check_cycle(data, report, jev)
    OpenSpecMemory.over_cap(ROOT).each do |name, chars, cap|
      report[:warnings] << "memory: #{name} holds #{chars} characters, over its cap of #{cap}; the next cycle is told to trim it first"
    end
    file = data.dig('roadmap', 'file').to_s
    full = File.join(ROOT, file)
    if !file.empty? && !File.file?(full)
      report[:warnings] << "roadmap.file: #{file} does not exist; the cycle proposes nothing from a roadmap"
    elsif !file.empty? && File.read(full).include?('{{')
      report[:warnings] << "roadmap.file: #{file} still has {{...}} placeholders; the cycle proposes nothing from it until they are filled"
    end
    approval = data.dig('proposals', 'approval') || 'jev'
    return unless approval == 'jev'

    mode = ENV['JEV_DISABLED'] == '1' ? 'off' : jev&.dig('gates', 'proposal_review', 'mode') || 'off'
    if mode != 'enforce'
      report[:warnings] << "proposals.approval: jev, but gate proposal_review is #{mode}: every proposal waits for a human"
    elsif !system('command -v jev >/dev/null 2>&1')
      report[:warnings] << 'proposals.approval: jev, but the jev CLI is not installed: every proposal waits for a human'
    end
  end

  def check_exploration(data, report, cycle)
    list = data['strategies']
    return report[:errors] << 'strategies: must be a list' unless list.is_a?(Array)

    seen = []
    list.each_with_index do |s, i|
      at = "strategies[#{i}]#{s.is_a?(Hash) && s['slug'] ? " (#{s['slug']})" : ''}"
      next report[:errors] << "#{at}: must be a mapping" unless s.is_a?(Hash)

      slug = s['slug'].to_s
      if slug.empty? then report[:errors] << "#{at}: no slug; the scripts skip it"
      elsif seen.include?(slug) then report[:errors] << "#{at}: slug used twice"
      elsif !slug.match?(CHANGE_NAME) then report[:warnings] << "#{at}: slug should be kebab-case"
      end
      seen << slug
      report[:errors] << "#{at}: kind must be one of #{KINDS.join(', ')}" unless KINDS.include?(s['kind'])
      report[:errors] << "#{at}: no directive" if s['directive'].to_s.strip.empty?
      report[:warnings] << "#{at}: no name" if s['name'].to_s.strip.empty?
      report[:errors] << "#{at}: needs must be browser or absent" unless [nil, 'browser'].include?(s['needs'])
      report[:errors] << "#{at}: enabled must be true or false" unless [nil, true, false].include?(s['enabled'])
    end
    enabled = list.select { |s| s.is_a?(Hash) && s['slug'] && s['enabled'] != false }
    return report[:warnings] << 'strategies: none enabled; the cycle only runs its regression sweep' if enabled.empty?

    browser = enabled.select { |s| s['needs'] == 'browser' }
    if cycle.dig('visual_qa', 'enabled') == true
      report[:warnings] << 'strategies: every enabled one needs a browser; the headless cycle explores none' if browser.size == enabled.size
    elsif browser.any?
      report[:warnings] << "strategies: #{browser.map { |s| s['slug'] }.join(', ')} need a browser but visual_qa " \
                           'is off: the headless cycle explores them without one'
    end
  end

  def check_jev(data, report)
    model = data['model'].to_s
    report[:warnings] << 'model: pin a versioned id (for example jev-1.14.0), not latest' if model.empty? || model.include?('latest')
    band = data['abstain_band']
    unless band.nil? || (band.is_a?(Array) && band.size == 2 && band.all?(Numeric) && band[0] < band[1] && band.all? { |x| x.between?(0, 1) })
      report[:errors] << 'abstain_band: must be [low, high] between 0 and 1'
    end
    gates = data['gates'].is_a?(Hash) ? data['gates'] : {}
    gates.each do |name, cfg|
      next report[:warnings] << "gates.#{name}: no script asks this gate" unless GATES.key?(name)
      next report[:errors] << "gates.#{name}: must be a mapping" unless cfg.is_a?(Hash)

      mode = cfg['mode'] || 'off'
      file = cfg['file'].to_s
      next if mode == 'off' || (!file.empty? && File.file?(File.join(ROOT, file)))

      report[:errors] << "gates.#{name}.file: #{file.empty? ? 'missing' : "#{file} does not exist"}"
    end
    active = gates.select { |name, cfg| GATES.key?(name) && cfg.is_a?(Hash) && cfg['mode'].to_s != 'off' && cfg['mode'] }
    return if active.empty?

    if ENV['JEV_DISABLED'] == '1'
      report[:warnings] << 'JEV_DISABLED=1 in this environment: every gate is off for commands run from it'
    elsif !system('command -v jev >/dev/null 2>&1')
      outcome = data['on_unavailable'] == 'block' ? 'enforce gates quarantine changes and pause the system' : 'the gates are skipped'
      report[:warnings] << "jev CLI not installed: #{outcome} (on_unavailable: #{data['on_unavailable'] || 'skip'})"
    end
  end

  def check_backlog(report)
    file = 'config/agent_backlog.json'
    items = read_json(File.join(ROOT, file))
    return report[:errors] << 'missing or not valid JSON' if items.nil?
    return report[:errors] << 'must be a JSON list' unless items.is_a?(Array)

    names = items.map { |i| i.is_a?(Hash) ? i['change_name'].to_s : '' }
    items.each_with_index do |item, i|
      name = names[i]
      at = name.empty? ? "item #{i}" : name
      next report[:errors] << "item #{i}: must be an object" unless item.is_a?(Hash)

      report[:errors] << "#{at}: change_name must be kebab-case (a-z, 0-9, -); the dispatcher skips it" unless name.match?(CHANGE_NAME)
      report[:errors] << "#{at}: listed twice" if names.count(name) > 1 && names.index(name) == i
      report[:warnings] << "#{at}: priority #{item['priority'].inspect} is read as normal" unless item['priority'].nil? || PRIORITIES.include?(item['priority'])
      report[:warnings] << "#{at}: no description" if item['description'].to_s.strip.empty?
      missing = Array(item['depends_on']) - names
      report[:warnings] << "#{at}: depends on #{missing.join(', ')}, not in the backlog (fine if already archived)" if missing.any?
    end
  end

  def check_proposals(report)
    items = read_json(File.join(ROOT, 'config/agent_proposals.json'))
    return report[:errors] << 'missing or not valid JSON' if items.nil?
    return report[:errors] << 'must be a JSON list' unless items.is_a?(Array)

    items.each_with_index do |item, i|
      next report[:errors] << "item #{i}: must be an object" unless item.is_a?(Hash)

      at = item['change_name'] || "item #{i}"
      report[:errors] << "#{at}: change_name must be kebab-case" unless item['change_name'].to_s.match?(CHANGE_NAME)
      report[:errors] << "#{at}: status must be one of #{STATUSES.join(', ')}" unless STATUSES.include?(item['status'])
      next unless item['kind'] == 'prompt'

      unless OpenSpecPrompts::PLACEHOLDERS.key?(item['prompt'].to_s)
        report[:errors] << "#{at}: prompt must be one of #{OpenSpecPrompts::PLACEHOLDERS.keys.join(', ')}"
      end
      edits = item['edits']
      unless edits.is_a?(Array) && edits.any? && edits.all? { |e| e.is_a?(Hash) && e['old'].is_a?(String) && !e['old'].empty? && e['new'].is_a?(String) }
        report[:errors] << "#{at}: edits must be a list of {old, new} texts"
      end
      report[:warnings] << "#{at}: a prompt edit waits for a human: ruby bin/proposals.rb show #{at}" if item['status'] == 'proposed'
    end
  end

  # Problems of one child repository's repo.config.yaml, shared with bin/app_setup.rb.
  def repo_problems(rel)
    dir = File.join(ROOT, rel)
    report = { errors: [], warnings: [] }
    unless File.directory?(dir) && !Dir.empty?(dir)
      report[:warnings] << 'not checked out: git submodule update --init'
      return report
    end
    cfg_file = File.join(dir, 'repo.config.yaml')
    unless File.exist?(cfg_file)
      report[:warnings] << 'no repo.config.yaml: no gates run, base branch from .gitmodules or main ' \
                           "(ruby bin/app_setup.rb repo #{File.basename(rel)} writes one)"
      return report
    end
    begin
      cfg = YAML.safe_load_file(cfg_file) || {}
    rescue Psych::Exception => e
      report[:errors] << "repo.config.yaml is not valid YAML: #{e.message}"
      return report
    end
    left = leaf_keys(cfg, 'cfg').select { |k| placeholder?(cfg.dig(*k.split('.').drop(1))) }.map { |k| k.delete_prefix('cfg.') }
    report[:warnings] << "placeholders left: #{left.join(', ')}" if left.any?
    kind = cfg['kind']
    unless kind.nil? || placeholder?(kind) || %w[web cli].include?(kind)
      report[:warnings] << "kind #{kind.inspect}: web or cli (QA opens a web application in a browser and runs a cli)"
    end
    script = cfg['env_script'].to_s.strip
    report[:errors] << "env_script #{script} does not exist: every command of the repository fails" if !script.empty? && !File.file?(File.join(dir, script))
    gates = (cfg['gates'] || {}).to_h.reject { |_, c| c.to_s.strip.empty? || placeholder?(c) }
    report[:warnings] << 'no gate set: changes to it merge untested' if gates.empty?
    report[:warnings] << 'no test gate' if gates.any? && !gates.key?('test')
    report
  end

  def kit_drift
    out, status = Open3.capture2e('ruby', File.join(ROOT, 'bin', 'openspec_kit.rb'), 'verify', ROOT)
    status.success? ? nil : out.strip.lines.first.to_s.strip
  end

  def check
    files = {}
    cycle = load_yaml('cycle') || {}
    jev = nil
    begin
      jev = load_yaml('jev')
    rescue Psych::Exception
      jev = nil
    end
    FILES.each_key do |file|
      report = files[FILES[file]] = { errors: [], warnings: [] }
      begin
        data = load_yaml(file)
      rescue Psych::Exception => e
        report[:errors] << "not valid YAML: #{e.message}"
        next
      end
      next report[:errors] << 'missing' if data.nil?
      next report[:errors] << 'must be a mapping' unless data.is_a?(Hash)

      check_settings(file, data, report)
      case file
      when 'agents' then check_agents(data, report)
      when 'cycle' then check_cycle(data, report, jev)
      when 'exploration' then check_exploration(data, report, cycle)
      when 'jev' then check_jev(data, report)
      end
    end
    check_backlog(files['config/agent_backlog.json'] = { errors: [], warnings: [] })
    check_proposals(files['config/agent_proposals.json'] = { errors: [], warnings: [] })
    files["#{OpenSpecPrompts::DIR}/"] = OpenSpecPrompts.problems(ROOT)
    child_paths.each { |rel| files["#{rel}/repo.config.yaml"] = repo_problems(rel) }
    files['application'] = application_problems
    files
  end

  def application_problems
    report = { errors: [], warnings: [] }
    drift = kit_drift
    report[:errors] << "kit files edited in place (#{drift}): bash bin/install.sh verify" if drift
    pending = Dir.glob(File.join(ROOT, '{*.md,config/*,config/prompts/*}.new')).map { |f| f.delete_prefix("#{ROOT}/") }
    report[:warnings] << "an upgrade left #{pending.join(', ')}: merge what you need into the file, then delete it" if pending.any?
    outside = git('status', '--porcelain', '--ignore-submodules=all', '--', '.', *SCOPE.map { |p| ":!#{p}" })
    if outside && !outside.empty?
      files = outside.lines.map { |l| l[3..].strip }
      report[:warnings] << "uncommitted outside the cycle's write scope: #{files.first(8).join(', ')}#{files.size > 8 ? ', ...' : ''}; " \
                           'the next cycle or visual session pauses the system (scope guard) until they are committed'
    end
    base = OpenSpecSettings.get(ROOT, 'base_branch')
    if git('remote').to_s.split.include?('origin') && git('rev-parse', '--verify', '--quiet', "origin/#{base}").nil?
      current = git('symbolic-ref', '--short', 'HEAD')
      report[:warnings] << "origin has no branch #{base} (pipeline.base_branch): push it, or ruby bin/kit_config.rb set " \
                           "pipeline.base_branch #{current || '<branch>'}"
    end
    OpenSpecSettings::KEYS.each do |key, (var, _)|
      report[:warnings] << "#{var}=#{ENV[var]} in this environment overrides pipeline.#{key} for commands run from it" unless ENV[var].to_s.empty?
    end
    report
  end

  def check_text(files)
    lines = []
    files.each do |name, r|
      state = if r[:errors].any? then "#{r[:errors].size} error(s)"
              elsif r[:warnings].any? then "#{r[:warnings].size} warning(s)"
              else 'ok'
              end
      lines << "#{name}: #{state}"
      r[:errors].each { |e| lines << "  ERROR #{e}" }
      r[:warnings].each { |w| lines << "  WARN  #{w}" }
    end
    errors = files.values.sum { |r| r[:errors].size }
    warnings = files.values.sum { |r| r[:warnings].size }
    lines << (errors.zero? ? "config: OK (#{warnings} warning(s))" : "config: FAIL (#{errors} error(s), #{warnings} warning(s))")
    lines.join("\n")
  end

  # ------------------------------------------------------------------ set

  def parse_value(setting, text, data)
    value = case setting['type']
            when :int then Integer(text, 10)
            when :bool then { 'true' => true, 'false' => false }.fetch(text)
            when :pipeline then OpenSpecSettings.parse(setting['key'].delete_prefix('pipeline.'), text) || text
            when :agents then OpenSpecAgents.names(text)
            else text
            end
    problem = type_problem(setting, value)
    raise Error, "#{setting['key']} #{problem}" if problem

    stray = setting['type'] == :agents ? value - Array(data['agents']).map(&:to_s) : []
    if stray.any?
      raise Error, "#{stray.join(', ')} not among the agents of config/agents.yaml (#{Array(data['agents']).join(', ')}); " \
                   'add it first with <release>/bin/install.sh upgrade <app> --agents ..., which installs its skills'
    end
    value
  rescue ArgumentError, KeyError
    raise Error, "#{setting['key']} #{type_problem(setting, nil)}, not #{text.inspect}"
  end

  def literal(value, old_text)
    return "[#{value.join(', ')}]" if value.is_a?(Array)
    return value.to_s unless value.is_a?(String)
    return value.to_json if old_text.to_s.start_with?('"', "'") || value.empty?

    plain = value.match?(%r{\A[A-Za-z0-9_./-]+\z}) && YAML.safe_load(value) == value
    plain ? value : value.to_json
  end

  def content?(line) = !line.strip.empty? && !line.lstrip.start_with?('#')

  def indent(line) = line[/\A */].size

  # The line of a dotted key in a block-style YAML text, or where to insert it.
  def locate(lines, keys)
    from = 0
    to = lines.size
    parent_indent = -1
    keys.each_with_index do |key, depth|
      child_indent = (from...to).map { |i| lines[i] }.find { |l| content?(l) }&.then { |l| indent(l) }
      found = child_indent && (from...to).find do |i|
        content?(lines[i]) && indent(lines[i]) == child_indent && lines[i].match?(/\A *#{Regexp.escape(key)}:(\s|$)/)
      end
      unless found
        return nil unless depth == keys.size - 1

        last = (from...to).select { |i| content?(lines[i]) }.last || (from - 1)
        return { insert_after: last, indent: child_indent || (parent_indent + 2) }
      end
      return { line: found } if depth == keys.size - 1

      parent_indent = indent(lines[found])
      from = found + 1
      to = (from...lines.size).find { |i| content?(lines[i]) && indent(lines[i]) <= parent_indent } || lines.size
    end
  end

  def set(key, text, dry_run: false)
    setting = find(key)
    raise Error, "#{key} is not a setting; ruby bin/kit_config.rb show lists them" unless setting
    raise Error, "#{key} is a list: #{setting['change']}" if setting['type'] == :list

    file = keys_of(key).first
    full = path(file)
    raise Error, "#{FILES[file]} does not exist" unless File.exist?(full)

    before = YAML.safe_load_file(full) || {}
    value = parse_value(setting, text, before)
    old = value_at(before, key)
    return puts("#{FILES[file]}: #{key.delete_prefix("#{file}.")} is already #{format_value(value)}") if old == value && !old.nil?

    lines = File.read(full).lines
    keys = keys_of(key).drop(1)
    spot = locate(lines, keys) || raise(Error, "cannot find where #{key} goes in #{FILES[file]}; edit it by hand")
    if spot[:line]
      match = lines[spot[:line]].match(/\A(?<head> *[^:#]+:[ \t]*)(?<value>.*?)(?<tail>[ \t]+#.*)?(?<eol>\r?\n)?\z/)
      lines[spot[:line]] = "#{match[:head]}#{literal(value, match[:value])}#{match[:tail]}#{match[:eol] || "\n"}"
    else
      lines.insert(spot[:insert_after] + 1, "#{' ' * spot[:indent]}#{keys.last}: #{literal(value, nil)}\n")
    end
    after_text = lines.join
    after = begin
      YAML.safe_load(after_text) || {}
    rescue Psych::Exception
      raise Error, "editing #{key} would break #{FILES[file]}; edit it by hand"
    end
    expected = Marshal.load(Marshal.dump(before))
    target = keys[0..-2].reduce(expected) { |h, k| h[k] ||= {} }
    target[keys.last] = value
    raise Error, "editing #{key} would change more than that setting; edit #{FILES[file]} by hand" unless after == expected

    report = { errors: [], warnings: [] }
    check_settings(file, after, report)
    check_agents(after, report) if file == 'agents'
    raise Error, "#{key} = #{format_value(value)} would make #{FILES[file]} invalid: #{report[:errors].join('; ')}" if report[:errors].any?

    change = "#{FILES[file]}: #{key.delete_prefix("#{file}.")} #{format_value(old.nil? ? setting['default'] : old)} -> #{format_value(value)}"
    return puts("would change #{change}") if dry_run

    File.write(full, after_text)
    puts "changed #{change}"
    puts "takes effect on the next run of #{setting['read_by']}. Commit and push it before the next cycle: an " \
         "uncommitted change outside the cycle's write scope pauses the system (git add #{FILES[file]} && git commit && git push)."
  end
end

if __FILE__ == $PROGRAM_NAME
  usage = "Usage: ruby bin/kit_config.rb show [agents|pipeline|cycle|exploration|jev|repos|prompts|env] [--json]\n" \
          "       ruby bin/kit_config.rb check [--json]\n" \
          '       ruby bin/kit_config.rb set <file>.<key> <value> [--dry-run]'
  # Flags by hand: a value given to set may start with a dash.
  args = ARGV.dup
  json = !args.delete('--json').nil?
  dry_run = !args.delete('--dry-run').nil?
  begin
    case args
    in ['show', *topic] if topic.size <= 1 && (topic.empty? || (KitConfig::FILES.keys + %w[repos prompts env]).include?(topic.first))
      view = KitConfig.show(topic.first)
      puts(json ? JSON.pretty_generate(view) : KitConfig.show_text(view))
    in ['check']
      files = KitConfig.check
      puts(json ? JSON.pretty_generate(files) : KitConfig.check_text(files))
      exit(files.values.any? { |r| r[:errors].any? } ? 1 : 0)
    in ['set', key, value]
      KitConfig.set(key, value, dry_run: dry_run)
    else
      warn usage
      exit 2
    end
  rescue KitConfig::Error, Psych::Exception => e
    warn "kit_config: #{e.message}"
    exit 1
  end
end
