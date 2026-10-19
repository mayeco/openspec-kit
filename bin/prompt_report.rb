#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# bin/prompt_report.rb
#
# How each version of the agents' prompts, or of the memory, did: the evidence to
# keep an edit of config/prompts/plan.md or build.md, or of MEMORY.md and memory/,
# or to undo it. Every PLAN and BUILD call records in its agent.exit event the
# version of its prompt (prompt_version: the prompt without its notes, with the
# kit's authoring rules; bin/lib/prompts.rb) and of the memory it read
# (memory_version: MEMORY.md and memory/; bin/lib/memory.rb). This counts each
# change under the version its first call of a role used, and reports for each
# version: when it was used, the changes and calls, the repair rounds, how many
# finished changes needed none, what happened to them (integrated, blocked and
# why, in flight) and the agents that ran. Read-only, from files alone.
#
#   ruby bin/prompt_report.rb [--since 30d|24h|<time>] [--by prompt|memory] [--json]
#
# A version with a few changes says little, and changes differ: compare versions
# once each has a handful. Calls where no agent could work (exit 75) are not
# attempts and do not count. What this reports lasts as long as log/events.jsonl,
# which is runtime state, and starts with the first calls that recorded versions.
# ==============================================================================

require 'json'
require 'optparse'
require 'time'
require_relative 'jev_report'
require_relative 'lib/memory'
require_relative 'lib/prompts'

module PromptReport
  P = CycleProgress
  KEYS = { 'prompt' => 'prompt_version', 'memory' => 'memory_version' }.freeze
  ROLES = %w[plan build].freeze
  ENGINES_DOWN = 75
  # A change in these states has not finished the role yet.
  UNFINISHED = ['in flight', 'pending or abandoned'].freeze

  module_function

  # PLAN calls are `plan` and `plan-repair-N`; BUILD calls `apply` and `repair-N`.
  def role_of(phase) = phase.to_s.start_with?('plan') ? 'plan' : 'build'

  def repair?(phase) = phase.to_s.include?('repair')

  # The version each role would record now, to mark it in the report.
  def current(by)
    if by == 'memory'
      version = OpenSpecMemory.fingerprint(P::ROOT)
      ROLES.to_h { |role| [role, version] }
    else
      ROLES.to_h { |role| [role, File.file?(OpenSpecPrompts.path(P::ROOT, role)) ? OpenSpecPrompts.version(P::ROOT, role) : nil] }
    end
  end

  def version_row(version, changes, outcome)
    calls = changes.values.flatten
    repairs = changes.transform_values { |list| list.count { |e| repair?(e['phase']) } }
    outcomes = changes.keys.to_h { |change| [change, outcome.call(change)] }
    finished = outcomes.reject { |_, o| UNFINISHED.include?(o) }.keys
    times = calls.map { |e| e['ts'] }.sort
    {
      'version' => version, 'first_used' => times.first, 'last_used' => times.last,
      'changes' => changes.size, 'calls' => calls.size, 'repairs' => repairs.values.sum,
      'repairs_per_change' => (repairs.values.sum.to_f / changes.size).round(2),
      'finished' => finished.size, 'finished_without_repair' => finished.count { |c| repairs[c].zero? },
      'outcomes' => outcomes.values.tally, 'engines' => calls.map { |e| e['engine'] }.tally,
      'change_list' => changes.keys.map { |c| { 'change' => c, 'repairs' => repairs[c], 'outcome' => outcomes[c] } }
    }
  end

  def report(since, by)
    key = KEYS.fetch(by) { raise ArgumentError, "--by takes #{KEYS.keys.join(' or ')}, not #{by.inspect}" }
    calls = P.events(since).select { |e| e['event'] == 'agent.exit' && e[key] && e['code'].to_i != ENGINES_DOWN }
    outcome = JevReport.outcome_of
    now = current(by)
    {
      'since' => since.utc.iso8601, 'by' => by,
      'roles' => ROLES.map do |role|
        by_change = calls.select { |e| role_of(e['phase']) == role }.group_by { |e| e['change'].to_s }
        versions = by_change.group_by { |_, list| list.first[key] }.map do |version, changes|
          version_row(version, changes.to_h, outcome).merge('current' => version == now[role])
        end
        { 'role' => role, 'current' => now[role], 'versions' => versions.sort_by { |v| v['first_used'].to_s } }
      end
    }
  end

  def text(r)
    what = r['by'] == 'memory' ? 'memory (MEMORY.md and memory/)' : 'prompt (config/prompts/<role>.md and the authoring rules)'
    lines = ["== Versions of the #{what} since #{r['since']}; each change counts under the version of its first call of the role"]
    r['roles'].each do |role|
      lines << "#{role['role']}: #{role['versions'].empty? ? 'no calls with a recorded version' : "#{role['versions'].size} version(s)"}, " \
               "current #{role['current'] || 'unknown'}"
      role['versions'].each do |v|
        span = [v['first_used'], v['last_used']].map { |t| t.to_s[0, 16].tr('T', ' ') }.uniq.join(' .. ')
        lines << "  #{v['version']}#{v['current'] ? ' (current)' : ''}  #{span}: #{v['changes']} change(s), #{v['calls']} call(s), " \
                 "#{v['repairs']} repair round(s) (#{v['repairs_per_change']} per change), " \
                 "#{v['finished_without_repair']} of #{v['finished']} finished without a repair"
        lines << "    outcomes: #{JevReport.tally(v['outcomes'])}; agents: #{JevReport.tally(v['engines'])}"
      end
    end
    lines << 'A version with a few changes says little. A new prompt version is an edit of config/prompts/<role>.md or a ' \
             "kit upgrade that changed the authoring rules; the change's repairs.md says what each repair round fixed."
    lines.join("\n")
  end
end

if __FILE__ == $PROGRAM_NAME
  options = { since: '30d', by: 'prompt', json: false }
  OptionParser.new do |opts|
    opts.banner = 'Usage: ruby bin/prompt_report.rb [--since 30d|24h|<time>] [--by prompt|memory] [--json]'
    opts.on('--since PERIOD', 'Period to report (default 30d)') { |v| options[:since] = v }
    opts.on('--by WHAT', 'prompt (default) or memory') { |v| options[:by] = v }
    opts.on('--json', 'Machine-readable output') { options[:json] = true }
  end.parse!
  begin
    report = PromptReport.report(CycleProgress.parse_since(options[:since]), options[:by])
    puts(options[:json] ? JSON.pretty_generate(report) : PromptReport.text(report))
  rescue ArgumentError => e
    warn "prompt_report: #{e.message}"
    exit 2
  end
end
