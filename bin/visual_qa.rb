#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# bin/visual_qa.rb
#
# The queue between the headless cycle and the visual QA session that an agent
# app (Claude, Hermes) runs with a browser. The queue is runtime state:
# log/cycle/visual_queue.json.
#
#   ruby bin/visual_qa.rb enqueue-integrated      # run_cycle.sh: queue what the merger integrated
#   ruby bin/visual_qa.rb request "<what>" [--change NAME]   # the headless judgment or a human
#   ruby bin/visual_qa.rb take <stamp> <plan-file> # visual_qa.sh begin: claim items, write the plan
#   ruby bin/visual_qa.rb done <id> <verdict> ["<note>"]     # the visual agent, per item
#   ruby bin/visual_qa.rb release <stamp>          # visual_qa.sh end: unfinished items go back
#   ruby bin/visual_qa.rb status
#
# Verdicts: verified, regression, not-visual, cannot-verify. Nothing happens while
# `visual_qa.enabled` in config/cycle.yaml is not true.
# ==============================================================================

require 'json'
require 'open3'
require 'optparse'
require 'time'
require 'yaml'
require_relative 'cycle_prompt'
require_relative 'lib/memory'

Encoding.default_external = Encoding::UTF_8

module VisualQA
  ROOT = File.expand_path('..', __dir__)
  QUEUE = File.join(ROOT, 'log', 'cycle', 'visual_queue.json')
  LOCK_FILE = "#{QUEUE}.lock"
  STRATEGY_STATE = File.join(ROOT, 'log', 'cycle', 'visual_strategy_state.json')
  VERDICTS = %w[verified regression not-visual cannot-verify].freeze
  MAX_PENDING = 50

  class Error < StandardError; end

  module_function

  def cycle = CyclePrompt.load_yaml(CyclePrompt::CYCLE)

  def settings = cycle['visual_qa'] || {}

  def enabled? = CyclePrompt.visual_qa?(cycle)

  def now = Time.now.utc.iso8601

  def load
    File.exist?(QUEUE) ? JSON.parse(File.read(QUEUE)) : { 'last_sha' => nil, 'next_id' => 1, 'items' => [] }
  end

  def save(queue)
    FileUtils.mkdir_p(File.dirname(QUEUE))
    tmp = "#{QUEUE}.tmp.#{Process.pid}"
    File.write(tmp, "#{JSON.pretty_generate(queue)}\n")
    File.rename(tmp, QUEUE)
  end

  def with_lock(&block)
    FileUtils.mkdir_p(File.dirname(LOCK_FILE))
    File.open(LOCK_FILE, File::RDWR | File::CREAT, 0o644) do |f|
      f.flock(File::LOCK_EX)
      block.call
    ensure
      f.flock(File::LOCK_UN)
    end
  end

  def add(queue, item)
    item = { 'id' => queue['next_id'], 'status' => 'pending', 'created_at' => now }.merge(item)
    queue['next_id'] += 1
    queue['items'] << item
    pending = queue['items'].select { |i| i['status'] == 'pending' }
    # A session that never runs must not grow the queue forever: the oldest pending items go.
    (pending.first([pending.size - MAX_PENDING, 0].max)).each { |i| i['status'] = 'dropped' }
    item
  end

  def git(*args)
    out, status = Open3.capture2e('git', *args, chdir: ROOT)
    raise Error, "git #{args.join(' ')}: #{out.strip}" unless status.success?

    out
  end

  # Every change the merger integrated since the last call becomes a "verify" item.
  # The first call only records where the queue starts.
  def enqueue_integrated
    return puts('visual-qa: disabled (visual_qa.enabled in config/cycle.yaml)') unless enabled?

    queue = load
    head = git('rev-parse', 'HEAD').strip
    added = []
    skipped = []
    # A history rewritten under the queue (a reset base branch) restarts it here.
    queue['last_sha'] = nil unless queue['last_sha'].nil? || system('git', 'merge-base', '--is-ancestor', queue['last_sha'], head, chdir: ROOT, err: File::NULL)
    if queue['last_sha'] && queue['last_sha'] != head
      log = git('log', '--reverse', '--format=%H%x09%(trailers:key=OpenSpec-Change,valueonly,separator=%x2C)',
                "#{queue['last_sha']}..#{head}")
      log.each_line do |line|
        sha, changes = line.chomp.split("\t", 2)
        changes.to_s.split(',').map(&:strip).reject(&:empty?).each do |change|
          next if queue['items'].any? { |i| i['change'] == change && i['kind'] == 'verify' && i['status'] == 'pending' }
          next skipped << change if terminal_only?(sha)

          added << add(queue, 'kind' => 'verify', 'change' => change, 'detail' => "integrated in #{sha[0, 12]}")
        end
      end
    end
    queue['last_sha'] = head
    save(queue)
    note = skipped.empty? ? '' : "; #{skipped.size} only touched terminal programs (#{skipped.join(', ')}): the headless cycle verifies them"
    puts "visual-qa: #{added.size} integrated change(s) queued#{note}; #{queue['items'].count { |i| i['status'] == 'pending' }} pending"
  end

  # A change whose child repositories are all terminal programs (kind: cli in their
  # repo.config.yaml) has nothing to show in a browser.
  def terminal_only?(sha)
    repos = git('show', '--format=', '--name-only', sha).lines.map(&:strip).grep(%r{\Arepos/[^/]+\z})
    repos.any? && repos.all? do |repo|
      cfg = File.join(ROOT, repo, 'repo.config.yaml')
      (File.exist?(cfg) && (YAML.safe_load_file(cfg) || {})['kind']) == 'cli'
    rescue Psych::Exception
      false
    end
  end

  def request(detail, change)
    raise Error, 'visual QA is disabled (visual_qa.enabled in config/cycle.yaml)' unless enabled?
    raise Error, 'say what to check' if detail.to_s.strip.empty?

    queue = load
    item = add(queue, 'kind' => 'request', 'change' => change, 'detail' => detail.strip)
    save(queue)
    puts "visual-qa: request #{item['id']} queued"
  end

  def take(stamp, plan_file)
    queue = load
    max = (settings['max_items_per_session'] || 5).to_i
    taken = queue['items'].select { |i| i['status'] == 'pending' }.first(max)
    taken.each do |i|
      i['status'] = 'in_progress'
      i['session'] = stamp
    end
    save(queue)
    strategies = CyclePrompt.strategies(cycle).select { |s| CyclePrompt.needs_browser?(s) }
    order = CyclePrompt.load_yaml(CyclePrompt::EXPLORATION)['order'] || 'rotation'
    strategy = CyclePrompt.pick(strategies, order, nil, STRATEGY_STATE)
    File.write(plan_file, plan(stamp, taken, strategy))
    puts "visual-qa: started #{stamp} plan=#{plan_file.delete_prefix("#{ROOT}/")} items=#{taken.size} " \
         "strategy=#{strategy ? strategy['slug'] : 'none'}"
  end

  def plan(stamp, items, strategy)
    minutes = (settings['minutes'] || 40).to_i
    max = (cycle.dig('exploration', 'max_new_backlog_items_per_cycle') || 3).to_i
    approval = cycle.dig('proposals', 'approval') || 'jev'
    skills = Array(cycle.dig('qa', 'skills'))
    checks = if items.empty?
               'Nothing is queued: spend the session on the exploration below.'
             else
               items.map do |i|
                 what = i['kind'] == 'verify' ? "change `#{i['change']}` (#{i['detail']})" : "request: #{i['detail']}#{i['change'] ? " (change `#{i['change']}`)" : ''}"
                 "#{i['id']}. #{what}"
               end.join("\n")
             end
    explore = if strategy
                "**#{strategy['name'] || strategy['slug']}** (`#{strategy['slug']}`, kind `#{strategy['kind'] || 'defects'}`)\n\n" \
                  "#{strategy['directive'].to_s.strip}"
              else
                'No strategy of `config/exploration.yaml` has `needs: browser`: explore the screens the checks above touched.'
              end
    <<~MD
      # Visual QA session #{stamp}

      Written by `bash bin/visual_qa.sh begin`. Follow the `openspec-kit-visual-qa` skill with this plan, within #{minutes} minutes, then run `bash bin/visual_qa.sh end`.

      ## Check in the browser

      #{checks}

      Close each one: `ruby bin/visual_qa.rb done <id> verified|regression|not-visual|cannot-verify "<one line of evidence>"`. An item you do not close goes back to the queue.

      ## Explore

      #{explore}

      ## Findings

      - Defects and regressions: backlog items (`openspec-kit-qa`, "Record a finding"); improvements and missing capabilities: proposals in `config/agent_proposals.json` (approval `#{approval}`). At most #{max} this session.
      - Evidence (screenshots, console and network logs): `log/cycle/evidence/visual-#{stamp}/`. Report: `log/cycle/reports/visual-#{stamp}.md`.
      - The application's QA skills: #{skills.empty? ? 'none configured (`qa.skills` in `config/cycle.yaml`)' : skills.map { |k| "`#{k}`" }.join(', ')}.
      - Lessons: #{OpenSpecMemory.plan_line(ROOT)}
    MD
  end

  def done(id, verdict, note)
    raise Error, "verdict must be one of #{VERDICTS.join(', ')}" unless VERDICTS.include?(verdict)

    queue = load
    item = queue['items'].find { |i| i['id'] == id.to_i } or raise Error, "no item #{id}"
    raise Error, "item #{id} is #{item['status']}, not in progress" unless item['status'] == 'in_progress'

    item.merge!('status' => 'done', 'verdict' => verdict, 'note' => note.to_s.strip, 'done_at' => now)
    save(queue)
    puts "visual-qa: #{id} #{verdict}"
  end

  def release(stamp)
    queue = load
    back = queue['items'].select { |i| i['status'] == 'in_progress' && i['session'] == stamp }
    back.each { |i| i.merge!('status' => 'pending', 'session' => nil) }
    save(queue)
    done = queue['items'].count { |i| i['session'] == stamp && i['status'] == 'done' }
    puts "visual-qa: #{done} checked, #{back.size} back to the queue"
  end

  def status
    unless enabled?
      puts 'visual QA: disabled'
      return
    end
    counts = load['items'].group_by { |i| i['status'] }.transform_values(&:size)
    puts "visual QA queue: #{counts.fetch('pending', 0)} pending, #{counts.fetch('in_progress', 0)} in progress, " \
         "#{counts.fetch('done', 0)} done"
  end
end

if __FILE__ == $PROGRAM_NAME
  change = nil
  args = OptionParser.new { |o| o.on('--change NAME') { |v| change = v } }.parse(ARGV)
  begin
    case args
    in ['enqueue-integrated'] then VisualQA.with_lock { VisualQA.enqueue_integrated }
    in ['request', detail] then VisualQA.with_lock { VisualQA.request(detail, change) }
    in ['take', stamp, plan_file] then VisualQA.with_lock { VisualQA.take(stamp, File.expand_path(plan_file)) }
    in ['done', id, verdict, *note] then VisualQA.with_lock { VisualQA.done(id, verdict, note.join(' ')) }
    in ['release', stamp] then VisualQA.with_lock { VisualQA.release(stamp) }
    in ['status'] then VisualQA.status
    else
      warn 'Usage: ruby bin/visual_qa.rb enqueue-integrated | request "<what>" [--change NAME] | ' \
           'take <stamp> <plan-file> | done <id> <verdict> ["<note>"] | release <stamp> | status'
      exit 2
    end
  rescue VisualQA::Error, JSON::ParserError, ArgumentError => e
    warn "visual-qa: #{e.message}"
    exit 1
  end
end
