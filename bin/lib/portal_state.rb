# frozen_string_literal: true

# ==============================================================================
# bin/lib/portal_state.rb
#
# Read-only inspection and agentic observability for bin/portal.rb: processes
# and locks, active worker worktrees (.worktrees/worker-*), agents catalog,
# per-change execution detail (PLAN and BUILD prompts, OpenSpec artifacts, Jev
# states, worker log) and the structured Agentic Observatory view of log/.
# ==============================================================================

module OpenSpecPortal
  O = OpenSpecOrchestrator
  ROOT = O::ROOT
  LOG = O::LOG_DIR
  PORTAL_DIR = File.join(LOG, 'portal')
  RUNS_DIR = File.join(PORTAL_DIR, 'runs')
  JOBS_DIR = File.join(PORTAL_DIR, 'jobs')
  DEFAULT_PORT = 4567
  DEFAULT_BIND = '127.0.0.1'
  PATH_ENV = "#{ENV.fetch('OPENSPEC_PATH_PREFIX', "#{Dir.home}/.local/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:/opt/homebrew/bin")}:#{ENV.fetch('PATH', '')}"

  module_function

  def ensure_dirs!
    O.ensure_dirs!
    [PORTAL_DIR, RUNS_DIR, JOBS_DIR].each { |d| FileUtils.mkdir_p(d) }
  end

  def now = Time.now.utc.iso8601

  def alive?(pid)
    pid.to_i.positive? && Process.kill(0, pid.to_i) && true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def which?(bin)
    PATH_ENV.split(File::PATH_SEPARATOR).any? do |dir|
      next false if dir.empty?

      full = File.join(dir, bin)
      File.file?(full) && File.executable?(full)
    end
  end

  def sh(*cmd, timeout: 60, env: {})
    O.run(cmd.map(&:to_s), chdir: ROOT, timeout: timeout, env: { 'PATH' => PATH_ENV }.merge(env))
  end

  def read_json(path, fallback = nil)
    File.exist?(path) ? JSON.parse(File.read(path)) : fallback
  rescue JSON::ParserError, Errno::ENOENT
    fallback
  end

  def backlog_items = Proposals.read(O::BACKLOG_FILE)

  def history_items = Proposals.read(O::HISTORY_FILE)

  def dry_run_queue
    res = sh('ruby', File.join(ROOT, 'bin', 'openspec_dispatcher.rb'), '--dry-run', '--json', timeout: 30)
    res.ok? ? (JSON.parse(res.out) rescue {}) : { 'error' => res.out.strip }
  end

  # Snapshot of every lock, process, queue, worktree and repository.
  def processes_and_locks
    dir_lock = lambda do |name|
      dir = File.join(LOG, "#{name}.lock")
      next { 'name' => name, 'held' => false, 'pid' => nil, 'alive' => false } unless File.directory?(dir)

      pid = (File.read(File.join(dir, 'pid')).strip.to_i rescue 0)
      { 'name' => name, 'held' => true, 'pid' => (pid.positive? ? pid : nil), 'alive' => alive?(pid),
        'age_seconds' => (Time.now - File.mtime(dir)).to_i }
    end
    file_lock = lambda do |name|
      path = File.join(O::LOCK_DIR, "#{name}.lock")
      text = (File.read(path) rescue '')
      pid = text[/pid=(\d+)/, 1].to_i
      live = alive?(pid)
      { 'name' => name, 'running' => live, 'pid' => (pid.positive? ? pid : nil),
        'started_at' => text[/started_at=(\S+)/, 1] }
    end
    visual_dir = File.join(LOG, 'visual_qa.lock')
    visual = if File.directory?(visual_dir)
               started = (File.read(File.join(visual_dir, 'started')).to_i rescue 0)
               ttl = (File.read(File.join(visual_dir, 'ttl')).to_i rescue 0)
               pid = (File.read(File.join(visual_dir, 'pid')).to_i rescue 0)
               { 'open' => (Time.now.to_i - started) < ttl, 'stamp' => (File.read(File.join(visual_dir, 'stamp')).strip rescue nil),
                 'pid' => (pid.positive? ? pid : nil), 'slot' => (File.read(File.join(visual_dir, 'slot')).strip rescue nil) }
             else
               { 'open' => false, 'stamp' => nil, 'pid' => nil, 'slot' => nil }
             end
    leases = Dir.glob(File.join(O::LOCK_DIR, '*.lock')).filter_map do |f|
      name = File.basename(f, '.lock')
      next if %w[dispatcher merger].include?(name)

      data = read_json(f, {})
      { 'change' => name, 'pid' => data['pid'], 'alive' => alive?(data['pid']),
        'acquired_at' => data['acquired_at'], 'heartbeat_at' => data['heartbeat_at'] }
    end
    in_use = OpenSpecAgents.registry(ROOT) do
      Dir.glob(File.join(ROOT, OpenSpecAgents::IN_USE, '*')).filter_map do |f|
        pid = Integer(File.basename(f), exception: false) or next
        next unless alive?(pid)

        { 'pid' => pid, 'agent' => (File.read(f).strip rescue '') }
      end
    end
    {
      'paused' => O.paused?,
      'pause_reason' => (File.read(O::PAUSE_FILE).lines.first.to_s.strip if O.paused?),
      'locks' => %w[cycle dispatch].map(&dir_lock),
      'visual_qa' => visual,
      'daemons' => %w[dispatcher merger].map(&file_lock),
      'merger_state' => read_json(File.join(LOG, 'merger_state.json')),
      'leases' => leases,
      'agents_in_use' => in_use,
      'portal_runs' => list_runs.select { |r| r['status'] == 'running' },
      'portal_jobs' => list_jobs.select { |j| j['status'] == 'running' }
    }
  end

  def agents_catalog
    cfg = OpenSpecAgents.load(ROOT) || {}
    selected = Array(cfg['agents'])
    roles = %w[plan build cycle].to_h { |r| [r, OpenSpecAgents.engines(ROOT, r)] }
    in_use = OpenSpecAgents.registry(ROOT) { OpenSpecAgents.in_use(ROOT) }
    items = OpenSpecAgents::SUPPORTED.map do |name, meta|
      {
        'name' => name, 'label' => meta['label'], 'tool' => meta['tool'], 'skills' => meta['skills'],
        'selected' => selected.include?(name), 'installed' => which?(name),
        'roles' => roles.select { |_, list| list.include?(name) }.keys,
        'in_use' => in_use[name].to_i, 'extra_args' => OpenSpecAgents.extra_args(ROOT, name)
      }
    end
    {
      'configured' => File.exist?(File.join(ROOT, OpenSpecAgents::CONFIG)),
      'selected' => selected, 'roles' => roles,
      'order' => OpenSpecAgents.order(ROOT), 'permissions' => OpenSpecAgents.permissions(ROOT),
      'in_use' => in_use, 'agents' => items
    }
  end

  def blocked_items
    by_name = {}
    Dir.glob(File.join(O::BLOCKED_DIR, '*.json')).sort.each do |f|
      b = read_json(f) or next
      change = b['change_name'] || File.basename(f, '.json')
      nh_file = File.join(O::WORKTREE_BASE, "worker-#{change}", 'openspec', 'changes', change, '.needs-human')
      by_name[change] = b.merge(
        'change_name' => change,
        'retry_note' => O.retry_note(f, b),
        'approved' => File.exist?(File.join(O::APPROVED_DIR, change)),
        'needs_human' => (File.read(nh_file).strip if File.file?(nh_file))
      )
    end
    Dir.glob(File.join(O::WORKTREE_BASE, 'worker-*', 'openspec', 'changes', '*', '.needs-human')).sort.each do |nh|
      change = File.basename(File.dirname(nh))
      next if by_name.key?(change)

      by_name[change] = {
        'change_name' => change, 'reason' => 'needs_human', 'blocked_at' => File.mtime(nh).utc.iso8601,
        'details' => File.read(nh), 'needs_human' => File.read(nh).strip,
        'retry_note' => 'waiting for a human (.needs-human in worktree)',
        'approved' => File.exist?(File.join(O::APPROVED_DIR, change))
      }
    end
    by_name.values
  end

  # Detailed status of every .worktrees/worker-* and log/ready_to_merge/*.json, cross-referenced
  # with leases, blocked records, dispatch_results.json and dry_run_queue.
  def worktrees_status
    dry = dry_run_queue
    dry_items = Array(dry['items']).to_h { |r| [r['change'], r] }
    blocked = blocked_items.to_h { |b| [b['change_name'], b] }
    leases = Dir.glob(File.join(O::LOCK_DIR, '*.lock')).each_with_object({}) do |f, acc|
      n = File.basename(f, '.lock')
      next if %w[dispatcher merger].include?(n)

      d = read_json(f, {})
      acc[n] = d.merge('alive' => alive?(d['pid']))
    end
    ready = Dir.glob(File.join(O::READY_DIR, '*.json')).each_with_object({}) do |f, acc|
      m = read_json(f) or next
      acc[m['change_name'] || File.basename(f, '.json')] = m
    end
    wt_dirs = Dir.glob(File.join(O::WORKTREE_BASE, 'worker-*')).select { |d| File.directory?(d) }
    names = (wt_dirs.map { |d| File.basename(d).delete_prefix('worker-') } + ready.keys + leases.keys).uniq.sort
    merger_lock = File.join(O::LOCK_DIR, 'merger.lock')
    merger_pid = (File.read(merger_lock)[/pid=(\d+)/, 1].to_i rescue 0)
    merger_running = alive?(merger_pid)

    names.filter_map do |change|
      next unless change.match?(O::CHANGE_NAME)

      wt = File.join(O::WORKTREE_BASE, "worker-#{change}")
      wt_exists = File.directory?(wt)
      cdir = File.join(wt, 'openspec', 'changes', change)
      has_proposal = File.file?(File.join(cdir, 'proposal.md'))
      tasks_file = File.join(cdir, 'tasks.md')
      tasks_done = 0
      tasks_total = 0
      if File.file?(tasks_file)
        File.foreach(tasks_file) do |line|
          if line.match?(/^\s*[-*+]\s+\[[xX]\]/)
            tasks_done += 1
            tasks_total += 1
          elsif line.match?(/^\s*[-*+]\s+\[\s\]/)
            tasks_total += 1
          end
        end
      end
      nh_file = File.join(cdir, '.needs-human')
      needs_human = File.file?(nh_file) ? File.read(nh_file).strip : nil
      lease = leases[change]
      dr = dry_items[change] || {}
      r_manifest = ready[change]

      status, diagnosis =
        if lease && lease['alive']
          ['IN_FLIGHT', "worker running (pid #{lease['pid']})"]
        elsif lease && !lease['alive']
          ['STALE_LEASE', "worker process died (stale pid #{lease['pid']} in log/locks/#{change}.lock)"]
        elsif needs_human
          ['NEEDS_HUMAN', "waiting for human answer in .needs-human: #{needs_human[0, 140]}"]
        elsif blocked.key?(change)
          b = blocked[change]
          ['QUARANTINED', "blocked (#{b['reason']})#{b['retry_note'] ? ": #{b['retry_note']}" : ''}"]
        elsif r_manifest
          why_not_merged = if O.paused?
                             "merger paused by log/PAUSE (#{File.read(O::PAUSE_FILE).lines.first.to_s.strip})"
                           elsif merger_running
                             "merger running (pid #{merger_pid})"
                           else
                             'merger is idle; click Integrate Now or Resume & Drain Merge Queue'
                           end
          ['READY_TO_MERGE', "built and queued in log/ready_to_merge/#{change}.json; #{why_not_merged}"]
        elsif dr['state'] == 'held' || dr['state'] == 'waiting'
          ['HELD_BY_LOCK', dr['why'] || dr['state']]
        elsif dr['state'] == 'next_dispatch'
          ['WAIT_NEXT_DISPATCH', dr['why']]
        elsif wt_exists && tasks_total.positive? && tasks_done < tasks_total
          ['INCOMPLETE_BUILD', "#{tasks_done}/#{tasks_total} tasks checked; waiting for next dispatch"]
        elsif wt_exists && has_proposal
          ['PLANNED', dr['why'] || 'plan artifacts written in worktree; waiting to build']
        else
          ['WORKTREE', dr['why'] || 'worktree present']
        end

      phase = if r_manifest then 'ready_to_merge'
              elsif tasks_total.positive? && tasks_done == tasks_total then 'build_complete'
              elsif tasks_done.positive? then "building (#{tasks_done}/#{tasks_total})"
              elsif has_proposal then "planned (0/#{tasks_total} tasks)"
              else 'planning'
              end
      {
        'change_name' => change, 'worktree' => (wt if wt_exists),
        'status' => status, 'phase' => phase,
        'tasks_done' => tasks_done, 'tasks_total' => tasks_total,
        'has_proposal' => has_proposal, 'needs_human' => needs_human,
        'lease' => lease, 'ready_manifest' => r_manifest,
        'blocked' => blocked[change], 'diagnosis' => diagnosis
      }
    end
  end

  def change_artifact_dir(change)
    wt_dir = File.join(O::WORKTREE_BASE, "worker-#{change}", 'openspec', 'changes', change)
    return [wt_dir, 'worktree'] if File.directory?(wt_dir)

    active = File.join(ROOT, 'openspec', 'changes', change)
    return [active, 'active'] if File.directory?(active)

    archived = Dir.glob(File.join(ROOT, 'openspec', 'changes', 'archive', "*-#{change}")).select do |d|
      File.basename(d).match?(/\A\d{4}-\d{2}-\d{2}-#{Regexp.escape(change)}\z/)
    end.max
    return [archived, 'archived'] if archived && File.directory?(archived)

    [nil, nil]
  end

  def changes_catalog
    backlog = backlog_items.to_h { |i| [i['change_name'], i] }
    history = history_items.to_h { |i| [i['change_name'], i] }
    blocked = blocked_items.to_h { |b| [b['change_name'], b] }
    ready = Dir.glob(File.join(O::READY_DIR, '*.json')).map { |f| File.basename(f, '.json') }
    leases = Dir.glob(File.join(O::LOCK_DIR, '*.lock')).each_with_object({}) do |f, acc|
      n = File.basename(f, '.lock')
      next if %w[dispatcher merger].include?(n)

      d = read_json(f, {})
      acc[n] = alive?(d['pid'])
    end
    wt_changes = Dir.glob(File.join(O::WORKTREE_BASE, 'worker-*')).select { |d| File.directory?(d) }.map { |d| File.basename(d).delete_prefix('worker-') }
    worker_dirs = Dir.glob(File.join(O::WORKER_LOG_DIR, '*')).select { |d| File.directory?(d) }.map { |d| File.basename(d) }
    worker_logs = Dir.glob(File.join(O::WORKER_LOG_DIR, '*.log')).map { |f| File.basename(f, '.log') }
    archived = Dir.glob(File.join(ROOT, 'openspec', 'changes', 'archive', '*')).filter_map do |d|
      File.basename(d)[/\A\d{4}-\d{2}-\d{2}-(.+)\z/, 1] if File.directory?(d)
    end
    names = (backlog.keys + history.keys + blocked.keys + ready + leases.keys + wt_changes + worker_dirs + worker_logs + archived).compact.uniq
    names.select! { |n| n.match?(O::CHANGE_NAME) }

    names.map do |name|
      state = if leases[name] == true then 'in_flight'
              elsif leases[name] == false then 'stale_lock'
              elsif ready.include?(name) then 'ready_to_merge'
              elsif blocked.key?(name) then 'blocked'
              elsif history.key?(name) || archived.include?(name) then 'integrated'
              elsif wt_changes.include?(name) then 'worktree'
              elsif backlog.key?(name) then 'queued'
              else 'recorded'
              end
      wdir = File.join(O::WORKER_LOG_DIR, name)
      prompts = File.directory?(wdir) ? Dir.glob(File.join(wdir, '*.prompt.md')).sort.map { |f| File.basename(f) } : []
      item = backlog[name] || history[name] || {}
      {
        'change_name' => name, 'state' => state, 'priority' => item['priority'],
        'description' => item['description'], 'blocked_reason' => blocked.dig(name, 'reason'),
        'prompt_count' => prompts.size, 'prompts' => prompts,
        'has_worktree' => wt_changes.include?(name),
        'has_worker_log' => File.file?(File.join(O::WORKER_LOG_DIR, "#{name}.log"))
      }
    end.sort_by { |c| [%w[in_flight stale_lock blocked ready_to_merge worktree].index(c['state']) || 9, c['change_name']] }
  end

  def change_detail(change)
    name = change.to_s.strip
    return nil unless name.match?(O::CHANGE_NAME)

    wdir = File.join(O::WORKER_LOG_DIR, name)
    prompts = if File.directory?(wdir)
                Dir.glob(File.join(wdir, '*.prompt.md')).sort.map do |f|
                  base = File.basename(f)
                  stamp, phase = base.sub(/\.prompt\.md\z/, '').split('-', 2)
                  role = phase.to_s.start_with?('plan') ? 'plan' : 'build'
                  { 'file' => base, 'timestamp' => stamp, 'phase' => phase || 'run',
                    'role' => role, 'size' => File.size(f), 'content' => File.read(f) }
                end
              else
                []
              end
    jev_states = if File.directory?(wdir)
                   Dir.glob(File.join(wdir, 'jev-*.state.json')).sort.map do |f|
                     { 'file' => File.basename(f), 'content' => File.read(f) }
                   end
                 else
                   []
                 end
    worker_files = []
    log_path = File.join(O::WORKER_LOG_DIR, "#{name}.log")
    if File.file?(log_path)
      worker_files << { 'path' => "#{name}.log", 'size' => File.size(log_path), 'mtime' => File.mtime(log_path).utc.iso8601 }
    end
    if File.directory?(wdir)
      Dir.glob(File.join(wdir, '**', '*'), File::FNM_DOTMATCH).select { |f| File.file?(f) }.sort.each do |f|
        worker_files << { 'path' => f.delete_prefix("#{O::WORKER_LOG_DIR}/"), 'size' => File.size(f), 'mtime' => File.mtime(f).utc.iso8601 }
      end
    end
    art_dir, art_source = change_artifact_dir(name)
    artifacts = {}
    if art_dir
      %w[proposal.md design.md tasks.md repairs.md handoff.md .needs-human].each do |af|
        full = File.join(art_dir, af)
        artifacts[af] = File.read(full) if File.file?(full)
      end
      Dir.glob(File.join(art_dir, 'specs', '**', 'spec.md')).sort.each do |sf|
        artifacts[sf.delete_prefix("#{art_dir}/")] = File.read(sf)
      end
    end
    events = if File.file?(O::EVENTS_FILE)
               File.foreach(O::EVENTS_FILE).filter_map do |line|
                 e = JSON.parse(line)
                 e if e['change'] == name
               rescue JSON::ParserError
                 nil
               end
             else
               []
             end
    b_path = File.join(O::BLOCKED_DIR, "#{name}.json")
    proposal = Proposals.read(Proposals::FILE).find { |i| i['change_name'] == name }
    item = backlog_items.find { |i| i['change_name'] == name } || history_items.find { |i| i['change_name'] == name } || proposal
    wt_root = File.directory?(File.join(O::WORKTREE_BASE, "worker-#{name}")) ? File.join(O::WORKTREE_BASE, "worker-#{name}") : ROOT
    rules = (File.read(File.join(ROOT, OpenSpecPrompts::RULES)) rescue '')
    mem_block = (OpenSpecMemory.prompt_block(wt_root, []) rescue '')
    rendered_prompts = {
      'plan' => (OpenSpecPrompts.render(ROOT, 'plan', 'change' => name, 'goal' => (item && item['description']).to_s,
                                                      'memory' => mem_block, 'jev_hint' => '', 'authoring_rules' => rules, 'feedback' => '') rescue nil),
      'build' => (OpenSpecPrompts.render(ROOT, 'build', 'change' => name, 'branch' => "feat/spec-#{name}",
                                                        'memory' => mem_block, 'jev_hint' => '', 'authoring_rules' => rules, 'feedback' => '', 'rebuild' => '') rescue nil)
    }.compact
    {
      'change_name' => name,
      'worktree_exists' => File.directory?(File.join(O::WORKTREE_BASE, "worker-#{name}")),
      'item' => item, 'blocked' => (read_json(b_path) if File.file?(b_path)),
      'ready_manifest' => read_json(File.join(O::READY_DIR, "#{name}.json")),
      'artifact_source' => art_source, 'artifacts' => artifacts,
      'prompts' => prompts, 'rendered_prompts' => rendered_prompts,
      'jev_states' => jev_states, 'worker_files' => worker_files,
      'events' => events, 'worker_log' => (File.file?(log_path) ? File.read(log_path) : nil)
    }
  end

  def prompt_templates_detail
    %w[plan build cycle].map do |role|
      file = OpenSpecPrompts.path(ROOT, role)
      raw = File.file?(file) ? File.read(file) : ''
      rendered = begin
        if role == 'cycle'
          OpenSpecPrompts.render(ROOT, 'cycle')
        else
          OpenSpecPrompts.render(ROOT, role,
                                 'change' => 'example-change', 'goal' => 'Example backlog item description',
                                 'branch' => 'feat/spec-example-change', 'memory' => OpenSpecMemory.prompt_block(ROOT, []),
                                 'jev_hint' => '', 'authoring_rules' => (File.read(File.join(ROOT, OpenSpecPrompts::RULES)) rescue ''),
                                 'feedback' => '', 'rebuild' => '')
        end
      rescue StandardError => e
        "render error: #{e.message}"
      end
      {
        'role' => role, 'path' => "#{OpenSpecPrompts::DIR}/#{role}.md",
        'version' => (File.file?(file) ? OpenSpecPrompts.version(ROOT, role) : nil),
        'placeholders' => (File.file?(file) ? OpenSpecPrompts.placeholders(ROOT, role) : []),
        'raw' => raw, 'rendered' => rendered
      }
    end
  end

  # Structured view of log/ organized by agentic subsystem, with clear context for every artifact.
  def agentic_observatory
    cycle_dir = File.join(LOG, 'cycle')
    cycle_state = read_json(File.join(cycle_dir, 'state.json'), {})
    cycle_runs = Dir.glob(File.join(cycle_dir, 'cycle-*.log')).sort.reverse.first(25).map do |f|
      stamp = File.basename(f, '.log').delete_prefix('cycle-')
      summary = (CycleProgress.cycle_summary(f, nil) rescue { 'stamp' => stamp, 'outcome' => 'unknown' })
      prompt_rel = "prompt-#{stamp}.md"
      report_file = Dir.glob(File.join(cycle_dir, 'reports', "*#{stamp}*.md")).reject { |r| File.basename(r).start_with?('visual-') }.first
      {
        'stamp' => stamp, 'at' => summary['at'], 'outcome' => summary['outcome'],
        'strategy' => summary['strategy'], 'engine' => summary['engine'],
        'log_file' => File.basename(f),
        'prompt_file' => (prompt_rel if File.file?(File.join(cycle_dir, prompt_rel))),
        'report_file' => (File.basename(report_file) if report_file)
      }
    end
    visual_sessions = Dir.glob(File.join(cycle_dir, 'visual-*.md')).sort.reverse.first(20).map do |f|
      stamp = File.basename(f, '.md').delete_prefix('visual-')
      rep = File.join(cycle_dir, 'reports', "visual-#{stamp}.md")
      sync = File.join(cycle_dir, "visual-#{stamp}.sync.log")
      {
        'stamp' => stamp, 'plan_file' => File.basename(f),
        'report_file' => ("visual-#{stamp}.md" if File.file?(rep)),
        'sync_log' => ("visual-#{stamp}.sync.log" if File.file?(sync))
      }
    end
    workers_by_change = changes_catalog.select { |c| c['has_worker_log'] || c['prompt_count'].positive? || c['has_worktree'] }.map do |c|
      name = c['change_name']
      wdir = File.join(O::WORKER_LOG_DIR, name)
      prompts = File.directory?(wdir) ? Dir.glob(File.join(wdir, '*.prompt.md')).sort.map { |p| "#{name}/#{File.basename(p)}" } : []
      jevs = File.directory?(wdir) ? Dir.glob(File.join(wdir, 'jev-*.state.json')).sort.map { |j| "#{name}/#{File.basename(j)}" } : []
      { 'change_name' => name, 'state' => c['state'], 'worker_log' => ("#{name}.log" if c['has_worker_log']),
        'prompts' => prompts, 'jev_states' => jevs }
    end
    recent_events = if File.file?(O::EVENTS_FILE)
                      File.readlines(O::EVENTS_FILE).last(80).reverse.filter_map { |l| JSON.parse(l) rescue nil }
                    else
                      []
                    end
    blocked_history = Dir.glob(File.join(O::BLOCKED_HISTORY_DIR, '*.json')).sort.reverse.first(20).filter_map do |f|
      (read_json(f) || {}).merge('file' => File.basename(f))
    end
    rebuilds = Dir.glob(File.join(O::REBUILD_DIR, '*.json')).sort.filter_map do |f|
      (read_json(f) || {}).merge('change_name' => File.basename(f, '.json'))
    end
    {
      'cycles' => {
        'context' => 'Scheduled hourly judgment runs (bin/run_cycle.sh in .worktrees/_cycle): each run has its execution log, the rendered cycle prompt and the judgment report.',
        'state' => cycle_state, 'cron_log' => File.file?(File.join(cycle_dir, 'cron.log')), 'runs' => cycle_runs
      },
      'visual_qa' => {
        'context' => 'Browser verification queue (log/cycle/visual_queue.json) and visual QA sessions (.worktrees/_visual_qa).',
        'enabled' => VisualQA.enabled?, 'queue' => VisualQA.load, 'sessions' => visual_sessions
      },
      'workers' => {
        'context' => 'Per-change PLAN and BUILD worker executions (log/workers/<change>.log, rendered prompts in log/workers/<change>/*.prompt.md, and Jev gate inputs jev-*.state.json).',
        'items' => workers_by_change
      },
      'events' => {
        'context' => 'Structured orchestrator event stream (log/events.jsonl): change lifecycle, agent calls with prompt/memory versions, Jev evaluations and merger integrations.',
        'recent' => recent_events
      },
      'recovery_state' => {
        'context' => 'Self-healing runtime state: engine deferrals (log/deferrals.json), automatic blocked retry counters (log/blocked_retries.json), healed block records (log/blocked/history/), conflict rebuilds (log/rebuilds/) and last dispatch results (log/dispatch_results.json).',
        'deferrals' => read_json(File.join(LOG, 'deferrals.json'), {}),
        'blocked_retries' => read_json(O::RETRIES_FILE, {}),
        'blocked_history' => blocked_history, 'rebuilds' => rebuilds,
        'dispatch_results' => read_json(File.join(LOG, 'dispatch_results.json'))
      }
    }
  end

  def logs_catalog
    cycles = Dir.glob(File.join(LOG, 'cycle', 'cycle-*.log')).sort.reverse.first(50).map { |f| File.basename(f) }
    reports = Dir.glob(File.join(LOG, 'cycle', 'reports', '*.md')).sort.reverse.first(50).map { |f| File.basename(f) }
    workers = Dir.glob(File.join(O::WORKER_LOG_DIR, '*.log')).sort.reverse.map { |f| File.basename(f) }
    worker_files = if File.directory?(O::WORKER_LOG_DIR)
                     Dir.glob(File.join(O::WORKER_LOG_DIR, '**', '*'), File::FNM_DOTMATCH).select { |f| File.file?(f) }.sort.map do |f|
                       rel = f.delete_prefix("#{O::WORKER_LOG_DIR}/")
                       { 'path' => rel, 'size' => File.size(f), 'mtime' => File.mtime(f).utc.iso8601 }
                     end
                   else
                     []
                   end
    { 'cycles' => cycles, 'reports' => reports, 'workers' => workers, 'worker_files' => worker_files,
      'observatory' => agentic_observatory }
  end

  def read_log_file(kind, name)
    case kind
    when 'cycle'
      return nil unless name.to_s.match?(/\A[A-Za-z0-9._-]+\z/)

      path = File.join(LOG, 'cycle', name)
    when 'report'
      return nil unless name.to_s.match?(/\A[A-Za-z0-9._-]+\z/)

      path = File.join(LOG, 'cycle', 'reports', name)
    when 'worker'
      return nil if name.to_s.empty?

      cand = File.expand_path(name.to_s, O::WORKER_LOG_DIR)
      return nil unless cand.start_with?("#{O::WORKER_LOG_DIR}/")

      path = cand
    when 'events'
      path = O::EVENTS_FILE
    end
    path && File.file?(path) ? File.read(path) : nil
  end
end
