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
  CACHE = {}
  CACHE_MUTEX = Mutex.new
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
      'portal_runs' => running_runs,
      'portal_jobs' => running_jobs
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
      tasks_done, tasks_total = task_progress(tasks_file)
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

  # Memoizes the result of a block while a file signature (mtime and size) holds.
  def cached(key, sig)
    entry = CACHE_MUTEX.synchronize { CACHE[key] }
    return entry[1] if entry && entry[0] == sig

    value = yield
    CACHE_MUTEX.synchronize { CACHE[key] = [sig, value] }
    value
  end

  def file_sig(path)
    File.file?(path) ? [File.mtime(path).to_f, File.size(path)] : nil
  end

  # Text of a file, or only its last `tail` bytes (from a whole line on) when it is longer.
  def read_text(path, tail: nil)
    size = File.size(path)
    truncated = tail.to_i.positive? && size > tail
    text = if truncated
             File.open(path, 'rb') { |f| f.seek(size - tail); f.read }.force_encoding('UTF-8').scrub.sub(/\A[^\n]*\n/, '')
           else
             File.read(path).force_encoding('UTF-8').scrub
           end
    { 'content' => text, 'size' => size, 'truncated' => truncated, 'mtime' => File.mtime(path).utc.iso8601 }
  end

  # [checked, total] of the task list of a change.
  def task_progress(tasks_file)
    done = total = 0
    return [0, 0] unless File.file?(tasks_file)

    File.foreach(tasks_file) do |line|
      if line.match?(/^\s*[-*+]\s+\[[xX]\]/)
        done += 1
        total += 1
      elsif line.match?(/^\s*[-*+]\s+\[\s\]/)
        total += 1
      end
    end
    [done, total]
  end

  # A UTC stamp as the kit writes them (20261023T170001Z, the Z optional) as a Time; nil when it is none.
  def stamp_utc(stamp)
    m = stamp.to_s.match(/\A(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z?\z/) or return nil
    Time.utc(*m.captures.map(&:to_i))
  end

  def parse_prompt_file(path)
    base = File.basename(path)
    stamp, phase = base.sub(/\.prompt\.md\z/, '').split('-', 2)
    phase ||= 'run'
    { 'file' => base, 'timestamp' => stamp, 'phase' => phase,
      'role' => phase.start_with?('plan') ? 'plan' : 'build', 'repair' => phase.include?('repair'),
      'size' => File.size(path), 'at' => (stamp_utc(stamp) || File.mtime(path)).utc.iso8601 }
  end

  # Every PLAN and BUILD prompt a change was run with, oldest first (no content).
  def change_prompts(name)
    dir = File.join(O::WORKER_LOG_DIR, name)
    return [] unless File.directory?(dir)

    Dir.glob(File.join(dir, '*.prompt.md')).sort.map { |f| parse_prompt_file(f) }
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
    archived = Dir.glob(File.join(ROOT, 'openspec', 'changes', 'archive', '*')).each_with_object({}) do |d, acc|
      m = File.basename(d).match(/\A(\d{4}-\d{2}-\d{2})-(.+)\z/)
      acc[m[2]] = "#{m[1]}T00:00:00Z" if m && File.directory?(d)
    end
    names = (backlog.keys + history.keys + blocked.keys + ready + leases.keys + wt_changes + worker_dirs + worker_logs + archived.keys).compact.uniq
    names.select! { |n| n.match?(O::CHANGE_NAME) }

    names.map do |name|
      state = if leases[name] == true then 'in_flight'
              elsif leases[name] == false then 'stale_lock'
              elsif ready.include?(name) then 'ready_to_merge'
              elsif blocked.key?(name) then 'blocked'
              elsif history.key?(name) || archived.key?(name) then 'integrated'
              elsif wt_changes.include?(name) then 'worktree'
              elsif backlog.key?(name) then 'queued'
              else 'recorded'
              end
      prompts = change_prompts(name)
      item = backlog[name] || history[name] || {}
      # Prompt stamps are written once; file mtimes move when logs are copied or restored, so they are only a fallback.
      touched = prompts.map { |p| p['at'] }
      if touched.empty?
        [File.join(O::WORKER_LOG_DIR, "#{name}.log"), File.join(O::BLOCKED_DIR, "#{name}.json"),
         File.join(O::READY_DIR, "#{name}.json")].each do |f|
          touched << File.mtime(f).utc.iso8601 if File.file?(f)
        end
      end
      touched << item['integrated_at'] << archived[name]
      {
        'change_name' => name, 'state' => state, 'priority' => item['priority'],
        'description' => item['description'], 'blocked_reason' => blocked.dig(name, 'reason'),
        'prompt_count' => prompts.size, 'plan_count' => prompts.count { |p| p['role'] == 'plan' },
        'build_count' => prompts.count { |p| p['role'] == 'build' }, 'repair_count' => prompts.count { |p| p['repair'] },
        'has_worktree' => wt_changes.include?(name),
        'has_worker_log' => File.file?(File.join(O::WORKER_LOG_DIR, "#{name}.log")),
        'integrated_at' => item['integrated_at'], 'updated_at' => touched.compact.max
      }
    end.sort_by { |c| [%w[in_flight stale_lock blocked ready_to_merge worktree].index(c['state']) || 9, c['change_name']] }
  end

  ARTIFACT_FILES = %w[proposal.md design.md tasks.md repairs.md handoff.md .needs-human].freeze

  def change_artifact_list(art_dir)
    return [] unless art_dir

    names = ARTIFACT_FILES.select { |af| File.file?(File.join(art_dir, af)) }
    names += Dir.glob(File.join(art_dir, 'specs', '**', 'spec.md')).sort.map { |sf| sf.delete_prefix("#{art_dir}/") }
    names.map { |n| { 'name' => n, 'size' => File.size(File.join(art_dir, n)) } }
  end

  # Events of one change, newest first (the last `limit`).
  def change_events(name, limit = 300)
    return [] unless File.file?(O::EVENTS_FILE)

    cached("change-events:#{name}", file_sig(O::EVENTS_FILE)) do
      found = []
      File.foreach(O::EVENTS_FILE) do |line|
        line = line.scrub
        next unless line.include?(name)

        begin
          e = JSON.parse(line)
          found << e if e['change'] == name
        rescue JSON::ParserError
          next
        end
      end
      found.last(limit).reverse
    end
  end

  def rendered_prompt(name, role)
    item = backlog_items.find { |i| i['change_name'] == name } || history_items.find { |i| i['change_name'] == name } ||
           Proposals.read(Proposals::FILE).find { |i| i['change_name'] == name }
    wt = File.join(O::WORKTREE_BASE, "worker-#{name}")
    memory = OpenSpecMemory.prompt_block(File.directory?(wt) ? wt : ROOT, capabilities: [])
    rules = (File.read(File.join(ROOT, OpenSpecPrompts::RULES)) rescue '')
    case role
    when 'plan'
      OpenSpecPrompts.render(ROOT, 'plan', 'change' => name, 'goal' => (item && item['description']).to_s,
                                           'memory' => memory, 'jev_hint' => '', 'authoring_rules' => rules, 'feedback' => '')
    when 'build'
      OpenSpecPrompts.render(ROOT, 'build', 'change' => name, 'branch' => "feat/spec-#{name}", 'memory' => memory,
                                            'jev_hint' => '', 'authoring_rules' => rules, 'feedback' => '', 'rebuild' => '')
    end
  end

  # Everything about one change except file contents (read them with change_file).
  def change_detail(change)
    name = change.to_s.strip
    return nil unless name.match?(O::CHANGE_NAME)

    entry = changes_catalog.find { |c| c['change_name'] == name }
    return nil unless entry

    wt = File.join(O::WORKTREE_BASE, "worker-#{name}")
    wdir = File.join(O::WORKER_LOG_DIR, name)
    art_dir, art_source = change_artifact_dir(name)
    log_path = File.join(O::WORKER_LOG_DIR, "#{name}.log")
    jev = File.directory?(wdir) ? Dir.glob(File.join(wdir, 'jev-*.state.json')).sort.map { |f| { 'file' => File.basename(f), 'size' => File.size(f) } } : []
    done, total = task_progress(File.join(art_dir.to_s, 'tasks.md'))
    lease_file = File.join(O::LOCK_DIR, "#{name}.lock")
    lease = File.file?(lease_file) ? read_json(lease_file, {}).merge('alive' => alive?(read_json(lease_file, {})['pid'])) : nil
    item = backlog_items.find { |i| i['change_name'] == name } || history_items.find { |i| i['change_name'] == name } ||
           Proposals.read(Proposals::FILE).find { |i| i['change_name'] == name }
    {
      'change_name' => name, 'state' => entry['state'], 'updated_at' => entry['updated_at'],
      'worktree_exists' => File.directory?(wt), 'worktree' => (wt if File.directory?(wt)),
      'item' => item, 'blocked' => blocked_items.find { |b| b['change_name'] == name },
      'ready_manifest' => read_json(File.join(O::READY_DIR, "#{name}.json")), 'lease' => lease,
      'artifact_source' => art_source, 'artifacts' => change_artifact_list(art_dir),
      'progress' => { 'done' => done, 'total' => total },
      'prompts' => change_prompts(name), 'rendered' => %w[plan build],
      'jev_states' => jev,
      'worker_log' => (File.file?(log_path) ? { 'size' => File.size(log_path), 'mtime' => File.mtime(log_path).utc.iso8601 } : nil),
      'events' => change_events(name),
      'runs' => read_runs.select { |r| r['change'] == name }.first(25)
    }
  end

  # One file of a change: a prompt, an artifact, a Jev state, the worker log or a rendered prompt.
  def change_file(change, kind, file, tail: nil)
    name = change.to_s.strip
    return nil unless name.match?(O::CHANGE_NAME)

    file = file.to_s
    path = case kind
           when 'prompt'
             File.join(O::WORKER_LOG_DIR, name, file) if file.match?(/\A[A-Za-z0-9._-]+\.prompt\.md\z/)
           when 'jev'
             File.join(O::WORKER_LOG_DIR, name, file) if file.match?(/\A[A-Za-z0-9._-]+\.json\z/)
           when 'log'
             File.join(O::WORKER_LOG_DIR, "#{name}.log")
           when 'artifact'
             art_dir, = change_artifact_dir(name)
             File.join(art_dir, file) if art_dir && change_artifact_list(art_dir).any? { |a| a['name'] == file }
           when 'rendered'
             begin
               text = %w[plan build].include?(file) ? rendered_prompt(name, file) : nil
             rescue StandardError => e
               return { 'error' => e.message }
             end
             return { 'content' => text, 'size' => text.bytesize, 'truncated' => false, 'mtime' => now } if text
           end
    path && File.file?(path) ? read_text(path, tail: tail) : nil
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
                                 'branch' => 'feat/spec-example-change', 'memory' => OpenSpecMemory.prompt_block(ROOT, capabilities: []),
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

  # Self-healing runtime state: engine deferrals, retry counters, healed blocks, conflict rebuilds and the last dispatch.
  def recovery_state
    blocked_history = Dir.glob(File.join(O::BLOCKED_HISTORY_DIR, '*.json')).sort.reverse.first(50).filter_map do |f|
      (read_json(f) || {}).merge('file' => File.basename(f))
    end
    rebuilds = Dir.glob(File.join(O::REBUILD_DIR, '*.json')).sort.filter_map do |f|
      (read_json(f) || {}).merge('change_name' => File.basename(f, '.json'))
    end
    {
      'deferrals' => read_json(File.join(LOG, 'deferrals.json'), {}),
      'blocked_retries' => read_json(O::RETRIES_FILE, {}),
      'blocked_history' => blocked_history, 'rebuilds' => rebuilds,
      'dispatch_results' => read_json(File.join(LOG, 'dispatch_results.json'))
    }
  end

  LOG_NAME = /\A[A-Za-z0-9._-]+\z/

  # A file under log/ by kind (cycle, report, worker, events, run, job), with its size and mtime; nil when absent.
  def log_file(kind, name, tail: nil)
    name = name.to_s
    path = case kind
           when 'cycle' then File.join(LOG, 'cycle', name) if name.match?(LOG_NAME)
           when 'report' then File.join(LOG, 'cycle', 'reports', name) if name.match?(LOG_NAME)
           when 'worker'
             cand = File.expand_path(name, O::WORKER_LOG_DIR)
             cand if !name.empty? && cand.start_with?("#{O::WORKER_LOG_DIR}/")
           when 'events' then O::EVENTS_FILE
           when 'run' then File.join(RUNS_DIR, name) if name.match?(/\A[\w-]+\.(prompt\.md|out\.log)\z/)
           when 'job' then File.join(JOBS_DIR, name) if name.match?(/\A[\w-]+\.out\.log\z/)
           end
    path && File.file?(path) ? read_text(path, tail: tail) : nil
  end
end
