#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# bin/jev_report.rb
#
# What Jev answered, gate by gate, and what happened to each change it judged:
# the evidence to tune a gate's thresholds and to decide when it may move from
# advisory to enforce. Read-only, from files alone: the jev.answer and
# jev.unavailable events of log/events.jsonl, config/jev_policy.yaml, the
# blocked records, the leases, the proposals and the OpenSpec-Change trailers
# of the published base branch.
#
#   ruby bin/jev_report.rb [--since 30d|24h|<time>] [--gate NAME] [--json]
#
# For each gate: answers by status, cached and unavailable calls, cost, each
# question's scores against its threshold, and, per change, what enforce would
# have done with today's policy (repair, quarantine, re-run, escalate, wait for
# a human) beside the change's outcome: integrated, blocked and why, in flight,
# pending. A gate is ready for enforce when the changes it would have stopped
# are the ones that went wrong, and the ones it let through went well.
# J0 (the canary) and J5 (asked by agents through the CLI) leave no events, and
# what this reports lasts as long as log/events.jsonl, which is runtime state.
# ==============================================================================

require 'json'
require 'optparse'
require 'time'
require 'yaml'
require_relative 'cycle_progress'

module JevReport
  P = CycleProgress
  POLICY = File.join(P::ROOT, 'config', 'jev_policy.yaml')
  # What enforce does with an answer that misses an assert, for the gates that use asserts.
  BLOCKS = {
    'plan_review' => 'repair the plan',
    'scenario_coverage' => 'repair the tests',
    'repair_progress' => 'quarantine repair_stalled',
    'proposal_review' => 'wait for a human'
  }.freeze

  module_function

  # jev.answer carries the answers summarized: a number for a noul or a score, "choice@confidence" for a choice.
  def answers_of(event)
    data = event['answers'].is_a?(String) ? JSON.parse(event['answers']) : event['answers']
    data.is_a?(Hash) ? data : {}
  rescue JSON::ParserError
    {}
  end

  def choice(value) = value.is_a?(String) && value.include?('@') ? value.split('@', 2).then { |c, p| [c, p.to_f] } : nil

  def matches?(answers, rule)
    return false unless rule.is_a?(Hash) && answers.key?(rule['question'])

    value = answers[rule['question']]
    if rule['choice']
      picked, confidence = choice(value)
      picked == rule['choice'] && confidence.to_f >= rule.fetch('min_confidence', 0).to_f
    elsif rule.key?('min') then value.to_f >= rule['min'].to_f
    elsif rule.key?('max') then value.to_f <= rule['max'].to_f
    else false
    end
  end

  # What enforce would do with one answer under today's policy; nil when it lets the change through.
  def enforce_action(gate, cfg, event)
    answers = answers_of(event)
    case gate
    when 'failure_triage'
      if matches?(answers, cfg['rerun_when']) then 're-run the gates'
      elsif matches?(answers, cfg['escalate_when']) then 'escalate spec_ambiguity'
      end
    when 'change_risk'
      'quarantine risk_review' if Array(cfg['block_when']).any? { |rule| matches?(answers, rule) }
    else
      BLOCKS.fetch(gate, 'block') if %w[failed abstained].include?(event['status'])
    end
  end

  # { question => [operator, threshold] } from the gate's asserts.
  def thresholds(cfg)
    Array(cfg['assert']).filter_map do |condition|
      question, operator, value = condition.to_s.split(/\s+/, 3)
      [question, [operator, value.to_f]] if question && value
    end.to_h
  end

  def outcome_of
    blocked = Dir.glob(File.join(P::LOG, 'blocked', '*.json')).filter_map { |f| P.read_json(f) }
                 .to_h { |b| [b['change_name'], b['reason']] }
    proposals = Array(P.read_json(File.join(P::ROOT, 'config', 'agent_proposals.json')))
                .select { |x| x.is_a?(Hash) }.to_h { |x| [x['change_name'], x['status']] }
    now = P.now_section
    in_flight = now['changes_in_flight'].map { |c| c['change'] }
    lambda do |change|
      if P.ever_integrated.include?(change) then 'integrated'
      elsif blocked.key?(change) then "blocked (#{blocked[change]})"
      elsif now['ready_to_merge'].include?(change) then 'ready to merge'
      elsif in_flight.include?(change) then 'in flight'
      elsif proposals.key?(change) then "proposal #{proposals[change]}"
      else 'pending or abandoned'
      end
    end
  end

  def question_stats(events, limits)
    values = Hash.new { |h, k| h[k] = [] }
    events.each { |e| answers_of(e).each { |q, v| values[q] << (choice(v)&.first || v) } }
    values.to_h do |question, list|
      next [question, { 'choices' => list.map(&:to_s).tally }] unless list.all?(Numeric)

      sorted = list.sort
      operator, limit = limits[question]
      missed = limit && list.count { |v| operator == '<=' ? v > limit : v < limit }
      [question, { 'min' => sorted.first.round(3), 'median' => sorted[sorted.size / 2].round(3), 'max' => sorted.last.round(3),
                   'threshold' => limit && "#{operator} #{limit}", 'missed' => missed }]
    end
  end

  def gate_report(gate, cfg, events, unavailable, outcome)
    changes = events.group_by { |e| e['change'].to_s }.map do |change, list|
      { 'change' => change, 'answers' => list.size, 'statuses' => list.map { |e| e['status'] }.tally,
        'enforce_would' => list.filter_map { |e| enforce_action(gate, cfg, e) }.uniq, 'outcome' => outcome.call(change) }
    end
    stopped, through = changes.partition { |c| c['enforce_would'].any? }
    {
      'gate' => gate, 'mode' => cfg['mode'] || 'off', 'answers' => events.size,
      'cached' => events.count { |e| e['cached'] }, 'unavailable' => unavailable,
      'statuses' => events.map { |e| e['status'] }.tally, 'cost_usd' => events.sum { |e| e['cost_usd'].to_f }.round(6),
      'questions' => question_stats(events, thresholds(cfg)),
      'enforce_would_stop' => stopped.map { |c| c['outcome'] }.tally,
      'enforce_would_let_through' => through.map { |c| c['outcome'] }.tally,
      'changes' => changes
    }
  end

  def report(since, only = nil)
    policy = P.yaml(POLICY)
    gates = policy['gates'].is_a?(Hash) ? policy['gates'] : {}
    events = P.events(since)
    answers = events.select { |e| e['event'] == 'jev.answer' }
    names = (gates.keys + answers.map { |e| e['gate'] }).compact.uniq
    names &= [only] if only
    outcome = outcome_of
    {
      'since' => since.utc.iso8601, 'model' => policy['model'],
      'gates' => names.map do |gate|
        gate_report(gate, gates[gate] || {}, answers.select { |e| e['gate'] == gate },
                    events.count { |e| e['event'] == 'jev.unavailable' && e['gate'] == gate }, outcome)
      end
    }
  end

  def tally(hash) = hash.empty? ? 'none' : hash.map { |k, v| "#{k} #{v}" }.join(', ')

  def text(r)
    lines = ["== Jev answers since #{r['since']} (model #{r['model'] || 'not pinned'}; " \
             'what enforce would do follows today\'s config/jev_policy.yaml)']
    r['gates'].each do |g|
      if g['gate'] == 'task_priority' && g['answers'].zero?
        lines << "#{g['gate']} (#{g['mode']}): asked by agents through the jev CLI, so it leaves no events"
        next
      elsif g['answers'].zero?
        lines << "#{g['gate']} (#{g['mode']}): no answers#{g['unavailable'].positive? ? ", #{g['unavailable']} unavailable" : ''}"
        next
      end
      lines << "#{g['gate']} (#{g['mode']}): #{g['answers']} answers, #{g['cached']} cached, #{g['unavailable']} unavailable, $#{g['cost_usd']}"
      lines << "  status: #{tally(g['statuses'])}"
      g['questions'].each do |q, s|
        lines << if s['choices'] then "  #{q}: #{tally(s['choices'])}"
                 else
                   limit = s['threshold'] ? ", threshold #{s['threshold']}, missed #{s['missed']}" : ''
                   "  #{q}: #{s['min']} / #{s['median']} / #{s['max']} (min / median / max)#{limit}"
                 end
      end
      stopped = g['changes'].select { |c| c['enforce_would'].any? }
      lines << "  enforce would stop #{stopped.size} change(s): #{tally(g['enforce_would_stop'])}"
      stopped.each { |c| lines << "    - #{c['change']}: #{c['enforce_would'].join(', ')}; now #{c['outcome']}" }
      lines << "  enforce would let through #{g['changes'].size - stopped.size} change(s): #{tally(g['enforce_would_let_through'])}"
    end
    lines << 'J0 (the canary) and J5 (asked by agents) leave no events; answers older than log/events.jsonl are gone.'
    lines.join("\n")
  end
end

if __FILE__ == $PROGRAM_NAME
  options = { since: '30d', gate: nil, json: false }
  OptionParser.new do |opts|
    opts.banner = 'Usage: ruby bin/jev_report.rb [--since 30d|24h|<time>] [--gate NAME] [--json]'
    opts.on('--since PERIOD', 'Period to report (default 30d)') { |v| options[:since] = v }
    opts.on('--gate NAME', 'Only this gate (plan_review, scenario_coverage, ...)') { |v| options[:gate] = v }
    opts.on('--json', 'Machine-readable output') { options[:json] = true }
  end.parse!
  begin
    report = JevReport.report(CycleProgress.parse_since(options[:since]), options[:gate])
    puts(options[:json] ? JSON.pretty_generate(report) : JevReport.text(report))
  rescue ArgumentError => e
    warn "jev_report: #{e.message}"
    exit 2
  end
end
