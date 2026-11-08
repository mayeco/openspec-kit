# frozen_string_literal: true

# ==============================================================================
# bin/lib/settings.rb
#
# How the pipeline runs (config/pipeline.yaml): the base branch, the dispatch's
# parallelism and the limits of agent calls, gates and leases. Every script
# reads them here, so a scheduled task never passes one: its prompt is always the
# same command.
#
#   ruby bin/lib/settings.rb get <key>   # base_branch, dispatch.workers, limits.gate_seconds, ...
#
# An environment variable overrides a setting for one manual run (a test, a
# retry); its name is next to each key below. A missing file or key gives the
# default; an invalid value gives the default with a warning, so a typo never
# stops a scheduled run (bin/kit_config.rb check reports it).
# ==============================================================================

require 'yaml'

module OpenSpecSettings
  KIT_ROOT = File.expand_path('../..', __dir__)
  FILE = 'config/pipeline.yaml'
  # key => [the environment variable that overrides it, the default]
  KEYS = {
    'base_branch' => ['OPENSPEC_BASE_BRANCH', 'master'],
    'dispatch.workers' => ['OPENSPEC_WORKERS', 2],
    'dispatch.max_ready' => ['OPENSPEC_MAX_READY', 4],
    'dispatch.wait_seconds' => ['OPENSPEC_WAIT_TIMEOUT', 3600],
    'dispatch.merge_interval_seconds' => ['OPENSPEC_MERGE_INTERVAL', 10],
    'dispatch.conflict_rebuilds' => ['OPENSPEC_CONFLICT_REBUILDS', 3],
    'dispatch.aging_hours' => ['OPENSPEC_AGING_HOURS', 6],
    'dispatch.blocked_retries' => ['OPENSPEC_BLOCKED_RETRIES', 1],
    'dispatch.blocked_retry_hours' => ['OPENSPEC_BLOCKED_RETRY_HOURS', 1],
    'limits.agent_seconds' => ['AGENT_TIMEOUT_SECONDS', 7200],
    'limits.agent_idle_seconds' => ['AGENT_IDLE_SECONDS', 1200],
    'limits.agent_retries' => ['AGENT_RETRIES', 1],
    'limits.agent_retry_delay_seconds' => ['AGENT_RETRY_DELAY_SECONDS', 120],
    'limits.agent_budget_usd' => ['AGENT_MAX_BUDGET_USD', 5],
    'limits.gate_seconds' => ['OPENSPEC_GATE_TIMEOUT', 2700],
    'limits.lease_seconds' => ['OPENSPEC_LEASE_TTL', 7200]
  }.freeze
  # Amounts of money may have decimals; every other number is a whole one.
  DECIMAL = %w[limits.agent_budget_usd].freeze
  # Counts where 0 turns the behavior off; every other number must be above 0.
  ZERO_OK = %w[dispatch.max_ready dispatch.conflict_rebuilds dispatch.aging_hours dispatch.blocked_retries
               dispatch.blocked_retry_hours limits.agent_idle_seconds limits.agent_retries limits.agent_retry_delay_seconds].freeze
  BRANCH = %r{\A[A-Za-z0-9._/-]+\z}

  class Error < StandardError; end

  module_function

  # The application checkout or worktree that contains `dir` (walking up until
  # .openspec-kit.lock, config/pipeline.yaml, config/agents.yaml or openspec/ is
  # found), or `dir` itself.
  def app_root(dir = Dir.pwd)
    return File.expand_path(ENV['OPENSPEC_APP_ROOT']) unless ENV['OPENSPEC_APP_ROOT'].to_s.empty?

    cur = File.expand_path(dir)
    loop do
      if File.exist?(File.join(cur, '.openspec-kit.lock')) ||
         File.exist?(File.join(cur, 'config', 'pipeline.yaml')) ||
         File.exist?(File.join(cur, 'config', 'agents.yaml')) ||
         File.directory?(File.join(cur, 'openspec'))
        return cur
      end
      break if File.exist?(File.join(cur, '.git')) && File.basename(File.dirname(cur)) != 'repos'

      parent = File.dirname(cur)
      break if parent == cur

      cur = parent
    end
    File.expand_path(dir)
  end

  # When `root` is an isolated worktree under <main>/.worktrees/<name>, the main
  # checkout is two levels up; otherwise `root` itself.
  def main_root(root = app_root)
    File.basename(File.dirname(root)) == '.worktrees' ? File.dirname(File.dirname(root)) : root
  end

  # A kit file (config/templates/..., bin/...) in `root` when present there,
  # otherwise in the kit's own checkout (KIT_ROOT).
  def kit_file(rel, root = app_root)
    local = File.join(root, rel)
    File.exist?(local) ? local : File.join(KIT_ROOT, rel)
  end

  def load(root)
    path = File.join(root, FILE)
    path = File.join(main_root(root), FILE) unless File.exist?(path)
    File.exist?(path) ? (YAML.safe_load_file(path) || {}) : {}
  rescue Psych::Exception => e
    $stderr.puts "settings: #{FILE} is not valid YAML (#{e.message.lines.first.strip}); using the defaults"
    {}
  end

  # The value of a setting: its environment variable, then config/pipeline.yaml, then the default.
  def get(root, key, env = ENV)
    var, default = KEYS.fetch(key) { raise Error, "unknown setting #{key} (#{KEYS.keys.join(', ')})" }
    raw = env[var].to_s.empty? ? key.split('.').reduce(load(root)) { |node, k| node.is_a?(Hash) ? node[k] : nil } : env[var]
    return default if raw.nil? || raw.to_s.strip.empty?

    source = env[var].to_s.empty? ? "#{key} in #{FILE}" : var
    value = parse(key, raw)
    return value unless value.nil?

    $stderr.puts "settings: #{source} must be #{expected(key)}, not #{raw.inspect}; using #{default}"
    default
  end

  # The typed value, or nil when it is not valid for the key.
  def parse(key, raw)
    text = raw.to_s.strip
    if key == 'base_branch'
      text.match?(BRANCH) ? text : nil
    elsif DECIMAL.include?(key)
      number = Float(text, exception: false)
      number&.positive? ? (number == number.to_i ? number.to_i : number) : nil
    else
      number = Integer(text, 10, exception: false)
      number && (number.positive? || (number.zero? && ZERO_OK.include?(key))) ? number : nil
    end
  end

  def expected(key)
    return 'a branch name' if key == 'base_branch'
    return 'a whole number, 0 or more' if ZERO_OK.include?(key)

    DECIMAL.include?(key) ? 'a number above 0' : 'a whole number above 0'
  end
end

if __FILE__ == $PROGRAM_NAME
  root = OpenSpecSettings.app_root
  case ARGV
  in ['get', key]
    begin
      puts OpenSpecSettings.get(root, key)
    rescue OpenSpecSettings::Error => e
      $stderr.puts "settings: #{e.message}"
      exit 2
    end
  else
    $stderr.puts 'Usage: ruby bin/lib/settings.rb get <key>'
    exit 2
  end
end
