#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# bin/cycle_progress.rb
#
# How the autonomous pipeline is going, read-only: what runs now, what was done
# in a period, what is pending, how far the roadmap got, the system's health, and
# what needs a human. The openspec-kit-status skill reads it to answer "how is it
# going?"; cycle_status.sh remains the instant snapshot.
#
#   ruby bin/cycle_progress.rb [--since 24h|90m|7d|<ISO time>] [--json]
#
# Every number comes from files: log/ (locks, events.jsonl, cycle logs, blocked
# records, the visual queue), config/ (backlog, proposals, cycle.yaml), the
# roadmap and git history (the OpenSpec-Change trailers of integrated changes).
# It never writes anything, so it is safe to run while a cycle runs.
# ==============================================================================

require 'json'
require 'open3'
require 'optparse'
require 'time'
require 'yaml'
require_relative 'lib/settings'

Encoding.default_external = Encoding::UTF_8

module CycleProgress
  ROOT = File.expand_path('..', __dir__)
  LOG = File.join(ROOT, 'log')
  CYCLE = File.join(LOG, 'cycle')
  OWN_LOCKS = %w[dispatcher merger].freeze

  module_function

  def read_json(path)
    JSON.parse(File.read(path))
  rescue Errno::ENOENT, JSON::ParserError
    nil
  end

  def yaml(path) = File.exist?(path) ? (YAML.safe_load_file(path) || {}) : {}

  def alive?(pid)
    pid.to_i.positive? && Process.kill(0, pid.to_i) && true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def git(*args)
    out, status = Open3.capture2e('git', *args, chdir: ROOT)
    status.success? ? out : ''
  end

  def parse_since(text)
    case text
    when /\A(\d+)m\z/ then Time.now - (Regexp.last_match(1).to_i * 60)
    when /\A(\d+)h\z/ then Time.now - (Regexp.last_match(1).to_i * 3600)
    when /\A(\d+)d\z/ then Time.now - (Regexp.last_match(1).to_i * 86_400)
    else Time.parse(text)
    end
  rescue ArgumentError
    raise ArgumentError, "--since takes 90m, 24h, 7d or a time, not #{text.inspect}"
  end

  def stamp_time(stamp) = Time.strptime(stamp, '%Y%m%dT%H%M%SZ').utc

  def events(since)
    path = File.join(LOG, 'events.jsonl')
    return [] unless File.exist?(path)

    File.foreach(path).filter_map do |line|
      e = JSON.parse(line)
      e if Time.parse(e['ts']) >= since
    rescue JSON::ParserError, ArgumentError, TypeError
      nil
    end
  end

  # One cycle log: when, what it explored, which agent judged, how it ended.
  def cycle_summary(path, running_pid)
    stamp = File.basename(path, '.log').delete_prefix('cycle-')
    text = File.read(path)
    outcome = if text.include?('wrote outside its scope') then 'scope violation'
              elsif text.include?('preflight: FAIL') then 'preflight failed'
              elsif text.match?(/^cycle: paused/) then 'paused'
              elsif text.include?('== done')
                if text.include?('this cycle does not judge') then 'dispatched only (visual QA session running)'
                elsif text.include?('dispatch: already running') then 'judged; an earlier dispatch was still running'
                else 'done'
                end
              elsif running_pid then "running (#{text.scan(/^== (\S+)/).flatten.last || 'starting'})"
              else 'stopped before the end'
              end
    { 'stamp' => stamp, 'at' => stamp_time(stamp).iso8601, 'outcome' => outcome,
      'strategy' => text[/^strategy: (\S+)/, 1], 'judge' => text[/^== judgment \(([^)]*)\)/, 1],
      'preflight' => text[/^preflight: (OK|FAIL)[^\n]*/] }
  end

  def now_section
    lock_pid = ->(dir) { (pid = File.read(File.join(LOG, dir, 'pid')).strip rescue nil) && alive?(pid) ? pid.to_i : nil }
    file_pid = ->(name) { (pid = File.read(File.join(LOG, 'locks', "#{name}.lock"))[/pid=(\d+)/, 1] rescue nil) && alive?(pid) ? pid.to_i : nil }
    visual = File.join(LOG, 'visual_qa.lock')
    visual_live = begin
      File.directory?(visual) &&
        (Time.now.to_i - File.read(File.join(visual, 'started')).to_i) < File.read(File.join(visual, 'ttl')).to_i
    rescue Errno::ENOENT
      false
    end
    in_flight = Dir.glob(File.join(LOG, 'locks', '*.lock')).filter_map do |f|
      name = File.basename(f, '.lock')
      next if OWN_LOCKS.include?(name)

      lease = read_json(f) || {}
      { 'change' => name, 'since' => lease['acquired_at'], 'heartbeat' => lease['heartbeat_at'] }
    end
    {
      'paused' => File.exist?(File.join(LOG, 'PAUSE')) ? File.read(File.join(LOG, 'PAUSE')).lines.first.to_s.strip : nil,
      'cycle_judging_pid' => lock_pid.call('cycle.lock'),
      'dispatch_pid' => lock_pid.call('dispatch.lock'),
      'dispatcher_pid' => file_pid.call('dispatcher'),
      'merger_pid' => file_pid.call('merger'),
      'visual_session' => visual_live ? File.read(File.join(visual, 'stamp')).strip : nil,
      'changes_in_flight' => in_flight,
      'ready_to_merge' => Dir.glob(File.join(LOG, 'ready_to_merge', '*.json')).map { |f| File.basename(f, '.json') }
    }
  end

  # The published base branch when this checkout knows it (the merger pushes there
  # first), else the checkout itself.
  def base_ref
    @base_ref ||= begin
      base = "origin/#{OpenSpecSettings.get(ROOT, 'base_branch')}"
      git('rev-parse', '--verify', '--quiet', base).empty? ? 'HEAD' : base
    end
  end

  # Integrated changes since a time, from the OpenSpec-Change trailers of the base branch.
  def integrated(since)
    git('log', base_ref, "--since=#{since.iso8601}", '--format=%cI%x09%(trailers:key=OpenSpec-Change,valueonly,separator=%x2C)')
      .lines.flat_map do |line|
        at, changes = line.chomp.split("\t", 2)
        changes.to_s.split(',').map(&:strip).reject(&:empty?).map { |c| { 'change' => c, 'at' => at } }
      end
  end

  def ever_integrated
    @ever_integrated ||= git('log', base_ref, '--format=%(trailers:key=OpenSpec-Change,valueonly,separator=%x2C)')
                         .split(/[,\n]/).map(&:strip).reject(&:empty?).uniq
  end

  def report(since)
    now = now_section
    evs = events(since)
    logs = Dir.glob(File.join(CYCLE, 'cycle-*.log')).sort
    newest = logs.last
    cycles = logs.select { |p| stamp_time(File.basename(p, '.log').delete_prefix('cycle-')) >= since rescue false }
                 .map { |p| cycle_summary(p, p == newest ? now['cycle_judging_pid'] || now['dispatch_pid'] : nil) }
    blocked = Dir.glob(File.join(LOG, 'blocked', '*.json')).filter_map { |f| read_json(f) }
    proposals = Array(read_json(File.join(ROOT, 'config', 'agent_proposals.json')))
    backlog = Array(read_json(File.join(ROOT, 'config', 'agent_backlog.json')))
    queue = read_json(File.join(CYCLE, 'visual_queue.json')) || { 'items' => [] }
    state = read_json(File.join(CYCLE, 'state.json')) || {}
    in_period = ->(t) { t && (Time.parse(t) >= since rescue false) }
    in_flight = now['changes_in_flight'].map { |c| c['change'] }

    status_of = lambda do |name|
      if !name.match?(/\A[a-z0-9][a-z0-9-]{0,62}\z/) then 'invalid name'
      elsif ever_integrated.include?(name) then 'integrated'
      elsif blocked.any? { |b| b['change_name'] == name } then 'blocked'
      elsif now['ready_to_merge'].include?(name) then 'ready to merge'
      elsif in_flight.include?(name) then 'in flight'
      else 'pending'
      end
    end
    backlog_status = backlog.select { |i| i.is_a?(Hash) && i['change_name'] }.map { |i| [i['change_name'], status_of.call(i['change_name'])] }.uniq

    agent_runs = evs.select { |e| e['event'] == 'agent.exit' }
    visual_done = Array(queue['items']).select { |i| i['status'] == 'done' && in_period.call(i['done_at']) }
    cfg = yaml(File.join(ROOT, 'config', 'cycle.yaml'))
    roadmap_file = cfg.dig('roadmap', 'file').to_s
    roadmap_path = File.join(ROOT, roadmap_file)
    roadmap_text = !roadmap_file.empty? && File.file?(roadmap_path) ? File.read(roadmap_path) : nil
    listed = roadmap_text ? roadmap_text.split(/^## Done/i).first.scan(/^\s*(?:\d+\.|[-*])\s+\S/).size : 0
    from_roadmap = proposals.select { |p| p['source'] == 'roadmap' }.group_by { |p| p['status'] }.transform_values(&:size)

    {
      'generated_at' => Time.now.utc.iso8601,
      'since' => since.utc.iso8601,
      'now' => now,
      'period' => {
        'cycles' => cycles,
        'integrated' => integrated(since),
        'blocked' => blocked.select { |b| in_period.call(b['blocked_at']) }.map { |b| b.slice('change_name', 'reason', 'blocked_at') },
        'proposals' => {
          'proposed' => proposals.count { |p| in_period.call(p['proposed_at']) },
          'queued' => proposals.count { |p| in_period.call(p['queued_at']) },
          'integrated' => proposals.count { |p| in_period.call(p['integrated_at']) }
        },
        'visual_checks' => visual_done.group_by { |i| i['verdict'] }.transform_values(&:size),
        'visual_sessions' => Dir.glob(File.join(CYCLE, 'visual-*.md')).count { |f| (stamp_time(File.basename(f, '.md').delete_prefix('visual-')) >= since rescue false) },
        'agent_calls' => agent_runs.size,
        'agent_minutes' => (agent_runs.sum { |e| e['seconds'].to_i } / 60.0).round(1),
        'agent_calls_by_engine' => agent_runs.group_by { |e| e['engine'] }.transform_values(&:size),
        'jev_cost_usd' => evs.select { |e| e['event'] == 'jev.answer' }.sum { |e| e['cost_usd'].to_f }.round(6)
      },
      'pending' => {
        'backlog' => backlog_status.group_by(&:last).transform_values { |v| v.map(&:first) },
        'proposals_waiting' => proposals.select { |p| p['status'] == 'proposed' }.map { |p| { 'change' => p['change_name'], 'source' => p['source'], 'jev' => p.dig('review', 'status') } },
        'visual_queue' => Array(queue['items']).group_by { |i| i['status'] }.transform_values(&:size).slice('pending', 'in_progress')
      },
      'roadmap' => {
        'file' => roadmap_file.empty? ? nil : roadmap_file,
        'filled_in' => roadmap_text ? !roadmap_text.include?('{{') : false,
        'items_listed' => listed,
        'proposals' => from_roadmap
      },
      'health' => {
        'last_cycle' => cycles.last || (newest && cycle_summary(newest, nil)),
        'judgment_outcome' => state.dig('last_cycle', 'outcome'),
        'consecutive_failures' => state['consecutive_failures'].to_i,
        'max_consecutive_failures' => cfg['max_consecutive_failures'],
        'blocked_by_reason' => blocked.group_by { |b| b['reason'] }.transform_values(&:size)
      },
      'needs_human' => {
        'paused' => now['paused'],
        'blocked' => blocked.map { |b| b.slice('change_name', 'reason') },
        'proposals_waiting' => proposals.count { |p| p['status'] == 'proposed' },
        'visual_cannot_verify' => visual_done.select { |i| i['verdict'] == 'cannot-verify' }.map { |i| i.slice('id', 'change', 'note') }
      }
    }
  end

  def list(items) = items.empty? ? 'none' : items.join(', ')

  def text(r)
    now = r['now']
    p = r['period']
    running = []
    running << "a cycle is judging (pid #{now['cycle_judging_pid']})" if now['cycle_judging_pid']
    running << "a dispatch is running (pid #{now['dispatch_pid']})" if now['dispatch_pid']
    running << "a dispatcher started by hand (pid #{now['dispatcher_pid']})" if now['dispatcher_pid'] && !now['dispatch_pid']
    running << "the merger (pid #{now['merger_pid']})" if now['merger_pid']
    running << "a visual QA session (#{now['visual_session']})" if now['visual_session']
    outcomes = p['cycles'].group_by { |c| c['outcome'] }.transform_values(&:size).map { |k, v| "#{v} #{k}" }
    lines = []
    lines << "== Now (#{r['generated_at']})"
    lines << "  PAUSED: #{now['paused']}" if now['paused']
    lines << "  running: #{list(running)}"
    lines << "  changes in flight: #{list(now['changes_in_flight'].map { |c| c['change'] })}; ready to merge: #{list(now['ready_to_merge'])}"
    lines << "== Since #{r['since']}"
    lines << "  cycles: #{p['cycles'].size}#{outcomes.empty? ? '' : " (#{outcomes.join(', ')})"}"
    lines << "  strategies explored: #{list(p['cycles'].filter_map { |c| c['strategy'] }.uniq)}"
    lines << "  integrated: #{p['integrated'].size} (#{list(p['integrated'].map { |i| i['change'] })})"
    lines << "  blocked: #{p['blocked'].size}#{p['blocked'].empty? ? '' : " (#{p['blocked'].map { |b| "#{b['change_name']}: #{b['reason']}" }.join(', ')})"}"
    lines << "  proposals: #{p['proposals']['proposed']} proposed, #{p['proposals']['queued']} queued, #{p['proposals']['integrated']} integrated"
    lines << "  visual QA: #{p['visual_sessions']} sessions; checks #{p['visual_checks'].empty? ? 'none' : p['visual_checks'].map { |k, v| "#{v} #{k}" }.join(', ')}"
    lines << "  agents: #{p['agent_calls']} calls, #{p['agent_minutes']} min (#{p['agent_calls_by_engine'].map { |k, v| "#{k} #{v}" }.join(', ')}); Jev: $#{p['jev_cost_usd']}"
    lines << '== Pending'
    r['pending']['backlog'].each { |status, names| lines << "  backlog #{status}: #{names.size} (#{list(names)})" }
    lines << "  proposals waiting for approval: #{list(r['pending']['proposals_waiting'].map { |w| w['change'] })}"
    lines << "  visual queue: #{r['pending']['visual_queue'].map { |k, v| "#{v} #{k}" }.join(', ').then { |s| s.empty? ? 'empty' : s }}"
    rm = r['roadmap']
    lines << '== Roadmap'
    lines << if rm['file'].nil? then '  none configured'
             elsif !rm['filled_in'] then "  #{rm['file']} still has {{...}} placeholders"
             else "  #{rm['file']}: #{rm['items_listed']} items listed; proposals from it: #{rm['proposals'].empty? ? 'none' : rm['proposals'].map { |k, v| "#{v} #{k}" }.join(', ')}"
             end
    h = r['health']
    lines << '== Health'
    last = h['last_cycle']
    lines << "  last cycle: #{last ? "#{last['at']}, #{last['outcome']}#{last['preflight'] ? "; #{last['preflight']}" : ''}" : 'none yet'}"
    lines << "  judgment's last outcome: #{h['judgment_outcome'] || 'none'}; consecutive failures: #{h['consecutive_failures']} of #{h['max_consecutive_failures'] || '?'}"
    lines << "  blocked by reason: #{h['blocked_by_reason'].empty? ? 'none' : h['blocked_by_reason'].map { |k, v| "#{k} #{v}" }.join(', ')}"
    n = r['needs_human']
    asks = []
    asks << "remove log/PAUSE once fixed (#{n['paused']})" if n['paused']
    n['blocked'].each { |b| asks << "#{b['change_name']} is blocked (#{b['reason']})" }
    asks << "#{n['proposals_waiting']} proposal(s) waiting for approval" if n['proposals_waiting'].positive?
    n['visual_cannot_verify'].each { |v| asks << "visual check #{v['id']} could not verify #{v['change'] || 'a request'}: #{v['note']}" }
    lines << '== Needs a human'
    lines.concat(asks.empty? ? ['  nothing'] : asks.map { |a| "  - #{a}" })
    lines.join("\n")
  end
end

if __FILE__ == $PROGRAM_NAME
  options = { since: '24h', json: false }
  OptionParser.new do |opts|
    opts.banner = 'Usage: ruby bin/cycle_progress.rb [--since 24h|90m|7d|<time>] [--json]'
    opts.on('--since PERIOD', 'Period to report (default 24h)') { |v| options[:since] = v }
    opts.on('--json', 'Machine-readable output') { options[:json] = true }
  end.parse!
  begin
    report = CycleProgress.report(CycleProgress.parse_since(options[:since]))
    puts(options[:json] ? JSON.pretty_generate(report) : CycleProgress.text(report))
  rescue ArgumentError => e
    warn "cycle_progress: #{e.message}"
    exit 2
  end
end
