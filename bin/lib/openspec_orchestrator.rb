# frozen_string_literal: true

# ==============================================================================
# bin/lib/openspec_orchestrator.rb
#
# Shared primitives for the dispatcher and the merger: bounded subprocesses,
# JSONL events, atomic files, leases, quarantine and repository topology.
# ==============================================================================

require 'digest'
require 'fileutils'
require 'json'
require 'securerandom'
require 'socket'
require 'time'
require 'tmpdir'
require 'yaml'
require_relative 'settings'

# launchd and cron start without LANG, so Ruby would tag subprocess output as
# US-ASCII and JSON.parse would raise on the UTF-8 that openspec and jev print.
Encoding.default_external = Encoding::UTF_8

module OpenSpecOrchestrator
  ROOT = File.expand_path('../..', __dir__)
  # base_branch and limits.lease_seconds of config/pipeline.yaml (bin/lib/settings.rb).
  BASE_BRANCH = OpenSpecSettings.get(ROOT, 'base_branch')
  REMOTE = ENV.fetch('OPENSPEC_REMOTE', 'origin')
  WORKTREE_BASE = File.expand_path(ENV.fetch('OPENSPEC_WORKTREE_BASE', '.worktrees'), ROOT)
  LOG_DIR = File.join(ROOT, 'log')
  LOCK_DIR = File.join(LOG_DIR, 'locks')
  READY_DIR = File.join(LOG_DIR, 'ready_to_merge')
  BLOCKED_DIR = File.join(LOG_DIR, 'blocked')
  APPROVED_DIR = File.join(LOG_DIR, 'approved') # operator-written: log/approved/<change> waives risk_review
  WORKER_LOG_DIR = File.join(LOG_DIR, 'workers')
  REBUILD_DIR = File.join(LOG_DIR, 'rebuilds') # <change>.json: automatic rebuilds after a rebase conflict
  # OPENSPEC_SLOT of the merger's integration worktree; the dispatcher's workers take 1, 2, ...
  MERGER_SLOT = 99
  EVENTS_FILE = File.join(LOG_DIR, 'events.jsonl')
  PAUSE_FILE = File.join(LOG_DIR, 'PAUSE')
  BACKLOG_FILE = File.join(ROOT, 'config', 'agent_backlog.json')
  AGENT_EXEC = File.join(ROOT, 'bin', 'agent_exec.sh')
  LEASE_TTL_SECONDS = OpenSpecSettings.get(ROOT, 'limits.lease_seconds')
  CHANGE_NAME = /\A[a-z0-9][a-z0-9-]{0,62}\z/

  # Raised to quarantine a change. The reason is one of the blocker taxonomy codes.
  class Blocked < StandardError
    attr_reader :reason, :details

    def initialize(reason, details)
      @reason = reason
      @details = details.to_s[-4000..] || details.to_s
      super("#{reason}: #{@details.lines.last(3).join.strip}")
    end
  end

  Result = Struct.new(:out, :code, :err) do
    def ok? = code.zero?

    def tail(lines = 80) = out.lines.last(lines).join
  end

  module_function

  def ensure_dirs!
    [LOG_DIR, LOCK_DIR, READY_DIR, BLOCKED_DIR, APPROVED_DIR, WORKER_LOG_DIR, REBUILD_DIR, WORKTREE_BASE].each { |d| FileUtils.mkdir_p(d) }
  end

  def rebuild_file(change) = File.join(REBUILD_DIR, "#{change}.json")

  RUNNING = {} # pid => true; every child runs in its own process group

  # On INT/TERM, take the agents and gates down with us instead of orphaning them.
  def install_signal_handlers!
    %w[INT TERM].each do |sig|
      Signal.trap(sig) do
        RUNNING.keys.each { |pid| Process.kill('TERM', -pid) rescue nil } # rubocop:disable Style/RescueModifier
        exit 130
      end
    end
  end

  # Runs argv without a shell and kills the whole process group on timeout
  # (exit code 124, like coreutils timeout). stdout and stderr are merged
  # unless stderr: :separate, which keeps machine-readable stdout clean.
  def run(cmd, chdir: ROOT, timeout: 1800, env: {}, log: nil, stderr: :merge)
    reader, writer = IO.pipe
    err_path = File.join(Dir.tmpdir, "openspec-#{Process.pid}-#{SecureRandom.hex(6)}.err") if stderr == :separate
    pid = Process.spawn(env, *cmd, chdir: chdir, out: writer, err: err_path ? [err_path, 'w'] : writer,
                                   in: File::NULL, pgroup: true)
    RUNNING[pid] = true
    writer.close
    collector = Thread.new { reader.read }
    deadline = Time.now + timeout
    status = nil
    until (status = Process.wait2(pid, Process::WNOHANG)&.last)
      if Time.now > deadline
        terminate_group(pid)
        status = :timeout
        break
      end
      sleep 0.2
    end
    RUNNING.delete(pid)
    out = collector.value.to_s
    reader.close
    err = err_path && File.exist?(err_path) ? File.read(err_path).tap { File.delete(err_path) } : nil
    code = status == :timeout ? 124 : (status.exitstatus || 128 + status.termsig.to_i)
    File.open(log, 'a') { |f| f.puts("$ #{cmd.join(' ')}  (cwd=#{chdir}, exit=#{code})", out, err.to_s) } if log
    Result.new(out, code, err)
  end

  def terminate_group(pid)
    Process.kill('TERM', -pid)
    20.times do
      return if Process.wait2(pid, Process::WNOHANG)
      sleep 0.5
    end
    Process.kill('KILL', -pid)
    Process.wait2(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def git(args, chdir:, **opts) = run(['git', *args], chdir: chdir, **opts)

  def git!(args, chdir:, **opts)
    res = git(args, chdir: chdir, **opts)
    raise "git #{args.join(' ')} failed in #{chdir}: #{res.tail(10)}" unless res.ok?

    res.out.strip
  end

  EVENT_MUTEX = Mutex.new
  def emit(event, **fields)
    line = JSON.generate({ ts: Time.now.utc.iso8601, event: event, pid: Process.pid }.merge(fields))
    EVENT_MUTEX.synchronize { File.open(EVENTS_FILE, 'a') { |f| f.puts(line) } }
    warn "[#{event}] #{fields.map { |k, v| "#{k}=#{v}" }.join(' ')}"
  end

  def write_json_atomic(path, obj)
    tmp = "#{path}.tmp.#{Process.pid}.#{Thread.current.object_id}"
    File.write(tmp, JSON.pretty_generate(obj))
    File.rename(tmp, path) # rename(2) is atomic: readers never see a partial manifest
  end

  def read_json(path)
    JSON.parse(File.read(path))
  rescue Errno::ENOENT, JSON::ParserError
    nil
  end

  # A CLI's stdout as JSON, or nil when it is not JSON. Unlike `rescue nil`, a
  # missing executable (Errno::ENOENT from spawn) still surfaces as a system failure.
  def parse_json(text)
    JSON.parse(text.to_s)
  rescue JSON::ParserError
    nil
  end

  def paused? = File.exist?(PAUSE_FILE)

  SYSTEM_REASONS = %w[judge_unavailable engine_unavailable orchestrator_error].freeze
  PAUSE_MUTEX = Mutex.new

  # Atomically writes log/PAUSE on the first system-wide failure so the
  # dispatcher stops starting new changes instead of quarantining the rest of
  # the backlog one by one. Returns true only for the caller that created it.
  def pause!(reason)
    PAUSE_MUTEX.synchronize do
      return false if paused?

      File.write(PAUSE_FILE, "#{reason}\n")
      emit('system.paused', reason: reason)
      true
    end
  end

  def blocked?(change) = File.exist?(File.join(BLOCKED_DIR, "#{change}.json"))

  def quarantine!(change, error, extra = {})
    write_json_atomic(File.join(BLOCKED_DIR, "#{change}.json"), {
      'change_name' => change, 'reason' => error.reason, 'details' => error.details,
      'blocked_at' => Time.now.utc.iso8601, 'host' => Socket.gethostname
    }.merge(extra))
    emit('change.blocked', change: change, reason: error.reason)
  end

  # { "repos/backend" => "submodule.repos/backend", ... } from .gitmodules.
  def submodules(dir)
    return {} unless File.exist?(File.join(dir, '.gitmodules'))

    res = git(['config', '-f', '.gitmodules', '--get-regexp', '^submodule\..*\.path$'], chdir: dir)
    return {} unless res.ok?

    res.out.lines.to_h { |l| key, path = l.split; [path, key.delete_suffix('.path')] }
  end

  # Child repos are the submodules under repos/. Any other submodule (a vendored
  # tool, a published deliverable) is not an application repo: workers must
  # never get a branch in it or a write to its pointer.
  def child_paths(dir) = submodules(dir).keys.select { |p| p.start_with?('repos/') }

  # Base branch of a child repo: repo.config.yaml base_branch, then the
  # .gitmodules branch setting, then "main".
  def child_base_branch(dir, path)
    cfg_file = File.join(dir, path, 'repo.config.yaml')
    if File.exist?(cfg_file)
      cfg = YAML.safe_load_file(cfg_file) || {}
      return cfg['base_branch'] if cfg['base_branch'].is_a?(String) && !cfg['base_branch'].include?('{{')
    end
    key = submodules(dir)[path]
    branch = key && git(['config', '-f', '.gitmodules', "#{key}.branch"], chdir: dir).out.strip
    branch.nil? || branch.empty? ? 'main' : branch
  end

  # File-based lease, created with O_EXCL so that two claimers can never both win.
  class Lease
    def self.path(change) = File.join(LOCK_DIR, "#{change}.lock")

    def self.acquire(change, owner)
      file = path(change)
      payload = { 'change_name' => change, 'owner' => owner, 'pid' => Process.pid,
                  'host' => Socket.gethostname, 'acquired_at' => Time.now.utc.iso8601,
                  'heartbeat_at' => Time.now.utc.iso8601 }
      2.times do
        File.open(file, File::WRONLY | File::CREAT | File::EXCL, 0o644) { |f| f.write(JSON.pretty_generate(payload)) }
        return new(file)
      rescue Errno::EEXIST
        return nil unless stale?(file)

        OpenSpecOrchestrator.emit('lease.stale_reclaimed', change: change, previous: File.read(file))
        File.delete(file)
      end
      nil
    end

    # Same host: stale when the owner PID is dead or the heartbeat expired.
    # Other host: PIDs are meaningless here, so only the heartbeat TTL counts.
    def self.stale?(file)
      data = OpenSpecOrchestrator.read_json(file) or return true
      age = Time.now - Time.parse(data['heartbeat_at'].to_s)
      return age > LEASE_TTL_SECONDS unless data['host'] == Socket.gethostname

      !alive?(data['pid']) || age > LEASE_TTL_SECONDS
    rescue ArgumentError
      true
    end

    def self.alive?(pid)
      Process.kill(0, Integer(pid))
      true
    rescue Errno::ESRCH, ArgumentError, TypeError
      false
    rescue Errno::EPERM
      true
    end

    def initialize(file) = @file = file

    def heartbeat!
      data = OpenSpecOrchestrator.read_json(@file) or return
      data['heartbeat_at'] = Time.now.utc.iso8601
      OpenSpecOrchestrator.write_json_atomic(@file, data)
    end

    def release! = FileUtils.rm_f(@file)
  end

  # Calibrated judgment through the `jev` CLI (TypeSafe AI's Jev model). Jev
  # answers typed questions (noul = yes/no, choice, score) with probabilities,
  # never with text, so every decision here is a deterministic rule over numbers
  # from config/jev_policy.yaml. Jev never approves what the deterministic gates
  # rejected: it can only add a block, an escalation or one gate re-run.
  module Jev
    POLICY_FILE = File.join(ROOT, 'config', 'jev_policy.yaml')
    UNAVAILABLE_CODES = [3, 4, 5, 6, 124].freeze # auth, rejected, rate limited, network, our timeout

    # status: :passed, :failed, :abstained (a missed threshold inside the abstain
    # band: the model cannot tell), :skipped (mode off) or :unavailable.
    # In enforce mode, both :failed and :abstained block or escalate: "cannot tell" never passes.
    Verdict = Struct.new(:gate, :mode, :status, :answers, :failed, :model, keyword_init: true) do
      def enforce? = mode == 'enforce'

      def blocking? = enforce? && %i[failed abstained].include?(status)

      def answer(id) = (answers || {})[id]
    end

    module_function

    def policy
      @policy ||= File.exist?(POLICY_FILE) ? (YAML.safe_load_file(POLICY_FILE) || {}) : {}
    end

    def gate(name) = (policy['gates'] || {})[name] || {}

    def mode(name) = ENV['JEV_DISABLED'] == '1' ? 'off' : gate(name).fetch('mode', 'off')

    def model = ENV.fetch('JEV_MODEL', policy.fetch('model', 'jev-latest'))

    def installed? = ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? { |d| File.executable?(File.join(d, 'jev')) }

    # Installed and holding an API key, checked offline (no API call).
    def available?
      return @available unless @available.nil?

      @available = installed? &&
                   JSON.parse(OpenSpecOrchestrator.run(%w[jev auth status --offline -o json --quiet],
                                                       timeout: 30, stderr: :separate).out)['authenticated'] == true
    rescue JSON::ParserError
      @available = false
    end

    # Asks every question of a gate about `state` in one call. Answers are cached
    # by content (question file, state, model, asserts), so re-checking an
    # unchanged plan after a hold or a resume costs nothing.
    def ask(name, state, cache_dir:, log: nil, change: nil)
      gate_mode = mode(name)
      return Verdict.new(gate: name, mode: gate_mode, status: :skipped) if gate_mode == 'off'
      return unavailable(name, gate_mode, change, 'jev is not installed or has no API key') unless available?

      cfg = gate(name)
      file = File.join(ROOT, cfg.fetch('file'))
      body = JSON.generate(clip(state))
      key = Digest::SHA256.hexdigest(JSON.generate([File.read(file), body, model, cfg['assert']]))[0, 16]
      FileUtils.mkdir_p(cache_dir)
      cache_file = File.join(cache_dir, "jev-#{name}-#{key}.json")
      data = OpenSpecOrchestrator.read_json(cache_file)
      cached = !data.nil?
      unless cached
        state_file = File.join(cache_dir, "jev-#{name}-#{key}.state.json")
        File.write(state_file, body)
        args = ['jev', 'eval', '-f', file, '--state-file', state_file, '--state-format', 'json', '--model', model,
                '--timeout', policy.fetch('timeout', '30s').to_s, '--max-retries', policy.fetch('max_retries', 2).to_s,
                '-o', 'json', '--quiet', '--no-input']
        Array(cfg['assert']).each { |c| args.push('--assert', c) }
        res = OpenSpecOrchestrator.run(args, timeout: 300, log: log, stderr: :separate)
        if UNAVAILABLE_CODES.include?(res.code)
          return unavailable(name, gate_mode, change, "exit #{res.code}: #{res.err.to_s.strip[0, 300]}")
        end
        # Exit 2 means our question file or policy is wrong: a framework bug, never the change's fault.
        raise "jev rejected #{cfg['file']} (exit #{res.code}): #{res.err.to_s.strip[0, 500]}" unless [0, 10].include?(res.code)

        data = JSON.parse(res.out)
        OpenSpecOrchestrator.write_json_atomic(cache_file, data)
      end
      verdict(name, gate_mode, data, change, cached)
    end

    def unavailable(name, gate_mode, change, detail)
      OpenSpecOrchestrator.emit('jev.unavailable', gate: name, change: change, detail: detail)
      if gate_mode == 'enforce' && policy['on_unavailable'] == 'block'
        raise OpenSpecOrchestrator::Blocked.new('judge_unavailable', "#{name}: #{detail}")
      end

      Verdict.new(gate: name, mode: gate_mode, status: :unavailable)
    end

    def verdict(name, gate_mode, data, change, cached)
      low, high = Array(policy.fetch('abstain_band', [0.4, 0.6])).map(&:to_f)
      missed = Array(data.dig('gate', 'conditions')).reject { |c| c['passed'] }
      undecided, failed = missed.partition { |c| c['actual'].is_a?(Numeric) && c['actual'].between?(low, high) }
      status = if failed.any? then :failed
               elsif undecided.any? then :abstained
               else :passed
               end
      OpenSpecOrchestrator.emit('jev.answer', gate: name, change: change, mode: gate_mode, status: status,
                                              model: data['model'], answers: summarize(data['answers']).to_json,
                                              cost_usd: cached ? 0 : data['cost_usd'], cached: cached)
      Verdict.new(gate: name, mode: gate_mode, status: status, answers: data['answers'] || {},
                  failed: missed, model: data['model'])
    end

    # A policy rule: {question, choice, min_confidence} for a choice answer,
    # {question, min} or {question, max} for a noul probability.
    def matches?(verdict, rule)
      return false unless rule.is_a?(Hash) && (answer = verdict.answer(rule['question']))

      if rule['choice']
        answer['choice'] == rule['choice'] && answer['confidence'].to_f >= rule.fetch('min_confidence', 0).to_f
      elsif rule.key?('min') then answer['noul'].to_f >= rule['min'].to_f
      elsif rule.key?('max') then answer['noul'].to_f <= rule['max'].to_f
      else false
      end
    end

    def summarize(answers)
      (answers || {}).transform_values do |a|
        case a['type']
        when 'noul' then a['noul']
        when 'choice' then "#{a['choice']}@#{a['confidence']}"
        when 'score' then a['score']
        else a
        end
      end
    end

    # Repair feedback for an agent. Jev returns no text, so the feedback is the
    # failed condition, the measured probability and the question itself.
    def feedback(verdict)
      questions = YAML.safe_load_file(File.join(ROOT, gate(verdict.gate).fetch('file'))).fetch('questions', {})
      lines = verdict.failed.map do |c|
        q = questions[c['condition'][/\A[\w-]+/]] || {}
        "- #{c['condition']} failed (measured #{c['actual']}). Question: #{q['instructions']} " \
          "A yes means: #{q.dig('criteria', 'true')}"
      end
      "Jev #{verdict.gate} (a calibrated yes/no judge, model #{verdict.model}) rejected this:\n#{lines.join("\n")}"
    end

    def clip(obj)
      limit = policy.fetch('max_state_chars', 24_000).to_i
      case obj
      when Hash then obj.transform_values { |v| clip(v) }
      when Array then obj.map { |v| clip(v) }
      when String then obj.length > limit ? "#{obj[0, limit]}\n[... clipped #{obj.length - limit} characters]" : obj
      else obj
      end
    end
  end
end
