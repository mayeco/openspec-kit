#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# bin/proposals.rb
#
# Proposals are work the scheduled cycle suggests but does not queue itself:
# improvements and missing capabilities it found while exploring, the next
# features of the roadmap, and edits of the agents' prompts. The judgment agent
# adds them to config/agent_proposals.json with status "proposed"; this script
# decides, deterministically, what reaches config/agent_backlog.json, and applies
# the prompt edits.
#
#   ruby bin/proposals.rb review           # run by run_cycle.sh after the judgment
#   ruby bin/proposals.rb list
#   ruby bin/proposals.rb show <change>     # one proposal; a prompt edit as a diff
#   ruby bin/proposals.rb approve <change>  # a human approves; the next review queues or applies it
#   ruby bin/proposals.rb reject <change>
#
# review applies `proposals.approval` of config/cycle.yaml to each proposal still
# "proposed":
#   jev    Jev answers config/templates/jev/proposal_review.yaml (gate proposal_review of
#          config/jev_policy.yaml). In enforce mode a passing proposal is approved;
#          otherwise, or with Jev off or unavailable, the answers are recorded and it
#          waits for a human. Jev is asked once per proposal: delete its "review"
#          to ask again.
#   human  it waits for `approve` or `reject`.
#   auto   it is approved at once.
# Every approved proposal is then appended to the backlog ("queued"), and a queued
# one whose change was archived becomes "integrated".
#
# A prompt proposal ("kind": "prompt") edits config/prompts/<prompt>.md (plan,
# build or cycle) instead: a list of "edits", each an "old" text that must occur
# exactly once and its "new" replacement, with the "evidence" that argues for it.
# `proposals.prompt_approval` decides who approves it: human (the default) or
# auto. Once approved, review applies the edits, checks the prompt
# (bin/lib/prompts.rb) and marks it "integrated" with the prompt's version before
# and after, which bin/prompt_report.rb then compares; the record step commits the
# prompt. An edit that no longer matches, or a prompt that fails its check, leaves
# the file as it was and the proposal "rejected" with the reason in review.apply_error.
# The judgment never writes a prompt itself: the scope guard runs before review.
# ==============================================================================

require 'json'
require 'time'
require 'yaml'
require_relative 'lib/openspec_orchestrator'
require_relative 'lib/prompts'

module Proposals
  O = OpenSpecOrchestrator
  FILE = File.join(O::ROOT, 'config', 'agent_proposals.json')
  CYCLE = File.join(O::ROOT, 'config', 'cycle.yaml')
  # Proposal-only fields: everything else is copied into the backlog item.
  OWN_FIELDS = %w[status source strategy proposed_at review queued_at integrated_at].freeze
  OPEN = %w[proposed approved queued].freeze
  PROMPT_APPROVALS = %w[human auto].freeze

  # A prompt proposal that cannot be applied as it stands.
  class ApplyError < StandardError; end

  module_function

  def read(path)
    data = File.exist?(path) ? JSON.parse(File.read(path)) : []
    data.is_a?(Hash) ? Array(data['changes']) : Array(data)
  end

  def write(path, items)
    tmp = "#{path}.tmp.#{Process.pid}"
    File.write(tmp, "#{JSON.pretty_generate(items)}\n")
    File.rename(tmp, path)
  end

  def settings = File.exist?(CYCLE) ? (YAML.safe_load_file(CYCLE) || {}) : {}

  def approval = settings.dig('proposals', 'approval') || 'jev'

  # Who approves a prompt proposal; anything but auto means a human.
  def prompt_approval = settings.dig('proposals', 'prompt_approval') == 'auto' ? 'auto' : 'human'

  def prompt?(item) = item['kind'] == 'prompt'

  def now = Time.now.utc.iso8601

  def archived?(name) = Dir.glob(File.join(O::ROOT, 'openspec', 'changes', 'archive', "*-#{name}")).any?

  # What Jev needs to judge a proposal: the proposal, the roadmap, and what is
  # already specified, queued or proposed, so that a duplicate is recognizable.
  def jev_state(item, items, backlog)
    roadmap = (File.exist?(CYCLE) && YAML.safe_load_file(CYCLE)&.dig('roadmap', 'file')).to_s
    roadmap_path = File.join(O::ROOT, roadmap)
    specs = O.run(%w[openspec list --specs --json], timeout: 120, stderr: :separate)
    capabilities = begin
      Array(JSON.parse(specs.out)['specs']).map { |s| s['id'] || s['name'] }.compact
    rescue JSON::ParserError, TypeError
      []
    end
    {
      'proposal' => item.reject { |k, _| OWN_FIELDS.include?(k) && k != 'source' },
      'roadmap' => !roadmap.empty? && File.file?(roadmap_path) ? File.read(roadmap_path) : '',
      'existing_capabilities' => capabilities,
      'queued_changes' => backlog.map { |b| b['change_name'] },
      'other_proposals' => items.reject { |p| p.equal?(item) }.map { |p| "#{p['change_name']} (#{p['status']})" }
    }
  end

  def ask_jev(item, items, backlog)
    verdict = O::Jev.ask('proposal_review', jev_state(item, items, backlog),
                         cache_dir: File.join(O::LOG_DIR, 'cycle', 'jev'), change: item['change_name'])
    review = { 'by' => 'jev', 'at' => now, 'mode' => verdict.mode, 'status' => verdict.status.to_s }
    review['model'] = verdict.model if verdict.model
    review['answers'] = O::Jev.summarize(verdict.answers) if verdict.answers
    review['failed'] = verdict.failed.map { |c| "#{c['condition']} (measured #{c['actual']})" } if verdict.failed&.any?
    [verdict.status == :passed && verdict.enforce?, review]
  rescue StandardError => e
    [false, { 'by' => 'jev', 'at' => now, 'status' => 'error', 'detail' => e.message[0, 300] }]
  end

  # The edits of a prompt proposal applied to its prompt, checked, and written; the
  # prompt's version before and after. Raises ApplyError and leaves the file as it was.
  def apply_prompt!(item)
    name = item['prompt'].to_s
    raise ApplyError, "prompt must be one of #{OpenSpecPrompts::PLACEHOLDERS.keys.join(', ')}" unless OpenSpecPrompts::PLACEHOLDERS.key?(name)

    rel = "#{OpenSpecPrompts::DIR}/#{name}.md"
    file = OpenSpecPrompts.path(O::ROOT, name)
    raise ApplyError, "#{rel} is missing" unless File.file?(file)

    edits = item['edits']
    unless edits.is_a?(Array) && edits.any? && edits.all? { |e| e.is_a?(Hash) && e['old'].is_a?(String) && !e['old'].empty? && e['new'].is_a?(String) }
      raise ApplyError, 'edits must be a list of {"old": <text in the prompt>, "new": <its replacement>}'
    end

    before = File.read(file, encoding: 'UTF-8')
    after = edits.each_with_index.reduce(before) do |text, (edit, i)|
      found = text.scan(edit['old']).size
      raise ApplyError, "edit #{i + 1}: its old text occurs #{found} times in #{rel}, not once (did the prompt change since?)" unless found == 1

      text.sub(edit['old']) { edit['new'] }
    end
    raise ApplyError, "the edits leave #{rel} as it is" if after == before

    from = OpenSpecPrompts.version(O::ROOT, name)
    write_text(file, after)
    errors = OpenSpecPrompts.problems(O::ROOT)[:errors].select { |e| e.start_with?("#{rel}:") }
    unless errors.empty?
      write_text(file, before)
      raise ApplyError, "the edited prompt fails its check: #{errors.join('; ')}"
    end
    { 'at' => now, 'prompt' => rel, 'from' => from, 'to' => OpenSpecPrompts.version(O::ROOT, name) }
  end

  def write_text(path, text)
    tmp = "#{path}.tmp.#{Process.pid}"
    File.write(tmp, text)
    File.rename(tmp, path)
  end

  # A prompt proposal never reaches the backlog: approved (by prompt_approval or a
  # human), it is applied to its prompt at once.
  def review_prompt(item, counts)
    if item['status'] == 'proposed' && !item.key?('review') && prompt_approval == 'auto'
      item['status'] = 'approved'
      item['review'] = { 'by' => 'auto', 'at' => now }
    end
    case item['status']
    when 'proposed' then counts['prompt edit(s) waiting for a human'] += 1
    when 'approved'
      begin
        item['applied'] = apply_prompt!(item)
        item['status'] = 'integrated'
        item['integrated_at'] = now
        O.emit('proposal.applied', change: item['change_name'], prompt: item['applied']['prompt'],
                                   from: item['applied']['from'], to: item['applied']['to'])
        counts['prompt edit(s) applied'] += 1
      rescue ApplyError => e
        item['status'] = 'rejected'
        item['review'] = (item['review'] || {}).merge('apply_error' => e.message)
        O.emit('proposal.apply_failed', change: item['change_name'], error: e.message[0, 300])
        counts['prompt edit(s) rejected'] += 1
      end
    end
  end

  def review
    items = read(FILE)
    backlog = read(O::BACKLOG_FILE)
    mode = approval
    counts = Hash.new(0)
    items.each do |item|
      next unless item.is_a?(Hash) && item['change_name'].to_s.match?(O::CHANGE_NAME)
      next review_prompt(item, counts) if prompt?(item)

      if item['status'] == 'proposed' && !item.key?('review')
        case mode
        when 'auto'
          item['status'] = 'approved'
          item['review'] = { 'by' => 'auto', 'at' => now }
        when 'jev'
          approved, review = ask_jev(item, items, backlog)
          O.emit('proposal.reviewed', change: item['change_name'], status: review['status'], approved: approved)
          # An answer is kept; no answer (Jev off, unavailable or failing) is retried next cycle.
          if %w[passed failed abstained].include?(review['status'])
            item['review'] = review
            item['status'] = 'approved' if approved
          else
            counts["not reviewed (jev #{review['status']})"] += 1
          end
        end
      end
      if item['status'] == 'approved'
        unless backlog.any? { |b| b['change_name'] == item['change_name'] }
          # queued_at lets the dispatcher age the item (dispatch.aging_hours of config/pipeline.yaml).
          backlog << item.reject { |k, _| OWN_FIELDS.include?(k) }.merge('queued_at' => now)
        end
        item['status'] = 'queued'
        item['queued_at'] = now
        O.emit('proposal.queued', change: item['change_name'], by: item.dig('review', 'by') || 'human')
        counts['queued'] += 1
      end
      if item['status'] == 'queued' && archived?(item['change_name'])
        item['status'] = 'integrated'
        item['integrated_at'] = now
      end
      counts["waiting for a human"] += 1 if item['status'] == 'proposed'
    end
    write(FILE, items) if File.exist?(FILE) || items.any?
    write(O::BACKLOG_FILE, backlog) if counts['queued'].positive?
    summary = counts.empty? ? 'nothing to review' : counts.map { |k, v| "#{v} #{k}" }.join(', ')
    puts "proposals: #{summary} (approval: #{mode}, prompt edits: #{prompt_approval})"
  end

  def decide(name, status)
    items = read(FILE)
    item = items.find { |i| i['change_name'] == name } or raise ArgumentError, "no proposal named #{name}"
    raise ArgumentError, "#{name} is #{item['status']}, not proposed" unless %w[proposed approved].include?(item['status'])

    item['status'] = status
    item['review'] = (item['review'] || {}).merge('decided_by' => 'human', 'decided_at' => now)
    write(FILE, items)
    nxt = prompt?(item) ? "the next cycle applies it to #{OpenSpecPrompts::DIR}/#{item['prompt']}.md" : 'the next cycle queues it'
    puts "proposals: #{name} #{status}#{status == 'approved' ? "; #{nxt}" : ''}"
  end

  def list
    read(FILE).each do |i|
      jev = i.dig('review', 'status') ? " jev=#{i.dig('review', 'status')}" : ''
      kind = prompt?(i) ? " prompt=#{i['prompt']}" : ''
      puts format('%-11<status>s %-40<name>s %<source>s%<kind>s%<jev>s', status: i['status'], name: i['change_name'],
                                                                           source: i['source'], kind: kind, jev: jev)
    end
  end

  # One proposal for a human to decide on; a prompt edit as a diff of its old and new text.
  def show(name)
    item = read(FILE).find { |i| i['change_name'] == name } or raise ArgumentError, "no proposal named #{name}"
    puts "#{item['change_name']} (#{item['status']}, #{prompt?(item) ? "prompt #{item['prompt']}" : 'change'}, source #{item['source'] || 'unknown'})"
    %w[description evidence].each { |k| puts "#{k}: #{item[k]}" if item[k] }
    puts "apply_error: #{item.dig('review', 'apply_error')}" if item.dig('review', 'apply_error')
    puts "applied: #{item['applied'].to_json}" if item['applied']
    Array(item['edits']).each_with_index do |edit, i|
      puts "--- edit #{i + 1} of #{OpenSpecPrompts::DIR}/#{item['prompt']}.md"
      edit['old'].to_s.each_line { |l| puts "-#{l.chomp}" }
      edit['new'].to_s.each_line { |l| puts "+#{l.chomp}" }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    case ARGV
    in ['review'] then Proposals.review
    in ['list'] then Proposals.list
    in ['show', name] then Proposals.show(name)
    in ['approve', name] then Proposals.decide(name, 'approved')
    in ['reject', name] then Proposals.decide(name, 'rejected')
    else
      warn 'Usage: ruby bin/proposals.rb review | list | show <change> | approve <change> | reject <change>'
      exit 2
    end
  rescue ArgumentError, JSON::ParserError => e
    warn "proposals: #{e.message}"
    exit 1
  end
end
