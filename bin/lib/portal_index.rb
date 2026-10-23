# frozen_string_literal: true

# ==============================================================================
# bin/lib/portal_index.rb
#
# Paginated, filterable views of what the kit keeps under log/ and config/, for
# the portal's pages: the changes index, one timeline of every execution (cycle,
# PLAN and BUILD prompt, manual agent run, job, visual QA session), the cycles
# and their reports, the orchestrator event stream, the integrated history, the
# manual agent runs and the dashboard. Read-only; the portal never writes here.
# ==============================================================================

module OpenSpecPortal
  PER_PAGE = 25
  MAX_PER_PAGE = 200
  EVENT_WINDOW = 20_000
  ATTENTION_STATES = %w[blocked stale_lock ready_to_merge].freeze
  # What is in progress or waiting for something: a worker, a lease, a worktree, a quarantine or the merger.
  ACTIVE_STATES = %w[in_flight stale_lock ready_to_merge blocked worktree].freeze

  module_function

  # One page of `items` and where it sits: items, page, per, total, pages.
  def paginate(items, page, per)
    per = per.to_i
    per = PER_PAGE if per <= 0
    per = MAX_PER_PAGE if per > MAX_PER_PAGE
    pages = [(items.size / per.to_f).ceil, 1].max
    page = page.to_i.clamp(1, pages)
    { 'items' => items[(page - 1) * per, per] || [], 'page' => page, 'per' => per, 'total' => items.size, 'pages' => pages }
  end

  def page_of(items, key, page, per, extra = {})
    data = paginate(items, page, per)
    { key => data['items'] }.merge(data.reject { |k, _| k == 'items' }).merge(extra)
  end

  def matches?(query, *fields)
    needle = query.to_s.strip.downcase
    needle.empty? || fields.any? { |f| f.to_s.downcase.include?(needle) }
  end

  def count_by(items, &key)
    items.group_by(&key).transform_values(&:size)
  end

  def parse_time(text)
    Time.parse(text.to_s)
  rescue ArgumentError
    nil
  end

  # ---------------------------------------------------------------- changes

  def changes_index(q: nil, state: nil, sort: 'recent', page: 1, per: PER_PAGE)
    base = changes_catalog.select { |c| matches?(q, c['change_name'], c['description']) }
    counts = count_by(base) { |c| c['state'] }.merge('all' => base.size,
                                                       'attention' => base.count { |c| ATTENTION_STATES.include?(c['state']) },
                                                       'active' => base.count { |c| ACTIVE_STATES.include?(c['state']) })
    rows = case state.to_s
           when '', 'all' then base
           when 'attention' then base.select { |c| ATTENTION_STATES.include?(c['state']) }
           when 'active' then base.select { |c| ACTIVE_STATES.include?(c['state']) }
           else base.select { |c| c['state'] == state }
           end
    rows = case sort.to_s
           when 'name' then rows.sort_by { |c| c['change_name'] }
           when 'prompts' then rows.sort_by { |c| [-c['prompt_count'], c['change_name']] }
           when 'state' then rows
           else rows.sort_by { |c| c['updated_at'].to_s }.reverse
           end
    page_of(rows, 'changes', page, per, 'counts' => counts)
  end

  def history_index(q: nil, page: 1, per: PER_PAGE)
    rows = history_items.reverse.select { |h| matches?(q, h['change_name'], h['description']) }
    page_of(rows, 'history', page, per)
  end

  # --------------------------------------------------------- cycles and QA

  def cycle_dir = File.join(LOG, 'cycle')

  def live_lock_pid(name)
    pid = (File.read(File.join(LOG, name, 'pid')).strip.to_i rescue 0)
    pid if alive?(pid)
  end

  # Every cycle that left a log, newest first, with its prompt and the judgment report written during it.
  def cycles_all
    files = Dir.glob(File.join(cycle_dir, 'cycle-*.log')).sort
    running = live_lock_pid('cycle.lock')
    reports = Dir.glob(File.join(cycle_dir, 'reports', '*.md')).filter_map do |f|
      m = File.basename(f).match(/\A(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})/) or next
      [Time.utc(*m.captures.map(&:to_i)), File.basename(f)]
    end.sort
    entries = files.each_with_index.map do |f, i|
      stamp = File.basename(f, '.log').delete_prefix('cycle-')
      live = running && i == files.size - 1
      summary = if live
                  CycleProgress.cycle_summary(f, running)
                else
                  cached("cycle:#{f}", file_sig(f)) do
                    CycleProgress.cycle_summary(f, nil)
                  rescue StandardError
                    { 'stamp' => stamp, 'at' => File.mtime(f).utc.iso8601, 'outcome' => 'unknown' }
                  end
                end
      { 'stamp' => stamp, 'at' => (stamp_utc(stamp)&.iso8601 || summary['at']), 'outcome' => summary['outcome'], 'strategy' => summary['strategy'],
        'engine' => summary['judge'], 'preflight' => summary['preflight'], 'running' => live ? true : false,
        'log_file' => File.basename(f), 'log_size' => File.size(f),
        'prompt_file' => (File.file?(File.join(cycle_dir, "prompt-#{stamp}.md")) ? "prompt-#{stamp}.md" : nil),
        'report_files' => [] }
    end
    starts = entries.map { |e| parse_time(e['at']) }
    reports.each do |t, name|
      i = starts.rindex { |s| s && s <= t + 60 }
      entries[i]['report_files'] << name if i && t - starts[i] <= 3 * 3600
    end
    entries.reverse
  end

  def cycles_index(q: nil, page: 1, per: PER_PAGE)
    rows = cycles_all.select { |c| matches?(q, c['stamp'], c['outcome'], c['strategy'], c['engine']) }
    page_of(rows, 'cycles', page, per)
  end

  def cycle_detail(stamp)
    all = cycles_all
    i = all.index { |c| c['stamp'] == stamp.to_s } or return nil
    all[i].merge('newer' => (all[i - 1]['stamp'] if i.positive?), 'older' => all[i + 1]&.fetch('stamp'))
  end

  def visual_sessions_all
    Dir.glob(File.join(cycle_dir, 'visual-*.md')).sort.reverse.map do |f|
      stamp = File.basename(f, '.md').delete_prefix('visual-')
      rep = File.join(cycle_dir, 'reports', "visual-#{stamp}.md")
      sync = "visual-#{stamp}.sync.log"
      at = (stamp_utc(stamp) || File.mtime(f)).utc.iso8601
      { 'stamp' => stamp, 'at' => at, 'plan_file' => File.basename(f),
        'report_file' => (File.file?(rep) ? "visual-#{stamp}.md" : nil),
        'sync_log' => (File.file?(File.join(cycle_dir, sync)) ? sync : nil) }
    end
  end

  def visual_overview(page: 1, per: PER_PAGE)
    queue = VisualQA.load
    page_of(visual_sessions_all, 'sessions', page, per,
            'enabled' => VisualQA.enabled?, 'queue' => queue.merge('items' => Array(queue['items']).reverse))
  end

  # ----------------------------------------------------------------- events

  def tail_lines(path, max)
    File.open(path, 'rb') do |f|
      pos = f.size
      buf = +''.b
      while pos.positive? && buf.count("\n") <= max
        read = [65_536, pos].min
        pos -= read
        f.seek(pos)
        buf = f.read(read) + buf
      end
      lines = buf.force_encoding('UTF-8').scrub.split("\n")
      lines.shift if pos.positive?
      lines.last(max)
    end
  end

  # The last EVENT_WINDOW events of log/events.jsonl, newest first.
  def events_window
    return [] unless File.file?(O::EVENTS_FILE)

    cached('events-window', file_sig(O::EVENTS_FILE)) do
      tail_lines(O::EVENTS_FILE, EVENT_WINDOW).reverse.filter_map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
    end
  end

  def events_index(event: nil, change: nil, q: nil, page: 1, per: PER_PAGE)
    all = events_window
    rows = all.select do |e|
      (event.to_s.empty? || e['event'] == event) && (change.to_s.empty? || e['change'] == change) &&
        (q.to_s.strip.empty? || e.to_s.downcase.include?(q.to_s.strip.downcase))
    end
    page_of(rows, 'events', page, per, 'event_types' => count_by(all) { |e| e['event'] }.sort_by { |k, n| [-n, k.to_s] }.to_h,
                                        'window' => [all.size, EVENT_WINDOW].min)
  end

  # ------------------------------------------------------------- executions

  EXECUTION_KINDS = %w[cycle plan build agent job visual].freeze

  # One entry per execution, newest first: cycles, PLAN/BUILD prompts of each change, manual agent runs, jobs, visual sessions.
  def executions_all
    items = []
    Dir.glob(File.join(O::WORKER_LOG_DIR, '*', '*.prompt.md')).each do |f|
      change = File.basename(File.dirname(f))
      p = parse_prompt_file(f)
      items << { 'id' => "#{change}/#{p['file']}", 'kind' => p['role'], 'title' => change, 'phase' => p['phase'],
                 'change' => change, 'at' => p['at'], 'size' => p['size'], 'repair' => p['repair'],
                 'href' => "/changes/#{change}/prompts/#{p['file']}" }
    end
    cycles_all.each do |c|
      items << { 'id' => c['stamp'], 'kind' => 'cycle', 'title' => c['strategy'] || 'cycle', 'status' => c['outcome'],
                 'agent' => c['engine'], 'at' => c['at'], 'size' => c['log_size'], 'href' => "/cycles/#{c['stamp']}" }
    end
    read_runs.each do |r|
      items << { 'id' => r['id'], 'kind' => 'agent', 'title' => r['title'], 'status' => r['status'], 'agent' => r['agent'],
                 'change' => r['change'], 'at' => r['started_at'], 'size' => r['output_size'], 'href' => "/runs/#{r['id']}" }
    end
    read_jobs.each do |j|
      items << { 'id' => j['id'], 'kind' => 'job', 'title' => "#{j['kind']}: #{j['command']}"[0, 110], 'status' => j['status'],
                 'at' => j['started_at'], 'size' => j['output_size'], 'href' => "/jobs/#{j['id']}" }
    end
    visual_sessions_all.each do |s|
      items << { 'id' => s['stamp'], 'kind' => 'visual', 'title' => 'visual QA session',
                 'status' => (s['report_file'] ? 'reported' : 'planned'), 'at' => s['at'], 'href' => "/visual/#{s['stamp']}" }
    end
    items.sort_by { |i| i['at'].to_s }.reverse
  end

  def executions_index(kind: nil, q: nil, change: nil, page: 1, per: 50)
    base = executions_all.select do |e|
      (change.to_s.empty? || e['change'] == change) && matches?(q, e['title'], e['change'], e['agent'], e['status'], e['phase'])
    end
    rows = kind.to_s.empty? || kind == 'all' ? base : base.select { |e| e['kind'] == kind }
    page_of(rows, 'executions', page, per, 'counts' => count_by(base) { |e| e['kind'] }.merge('all' => base.size))
  end

  # ------------------------------------------------------------ manual runs

  def runs_index(status: nil, agent: nil, change: nil, q: nil, page: 1, per: PER_PAGE)
    base = read_runs.select do |r|
      (agent.to_s.empty? || r['agent'] == agent) && (change.to_s.empty? || r['change'] == change) &&
        matches?(q, r['title'], r['prompt'], r['agent'], r['change'])
    end
    rows = status.to_s.empty? || status == 'all' ? base : base.select { |r| r['status'] == status }
    page_of(rows.map { |r| r.except('prompt') }, 'runs', page, per,
            'counts' => count_by(base) { |r| r['status'] }.merge('all' => base.size),
            'agents' => count_by(base) { |r| r['agent'] })
  end

  def jobs_index(status: nil, page: 1, per: PER_PAGE)
    base = read_jobs
    rows = status.to_s.empty? || status == 'all' ? base : base.select { |j| j['status'] == status }
    page_of(rows, 'jobs', page, per, 'counts' => count_by(base) { |j| j['status'] }.merge('all' => base.size))
  end

  # -------------------------------------------------------------- dashboard

  def ready_names = Dir.glob(File.join(O::READY_DIR, '*.json')).map { |f| File.basename(f, '.json') }.sort

  # What the sidebar and the dashboard show: guards, running work and what needs a person. No dispatcher dry run.
  def summary
    procs = processes_and_locks
    blocked = blocked_items
    proposals = Proposals.read(Proposals::FILE)
    counts = {
      'in_flight' => procs['leases'].count { |l| l['alive'] }, 'stale' => procs['leases'].count { |l| !l['alive'] },
      'ready' => ready_names.size, 'blocked' => blocked.size, 'needs_human' => blocked.count { |b| b['needs_human'] },
      'backlog' => backlog_items.size, 'proposals' => proposals.count { |p| p['status'] == 'proposed' },
      'running_runs' => procs['portal_runs'].size, 'running_jobs' => procs['portal_jobs'].size
    }
    { 'app_name' => File.basename(ROOT), 'processes' => procs, 'counts' => counts, 'blocked' => blocked,
      'last_health' => read_json(File.join(PORTAL_DIR, 'last_health.json')) }
  end

  def dashboard
    sum = summary
    in_flight = sum['processes']['leases'].map do |l|
      done, total = task_progress(File.join(O::WORKTREE_BASE, "worker-#{l['change']}", 'openspec', 'changes', l['change'], 'tasks.md'))
      l.merge('done' => done, 'total' => total)
    end
    sum.merge('in_flight' => in_flight, 'ready' => ready_names, 'last_cycle' => cycles_all.first,
              'executions' => executions_all.first(10), 'events' => events_window.first(10))
  end
end
