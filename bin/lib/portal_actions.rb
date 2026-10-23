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

  def run_agent_prompt(agent:, prompt:, async: false, workdir: ROOT)
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
    O.write_json_atomic(meta_file, meta)
    cmd = ['bash', File.join(ROOT, 'bin', 'agent_exec.sh'), workdir, prompt_file]
    cmd << chosen unless chosen.empty?

    if async
      pid = Process.spawn({ 'PATH' => PATH_ENV }, *cmd, chdir: workdir, out: [out_file, 'w'], err: [:child, :out], in: File::NULL, pgroup: true)
      meta['pid'] = pid
      O.write_json_atomic(meta_file, meta)
      Thread.new do
        _, st = Process.wait2(pid)
        code = st.exitstatus || (128 + st.termsig.to_i)
        done = read_json(meta_file, meta).merge('status' => (code.zero? ? 'ok' : 'failed'), 'code' => code, 'finished_at' => now)
        O.write_json_atomic(meta_file, done)
      rescue StandardError
        nil
      end
      return meta.merge('output' => '')
    end

    res = O.run(cmd, chdir: workdir, timeout: OpenSpecSettings.get(ROOT, 'limits.agent_seconds'), env: { 'PATH' => PATH_ENV })
    File.write(out_file, res.out)
    meta.merge!('status' => (res.ok? ? 'ok' : 'failed'), 'code' => res.code, 'finished_at' => now)
    O.write_json_atomic(meta_file, meta)
    meta.merge('output' => res.out)
  end

  def list_runs(limit = 25)
    Dir.glob(File.join(RUNS_DIR, '*.json')).sort.reverse.first(limit).filter_map do |f|
      m = read_json(f) or next
      out_path = f.sub(/\.json\z/, '.out.log')
      if m['status'] == 'running' && m['pid'] && !alive?(m['pid'])
        m['status'] = 'stopped'
        O.write_json_atomic(f, m)
      end
      m.merge('output' => (File.exist?(out_path) ? File.read(out_path)[-8000..] || File.read(out_path) : ''))
    end
  end

  def get_run(id)
    return nil unless id.to_s.match?(/\A[A-Za-z0-9_-]+\z/)

    f = File.join(RUNS_DIR, "#{id}.json")
    return nil unless File.exist?(f)

    m = read_json(f) or return nil
    out_path = File.join(RUNS_DIR, "#{id}.out.log")
    m.merge('output' => (File.exist?(out_path) ? File.read(out_path) : ''))
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
    Thread.new do
      _, st = Process.wait2(pid)
      code = st.exitstatus || (128 + st.termsig.to_i)
      O.write_json_atomic(meta_file, read_json(meta_file, meta).merge('status' => (code.zero? ? 'ok' : 'failed'),
                                                                      'code' => code, 'finished_at' => now))
    rescue StandardError
      nil
    end
    meta
  end

  def list_jobs(limit = 20)
    Dir.glob(File.join(JOBS_DIR, '*.json')).sort.reverse.first(limit).filter_map do |f|
      m = read_json(f) or next
      out_path = f.sub(/\.json\z/, '.out.log')
      if m['status'] == 'running' && m['pid'] && !alive?(m['pid'])
        m['status'] = 'finished'
        O.write_json_atomic(f, m)
      end
      m.merge('output' => (File.exist?(out_path) ? File.read(out_path)[-4000..] || File.read(out_path) : ''))
    end
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
