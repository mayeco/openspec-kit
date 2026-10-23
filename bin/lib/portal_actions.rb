# frozen_string_literal: true

# ==============================================================================
# bin/lib/portal_actions.rb
#
# Operator actions for bin/portal.rb: pause/resume, agent pings and prompt runs
# (on the root checkout or inside a change's worktree), preflight health checks,
# background kit jobs, backlog and quarantine management, stale lease
# reclamation and individual worker worktree operations.
# ==============================================================================

module OpenSpecPortal
  PING_COMMANDS = {
    'claude' => ['claude', '-p', 'Reply with the single word: pong', '--max-budget-usd', '0.50', '--no-session-persistence', '@EXTRA@'],
    'codex' => ['codex', 'exec', '@EXTRA@', 'Reply with the single word: pong'],
    'copilot' => ['copilot', '-p', 'Reply with the single word: pong', '--silent', '@EXTRA@'],
    'hermes' => ['hermes', '-z', 'Reply with the single word: pong', '@EXTRA@'],
    'opencode' => ['opencode', 'run', '@EXTRA@', 'Reply with the single word: pong'],
    'agy' => ['agy', '-p', 'Reply with the single word: pong', '--print-timeout', '170s', '@EXTRA@'],
    'kilo' => ['kilo', 'run', '--agent', 'code', '@EXTRA@', 'Reply with the single word: pong'],
    'cline' => ['cline', '--yolo', '@EXTRA@', 'Reply with the single word: pong'],
    'pi' => ['pi', '-p', '--no-session', '@EXTRA@', '--', 'Reply with the single word: pong'],
    'omp' => ['omp', '-p', '--no-session', '@EXTRA@', 'Reply with the single word: pong'],
    'crush' => ['crush', 'run', '--quiet', '@EXTRA@', 'Reply with the single word: pong'],
    'cursor-agent' => ['cursor-agent', '-p', '--trust', '@EXTRA@', 'Reply with the single word: pong'],
    'zcode' => ['zcode', '-p', 'Reply with the single word: pong', '@EXTRA@']
  }.freeze
  AUTH_ERRORS = /Not logged in|authentication_error|Invalid API key|Please run \/login|401 Unauthorized|No authentication information found|No models available|No API key for/i

  module_function

  def ping_agent(agent, timeout: 60)
    agent = agent.to_s.strip
    raise ArgumentError, "unknown agent #{agent}" unless OpenSpecAgents::SUPPORTED.key?(agent) || agent == 'stub'

    started = Time.now
    if agent == 'stub'
      stub = ENV['AGENT_STUB']
      return { 'agent' => 'stub', 'status' => 'not_installed', 'detail' => 'AGENT_STUB is not set' } if stub.to_s.empty? || !File.exist?(stub)

      res = sh('bash', stub, File::NULL, timeout: timeout)
      return { 'agent' => 'stub', 'status' => (res.ok? ? 'ok' : 'failed'), 'code' => res.code,
               'latency_ms' => ((Time.now - started) * 1000).round, 'output' => res.out.strip }
    end
    return { 'agent' => agent, 'status' => 'not_installed', 'detail' => "#{agent} not found on PATH" } unless which?(agent)

    extra = OpenSpecAgents.extra_args(ROOT, agent)
    cmd = PING_COMMANDS.fetch(agent).flat_map { |arg| arg == '@EXTRA@' ? extra : [arg] }
    res = sh(*cmd, timeout: timeout)
    ms = ((Time.now - started) * 1000).round
    out = res.out.to_s.gsub(/\e\[[0-9;]*m/, '').strip
    status = if out.match?(AUTH_ERRORS) then 'auth_failed'
             elsif !res.ok? && res.code != 124 then 'failed'
             elsif res.ok? && !out.empty? then 'ok'
             else 'timeout'
             end
    { 'agent' => agent, 'status' => status, 'code' => res.code, 'latency_ms' => ms,
      'output' => out.lines.last(5).join.strip[0, 300] }
  end

  def run_health_check(services_only: false, timeout: 240)
    ensure_dirs!
    args = ['bash', File.join(ROOT, 'bin', 'check_ai_engines.sh')]
    args << '--services' if services_only
    res = sh(*args, timeout: timeout)
    summary = res.out.lines.reverse.find { |l| l.start_with?('preflight:') }&.strip || (res.ok? ? 'preflight: OK' : 'preflight: FAIL')
    last = { 'checked_at' => now, 'services_only' => services_only, 'ok' => res.ok?, 'code' => res.code,
             'summary' => summary, 'output' => res.out }
    O.write_json_atomic(File.join(PORTAL_DIR, 'last_health.json'), last)
    last
  end

  RUN_ID = /\A[A-Za-z0-9_-]+\z/
  OUTPUT_TAIL = 200_000

  # The worker worktree a directory is, as a change name (nil for any other directory).
  def change_for_workdir(workdir)
    return nil unless File.dirname(workdir.to_s) == O::WORKTREE_BASE

    File.basename(workdir)[/\Aworker-(.+)\z/, 1]
  end

  # Waits for a process the portal spawned and records how it ended (a stop the operator asked for is `stopped`).
  def watch_process(pid, meta_file, meta)
    Thread.new do
      _, st = Process.wait2(pid)
      code = st.exitstatus || (128 + st.termsig.to_i)
      cur = read_json(meta_file, meta)
      status = cur['stop_requested'] ? 'stopped' : (code.zero? ? 'ok' : 'failed')
      O.write_json_atomic(meta_file, cur.merge('status' => status, 'code' => code, 'finished_at' => now))
    rescue StandardError
      nil
    end
  end

  def run_agent_prompt(agent:, prompt:, async: false, workdir: ROOT, parent: nil, relation: nil, summary: nil)
    ensure_dirs!
    agent = agent.to_s.strip
    prompt = prompt.to_s
    raise ArgumentError, 'prompt cannot be empty' if prompt.strip.empty?
    unless agent.empty? || agent == 'stub' || OpenSpecAgents::SUPPORTED.key?(agent)
      raise ArgumentError, "unknown agent #{agent} (supported: #{OpenSpecAgents::SUPPORTED.keys.join(', ')})"
    end
    raise ArgumentError, "workdir #{workdir} does not exist" unless File.directory?(workdir)

    id = "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(3)}"
    prompt_file = File.join(RUNS_DIR, "#{id}.prompt.md")
    out_file = File.join(RUNS_DIR, "#{id}.out.log")
    meta_file = File.join(RUNS_DIR, "#{id}.json")
    File.write(prompt_file, prompt)
    chosen = agent.empty? ? (OpenSpecAgents.load(ROOT)&.fetch('agents', [])&.first || '') : agent
    meta = {
      'id' => id, 'agent' => (chosen.empty? ? 'auto' : chosen), 'prompt' => prompt, 'workdir' => workdir,
      'started_at' => now, 'status' => 'running', 'pid' => nil, 'code' => nil, 'finished_at' => nil
    }
    meta['change'] = change_for_workdir(workdir) if change_for_workdir(workdir)
    meta['parent'] = parent if parent
    meta['relation'] = relation if relation
    meta['summary'] = summary if summary
    O.write_json_atomic(meta_file, meta)
    cmd = ['bash', File.join(ROOT, 'bin', 'agent_exec.sh'), workdir, prompt_file]
    cmd << chosen unless chosen.empty?

    if async
      pid = Process.spawn({ 'PATH' => PATH_ENV }, *cmd, chdir: workdir, out: [out_file, 'w'], err: [:child, :out], in: File::NULL, pgroup: true)
      meta['pid'] = pid
      O.write_json_atomic(meta_file, meta)
      watch_process(pid, meta_file, meta)
      return meta.merge('output' => '')
    end

    res = O.run(cmd, chdir: workdir, timeout: OpenSpecSettings.get(ROOT, 'limits.agent_seconds'), env: { 'PATH' => PATH_ENV })
    File.write(out_file, res.out)
    meta.merge!('status' => (res.ok? ? 'ok' : 'failed'), 'code' => res.code, 'finished_at' => now)
    O.write_json_atomic(meta_file, meta)
    meta.merge('output' => res.out)
  end

  # A new run that carries an earlier run's request and output as context, plus the operator's follow-up.
  def continue_run!(id, prompt:, agent: nil, context: true, async: true)
    prev = get_run(id) or raise ArgumentError, 'run not found'
    follow = prompt.to_s.strip
    raise ArgumentError, 'follow-up cannot be empty' if follow.empty?

    text = if context
             tail = prev['output'].to_s[-6000..] || prev['output'].to_s
             "You are continuing an earlier agent run in the same working directory.\n\n## Previous request\n\n#{prev['prompt']}\n\n" \
               "## Previous output (last part)\n\n#{tail}\n\n## Follow-up\n\n#{follow}\n"
           else
             follow
           end
    workdir = File.directory?(prev['workdir'].to_s) ? prev['workdir'] : ROOT
    run_agent_prompt(agent: agent.to_s.strip.empty? ? prev['agent'].to_s.sub('auto', '') : agent, prompt: text, async: async,
                     workdir: workdir, parent: id, relation: 'continue', summary: follow)
  end

  # The same request again, in the same directory, with the same agent unless another one is named.
  def rerun_run!(id, agent: nil, async: true)
    prev = get_run(id) or raise ArgumentError, 'run not found'
    workdir = File.directory?(prev['workdir'].to_s) ? prev['workdir'] : ROOT
    run_agent_prompt(agent: agent.to_s.strip.empty? ? prev['agent'].to_s.sub('auto', '') : agent, prompt: prev['prompt'], async: async,
                     workdir: workdir, parent: id, relation: 'rerun', summary: prev['summary'])
  end

  def run_title(meta)
    (meta['summary'] || meta['prompt']).to_s.lines.map(&:strip).find { |l| !l.empty? }.to_s[0, 110]
  end

  def tail_of(path, bytes = OUTPUT_TAIL)
    return ['', 0, false] unless File.exist?(path)

    size = File.size(path)
    return [File.read(path).force_encoding('UTF-8').scrub, size, false] if size <= bytes

    [File.open(path, 'rb') { |f| f.seek(size - bytes); f.read }.force_encoding('UTF-8').scrub, size, true]
  end

  def decorate_run(meta, file, output)
    out_path = file.sub(/\.json\z/, '.out.log')
    started = Time.parse(meta['started_at']) rescue nil
    ended = (Time.parse(meta['finished_at']) rescue nil) || (Time.now if meta['status'] == 'running')
    meta = meta.merge('title' => run_title(meta), 'output_size' => (File.size(out_path) if File.exist?(out_path)).to_i,
                      'duration_seconds' => (started && ended ? (ended - started).round : nil))
    meta['change'] ||= change_for_workdir(meta['workdir'])
    return meta unless output

    text, _size, truncated = tail_of(out_path)
    meta.merge('output' => text, 'output_truncated' => truncated)
  end

  def fix_stale!(file, meta, label)
    return unless meta['status'] == 'running' && meta['pid'] && !alive?(meta['pid'])

    meta['status'] = meta['stop_requested'] ? 'stopped' : label
    O.write_json_atomic(file, meta)
  end

  # Manual agent runs, newest first, without their output unless asked.
  def read_runs(output: false, limit: nil)
    files = Dir.glob(File.join(RUNS_DIR, '*.json')).sort.reverse
    files = files.first(limit) if limit
    files.filter_map do |f|
      m = read_json(f) or next
      fix_stale!(f, m, 'stopped')
      decorate_run(m, f, output)
    end
  end

  def list_runs(limit = 25, output: true) = read_runs(output: output, limit: limit)

  def running_runs = read_runs(limit: 100).select { |r| r['status'] == 'running' }

  def get_run(id)
    return nil unless id.to_s.match?(RUN_ID)

    f = File.join(RUNS_DIR, "#{id}.json")
    return nil unless File.exist?(f)

    m = read_json(f) or return nil
    fix_stale!(f, m, 'stopped')
    run = decorate_run(m, f, true)
    others = read_runs
    run.merge('children' => others.select { |r| r['parent'] == id }.reverse,
              'parent_run' => others.find { |r| r['id'] == m['parent'] })
  end

  def stop_process!(meta_file)
    meta = read_json(meta_file) or raise ArgumentError, 'not found'
    raise ArgumentError, 'it is not running' unless meta['status'] == 'running' && alive?(meta['pid'])

    O.write_json_atomic(meta_file, meta.merge('stop_requested' => true))
    begin
      Process.kill('TERM', -meta['pid'].to_i)
    rescue Errno::ESRCH, Errno::EPERM
      Process.kill('TERM', meta['pid'].to_i)
    end
    meta
  rescue Errno::ESRCH
    meta
  end

  def stop_run!(id)
    raise ArgumentError, 'invalid run id' unless id.to_s.match?(RUN_ID)

    stop_process!(File.join(RUNS_DIR, "#{id}.json"))
  end

  def stop_job!(id)
    raise ArgumentError, 'invalid job id' unless id.to_s.match?(RUN_ID)

    stop_process!(File.join(JOBS_DIR, "#{id}.json"))
  end

  def start_job(kind, *cmd)
    ensure_dirs!
    id = "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{kind}-#{SecureRandom.hex(2)}"
    out_file = File.join(JOBS_DIR, "#{id}.out.log")
    meta_file = File.join(JOBS_DIR, "#{id}.json")
    pid = Process.spawn({ 'PATH' => PATH_ENV }, *cmd.map(&:to_s), chdir: ROOT,
                        out: [out_file, 'w'], err: [:child, :out], in: File::NULL, pgroup: true)
    meta = { 'id' => id, 'kind' => kind, 'command' => cmd.join(' '), 'pid' => pid, 'started_at' => now, 'status' => 'running' }
    O.write_json_atomic(meta_file, meta)
    watch_process(pid, meta_file, meta)
    meta
  end

  def decorate_job(meta, file, output)
    out_path = file.sub(/\.json\z/, '.out.log')
    started = Time.parse(meta['started_at']) rescue nil
    ended = (Time.parse(meta['finished_at']) rescue nil) || (Time.now if meta['status'] == 'running')
    meta = meta.merge('output_size' => (File.size(out_path) if File.exist?(out_path)).to_i,
                      'duration_seconds' => (started && ended ? (ended - started).round : nil))
    return meta unless output

    text, _size, truncated = tail_of(out_path)
    meta.merge('output' => text, 'output_truncated' => truncated)
  end

  # Background kit jobs, newest first, without their output unless asked.
  def read_jobs(output: false, limit: nil)
    files = Dir.glob(File.join(JOBS_DIR, '*.json')).sort.reverse
    files = files.first(limit) if limit
    files.filter_map do |f|
      m = read_json(f) or next
      fix_stale!(f, m, 'finished')
      decorate_job(m, f, output)
    end
  end

  def list_jobs(limit = 20) = read_jobs(output: true, limit: limit)

  def running_jobs = read_jobs(limit: 50).select { |j| j['status'] == 'running' }

  def get_job(id)
    return nil unless id.to_s.match?(RUN_ID)

    f = File.join(JOBS_DIR, "#{id}.json")
    m = read_json(f) or return nil
    fix_stale!(f, m, 'finished')
    decorate_job(m, f, true)
  end

  def pause!(reason)
    ensure_dirs!
    text = reason.to_s.strip
    text = 'paused from the web portal' if text.empty?
    File.write(O::PAUSE_FILE, "#{text}\n")
    text
  end

  def resume!
    FileUtils.rm_f(O::PAUSE_FILE)
  end

  def add_backlog_item!(change_name:, priority:, description:, depends_on: [])
    name = change_name.to_s.strip
    raise ArgumentError, "invalid change_name #{name.inspect} (lowercase letters, digits and hyphens)" unless name.match?(O::CHANGE_NAME)

    prio = priority.to_s.strip.empty? ? 'normal' : priority.to_s.strip
    raise ArgumentError, "priority must be one of #{KitConfig::PRIORITIES.join(', ')}" unless KitConfig::PRIORITIES.include?(prio)

    desc = description.to_s.strip
    raise ArgumentError, 'description cannot be empty' if desc.empty?

    deps = Array(depends_on).flat_map { |d| d.to_s.split(',') }.map(&:strip).reject(&:empty?).uniq
    items = backlog_items
    raise ArgumentError, "#{name} is already in the backlog" if items.any? { |i| i['change_name'] == name }

    item = { 'change_name' => name, 'priority' => prio, 'description' => desc, 'queued_at' => now }
    item['depends_on'] = deps if deps.any?
    items << item
    Proposals.write(O::BACKLOG_FILE, items)
    item
  end

  def delete_backlog_item!(change_name)
    items = backlog_items
    before = items.size
    items.reject! { |i| i['change_name'] == change_name.to_s.strip }
    raise ArgumentError, "no backlog item named #{change_name}" if items.size == before

    Proposals.write(O::BACKLOG_FILE, items)
  end

  def unblock!(change_name, approve_risk: false, reset_retries: false)
    name = change_name.to_s.strip
    raise ArgumentError, "invalid change name #{name.inspect}" unless name.match?(O::CHANGE_NAME)

    ensure_dirs!
    FileUtils.touch(File.join(O::APPROVED_DIR, name)) if approve_risk
    FileUtils.rm_f(File.join(O::WORKTREE_BASE, "worker-#{name}", 'openspec', 'changes', name, '.needs-human'))
    if reset_retries && File.exist?(O::RETRIES_FILE)
      retries = read_json(O::RETRIES_FILE, {})
      retries.delete(name)
      O.write_json_atomic(O::RETRIES_FILE, retries)
    end
    FileUtils.rm_f(File.join(O::BLOCKED_DIR, "#{name}.json"))
  end

  def reclaim_lease!(change_name)
    name = change_name.to_s.strip
    raise ArgumentError, "invalid change name #{name.inspect}" unless name.match?(O::CHANGE_NAME)

    lock = File.join(O::LOCK_DIR, "#{name}.lock")
    return false unless File.exist?(lock)

    data = read_json(lock, {})
    raise ArgumentError, "#{name} lease is held by live pid #{data['pid']}" if alive?(data['pid'])

    FileUtils.rm_f(lock)
    true
  end

  def validate_worker!(change_name)
    name = change_name.to_s.strip
    raise ArgumentError, "invalid change name #{name.inspect}" unless name.match?(O::CHANGE_NAME)

    wt = File.join(O::WORKTREE_BASE, "worker-#{name}")
    raise ArgumentError, "worktree #{wt} does not exist" unless File.directory?(wt)

    res = O.run(['openspec', 'validate', name, '--strict', '--json'], chdir: wt, timeout: 60, env: { 'PATH' => PATH_ENV })
    { 'ok' => res.ok?, 'code' => res.code, 'output' => res.out }
  end

  def run_worker_gates!(change_name)
    name = change_name.to_s.strip
    raise ArgumentError, "invalid change name #{name.inspect}" unless name.match?(O::CHANGE_NAME)

    wt = File.join(O::WORKTREE_BASE, "worker-#{name}")
    raise ArgumentError, "worktree #{wt} does not exist" unless File.directory?(wt)

    start_job("gates-#{name}", 'bash', File.join(wt, 'bin', 'run_gates.sh'), '--base', "#{O::REMOTE}/#{O::BASE_BRANCH}")
  end

  def reset_worker!(change_name)
    name = change_name.to_s.strip
    raise ArgumentError, "invalid change name #{name.inspect}" unless name.match?(O::CHANGE_NAME)

    lock = File.join(O::LOCK_DIR, "#{name}.lock")
    if File.exist?(lock)
      data = read_json(lock, {})
      raise ArgumentError, "cannot reset #{name} while worker pid #{data['pid']} is alive" if alive?(data['pid'])

      FileUtils.rm_f(lock)
    end
    wt = File.join(O::WORKTREE_BASE, "worker-#{name}")
    branch = "feat/spec-#{name}"
    if File.directory?(wt)
      O.child_paths(wt).each do |rel|
        child = File.join(wt, rel)
        O.git(['checkout', '--detach'], chdir: child) if File.directory?(child)
      end
      sh('git', 'worktree', 'remove', '--force', wt)
      FileUtils.rm_rf(wt)
      sh('git', 'worktree', 'prune')
    end
    O.child_paths(ROOT).each do |rel|
      child = File.join(ROOT, rel)
      O.git(['branch', '-D', branch], chdir: child) if File.directory?(child)
    end
    sh('git', 'branch', '-D', branch)
    FileUtils.rm_f([
                     File.join(O::BLOCKED_DIR, "#{name}.json"),
                     File.join(O::READY_DIR, "#{name}.json"),
                     O.rebuild_file(name)
                   ])
    if File.exist?(O::RETRIES_FILE)
      retries = read_json(O::RETRIES_FILE, {})
      retries.delete(name)
      O.write_json_atomic(O::RETRIES_FILE, retries)
    end
    res_file = File.join(LOG, 'dispatch_results.json')
    if File.exist?(res_file)
      res = read_json(res_file, {})
      if res['results'].is_a?(Hash) && res['results'].delete(name)
        O.write_json_atomic(res_file, res)
      end
    end
    { 'ok' => true, 'change_name' => name }
  end
end
