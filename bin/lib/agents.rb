# frozen_string_literal: true

# ==============================================================================
# bin/lib/agents.rb
#
# The agent CLIs the kit can drive, and the selection an application made when
# it installed the kit (config/agents.yaml): the agents it uses and the one that
# runs each role. Scripts read the selection here, so a scheduled task never
# passes it: its prompt is always the same command.
#
#   ruby bin/lib/agents.rb engine <plan|build|cycle>   # the engine of a role
#   ruby bin/lib/agents.rb list                        # the selected agents
#   ruby bin/lib/agents.rb permissions                 # all | restricted
#
# AGENT_ENGINE_PLAN, AGENT_ENGINE_BUILD, AGENT_ENGINE_CYCLE and AGENT_ENGINE
# override the selection for one run (tests, a manual retry with another agent),
# and AGENT_PERMISSIONS the permissions.
# ==============================================================================

require 'yaml'

module OpenSpecAgents
  # name => the `openspec init --tools` id and the directory its skills live in.
  SUPPORTED = {
    'claude' => { 'tool' => 'claude', 'skills' => '.claude/skills' },
    'codex' => { 'tool' => 'codex', 'skills' => '.agents/skills' },
    'copilot' => { 'tool' => 'github-copilot', 'skills' => '.github/skills' },
    'hermes' => { 'tool' => 'hermes', 'skills' => '.hermes/skills' },
    'opencode' => { 'tool' => 'opencode', 'skills' => '.opencode/skills' }
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

  # { 'agents' => [...], 'roles' => { role => agent }, 'permissions' => ... }, or nil without a config.
  def load(root)
    path = File.join(root, CONFIG)
    return nil unless File.exist?(path)

    data = YAML.safe_load_file(path) || {}
    agents = Array(data['agents']).map(&:to_s)
    roles = (data['roles'] || {}).to_h { |role, agent| [role.to_s, agent.to_s] }
    { 'agents' => agents, 'roles' => roles, 'permissions' => data['permissions']&.to_s }
  end

  # What agents may do: AGENT_PERMISSIONS, then config/agents.yaml, then all. An
  # unknown value is read as restricted, the safer side.
  def permissions(root, env = ENV)
    value = env['AGENT_PERMISSIONS'] || load(root)&.fetch('permissions') || DEFAULT_PERMISSIONS
    return value if PERMISSIONS.include?(value)

    warn "agents: unknown permissions #{value.inspect} (#{PERMISSIONS.join(' | ')}); using restricted"
    'restricted'
  end

  # The engine of a role: an environment override, then the selection. nil when
  # neither names one; agent_exec.sh then takes the first agent on PATH.
  def engine(root, role, env = ENV)
    raise Error, "unknown role #{role} (roles: #{ROLES.keys.join(', ')})" unless ROLES.key?(role)

    env["AGENT_ENGINE_#{role.upcase}"] || env['AGENT_ENGINE'] || load(root)&.dig('roles', role)
  end

  # Rewrites the file with these agents and roles; the permissions already set are kept.
  def write(root, agents, roles)
    permissions = load(root)&.fetch('permissions') || DEFAULT_PERMISSIONS
    lines = ['# The agents this application uses, written by install.sh (init, or upgrade --agents).',
             '# Each one gets the skills in its own directory. The scripts read the roles from here,',
             '# so the scheduled task always runs the same command. Change the agents with',
             '# `<release>/bin/install.sh upgrade <app> --agents ...`; a role and the permissions may be edited by hand.',
             "agents: [#{agents.join(', ')}]",
             'roles:']
    width = ROLES.keys.map(&:size).max
    ROLES.each { |role, does| lines << "  #{"#{role}:".ljust(width + 1)} #{roles.fetch(role).ljust(8)} # #{does}" }
    lines.push('# all: agents may run any command (servers, curl, browsers, test tools), except the git',
               '# commands only the scripts run (commit, push, rebase, reset, checkout, switch).',
               '# restricted: Claude Code may only read, edit, run openspec, inspect git, run the gates',
               '# and ask Jev; Codex keeps its workspace sandbox. Hermes, Copilot and OpenCode ignore it.',
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
    else
      warn 'Usage: ruby bin/lib/agents.rb engine <plan|build|cycle> | list | permissions'
      exit 2
    end
  rescue OpenSpecAgents::Error => e
    warn "agents: #{e.message}"
    exit 1
  end
end
