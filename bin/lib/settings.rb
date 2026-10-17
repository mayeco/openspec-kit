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
  FILE = 'config/pipeline.yaml'
  # key => [the environment variable that overrides it, the default]
  KEYS = {
    'base_branch' => ['OPENSPEC_BASE_BRANCH', 'master'],
    'dispatch.workers' => ['OPENSPEC_WORKERS', 2],
    'dispatch.wait_seconds' => ['OPENSPEC_WAIT_TIMEOUT', 3600],
    'dispatch.merge_interval_seconds' => ['OPENSPEC_MERGE_INTERVAL', 10],
    'dispatch.conflict_rebuilds' => ['OPENSPEC_CONFLICT_REBUILDS', 1],
    'dispatch.aging_hours' => ['OPENSPEC_AGING_HOURS', 6],
    'limits.agent_seconds' => ['AGENT_TIMEOUT_SECONDS', 7200],
    'limits.agent_retries' => ['AGENT_RETRIES', 1],
    'limits.agent_retry_delay_seconds' => ['AGENT_RETRY_DELAY_SECONDS', 120],
    'limits.agent_budget_usd' => ['AGENT_MAX_BUDGET_USD', 5],
    'limits.gate_seconds' => ['OPENSPEC_GATE_TIMEOUT', 2700],
    'limits.lease_seconds' => ['OPENSPEC_LEASE_TTL', 7200]
  }.freeze
  # Amounts of money may have decimals; every other number is a whole one.
  DECIMAL = %w[limits.agent_budget_usd].freeze
  # Counts where 0 turns the behavior off; every other number must be above 0.
  ZERO_OK = %w[dispatch.conflict_rebuilds dispatch.aging_hours limits.agent_retries limits.agent_retry_delay_seconds].freeze
  BRANCH = %r{\A[A-Za-z0-9._/-]+\z}

  class Error < StandardError; end

  module_function

  def load(root)
    path = File.join(root, FILE)
    File.exist?(path) ? (YAML.safe_load_file(path) || {}) : {}
  rescue Psych::Exception => e
    warn "settings: #{FILE} is not valid YAML (#{e.message.lines.first.strip}); using the defaults"
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

    warn "settings: #{source} must be #{expected(key)}, not #{raw.inspect}; using #{default}"
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
  root = File.expand_path('../..', __dir__)
  case ARGV
  in ['get', key]
    begin
      puts OpenSpecSettings.get(root, key)
    rescue OpenSpecSettings::Error => e
      warn "settings: #{e.message}"
      exit 2
    end
  else
    warn 'Usage: ruby bin/lib/settings.rb get <key>'
    exit 2
  end
end
