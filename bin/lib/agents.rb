# frozen_string_literal: true

# ==============================================================================
# bin/lib/agents.rb
#
# The agent CLIs the kit can drive, and the selection an application made when
# it installed the kit (config/agents.yaml): the agents it uses and, for each
# role, the agents that run it in order of preference. bin/agent_exec.sh tries
# them in that order: one that fails (out of quota, not logged in, timed out) is
# tried again limits.agent_retries times, then the next one runs, told what the
# failed attempts left so it continues from there. With `order: random` each call
# starts with any agent of the role instead of the first, then the others in the
# order listed, so the calls spread over the agents' quotas. Scripts read the
# selection here, so a scheduled task never passes it: its prompt is always the
# same command.
#
#   ruby bin/lib/agents.rb engine <plan|build|cycle>   # the engines of a role: claude,hermes
#   ruby bin/lib/agents.rb list                        # the selected agents
#   ruby bin/lib/agents.rb order                       # fallback | random
#   ruby bin/lib/agents.rb permissions                 # all | restricted
#
# AGENT_ENGINE_PLAN, AGENT_ENGINE_BUILD, AGENT_ENGINE_CYCLE and AGENT_ENGINE
# (an agent or a comma list) override the selection for one run (tests, a manual
# retry with another agent), AGENT_ORDER the order and AGENT_PERMISSIONS the
# permissions.
# ==============================================================================

require 'yaml'

module OpenSpecAgents
  # name (the CLI's command) => the `openspec init --tools` id and the directory its skills live in.
  SUPPORTED = {
    'claude' => { 'tool' => 'claude', 'skills' => '.claude/skills' },
    'codex' => { 'tool' => 'codex', 'skills' => '.agents/skills' },
    'copilot' => { 'tool' => 'github-copilot', 'skills' => '.github/skills' },
    'hermes' => { 'tool' => 'hermes', 'skills' => '.hermes/skills' },
    'opencode' => { 'tool' => 'opencode', 'skills' => '.opencode/skills' },
    'agy' => { 'tool' => 'antigravity', 'skills' => '.agents/skills' }, # Google Antigravity's CLI
    'kilo' => { 'tool' => 'kilocode', 'skills' => '.kilocode/skills' }  # Kilo Code's CLI
  }.freeze
  ROLES = {
    'plan' => 'writes the OpenSpec artifacts of each backlog item',
    'build' => 'implements the tasks in the child repositories',
    'cycle' => 'runs the judgment of the scheduled cycle'
  }.freeze
  CONFIG = 'config/agents.yaml'
  # Every application gets the kit's skills here, the skills directory agents share;
  # the other selected agents get a copy in their own directory.
  DEFAULT_SKILLS = '.agents/skills'
  # all: agents may run any command (servers, curl, browsers, test tools) except the
  # git commands only the scripts run. restricted: Claude Code may only read, edit, run
  # openspec, inspect git, run the gates and ask Jev; Codex keeps its workspace sandbox.
  PERMISSIONS = %w[all restricted].freeze
  DEFAULT_PERMISSIONS = 'all'
  # fallback: every call starts with a role's first agent, the next running when one
  # fails. random: every call starts with any of them, then the others in the order
  # listed, so no agent's quota is drained first.
  ORDERS = %w[fallback random].freeze
  DEFAULT_ORDER = 'fallback'

  class Error < StandardError; end

  module_function

  # "hermes, opencode" -> ["hermes", "opencode"], in the given order, without duplicates.
  def parse(list)
    names = list.to_s.split(',').map(&:strip).reject(&:empty?).uniq
    raise Error, 'no agent given' if names.empty?

    unknown = names - SUPPORTED.keys
    raise Error, "unknown agent #{unknown.join(', ')} (supported: #{SUPPORTED.keys.join(', ')})" if unknown.any?

    names
  end

  def skills_dir(name) = SUPPORTED.fetch(name)['skills']

  # Where the kit's skills go for these agents: the shared directory, then theirs.
  def skills_dirs(agents) = ([DEFAULT_SKILLS] + agents.map { |agent| skills_dir(agent) }).uniq

  # The `openspec init --tools` ids for these agents, `agents` (the shared directory) first.
  def tools(agents) = (['agents'] + agents.map { |agent| tool(agent) }).uniq

  def tool(name) = SUPPORTED.fetch(name)['tool']

  # "claude, hermes", ["claude", "hermes"] or "claude" -> ["claude", "hermes"] / ["claude"].
  def names(value) = Array(value).flat_map { |v| v.to_s.split(',') }.map(&:strip).reject(&:empty?).uniq

  # { 'agents' => [...], 'roles' => { role => agent }, 'permissions' => ... }, or nil without a config.
  def load(root)
    path = File.join(root, CONFIG)
    return nil unless File.exist?(path)

    data = YAML.safe_load_file(path) || {}
    agents = Array(data['agents']).map(&:to_s)
    roles = (data['roles'] || {}).to_h { |role, list| [role.to_s, names(list)] }
    { 'agents' => agents, 'roles' => roles, 'permissions' => data['permissions']&.to_s, 'order' => data['order']&.to_s }
  end

  # How each call picks among a role's agents: AGENT_ORDER, then config/agents.yaml,
  # then fallback. An unknown value is read as fallback, the order the file lists.
  def order(root, env = ENV)
    value = env['AGENT_ORDER'] || load(root)&.fetch('order') || DEFAULT_ORDER
    return value if ORDERS.include?(value)

    warn "agents: unknown order #{value.inspect} (#{ORDERS.join(' | ')}); using fallback"
    'fallback'
  end

  # What agents may do: AGENT_PERMISSIONS, then config/agents.yaml, then all. An
  # unknown value is read as restricted, the safer side.
  def permissions(root, env = ENV)
    value = env['AGENT_PERMISSIONS'] || load(root)&.fetch('permissions') || DEFAULT_PERMISSIONS
    return value if PERMISSIONS.include?(value)

    warn "agents: unknown permissions #{value.inspect} (#{PERMISSIONS.join(' | ')}); using restricted"
    'restricted'
  end

  # The engines of a role, in order: an environment override, then the selection.
  # Empty when neither names one; agent_exec.sh then takes the first agent on PATH.
  def engines(root, role, env = ENV)
    raise Error, "unknown role #{role} (roles: #{ROLES.keys.join(', ')})" unless ROLES.key?(role)

    override = env["AGENT_ENGINE_#{role.upcase}"] || env['AGENT_ENGINE']
    override.to_s.empty? ? Array(load(root)&.dig('roles', role)) : names(override)
  end

  # The same as the comma list bin/agent_exec.sh takes, or nil.
  def engine(root, role, env = ENV) = engines(root, role, env).join(',').then { |list| list.empty? ? nil : list }

  # Rewrites the file with these agents and roles (role => engines in order); the
  # order and the permissions already set are kept unless an order is given.
  def write(root, agents, roles, order: nil)
    current = load(root)
    permissions = current&.fetch('permissions') || DEFAULT_PERMISSIONS
    order ||= current&.fetch('order') || DEFAULT_ORDER
    raise Error, "unknown order #{order} (#{ORDERS.join(', ')})" unless ORDERS.include?(order)
    lines = ['# The agents this application uses, written by install.sh (init, or upgrade --agents).',
             '# Each one gets the skills in its own directory. The scripts read the roles from here,',
             '# so the scheduled task always runs the same command. Change the agents with',
             '# `<release>/bin/install.sh upgrade <app> --agents ...`; a role, the order and the permissions may be edited by hand.',
             "agents: [#{agents.join(', ')}]",
             '# Each role lists its agents in order of preference. One that fails (out of quota, not',
             '# logged in, timed out) is tried again limits.agent_retries times (config/pipeline.yaml),',
             '# then the next one runs and continues from what the failed attempts left.',
             'roles:']
    width = ROLES.keys.map(&:size).max
    lists = roles.transform_values { |list| "[#{names(list).join(', ')}]" }
    pad = lists.values.map(&:size).max
    ROLES.each { |role, does| lines << "  #{"#{role}:".ljust(width + 1)} #{lists.fetch(role).ljust(pad)} # #{does}" }
    lines.push('# fallback: every call starts with the first agent of its role, then the next when one',
               '# fails. random: every call starts with any agent of its role, then the others in the',
               "# order listed, so the calls spread over the agents' quotas instead of draining the first.",
               "order: #{order}",
               '# all: agents may run any command (servers, curl, browsers, test tools), except the git',
               '# commands only the scripts run (commit, push, rebase, reset, checkout, switch).',
               '# restricted: Claude Code may only read, edit, run openspec, inspect git, run the gates',
               '# and ask Jev; Codex and Antigravity (agy) keep their sandbox; Kilo loses --auto. Hermes, Copilot and OpenCode ignore it.',
               "permissions: #{permissions}")
    path = File.join(root, CONFIG)
    File.write(path, "#{lines.join("\n")}\n")
  end
end

if __FILE__ == $PROGRAM_NAME
  root = File.expand_path('../..', __dir__)
  begin
    case ARGV
    in ['engine', role] then puts OpenSpecAgents.engine(root, role)
    in ['list'] then puts((OpenSpecAgents.load(root) || {}).fetch('agents', []).join(' '))
    in ['permissions'] then puts OpenSpecAgents.permissions(root)
    in ['order'] then puts OpenSpecAgents.order(root)
    else
      warn 'Usage: ruby bin/lib/agents.rb engine <plan|build|cycle> | list | order | permissions'
      exit 2
    end
  rescue OpenSpecAgents::Error => e
    warn "agents: #{e.message}"
    exit 1
  end
end
