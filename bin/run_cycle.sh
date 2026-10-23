#!/usr/bin/env bash
# ==============================================================================
# bin/run_cycle.sh - Deterministic wrapper for one scheduled autonomous cycle
# ==============================================================================
# Usage: bin/run_cycle.sh [--detach]
#   --detach  what a scheduled task runs (Claude or Hermes app): start the cycle
#             in a new session and return at once with its pid and log.
#
# Owns everything that must not depend on an LLM remembering to do it: PATH,
# the locks, the pause switch, preflight, merging, sync, the cycle's plan
# (bin/cycle_prompt.rb), the write-scope guard, the review of proposals
# (bin/proposals.rb), recording memory, and dispatch. The agent runs once, for
# judgment only (verify, triage, explore, queue, propose, curate memory),
# following the openspec-kit-cycle skill through the prompt the script renders.
# The scheduled task always runs the same command: every setting, the engines
# included, is read here from config/ (config/agents.yaml, config/cycle.yaml,
# config/exploration.yaml, config/pipeline.yaml).
#
# Two locks: log/cycle.lock covers the judgment, from preflight to record, and
# log/dispatch.lock covers a dispatch. A dispatch can take hours; the cycle lock
# is released before it starts, so the next scheduled cycle still verifies,
# explores and queues while it runs, and leaves the dispatch to it.
#
# The judgment here is headless: crontab, launchd or an agent app may schedule
# it, and it runs in its own worktree (.worktrees/_cycle, OPENSPEC_SLOT=98).
# Testing in a browser needs an agent app (Claude, Hermes) in the main checkout:
# changes the merger integrated are queued for the visual QA session of
# bin/visual_qa.sh, which runs in parallel and reconciles its findings on record.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
# Schedulers (cron, systemd, launchd) start with a minimal PATH: ~/.local/bin, /usr/local/bin and language shims are missing.
export PATH="${OPENSPEC_PATH_PREFIX:-$HOME/.local/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:/opt/homebrew/bin}:$PATH"
export CI=1 NONINTERACTIVE=1 GIT_TERMINAL_PROMPT=0
BASE="$(ruby "$ROOT/bin/lib/settings.rb" get base_branch)"   # config/pipeline.yaml
LOG_DIR="$ROOT/log"
CYCLE_DIR="$LOG_DIR/cycle"            # state.json, reports/, prompts and one log per cycle (git-ignored)
LOCK="$LOG_DIR/cycle.lock"            # directories: mkdir is atomic everywhere (macOS has no flock(1))
DISPATCH_LOCK="$LOG_DIR/dispatch.lock"
WORKTREE_BASE="${OPENSPEC_WORKTREE_BASE:-$ROOT/.worktrees}"
CYCLE_WT="$WORKTREE_BASE/_cycle"      # isolated worktree where the headless cycle judges (slot 98)
CYCLE_SLOT="${OPENSPEC_CYCLE_SLOT:-98}"
mkdir -p "$CYCLE_DIR/reports"

lock_owner() { # <lock-dir>: prints the PID of its live owner, if any
  local pid
  pid="$(cat "$1/pid" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && echo "$pid"
}
take_lock() { # <lock-dir>: succeeds when this process now holds it
  if ! mkdir "$1" 2>/dev/null; then
    lock_owner "$1" >/dev/null && return 1
    echo "cycle: reclaiming stale $(basename "$1") (pid $(cat "$1/pid" 2>/dev/null || echo unknown))"
    rm -rf "$1" && mkdir "$1" || return 1
  fi
  echo "$$" > "$1/pid"
}
live_pid_in() { # <lockfile with pid=N>: prints N when that process is alive
  local pid
  pid="$(sed -nE 's/.*pid=([0-9]+).*/\1/p' "$1" 2>/dev/null | head -1)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && echo "$pid"
}
merger_running() { live_pid_in "$LOG_DIR/locks/merger.lock" >/dev/null; }
# A cycle's dispatch, or a dispatcher an operator started by hand.
dispatch_owner() { lock_owner "$DISPATCH_LOCK" || live_pid_in "$LOG_DIR/locks/dispatcher.lock"; }
# shellcheck source=lib/record.sh
. "$ROOT/bin/lib/record.sh"   # SCOPE, with_record_lock, scope_guard, record, visual_session

# Resets .worktrees/_cycle to origin/<base> (bin/lib/record.sh). When no visual
# session owns the main checkout, syncs it first and carries its uncommitted edits
# of the scope (`proposals.rb approve`, an item queued by hand) into _cycle with a
# three-way merge; the main checkout keeps them until this cycle has published them.
CARRIED=""
prepare_cycle_worktree() {
  local base_ref visual
  visual="$(visual_session || true)"
  if [ -n "$visual" ]; then
    echo "visual QA session $visual in progress: leaving main checkout untouched; judging in .worktrees/_cycle"
    git -C "$ROOT" fetch --quiet origin "$BASE" 2>/dev/null || true
  else
    scope_guard "cycle $STAMP" || return 1
    bash bin/sync_repos.sh
  fi
  base_ref="$(git -C "$ROOT" rev-parse --verify --quiet "origin/$BASE" || git -C "$ROOT" rev-parse HEAD)"
  prepare_session_worktree "$CYCLE_WT" "$base_ref" || return 1
  [ -z "$visual" ] || return 0
  CARRIED="$(scope_edits "$ROOT")"
  [ -z "$CARRIED" ] || (cd "$CYCLE_WT" && ruby bin/proposals.rb carry "$ROOT")
}

if [ -f "$LOG_DIR/PAUSE" ]; then echo "cycle: paused ($(head -1 "$LOG_DIR/PAUSE"))"; exit 0; fi

if [ "${1:-}" = "--detach" ]; then
  if pid="$(lock_owner "$LOCK")"; then echo "cycle: already running (pid $pid)"; exit 0; fi
  # A scheduled agent's shell must not own the cycle (Claude Code stops a command
  # after 10 minutes, and the session ends): start it in a new session, with no
  # terminal and no inherited pipes, so the agent can return at once.
  STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
  pid="$(CYCLE_STAMP="$STAMP" ruby -e '
    pid = fork do
      Process.setsid
      [$stdin, $stdout, $stderr].each { |io| io.reopen(File::NULL, io.equal?($stdin) ? "r" : "w") }
      exec("bash", ARGV[0])
    end
    puts pid' "$ROOT/bin/run_cycle.sh")"
  echo "cycle: started pid=$pid log=log/cycle/cycle-$STAMP.log"
  exit 0
fi

if ! take_lock "$LOCK"; then echo "cycle: already running (pid $(lock_owner "$LOCK"))"; exit 0; fi
CYCLE_HELD=1; DISPATCH_HELD=0; MERGER=""
cleanup() {
  [ "$CYCLE_HELD" = 1 ] && rm -rf "$LOCK"
  [ "$DISPATCH_HELD" = 1 ] && rm -rf "$DISPATCH_LOCK"
  [ -n "$MERGER" ] && kill "$MERGER" 2>/dev/null
}
trap cleanup EXIT

STAMP="${CYCLE_STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
exec > >(tee -a "$CYCLE_DIR/cycle-$STAMP.log") 2>&1

# roles.cycle in config/agents.yaml, unless AGENT_ENGINE_CYCLE or AGENT_ENGINE overrides it.
ENGINE_CYCLE="$(ruby bin/lib/agents.rb engine cycle)"

# First cycle: start the state from its template.
[ -f "$CYCLE_DIR/state.json" ] || cp config/templates/cycle_state.json "$CYCLE_DIR/state.json"

echo "== cycle $STAMP"
DISPATCHING="$(dispatch_owner || true)"
[ -n "$DISPATCHING" ] && echo "dispatch in progress (pid $DISPATCHING): this cycle judges and records, and does not dispatch"
echo "== preflight"; bash bin/check_ai_engines.sh || exit 1
# Integrate what the previous cycle queued, so the judgment verifies it.
echo "== merge";     merger_running && echo "merger running; not draining" || ruby bin/openspec_merger.rb
echo "== sync"
with_record_lock prepare_cycle_worktree || exit 1
# What the merger integrated since the last cycle waits for the browser (bin/visual_qa.sh).
echo "== visual queue"; ruby "$CYCLE_WT/bin/visual_qa.rb" enqueue-integrated || echo "cycle: visual queue not updated"

echo "== plan"
PROMPT="$CYCLE_DIR/prompt-$STAMP.md"
ruby "$CYCLE_WT/bin/cycle_prompt.rb" "$PROMPT" --dispatch-running "$DISPATCHING" || exit 1
echo "== judgment (${ENGINE_CYCLE:-first engine on PATH})"
# Each attempt gets the judgment's budget plus 15 minutes, not limits.agent_seconds (a
# long BUILD's limit): a stuck judgment must not hold up the hourly cycle and its dispatch.
budget="$(ruby -ryaml -e 'puts(((YAML.safe_load_file(ARGV[0]) rescue {}) || {}).fetch("qa_time_budget_minutes", 45).to_i)' "$CYCLE_WT/config/cycle.yaml")"
OPENSPEC_SLOT="${OPENSPEC_SLOT:-$CYCLE_SLOT}" AGENT_TIMEOUT_SECONDS="${AGENT_TIMEOUT_SECONDS:-$(( (budget + 15) * 60 ))}" \
  bash "$CYCLE_WT/bin/agent_exec.sh" "$CYCLE_WT" "$PROMPT" "$ENGINE_CYCLE" || echo "cycle: agent exited non-zero"

echo "== scope guard"; (cd "$CYCLE_WT" && scope_guard "cycle $STAMP") || exit 1
# Proposals the judgment added are approved (Jev, a human or automatically, as
# config/cycle.yaml says) and the approved ones are queued in the backlog.
echo "== proposals"; (cd "$CYCLE_WT" && ruby bin/proposals.rb review) || echo "cycle: proposal review failed; proposals left as they were"
echo "== record"
record_cycle() {
  if (cd "$CYCLE_WT" && record "chore(memory): scheduled cycle $STAMP"); then
    # A visual session that began meanwhile owns the main checkout: its end carries them again.
    visual_session >/dev/null || release_scope_edits "$CARRIED"
  fi
  visual_session >/dev/null || bash bin/sync_repos.sh >/dev/null 2>&1 || true
}
with_record_lock record_cycle

# The judgment is recorded: from here on the next scheduled cycle may start.
rm -rf "$LOCK"; CYCLE_HELD=0
if [ -f "$LOG_DIR/PAUSE" ]; then echo "cycle: paused by agent or operator"; exit 0; fi
echo "== dispatch"
if ! take_lock "$DISPATCH_LOCK"; then
  echo "dispatch: already running (pid $(dispatch_owner)); it picks up what this cycle queued when a worker is free"
  echo "== done"; exit 0
fi
DISPATCH_HELD=1
if pid="$(live_pid_in "$LOG_DIR/locks/dispatcher.lock")"; then
  echo "dispatch: a dispatcher started by hand is running (pid $pid); not starting another"
  echo "== done"; exit 0
fi
# A merger integrates while the dispatcher waits on dependencies. Once the
# dispatcher has finished, log/merger.stop makes it drain the queue and exit
# between changes. A merger the operator runs as a service is left alone.
if ! merger_running; then
  ruby bin/openspec_merger.rb --watch &
  MERGER=$!
fi
# Workers, waiting and the merger's interval come from config/pipeline.yaml.
ruby bin/openspec_dispatcher.rb --wait
if [ -n "$MERGER" ]; then
  echo "$MERGER" > "$LOG_DIR/merger.stop"
  wait "$MERGER"
  MERGER=""
fi
echo "== done"
