#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# bin/openspec_dispatcher.rb
#
# Parallel OpenSpec dispatcher. For each backlog item it provisions an isolated
# worktree, runs PLAN (agent writes artifacts until `openspec validate --strict`
# passes), claims the change's capabilities, runs BUILD (agent implements tasks
# in child repos until tasks are complete and gates pass) and hands the result
# to the merger through an atomic manifest in log/ready_to_merge/.
#
# The agent is never trusted: every phase ends with deterministic post-checks.
# ==============================================================================

require 'optparse'
require_relative 'lib/openspec_orchestrator'

class OpenSpecDispatcher
  O = OpenSpecOrchestrator
  PRIORITY = { 'critical' => 0, 'high' => 1, 'normal' => 2, 'low' => 3 }.freeze
  POLL_SECONDS = 2
  FETCH_EVERY_SECONDS = 30
  DEFAULT_WAIT_TIMEOUT = Integer(ENV.fetch('OPENSPEC_WAIT_TIMEOUT', '1800'))
  GATE_TIMEOUT = Integer(ENV.fetch('OPENSPEC_GATE_TIMEOUT', '2700'))
  AGENT_TIMEOUT = Integer(ENV.fetch('AGENT_TIMEOUT_SECONDS', '3600'))
  DEFAULT_ENGINE = ENV.fetch('AGENT_ENGINE', nil)
  ENGINE_PLAN = ENV.fetch('AGENT_ENGINE_PLAN', DEFAULT_ENGINE)
  ENGINE_BUILD = ENV.fetch('AGENT_ENGINE_BUILD', DEFAULT_ENGINE)
  # Workers never publish: strip push credentials from their environment.
  # (A git credential helper such as osxkeychain is not covered; see section 12.)
  AGENT_ENV = %w[SSH_AUTH_SOCK GH_TOKEN GITHUB_TOKEN GITLAB_TOKEN GIT_ASKPASS].to_h { |k| [k, nil] }.freeze

  def initialize(max_workers:, repair_attempts:, backlog_file:, wait:, dry_run:, engine_plan: ENGINE_PLAN, engine_build: ENGINE_BUILD)
    @max_workers = max_workers
    @repair_attempts = repair_attempts
    @backlog_file = backlog_file
    @wait = wait
    @dry_run = dry_run
    @engine_plan = engine_plan
    @engine_build = engine_build
    @git_mutex = Mutex.new    # serializes shared-.git operations (worktrees, config, refs)
    @state_mutex = Mutex.new  # protects the scheduling tables below
    @threads = {}             # change => Thread
    @leases = {}              # change => Lease
    @building = {}            # change => capabilities held while building
    @held = {}                # change => capabilities that conflicted at claim time
    @results = {}             # change => :ready | :blocked | :busy
    @last_fetch = Time.at(0)
  end

  def run
    O.ensure_dirs!
    acquire_singleton!
    O.install_signal_handlers!
    backlog = load_backlog
    by_name = backlog.to_h { |i| [i['change_name'], i] }
    wait_deadline = nil
    O.emit('dispatcher.start', workers: @max_workers, backlog: backlog.size)

    loop do
      reap!
      refresh_remote!(force: @threads.empty?)
      pending = backlog.reject { |item| @threads.key?(item['change_name']) || @results.key?(item['change_name']) }
      eligible = pending.select { |item| eligible?(item) }

      if @dry_run
        puts "eligible: #{eligible.map { |i| i['change_name'] }.join(', ')}"
        return
      end

      if O.paused?
        O.emit('dispatcher.paused') if @threads.empty?
        break if @threads.empty?
      else
        eligible.first([@max_workers - @threads.size, 0].max).each { |item| start(item) }
      end

      if @threads.empty? && (eligible.empty? || O.paused?)
        waiting = pending.select { |i| waiting_on_flight?(i, by_name) }
        break unless @wait && !O.paused? && waiting.any? && Dir.glob(File.join(O::READY_DIR, '*.json')).any?

        wait_deadline ||= Time.now + @wait
        if Time.now >= wait_deadline
          O.emit('dispatcher.wait_timeout', seconds: @wait, waiting: waiting.map { |i| i['change_name'] }.join(','))
          break
        end
      else
        wait_deadline = nil
      end
      @state_mutex.synchronize { @leases.each_value(&:heartbeat!) }
      sleep POLL_SECONDS
    end

    waiting = backlog.select { |i| waiting_on_flight?(i, by_name) }.map { |i| i['change_name'] }
    O.emit('dispatcher.finish', results: @results.transform_values(&:to_s), waiting: waiting.join(','))
  end

  private

  # ---------------------------------------------------------------- scheduling

  def acquire_singleton!
    @singleton = File.open(File.join(O::LOCK_DIR, 'dispatcher.lock'), File::RDWR | File::CREAT, 0o644)
    unless @singleton.flock(File::LOCK_EX | File::LOCK_NB)
      warn '[dispatcher] another dispatcher is running; exiting'
      exit 0
    end
    @singleton.truncate(0)
    @singleton.write("pid=#{Process.pid} started_at=#{Time.now.utc.iso8601}\n")
    @singleton.flush
  end

  def load_backlog
    raw = O.read_json(@backlog_file)
    O.emit('backlog.unreadable', file: @backlog_file) if raw.nil? && File.exist?(@backlog_file)
    items = raw.is_a?(Hash) ? Array(raw['changes']) : Array(raw)
    valid, invalid = items.partition { |i| i.is_a?(Hash) && i['change_name'].to_s.match?(O::CHANGE_NAME) }
    invalid.each { |i| O.emit('backlog.invalid_name', item: i.to_s[0, 200]) }
    sorted = valid.each_with_index.sort_by do |i, idx|
      [PRIORITY.fetch(i['priority'], 2), -(Float(i['impact_score'], exception: false) || 0.0), idx]
    end.map(&:first)
    # Two entries with one name would start two threads for one change; keep the first.
    sorted.group_by { |i| i['change_name'] }.each do |name, dups|
      O.emit('backlog.duplicate_name', change: name, count: dups.size) if dups.size > 1
    end
    sorted.uniq { |i| i['change_name'] }
  end

  def refresh_remote!(force: false)
    return if !force && Time.now - @last_fetch < FETCH_EVERY_SECONDS

    @git_mutex.synchronize { O.git(['fetch', '--quiet', O::REMOTE, O::BASE_BRANCH], chdir: O::ROOT) }
    listing = O.git(['ls-tree', '--name-only', "#{O::REMOTE}/#{O::BASE_BRANCH}", 'openspec/changes/archive/'],
                    chdir: O::ROOT).out
    @archived = listing.lines.map { |l| File.basename(l.strip).sub(/\A\d{4}-\d{2}-\d{2}-/, '') }
    @last_fetch = Time.now
  end

  def eligible?(item)
    change = item['change_name']
    return false if O.blocked?(change) || File.exist?(File.join(O::READY_DIR, "#{change}.json"))
    return false if @archived.include?(change)
    return false unless Array(item['depends_on']).all? { |dep| @archived.include?(dep) }

    held = @state_mutex.synchronize { @held[change] }
    held.nil? || (held & @state_mutex.synchronize { capabilities_in_flight(except: change) }).empty?
  end

  # True only when `item` is neither archived nor blocked, and every dependency
  # in its transitive `depends_on` chain is archived, queued for merge, or still
  # resolvable in the backlog (never blocked or missing).
  def waiting_on_flight?(item, by_name, seen = {})
    change = item['change_name']
    return false if seen[change] || O.blocked?(change) || @results[change] == :blocked || @archived.include?(change)

    seen = seen.merge(change => true)
    Array(item['depends_on']).all? do |dep|
      @archived.include?(dep) ||
        File.exist?(File.join(O::READY_DIR, "#{dep}.json")) ||
        (by_name.key?(dep) && waiting_on_flight?(by_name[dep], by_name, seen))
    end
  end

  # Capabilities are held from BUILD start until the merger consumes the
  # manifest. Caller must hold @state_mutex.
  def capabilities_in_flight(except:)
    queued = Dir.glob(File.join(O::READY_DIR, '*.json')).flat_map do |f|
      m = O.read_json(f)
      m.is_a?(Hash) ? Array(m['capabilities']) : [] # the merger sets malformed manifests aside
    end
    (queued + @building.reject { |c, _| c == except }.values.flatten).uniq
  end

  def claim_capabilities(change, caps)
    @state_mutex.synchronize do
      conflicts = caps & capabilities_in_flight(except: change)
      if conflicts.any?
        @held[change] = caps
        O.emit('change.held', change: change, conflicts: conflicts.join(','))
        return false
      end
      @held.delete(change)
      @building[change] = caps
      true
    end
  end

  def start(item)
    change = item['change_name']
    @threads[change] = Thread.new { process_change(item) }
  end

  def reap!
    @threads.each do |change, thread|
      next if thread.alive?

      result = thread.value
      @results[change] = result unless %i[held paused].include?(result)
      @state_mutex.synchronize { @building.delete(change) }
      O.emit('change.finished', change: change, result: result)
    end
    @threads.reject! { |_, thread| !thread.alive? }
  end

  # ------------------------------------------------------------- change worker

  def process_change(item)
    change = item['change_name']
    lease = O::Lease.acquire(change, "dispatcher-#{Process.pid}") or return :busy
    @state_mutex.synchronize { @leases[change] = lease }
    wt = File.join(O::WORKTREE_BASE, "worker-#{change}")
    branch = "feat/spec-#{change}"
    log = File.join(O::WORKER_LOG_DIR, "#{change}.log")
    O.emit('change.start', change: change, worktree: wt)

    provision_worktree!(wt, change, branch, log)
    plan!(item, wt, log)
    caps = capabilities(wt, change) + Array(item['locks']).map { |l| "lock:#{l}" }
    return :held unless claim_capabilities(change, caps)

    refresh!(item, wt, branch, log)
    build!(item, wt, branch, log)
    assessment = assess_risk!(item, wt, change, caps, log)
    enqueue!(change, wt, branch, caps, assessment)
    :ready
  rescue O::Blocked => e
    # System/framework errors (unavailable judge or engine, malformed question
    # files) pause the pipeline after the first failure so the dispatcher does
    # not quarantine the rest of the backlog one by one.
    if O::SYSTEM_REASONS.include?(e.reason) && !O.pause!("#{e.reason} (#{change}): #{e.details.lines.first&.strip}")
      return :paused
    end
    O.quarantine!(change, e, 'worktree' => wt, 'branch' => branch, 'log' => log)
    :blocked
  rescue StandardError => e
    err = O::Blocked.new('orchestrator_error', "#{e.class}: #{e.message}")
    return :paused unless O.pause!("#{err.reason} (#{change}): #{err.details.lines.first&.strip}")

    O.quarantine!(change, err, 'worktree' => wt, 'branch' => branch, 'log' => log)
    :blocked
  ensure
    @state_mutex.synchronize { @leases.delete(change) }
    lease&.release!
  end

  def provision_worktree!(wt, change, branch, log)
    @git_mutex.synchronize do
      unless Dir.exist?(wt)
        O.git(%w[worktree prune], chdir: O::ROOT, log: log) # forget worktree directories deleted by hand
        exists = O.git(['rev-parse', '--verify', '--quiet', "refs/heads/#{branch}"], chdir: O::ROOT).ok?
        args = exists ? ['worktree', 'add', wt, branch] : ['worktree', 'add', '-b', branch, wt, "#{O::REMOTE}/#{O::BASE_BRANCH}"]
        O.git!(args, chdir: O::ROOT, log: log)
        abort_lost_build!(wt, change, branch, log) if exists
      end
      # Each linked worktree gets its own submodule clones under
      # .git/worktrees/<wt>/modules. Initialize only once: re-running update on
      # a resumed worktree would detach child repos from their feature branch.
      if O.child_paths(wt).any? { |p| !File.exist?(File.join(wt, p, '.git')) }
        O.git!(%w[submodule update --init --recursive], chdir: wt, log: log, timeout: 1800)
      end
    end
  end

  # The branch survived but its worktree did not. If BUILD had already run,
  # the child commits lived only in that worktree's private submodule store
  # (G1): resuming would integrate the change without its code, because the
  # committed tasks.md says it is done. Undo the checkout and block instead.
  def abort_lost_build!(wt, change, branch, log)
    children = O.child_paths(wt)
    fork = O.git!(['merge-base', 'HEAD', "#{O::REMOTE}/#{O::BASE_BRANCH}"], chdir: wt)
    moved = children.any? && !O.git(['diff', '--quiet', fork, 'HEAD', '--', *children], chdir: wt).ok?
    return unless moved || tasks_complete?(wt, change)

    O.git(['worktree', 'remove', '--force', wt], chdir: O::ROOT, log: log)
    raise O::Blocked.new('missing_child_commits',
                         "The worktree of #{change} was deleted after BUILD, so its child commits are lost. " \
                         "Abandon the change (git branch -D #{branch}; rm log/blocked/#{change}.json) " \
                         'and keep its backlog item to rebuild it from scratch.')
  end

  # PLAN: loop until the change validates strictly and every artifact is done.
  def plan!(item, wt, log)
    change = item['change_name']
    unless Dir.exist?(File.join(wt, 'openspec', 'changes', change))
      args = ['openspec', 'new', 'change', change, '--json']
      args += ['--description', item['description']] if item['description']
      res = O.run(args, chdir: wt, log: log)
      raise O::Blocked.new('planning_failed', res.out) unless res.ok?
    end

    attempts = 0
    loop do
      failure = plan_failure(wt, change, log)
      if failure.nil?
        commit_umbrella!(wt, "docs(openspec): plan #{change}", ["openspec/changes/#{change}"], log)
        return
      end
      raise O::Blocked.new(failure[:reason], failure[:details]) if attempts > @repair_attempts

      # A fresh plan gets no feedback; anything else (repairs, deltas made stale
      # by a rebase, a Jev rejection) gets the exact verification failure.
      fresh = !File.exist?(File.join(wt, 'openspec', 'changes', change, 'proposal.md'))
      agent!(change, fresh ? 'plan' : "plan-repair-#{attempts}", plan_prompt(item, fresh ? nil : failure[:details]), wt, log, engine: @engine_plan)
      attempts += 1
    end
  end

  # Deterministic checks first; Jev (J1) is asked only about a plan that
  # already validates, so it judges substance, never syntax.
  def plan_failure(wt, change, log)
    validation = O.run(['openspec', 'validate', change, '--strict', '--json'], chdir: wt)
    return { reason: 'spec_invalid', details: "openspec validate failed:\n#{validation.tail}" } unless validation.ok?

    status = O.run(['openspec', 'status', '--change', change, '--json'], chdir: wt)
    data = O.parse_json(status.out)
    return { reason: 'spec_invalid', details: "openspec status unreadable:\n#{status.tail}" } unless status.ok? && data.is_a?(Hash)

    pending = Array(data['artifacts']).reject { |a| %w[done skipped].include?(a['status']) }
    if pending.any?
      return { reason: 'spec_invalid', details: "Artifacts not complete: #{pending.map { |a| "#{a['id']}=#{a['status']}" }.join(', ')}" }
    end

    preview = archive_preview(wt, change)
    return { reason: 'spec_invalid', details: preview } if preview

    review = O::Jev.ask('plan_review', plan_state(wt, change), cache_dir: jev_dir(change), log: log, change: change)
    review.blocking? ? { reason: 'plan_review', details: O::Jev.feedback(review) } : nil
  end

  # `validate <change>` checks the deltas alone; the merger validates the
  # canonical specs that `archive` produces from them. Archive a scratch copy
  # (canonical specs plus this change only) and validate the result, so a plan
  # that would fail there, such as a new capability whose delta has no Purpose,
  # is repaired now instead of being blocked after BUILD. Only this change's
  # capabilities count: a spec already broken on the base is not its fault.
  def archive_preview(wt, change)
    src = File.join(wt, 'openspec')
    Dir.mktmpdir('openspec-preview-') do |tmp|
      dst = File.join(tmp, 'openspec')
      FileUtils.mkdir_p(File.join(dst, 'changes'))
      Dir.children(src).reject { |c| c == 'changes' }.each { |c| FileUtils.cp_r(File.join(src, c), dst) }
      FileUtils.cp_r(File.join(src, 'changes', change), File.join(dst, 'changes'))

      archive = O.run(['openspec', 'archive', change, '--yes', '--json'], chdir: tmp)
      break "A trial `openspec archive #{change}` failed:\n#{archive.tail}" unless archive.ok?

      specs = O.run(%w[openspec validate --specs --strict --json], chdir: tmp)
      data = O.parse_json(specs.out)
      items = data.is_a?(Hash) ? Array(data['items']) : []
      caps = capabilities(wt, change)
      break nil if specs.ok? || (items.any? && items.none? { |i| i['valid'] == false && caps.include?(i['id']) })

      'Once archived, this change would leave canonical specs that fail `openspec validate --specs --strict`. ' \
        'Fix it in the delta specs only, never in openspec/specs/: the delta of a new capability must start with ' \
        "a `## Purpose` section of at least 50 characters, which becomes the canonical Purpose.\n#{specs.tail}"
    end
  end

  # ----------------------------------------------------------- Jev judgment state

  def jev_dir(change) = File.join(O::WORKER_LOG_DIR, change)

  def read_or_empty(path) = File.exist?(path) ? File.read(path) : ''

  def delta_specs(wt, change)
    dir = File.join(wt, 'openspec', 'changes', change, 'specs')
    Dir.glob(File.join(dir, '**', 'spec.md')).sort.to_h { |f| [File.dirname(f).delete_prefix("#{dir}/"), File.read(f)] }
  end

  def plan_state(wt, change)
    dir = File.join(wt, 'openspec', 'changes', change)
    deltas = delta_specs(wt, change)
    {
      'change' => change,
      'proposal' => read_or_empty(File.join(dir, 'proposal.md')),
      'design' => read_or_empty(File.join(dir, 'design.md')),
      'tasks' => read_or_empty(File.join(dir, 'tasks.md')),
      'delta_specs' => deltas,
      'canonical_specs' => deltas.keys.to_h { |cap| [cap, read_or_empty(File.join(wt, 'openspec', 'specs', cap, 'spec.md'))] }
    }
  end

  # Child-repo changes since the fork point: files, diffstat and (by policy) the diff.
  def risk_state(item, wt, change, caps)
    fork = O.git!(['merge-base', 'HEAD', "#{O::REMOTE}/#{O::BASE_BRANCH}"], chdir: wt)
    repos = O.child_paths(wt).each_with_object({}) do |path, acc|
      from = O.git(['rev-parse', "#{fork}:#{path}"], chdir: wt).out.strip
      to = O.git!(['rev-parse', "HEAD:#{path}"], chdir: wt)
      next if from == to

      child = File.join(wt, path)
      acc[path] = {
        'files' => O.git(['diff', '--name-only', from, to], chdir: child).out.split("\n"),
        'diffstat' => O.git(['diff', '--stat', from, to], chdir: child).out
      }
      acc[path]['diff'] = O.git(['diff', from, to], chdir: child).out if O::Jev.policy.fetch('include_diffs', true)
    end
    {
      'change' => change,
      'goal' => item['description'].to_s,
      'proposal' => read_or_empty(File.join(wt, 'openspec', 'changes', change, 'proposal.md')),
      'capabilities' => caps,
      'repos' => repos
    }
  end

  def capabilities(wt, change)
    specs_dir = File.join(wt, 'openspec', 'changes', change, 'specs')
    Dir.glob(File.join(specs_dir, '**', 'spec.md')).map { |f| File.dirname(f).delete_prefix("#{specs_dir}/") }.sort
  end

  # Rebase the plan onto the latest base (another change may have just updated
  # the same canonical spec), re-validate, and put every child repo on the
  # feature branch rooted at the gitlink recorded by the refreshed base.
  def refresh!(item, wt, branch, log)
    change = item['change_name']
    base_ref = "#{O::REMOTE}/#{O::BASE_BRANCH}"
    children = O.child_paths(wt)
    @git_mutex.synchronize { O.git!(['fetch', '--quiet', O::REMOTE, O::BASE_BRANCH], chdir: wt, log: log) }

    # If a previous run blocked after BUILD (for example at risk_review or in
    # the merger), the umbrella branch already carries a commit that moves child
    # gitlinks. Rebasing that commit onto an advanced base would conflict on the
    # submodule pointer before child repos are rebased. Strip child pointer
    # moves from the umbrella branch first; the commits themselves stay safe on
    # feat/spec-<change> inside each child repo and are re-recorded by build!.
    fork = O.git!(['merge-base', 'HEAD', base_ref], chdir: wt)
    if children.any? && !O.git(['diff', '--quiet', fork, 'HEAD', '--', *children], chdir: wt).ok?
      O.git!(['reset', '--soft', fork], chdir: wt, log: log)
      O.git!(['reset', fork, '--', *children], chdir: wt, log: log)
      commit_umbrella!(wt, "docs(openspec): plan #{change}", ["openspec/changes/#{change}"], log)
    end

    rebase = O.git(['rebase', base_ref], chdir: wt, log: log)
    unless rebase.ok?
      O.git(%w[rebase --abort], chdir: wt)
      raise O::Blocked.new('rebase_conflict', rebase.out)
    end
    plan!(item, wt, log) # strict validation catches MODIFIED blocks made stale by the rebase

    children.each do |path|
      child = File.join(wt, path)
      target = O.git!(['rev-parse', "HEAD:#{path}"], chdir: wt)
      O.git(['fetch', '--quiet', O::REMOTE], chdir: child, log: log)
      if O.git(['rev-parse', '--verify', '--quiet', "refs/heads/#{branch}"], chdir: child).ok?
        O.git!(['switch', '--quiet', branch], chdir: child, log: log)
        next if O.git(['merge-base', '--is-ancestor', target, 'HEAD'], chdir: child).ok?

        res = O.git(['rebase', target], chdir: child, log: log)
        next if res.ok?

        O.git(%w[rebase --abort], chdir: child)
        raise O::Blocked.new('rebase_conflict', "#{path}: #{res.out}")
      else
        O.git!(['switch', '--quiet', '--detach', target], chdir: child, log: log)
        O.git!(['switch', '--quiet', '-c', branch], chdir: child, log: log)
      end
    end
  end

  # BUILD: implement, commit inside child repos, verify; repair on failure.
  # When resuming an already-built change (for example after an operator
  # approves a risk_review), verify the refreshed tree first so the agent never
  # rewrites a human-approved diff unless verification now fails.
  def build!(item, wt, branch, log)
    change = item['change_name']
    attempts = 0
    failure = nil
    reran = false
    if tasks_complete?(wt, change)
      commit_children!(wt, change, log)
      failure = verify_build(wt, change, branch, log)
      failure, reran = triage_failure(change, wt, branch, failure, reran, log) if failure && failure[:reason] == 'gate_failure'
      if failure.nil?
        commit_umbrella!(wt, "feat(spec): implement #{change}", ["openspec/changes/#{change}", *O.child_paths(wt)], log)
        return
      end
      attempts = 1
      raise O::Blocked.new(failure[:reason], failure[:details]) if attempts > @repair_attempts
    end
    loop do
      phase = attempts.zero? ? 'apply' : "repair-#{attempts}"
      # Any new agent edit invalidates a prior human risk_review approval.
      FileUtils.rm_f(File.join(O::APPROVED_DIR, change))
      agent!(change, phase, apply_prompt(item, branch, failure && failure[:details]), wt, log, engine: @engine_build)
      commit_children!(wt, change, log)
      failure = verify_build(wt, change, branch, log)
      failure, reran = triage_failure(change, wt, branch, failure, reran, log) if failure && failure[:reason] == 'gate_failure'
      break if failure.nil?

      attempts += 1
      raise O::Blocked.new(failure[:reason], failure[:details]) if attempts > @repair_attempts
    end
    commit_umbrella!(wt, "feat(spec): implement #{change}", ["openspec/changes/#{change}", *O.child_paths(wt)], log)
  end

  # J2: Jev classifies a gate failure. In enforce mode a confident
  # environment/flaky verdict re-runs the gates once without spending an agent
  # repair, and a confident requirement-ambiguity verdict escalates to a human
  # instead of letting the agent pick a side. The verdict is always added to
  # the repair feedback as a hint.
  def triage_failure(change, wt, branch, failure, reran, log)
    state = { 'change' => change, 'gate_output' => failure[:details], 'delta_specs' => delta_specs(wt, change) }
    verdict = O::Jev.ask('failure_triage', state, cache_dir: jev_dir(change), log: log, change: change)
    cause = verdict.answer('cause') or return [failure, reran]

    policy = O::Jev.gate('failure_triage')
    hint = "Jev failure triage: most likely cause is #{cause['choice']} (confidence #{cause['confidence']})."
    if verdict.enforce?
      if !reran && O::Jev.matches?(verdict, policy['rerun_when'])
        O.emit('jev.route', change: change, action: 'rerun_gates', cause: cause['choice'], confidence: cause['confidence'])
        return [verify_build(wt, change, branch, log), true]
      end
      if O::Jev.matches?(verdict, policy['escalate_when'])
        O.emit('jev.route', change: change, action: 'escalate', cause: cause['choice'], confidence: cause['confidence'])
        raise O::Blocked.new('spec_ambiguity', "#{hint}\n#{failure[:details]}")
      end
    end
    [failure.merge(details: "#{hint}\n#{failure[:details]}"), reran]
  end

  # J3: Jev rates the finished change. In enforce mode a matching block_when
  # rule quarantines it as risk_review unless an operator created
  # log/approved/<change>. The assessment travels in the manifest and ends up
  # as a commit trailer; the merger itself never calls a model.
  def assess_risk!(item, wt, change, caps, log)
    verdict = O::Jev.ask('change_risk', risk_state(item, wt, change, caps), cache_dir: jev_dir(change), log: log, change: change)
    return nil if verdict.answers.nil? || verdict.answers.empty?

    summary = O::Jev.summarize(verdict.answers).merge('model' => verdict.model)
    flagged = Array(O::Jev.gate('change_risk')['block_when']).select { |rule| O::Jev.matches?(verdict, rule) }
    approved = File.exist?(File.join(O::APPROVED_DIR, change))
    reasons = flagged.map { |r| r['choice'] ? "#{r['question']}=#{r['choice']}" : "#{r['question']}>=#{r['min']}" }
    if flagged.any?
      action = if approved then 'approved_by_operator' elsif verdict.enforce? then 'risk_review' else 'flagged_advisory' end
      O.emit('jev.route', change: change, action: action, rules: reasons.join(','))
    end
    if verdict.enforce? && flagged.any? && !approved
      raise O::Blocked.new('risk_review', "Jev flagged #{reasons.join(', ')} (#{summary.to_json}). " \
                                          "Review, then `touch log/approved/#{change}` and requeue.")
    end
    summary.merge('approved_by_operator' => approved && flagged.any?)
  end

  def tasks_complete?(wt, change)
    listing = O.parse_json(O.run(%w[openspec list --json], chdir: wt).out) || {}
    entry = Array(listing['changes']).find { |c| c['name'] == change }
    entry && entry['totalTasks'].to_i.positive? && entry['completedTasks'] == entry['totalTasks']
  end

  def verify_build(wt, change, branch, log)
    children = O.child_paths(wt)
    # Remote-tracking refs are shared by all worktrees and move when another
    # thread fetches, so diff against the fork point, not origin/<base> itself.
    base = O.git!(['merge-base', 'HEAD', "#{O::REMOTE}/#{O::BASE_BRANCH}"], chdir: wt)
    touched = (O.git(['diff', '--name-only', base], chdir: wt).out.lines +
               O.git(%w[status --porcelain=v1 -uall], chdir: wt).out.lines.map { |l| l[3..] }).map(&:strip).uniq
    outside = touched.reject do |p|
      p.start_with?("openspec/changes/#{change}/") || children.any? { |c| p == c || p.start_with?("#{c}/") }
    end
    return { reason: 'policy_violation', details: "Revert changes outside the allowed paths: #{outside.join(', ')}" } if outside.any?

    off_branch = children.reject { |c| O.git(%w[branch --show-current], chdir: File.join(wt, c)).out.strip == branch }
    return { reason: 'policy_violation', details: "Child repos left #{branch}: #{off_branch.join(', ')}" } if off_branch.any?

    unless tasks_complete?(wt, change)
      listing = O.parse_json(O.run(%w[openspec list --json], chdir: wt).out) || {}
      entry = Array(listing['changes']).find { |c| c['name'] == change }
      return { reason: 'incomplete_tasks', details: "Tasks complete: #{entry&.values_at('completedTasks', 'totalTasks')&.join('/') || 'unknown'}" }
    end

    gates = O.run(['bash', 'bin/run_gates.sh', '--base', base], chdir: wt, log: log, timeout: GATE_TIMEOUT)
    gates.ok? ? nil : { reason: 'gate_failure', details: gates.tail(120) }
  end

  def commit_children!(wt, change, log)
    O.child_paths(wt).each do |path|
      child = File.join(wt, path)
      next if O.git(%w[status --porcelain], chdir: child).out.strip.empty?

      O.git!(%w[add -A], chdir: child, log: log)
      res = O.git(['commit', '--quiet', '-m', "feat(#{change}): implement OpenSpec change #{change}"], chdir: child, log: log)
      raise O::Blocked.new('gate_failure', "commit hook rejected #{path}:\n#{res.out}") unless res.ok?
    end
  end

  def commit_umbrella!(wt, message, paths, log)
    O.git!(['add', '-A', '--', *paths], chdir: wt, log: log)
    return if O.git(%w[diff --cached --quiet], chdir: wt).ok?

    O.git!(['commit', '--quiet', '-m', message], chdir: wt, log: log)
  end

  def enqueue!(change, wt, branch, caps, assessment)
    O.write_json_atomic(File.join(O::READY_DIR, "#{change}.json"), {
      'change_name' => change, 'branch' => branch, 'worktree' => wt,
      'head' => O.git!(%w[rev-parse HEAD], chdir: wt),
      'capabilities' => caps, 'enqueued_at' => Time.now.utc.iso8601,
      'jev' => assessment
    })
    O.emit('change.ready', change: change, capabilities: caps.join(','))
  end

  # --------------------------------------------------------------------- agent

  def agent!(change, phase, prompt, wt, log, engine: nil)
    dir = File.join(O::WORKER_LOG_DIR, change)
    FileUtils.mkdir_p(dir)
    prompt_file = File.join(dir, "#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{phase}.prompt.md")
    File.write(prompt_file, prompt)
    started = Time.now
    cmd = ['bash', O::AGENT_EXEC, wt, prompt_file]
    cmd << engine if engine
    res = O.run(cmd, chdir: wt, log: log, env: AGENT_ENV, timeout: AGENT_TIMEOUT + 120)
    O.emit('agent.exit', change: change, phase: phase, code: res.code, seconds: (Time.now - started).round, engine: engine || 'default')
    raise O::Blocked.new('engine_unavailable', res.out) if res.code == 127

    # The agent's only escalation channel: a question a human must answer.
    flag = File.join(wt, 'openspec', 'changes', change, '.needs-human')
    raise O::Blocked.new('spec_ambiguity', File.read(flag)) if File.exist?(flag)
  end

  # The framework's authoring rules travel with the kit (templates/authoring_rules.md),
  # so openspec/config.yaml stays the project's own, as `openspec init` created it.
  def authoring_rules
    @authoring_rules ||= read_or_empty(File.join(O::ROOT, 'templates', 'authoring_rules.md'))
  end

  # J4: agents may ask Jev their own yes/no questions while they work.
  def jev_hint
    # The kill switch is checked first so JEV_DISABLED=1 never runs the jev CLI.
    return '' if ENV['JEV_DISABLED'] == '1' || !O::Jev.available?

    <<~HINT

      When a yes/no judgment cannot be settled by running code (for example: does this test assert the THEN
      clause of that scenario?), ask Jev, a calibrated judge that answers with a probability instead of text:
      `jev noul "<question>" --true "<what yes means>" --false "<what no means>" --state-file <file> --model #{O::Jev.model} --field noul`
      0.7 or more means yes, 0.3 or less means no, anything in between means it cannot tell. Never pass
      secrets, .env files or credentials as state: the state is sent to the TypeSafe API.
    HINT
  end

  def plan_prompt(item, feedback)
    change = item['change_name']
    <<~PROMPT
      You are the PLANNING agent for OpenSpec change "#{change}" in this git worktree.
      Goal: #{item['description'] || item['why'] || change}

      Read MEMORY.md first: it holds this workspace's conventions and the lessons of earlier changes.

      Follow the openspec-propose workflow:
      1. Run `openspec status --change #{change} --json`, then for each artifact in dependency order run
         `openspec instructions <artifact-id> --change #{change} --json` and write that artifact.
      2. Keep every file inside openspec/changes/#{change}/ (proposal.md, specs/<capability>/spec.md, design.md, tasks.md).
         The delta of a capability that has no openspec/specs/<capability>/ yet starts with a `## Purpose` section
         (at least 50 characters): archiving copies it into the new canonical spec, and strict validation requires it.
      3. Run `openspec validate #{change} --strict --json` and fix every reported issue.

      If the requirements contradict each other in a way that affects data integrity or security, write the
      question to openspec/changes/#{change}/.needs-human and stop: a human will answer it.
      #{jev_hint}
      #{authoring_rules}
      Hard rules: never edit openspec/specs/ or anything outside openspec/changes/#{change}/;
      never commit, push, reset or switch branches.
      #{feedback ? "\nThe previous attempt failed deterministic verification. Fix exactly this:\n```\n#{feedback}\n```" : ''}
    PROMPT
  end

  def apply_prompt(item, branch, feedback)
    change = item['change_name']
    <<~PROMPT
      You are the IMPLEMENTATION agent for OpenSpec change "#{change}" in this git worktree.

      Read MEMORY.md first: it holds this workspace's conventions and the lessons of earlier changes.

      Follow the openspec-apply-change workflow: run `openspec instructions apply --change #{change} --json`
      and implement the pending tasks in order.
      - Application code lives in the child repositories under repos/, each already on branch #{branch}.
      - Pair every behavior change with automated tests. Mark a task `- [x]` only after its verification passes.
      - Run `bash bin/run_gates.sh` before you finish and fix every failure.
      - Write non-obvious lessons (pitfalls, required flags, environment quirks) to
        openspec/changes/#{change}/handoff.md. Do not edit MEMORY.md: the scheduled cycle curates it from handoff.md.

      If you hit a contradiction or a decision that needs a human (data migration, security trade-off),
      write the question to openspec/changes/#{change}/.needs-human and stop.
      #{jev_hint}
      #{authoring_rules}
      Hard rules: never edit openspec/specs/; never push, reset, rebase or switch branches;
      never edit repos/*/repo.config.yaml or CI configuration; only modify repos/ and openspec/changes/#{change}/.
      #{feedback ? "\nThe previous attempt failed deterministic verification. Fix exactly this:\n```\n#{feedback}\n```" : ''}
    PROMPT
  end
end

if __FILE__ == $PROGRAM_NAME
  options = {
    max_workers: 2, repair_attempts: 2, backlog_file: OpenSpecOrchestrator::BACKLOG_FILE,
    wait: nil, dry_run: false,
    engine_plan: OpenSpecDispatcher::ENGINE_PLAN,
    engine_build: OpenSpecDispatcher::ENGINE_BUILD
  }
  OptionParser.new do |opts|
    opts.banner = 'Usage: ruby bin/openspec_dispatcher.rb [options]'
    opts.on('-w', '--workers COUNT', Integer, 'Max concurrent workers (default: 2)') { |v| options[:max_workers] = v }
    opts.on('-r', '--repairs COUNT', Integer, 'Repair attempts per phase (default: 2)') { |v| options[:repair_attempts] = v }
    opts.on('-q', '--queue PATH', 'Backlog JSON (default: config/agent_backlog.json)') { |v| options[:backlog_file] = File.expand_path(v) }
    opts.on('--engine-plan ENGINE', 'Engine for PLAN phase (default: $AGENT_ENGINE_PLAN or $AGENT_ENGINE)') { |v| options[:engine_plan] = v }
    opts.on('--engine-build ENGINE', 'Engine for BUILD phase (default: $AGENT_ENGINE_BUILD or $AGENT_ENGINE)') { |v| options[:engine_build] = v }
    opts.on('--wait [SECONDS]', Integer, 'Wait up to SECONDS (default: 1800) while changes wait on merges') do |v|
      options[:wait] = v || OpenSpecDispatcher::DEFAULT_WAIT_TIMEOUT
    end
    opts.on('--dry-run', 'Print eligible changes and exit') { options[:dry_run] = true }
  end.parse!
  OpenSpecDispatcher.new(**options).run
end
