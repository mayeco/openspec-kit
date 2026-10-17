#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# bin/proposals.rb
#
# Proposals are work the scheduled cycle suggests but does not queue itself:
# improvements and missing capabilities it found while exploring, and the next
# features of the roadmap. The judgment agent adds them to
# config/agent_proposals.json with status "proposed"; this script decides,
# deterministically, what reaches config/agent_backlog.json.
#
#   ruby bin/proposals.rb review           # run by run_cycle.sh after the judgment
#   ruby bin/proposals.rb list
#   ruby bin/proposals.rb approve <change>  # a human approves; the next review queues it
#   ruby bin/proposals.rb reject <change>
#
# review applies `proposals.approval` of config/cycle.yaml to each proposal still
# "proposed":
#   jev    Jev answers templates/jev/proposal_review.yaml (gate proposal_review of
#          config/jev_policy.yaml). In enforce mode a passing proposal is approved;
#          otherwise, or with Jev off or unavailable, the answers are recorded and it
#          waits for a human. Jev is asked once per proposal: delete its "review"
#          to ask again.
#   human  it waits for `approve` or `reject`.
#   auto   it is approved at once.
# Every approved proposal is then appended to the backlog ("queued"), and a queued
# one whose change was archived becomes "integrated".
# ==============================================================================

require 'json'
require 'time'
require 'yaml'
require_relative 'lib/openspec_orchestrator'

module Proposals
  O = OpenSpecOrchestrator
  FILE = File.join(O::ROOT, 'config', 'agent_proposals.json')
  CYCLE = File.join(O::ROOT, 'config', 'cycle.yaml')
  # Proposal-only fields: everything else is copied into the backlog item.
  OWN_FIELDS = %w[status source strategy proposed_at review queued_at integrated_at].freeze
  OPEN = %w[proposed approved queued].freeze

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

  def approval
    cycle = File.exist?(CYCLE) ? (YAML.safe_load_file(CYCLE) || {}) : {}
    cycle.dig('proposals', 'approval') || 'jev'
  end

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

  def review
    items = read(FILE)
    backlog = read(O::BACKLOG_FILE)
    mode = approval
    counts = Hash.new(0)
    items.each do |item|
      next unless item.is_a?(Hash) && item['change_name'].to_s.match?(O::CHANGE_NAME)

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
          backlog << item.reject { |k, _| OWN_FIELDS.include?(k) }
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
    puts "proposals: #{summary} (approval: #{mode})"
  end

  def decide(name, status)
    items = read(FILE)
    item = items.find { |i| i['change_name'] == name } or raise ArgumentError, "no proposal named #{name}"
    raise ArgumentError, "#{name} is #{item['status']}, not proposed" unless %w[proposed approved].include?(item['status'])

    item['status'] = status
    item['review'] = (item['review'] || {}).merge('decided_by' => 'human', 'decided_at' => now)
    write(FILE, items)
    puts "proposals: #{name} #{status}#{status == 'approved' ? '; the next cycle queues it' : ''}"
  end

  def list
    read(FILE).each do |i|
      jev = i.dig('review', 'status') ? " jev=#{i.dig('review', 'status')}" : ''
      puts format('%-11<status>s %-40<name>s %<source>s%<jev>s', status: i['status'], name: i['change_name'],
                                                                  source: i['source'], jev: jev)
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    case ARGV
    in ['review'] then Proposals.review
    in ['list'] then Proposals.list
    in ['approve', name] then Proposals.decide(name, 'approved')
    in ['reject', name] then Proposals.decide(name, 'rejected')
    else
      warn 'Usage: ruby bin/proposals.rb review | list | approve <change> | reject <change>'
      exit 2
    end
  rescue ArgumentError, JSON::ParserError => e
    warn "proposals: #{e.message}"
    exit 1
  end
end
