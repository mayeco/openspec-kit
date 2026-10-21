#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# bin/openspec_merger.rb
#
# Single-writer integration agent. For each manifest in log/ready_to_merge/ it
# assembles the change in a dedicated, disposable integration worktree, rebases
# the child-repo commits onto their base branches, re-verifies everything with
# the base branch's own (trusted) scripts, archives the change with the
# deterministic OpenSpec CLI, and only then pushes: children first, umbrella last.
# Nothing touches a shared branch until every check has passed.
# ==============================================================================

require 'optparse'
require_relative 'lib/openspec_orchestrator'

class OpenSpecMerger
  O = OpenSpecOrchestrator
  INTEGRATION_WT = File.join(O::WORKTREE_BASE, '_integration')
  STATE_FILE = File.join(O::LOG_DIR, 'merger_state.json')
  # Written by bin/run_cycle.sh once its dispatcher has finished, holding the
  # PID of the merger it started: that merger drains the queue and exits
  # between changes, never mid-integration. Any other merger ignores it.
  STOP_FILE = File.join(O::LOG_DIR, 'merger.stop')
  MAX_ATTEMPTS = 3
  GATE_TIMEOUT = OpenSpecSettings.get(O::ROOT, 'limits.gate_seconds') # config/pipeline.yaml
  # Child-repo paths a worker must not change on its own: they define the gates
  # that judge the worker. Changes here need a human (framework lane).
  PROTECTED_CHILD_PATHS = ENV.fetch('OPENSPEC_PROTECTED_PATHS', 'repo.config.yaml .github .gitlab-ci.yml').split

  # A push was rejected (usually a concurrent push to the same base): retry from the top.
  class PushRejected < StandardError; end
  # A child no longer rebases onto its base: the dispatcher rebuilds the change on the new base.
  class SendBack < StandardError; end

  def run(watch:, interval:)
    O.ensure_dirs!
    acquire_singleton!
    O.install_signal_handlers!
    recover!
    loop do
      process_queue unless O.paused?
      break unless watch

      if stop_requested?
        process_queue unless O.paused? # manifests written while the last pass ran
        FileUtils.rm_f(STOP_FILE)
        break
      end
      sleep interval
    end
  end

  private

  def stop_requested? = File.exist?(STOP_FILE) && File.read(STOP_FILE).to_i == Process.pid

  def acquire_singleton!
    @singleton = File.open(File.join(O::LOCK_DIR, 'merger.lock'), File::RDWR | File::CREAT, 0o644)
    unless @singleton.flock(File::LOCK_EX | File::LOCK_NB)
      warn '[merger] another merger holds log/locks/merger.lock; exiting'
      exit 0
    end
    @singleton.truncate(0)
    @singleton.write("pid=#{Process.pid} started_at=#{Time.now.utc.iso8601}\n")
    @singleton.flush
  end

  def update_state(state, extra = {})
    @state = {} if state == 'IDLE' || state == 'CLAIMED'
    @state = (@state || {}).merge('state' => state, 'updated_at' => Time.now.utc.iso8601).merge(extra)
    O.write_json_atomic(STATE_FILE, @state)
  end

  # Every step before PUSHING_* only mutates the disposable integration
  # worktree, so recovery never needs `reset --hard` on a shared checkout:
  # the interrupted change is simply integrated again from the top. A change
  # whose pushes completed is recognized by its commit trailer and only cleaned up.
  def recover!
    state = O.read_json(STATE_FILE)
    return if state.nil? || %w[IDLE COMPLETED].include?(state['state'])

    O.emit('merger.recover', state: state['state'], change: state['change'])
    update_state('IDLE', 'change' => nil)
  end

  def process_queue
    manifests = Dir.glob(File.join(O::READY_DIR, '*.json')).filter_map do |f|
      m = O.read_json(f)
      next [f, m] if m.is_a?(Hash)

      # Manifests are written atomically, so one that is not a JSON object never
      # heals: set it aside instead of crashing on it after every restart.
      reject_manifest!(f) if File.exist?(f)
      nil
    end
    manifests.sort_by { |_, m| m['enqueued_at'].to_s }.each do |path, manifest|
      break if O.paused?

      integrate(path, manifest)
    end
  end

  def reject_manifest!(path)
    O.emit('merge.invalid_manifest', file: path)
    File.rename(path, "#{path}.invalid")
  end

  def integrate(path, m)
    change = m['change_name'].to_s
    # never let a manifest name reach a path or a git argument
    return reject_manifest!(path) unless change.match?(O::CHANGE_NAME)

    attempts = 0
    begin
      attempts += 1
      integrate_once(m)
      cleanup_worker!(m)
      FileUtils.rm_f([path, O.rebuild_file(change)])
      O.forget_retries(change)
      update_state('IDLE', 'change' => nil)
    rescue SendBack => e
      send_back!(path, m, e.message)
    rescue PushRejected => e
      O.emit('merge.push_rejected', change: change, attempt: attempts, error: e.message[0, 300])
      retry if attempts < MAX_ATTEMPTS
      block!(path, m, O::Blocked.new('push_failed', e.message))
    end
  rescue O::Blocked => e
    block!(path, m, e)
  rescue StandardError => e
    err = O::Blocked.new('orchestrator_error', "#{e.class}: #{e.message}")
    # A framework or environment failure would hit every queued change the same
    # way: pause so process_queue stops here instead of quarantining them all.
    O.pause!("#{err.reason} (#{change}): #{err.details.lines.first&.strip}")
    block!(path, m, err)
  end

  # Up to dispatch.conflict_rebuilds times, a change whose code no longer rebases
  # onto the base goes back to the dispatcher instead of waiting for a human: the
  # manifest is dropped, the worktree and branch stay, and log/rebuilds/<change>.json
  # asks for the rebuild, which the dispatcher does on the new base.
  def send_back!(path, m, details)
    change = m['change_name']
    record = O.read_json(O.rebuild_file(change)) || {}
    O.write_json_atomic(O.rebuild_file(change), record.merge('requested' => true, 'conflict' => details[0, 4000],
                                                             'requested_at' => Time.now.utc.iso8601))
    FileUtils.rm_f(path)
    O.emit('merge.sent_back', change: change, reason: 'rebase_conflict', rebuilds: record['rebuilds'].to_i)
    update_state('IDLE', 'change' => nil)
  end

  def rebuild_allowed?(change)
    (O.read_json(O.rebuild_file(change)) || {})['rebuilds'].to_i < OpenSpecSettings.get(O::ROOT, 'dispatch.conflict_rebuilds')
  end

  def block!(path, m, error)
    O.quarantine!(m['change_name'], error, 'worktree' => m['worktree'], 'branch' => m['branch'], 'stage' => @state&.fetch('state', nil))
    FileUtils.rm_f(path) # the blocked record replaces the queue entry; worktree and branch are kept for audit
    update_state('IDLE', 'change' => nil)
  end

  def integrate_once(m)
    change = m['change_name']
    head = m['head']
    base_ref = "#{O::REMOTE}/#{O::BASE_BRANCH}"
    update_state('CLAIMED', 'change' => change, 'branch' => m['branch'], 'head' => head)

    O.git!(['fetch', '--quiet', O::REMOTE, O::BASE_BRANCH], chdir: O::ROOT)
    if already_integrated?(change, base_ref)
      O.emit('merge.already_integrated', change: change)
      return
    end
    branch_tip = O.git(['rev-parse', '--verify', '--quiet', m['branch']], chdir: O::ROOT).out.strip
    raise O::Blocked.new('manifest_stale', "#{m['branch']} is at #{branch_tip}, manifest says #{head}") unless branch_tip == head

    prepare_integration_worktree!(base_ref)
    wt = INTEGRATION_WT
    fork_point = O.git!(['merge-base', base_ref, head], chdir: wt)

    # 1. Path policy: a worker branch may only touch its own change directory
    #    and child-repo pointers. This also keeps canonical specs single-writer.
    update_state('POLICY_CHECK')
    children = O.child_paths(wt)
    changed = O.git!(['diff', '--name-only', fork_point, head], chdir: wt).lines.map(&:strip)
    outside = changed.reject { |p| p.start_with?("openspec/changes/#{change}/") || children.include?(p) }
    raise O::Blocked.new('policy_violation', "branch modifies #{outside.join(', ')}") if outside.any?

    # 2. Rebase each touched child repo onto its own base branch.
    update_state('REBASING_CHILDREN')
    touched = children.select do |p|
      O.git(['rev-parse', "#{fork_point}:#{p}"], chdir: wt).out != O.git(['rev-parse', "#{head}:#{p}"], chdir: wt).out
    end
    rebased = touched.to_h { |p| [p, rebase_child!(m, p, head)] }

    # 3. Assemble: the change's artifacts from the branch, rebased child pointers.
    update_state('ASSEMBLING', 'children' => rebased)
    O.git!(['checkout', head, '--', "openspec/changes/#{change}"], chdir: wt)
    touched.each { |p| O.git!(['add', p], chdir: wt) }

    # 4. Task audit. `openspec archive --yes` does NOT enforce this; we must.
    update_state('AUDITING_TASKS')
    listing = O.parse_json(O.run(%w[openspec list --json], chdir: wt).out) || {}
    entry = Array(listing['changes']).find { |c| c['name'] == change }
    unless entry && entry['totalTasks'].to_i.positive? && entry['completedTasks'] == entry['totalTasks']
      raise O::Blocked.new('incomplete_tasks', "tasks #{entry&.values_at('completedTasks', 'totalTasks')&.join('/') || 'unknown'}")
    end
    # Canonical specs may have moved since the dispatcher's refresh, making a
    # MODIFIED block stale (B3). Report that as spec_conflict, with the
    # validator's own message, instead of an anonymous gate failure.
    stale = O.run(['openspec', 'validate', change, '--strict', '--json'], chdir: wt)
    raise O::Blocked.new('spec_conflict', stale.tail) unless stale.ok?

    # 5. Gates on exactly what will be pushed, using the base branch's gate script.
    update_state('RUNNING_GATES')
    gates = O.run(['bash', 'bin/run_gates.sh', '--base', fork_point], chdir: wt, timeout: GATE_TIMEOUT,
                                                                     env: { 'OPENSPEC_SLOT' => O::MERGER_SLOT.to_s },
                                                                     log: File.join(O::WORKER_LOG_DIR, "#{change}.merge.log"))
    raise O::Blocked.new('gate_failure', gates.tail(120)) unless gates.ok?

    # 6. Deterministic spec sync: `openspec archive` applies ADDED/MODIFIED/
    #    REMOVED/RENAMED to openspec/specs/ and moves the change to archive/.
    update_state('ARCHIVING')
    archive = O.run(['openspec', 'archive', change, '--yes', '--json'], chdir: wt)
    result = O.parse_json(archive.out)
    unless archive.ok? && result.is_a?(Hash) && result['archive']
      codes = Array(result && result['status']).map { |s| s['code'] }
      reason = codes.include?('archive_spec_update_failed') ? 'spec_conflict' : 'archive_failed'
      raise O::Blocked.new(reason, archive.out)
    end
    specs = O.run(%w[openspec validate --specs --strict --json], chdir: wt)
    raise O::Blocked.new('spec_invalid', specs.tail) unless specs.ok?

    # 7. One umbrella commit carrying archive move, canonical specs, backlog history and pointers.
    update_state('COMMITTING')
    totals = result['archive']['totals'] || {}
    archived_at = Time.now.utc.iso8601
    O.archive_backlog!(wt, item: m['item'] || { 'change_name' => change }, at: archived_at)
    stage = ['openspec', *touched]
    %w[config/agent_backlog.json config/agent_history.json].each do |rel|
      stage << rel if File.exist?(File.join(wt, rel))
    end
    O.git!(['add', '-A', '--', *stage], chdir: wt)
    # The dispatcher's Jev risk assessment, recorded as data. The merger never calls a model.
    jev = m['jev'].is_a?(Hash) ? "\nJev-Assessment: #{m['jev'].map { |k, v| "#{k}=#{v}" }.join(' ')}" : ''
    message = <<~MSG
      chore(merge): integrate #{change}

      Specs: +#{totals['added'].to_i} ~#{totals['modified'].to_i} -#{totals['removed'].to_i} >#{totals['renamed'].to_i}
      Archived as: #{result['archive']['archivedAs']}
      Repos: #{touched.empty? ? 'none' : touched.join(', ')}

      OpenSpec-Change: #{change}#{jev}
    MSG
    O.git!(['commit', '--quiet', '-m', message], chdir: wt)

    # 8. Publish: children first so the umbrella never points at unpublished commits.
    update_state('PUSHING_CHILDREN')
    touched.each do |p|
      res = O.git(['push', '--quiet', O::REMOTE, "HEAD:refs/heads/#{O.child_base_branch(wt, p)}"], chdir: File.join(wt, p))
      raise PushRejected, "#{p}: #{res.tail(5)}" unless res.ok?
    end
    update_state('PUSHING_ROOT')
    res = O.git(['push', '--quiet', O::REMOTE, "HEAD:refs/heads/#{O::BASE_BRANCH}"], chdir: wt)
    raise PushRejected, "umbrella: #{res.tail(5)}" unless res.ok?

    commit = O.git!(%w[rev-parse HEAD], chdir: wt)
    sync_root_backlog!(m, commit, archived_at)
    update_state('COMPLETED')
    O.emit('merge.integrated', change: change, commit: commit, specs: totals.to_json, repos: touched.join(','))
  end

  BACKLOG_FILES = %w[config/agent_backlog.json config/agent_history.json].freeze

  # Moves the integrated item out of the main checkout's backlog too, when no cycle
  # or visual session holds it. Only ever to exactly what `ref` has on origin: a
  # checkout with edits of its own, or behind origin, would end up with a file that
  # bin/sync_repos.sh could neither restore nor fast-forward over, so it is left for
  # that sync instead.
  def sync_root_backlog!(m, ref, at)
    return if Dir.exist?(File.join(O::LOG_DIR, 'cycle.lock')) || O.visual_session?

    published = BACKLOG_FILES.to_h do |rel|
      res = O.git(['show', "#{ref}:#{rel}"], chdir: O::ROOT, stderr: :separate)
      [rel, res.ok? ? res.out : nil]
    end
    archived = O.git(['ls-tree', '--name-only', ref, 'openspec/changes/archive/'], chdir: O::ROOT)
                .out.lines.map { |l| File.basename(l.strip).sub(/\A\d{4}-\d{2}-\d{2}-/, '') }
    same = Dir.mktmpdir('openspec-backlog-') do |tmp|
      FileUtils.mkdir_p(File.join(tmp, 'config'))
      BACKLOG_FILES.each { |rel| FileUtils.cp(File.join(O::ROOT, rel), File.join(tmp, rel)) if File.file?(File.join(O::ROOT, rel)) }
      O.archive_backlog!(tmp, item: m['item'] || { 'change_name' => m['change_name'] }, archived: archived, at: at)
      BACKLOG_FILES.all? { |rel| O.read_json(File.join(tmp, rel)) == (published[rel] && O.parse_json(published[rel])) }
    end
    return unless same

    BACKLOG_FILES.each do |rel|
      path = File.join(O::ROOT, rel)
      next if published[rel].nil? || (File.file?(path) && File.binread(path) == published[rel].b)

      tmp = "#{path}.tmp.#{Process.pid}"
      File.binwrite(tmp, published[rel])
      File.rename(tmp, path)
    end
  end

  def already_integrated?(change, base_ref)
    !O.git(['log', base_ref, '-n', '1', '--format=%H', "--grep=^OpenSpec-Change: #{change}$"], chdir: O::ROOT).out.strip.empty?
  end

  # The integration worktree is reused (keeps ignored build caches such as
  # node_modules) but always reset to the exact base before each change.
  def prepare_integration_worktree!(base_ref)
    unless Dir.exist?(INTEGRATION_WT)
      O.git(%w[worktree prune], chdir: O::ROOT) # forget an integration worktree deleted by hand
      O.git!(['worktree', 'add', '--detach', INTEGRATION_WT, base_ref], chdir: O::ROOT)
    end
    wt = INTEGRATION_WT
    O.git(%w[rebase --abort], chdir: wt)
    O.git!(['checkout', '--quiet', '--force', '--detach', base_ref], chdir: wt)
    O.git!(%w[clean -fdq], chdir: wt)
    O.git!(%w[submodule update --init --recursive --force], chdir: wt, timeout: 1800)
    O.child_paths(wt).each do |p|
      child = File.join(wt, p)
      O.git(%w[rebase --abort], chdir: child)
      O.git!(%w[clean -fdq], chdir: child)
      O.git(%w[for-each-ref --format=%(refname:short) refs/heads/integrate/], chdir: child).out.split
       .each { |b| O.git(['branch', '-D', b], chdir: child) }
    end
  end

  # The repository's env_script prepares the shell of its gates, so it is protected like
  # repo.config.yaml. Read from the fork point: a change cannot move it out of the way.
  def env_script(child, fork)
    res = O.git(['show', "#{fork}:repo.config.yaml"], chdir: child)
    return [] unless res.ok?

    path = (YAML.safe_load(res.out) || {})['env_script'].to_s.strip
    path.empty? ? [] : [path]
  rescue Psych::Exception
    []
  end

  # Worker commits live only in the worker worktree's private submodule store
  # (.git/worktrees/<wt>/modules/...), so fetch them from that path by SHA.
  def rebase_child!(m, path, head)
    child = File.join(INTEGRATION_WT, path)
    base = O.child_base_branch(INTEGRATION_WT, path)
    worker_sha = O.git!(['rev-parse', "#{head}:#{path}"], chdir: INTEGRATION_WT)
    O.git!(['fetch', '--quiet', O::REMOTE, base], chdir: child)
    fetched = O.git(['fetch', '--quiet', File.join(m['worktree'], path), worker_sha], chdir: child)
    raise O::Blocked.new('missing_child_commits', "#{path}@#{worker_sha}: #{fetched.tail(5)}") unless fetched.ok?

    fork = O.git!(['merge-base', "#{O::REMOTE}/#{base}", worker_sha], chdir: child)
    tampered = O.git!(['diff', '--name-only', fork, worker_sha, '--', *PROTECTED_CHILD_PATHS, *env_script(child, fork)], chdir: child)
    raise O::Blocked.new('policy_violation', "#{path}: protected paths changed: #{tampered.split.join(', ')}") unless tampered.empty?

    O.git!(['checkout', '--quiet', '-B', "integrate/#{m['change_name']}", worker_sha], chdir: child)
    res = O.git(['rebase', "#{O::REMOTE}/#{base}"], chdir: child)
    unless res.ok?
      O.git(%w[rebase --abort], chdir: child)
      # A rebase git refused to start is not a conflict: a rebuild would not help.
      raise O::Blocked.new('rebase_failed', "#{path}: #{res.tail(40)}") unless O.content_conflict?(res.out)
      raise SendBack, "#{path}: #{res.tail(40)}" if rebuild_allowed?(m['change_name'])

      raise O::Blocked.new('rebase_conflict', "#{path}: #{res.tail(40)}")
    end
    O.git!(%w[rev-parse HEAD], chdir: child)
  end

  def cleanup_worker!(m)
    # --force is required: git refuses to remove worktrees that contain submodules.
    O.git(['worktree', 'remove', '--force', m['worktree']], chdir: O::ROOT) if m['worktree'] && Dir.exist?(m['worktree'])
    O.git(['branch', '-D', m['branch']], chdir: O::ROOT)
    O.git(%w[worktree prune], chdir: O::ROOT)
  end
end

if __FILE__ == $PROGRAM_NAME
  options = { watch: false, interval: OpenSpecSettings.get(OpenSpecOrchestrator::ROOT, 'dispatch.merge_interval_seconds') }
  OptionParser.new do |opts|
    opts.banner = 'Usage: ruby bin/openspec_merger.rb [--watch [--interval SECONDS]]'
    opts.on('--watch', 'Keep polling the ready queue') { options[:watch] = true }
    opts.on('--interval SECONDS', Integer, 'Polling interval (default: dispatch.merge_interval_seconds of config/pipeline.yaml)') { |v| options[:interval] = v }
  end.parse!
  OpenSpecMerger.new.run(**options)
end
