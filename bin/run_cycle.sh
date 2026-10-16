#!/usr/bin/env bash
# ==============================================================================
# bin/run_cycle.sh - Deterministic wrapper for one scheduled autonomous cycle
# ==============================================================================
# Usage: bin/run_cycle.sh [--detach]
#   --detach  what a scheduled task runs (Claude or Hermes app): start the cycle
#             in a new session and return at once with its pid and log.
#
# Owns everything that must not depend on an LLM remembering to do it: PATH,
# the re-entrancy lock, the pause switch, preflight, merging, sync, the
# write-scope guard, recording memory, and dispatch. The agent runs once, for
# judgment only (verify, triage, explore, queue, curate memory), following the
# openspec-cycle skill through templates/cycle_prompt.md.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
# Schedulers start with a minimal PATH: Homebrew, ~/.local/bin and Ruby shims are missing.
export PATH="${OPENSPEC_PATH_PREFIX:-/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin}:$PATH"
export CI=1 NONINTERACTIVE=1 GIT_TERMINAL_PROMPT=0
BASE="${OPENSPEC_BASE_BRANCH:-master}"
LOG_DIR="$ROOT/log"
CYCLE_DIR="$LOG_DIR/cycle"   # state.json, reports/ and one log per cycle (git-ignored)
LOCK="$LOG_DIR/cycle.lock"   # a directory: mkdir is atomic everywhere (macOS has no flock(1))
mkdir -p "$CYCLE_DIR/reports"

lock_owner() { # prints the PID of a live cycle, if any
  local pid
  pid="$(cat "$LOCK/pid" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && echo "$pid"
}

if [ -f "$LOG_DIR/PAUSE" ]; then echo "cycle: paused ($(head -1 "$LOG_DIR/PAUSE"))"; exit 0; fi

if [ "${1:-}" = "--detach" ]; then
  if pid="$(lock_owner)"; then echo "cycle: already running (pid $pid)"; exit 0; fi
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

if ! mkdir "$LOCK" 2>/dev/null; then
  if OWNER="$(lock_owner)"; then echo "cycle: already running (pid $OWNER)"; exit 0; fi
  echo "cycle: reclaiming stale lock (pid $(cat "$LOCK/pid" 2>/dev/null || echo unknown))"
  rm -rf "$LOCK" && mkdir "$LOCK" || exit 1
fi
echo "$$" > "$LOCK/pid"
MERGER=""
trap 'rm -rf "$LOCK"; [ -n "$MERGER" ] && kill "$MERGER" 2>/dev/null' EXIT

STAMP="${CYCLE_STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
exec > >(tee -a "$CYCLE_DIR/cycle-$STAMP.log") 2>&1

# The judgment agent may write only these versioned paths (plus log/cycle/ and
# log/PAUSE, which git ignores); everything else belongs to the merger or to humans.
SCOPE=(MEMORY.md config/agent_backlog.json)

DEFAULT_ENGINE="${AGENT_ENGINE:-claude}"
ENGINE_CYCLE="${AGENT_ENGINE_CYCLE:-$DEFAULT_ENGINE}"

# First cycle: start the state from the skill's template.
STATE_TEMPLATE=".agents/skills/openspec-cycle/references/state.template.json"
[ -f "$CYCLE_DIR/state.json" ] || { [ -f "$STATE_TEMPLATE" ] && cp "$STATE_TEMPLATE" "$CYCLE_DIR/state.json"; }

merger_running() {
  local pid
  pid="$(sed -nE 's/.*pid=([0-9]+).*/\1/p' "$LOG_DIR/locks/merger.lock" 2>/dev/null | head -1)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

echo "== cycle $STAMP"
echo "== preflight"; bash bin/check_ai_engines.sh || exit 1
# Integrate what the previous cycle queued, so the judgment verifies it.
echo "== merge";     merger_running && echo "merger service running; not draining" || ruby bin/openspec_merger.rb
echo "== sync";      bash bin/sync_repos.sh
echo "== judgment";  bash bin/agent_exec.sh "$ROOT" templates/cycle_prompt.md "$ENGINE_CYCLE" || echo "cycle: agent exited non-zero"

echo "== scope guard"
OUTSIDE="$(git status --porcelain --ignore-submodules=all -- . "${SCOPE[@]/#/:!}")"
if [ -n "$OUTSIDE" ]; then
  echo "cycle: agent wrote outside its scope; nothing recorded, pausing for a human:"; echo "$OUTSIDE"
  echo "scope violation in cycle $STAMP" > "$LOG_DIR/PAUSE"
  exit 1
fi

echo "== record"
if [ -n "$(git status --porcelain -- "${SCOPE[@]}")" ]; then
  # git add aborts on a pathspec that matches nothing: stage existing or tracked paths only.
  STAGE=()
  for p in "${SCOPE[@]}"; do
    if [ -e "$p" ] || git ls-files --error-unmatch -- "$p" >/dev/null 2>&1; then STAGE+=("$p"); fi
  done
  git add -A -- "${STAGE[@]}" && git commit --quiet -m "chore(memory): scheduled cycle $STAMP"
  for attempt in 1 2 3; do
    # Disjoint paths from the merger's commits, so this rebase cannot conflict on content.
    git pull --quiet --rebase origin "$BASE" && git push --quiet origin "HEAD:$BASE" && break
    sleep $((attempt * 5))
  done
  git submodule update --init --quiet
fi

if [ -f "$LOG_DIR/PAUSE" ]; then echo "cycle: paused by agent or operator"; exit 0; fi
echo "== dispatch"
# A merger integrates while the dispatcher waits on dependencies. Once the
# dispatcher has finished, log/merger.stop makes it drain the queue and exit
# between changes. A merger the operator runs as a service is left alone.
if ! merger_running; then
  ruby bin/openspec_merger.rb --watch --interval "${OPENSPEC_MERGE_INTERVAL:-10}" &
  MERGER=$!
fi
ruby bin/openspec_dispatcher.rb --workers "${OPENSPEC_WORKERS:-2}" --wait "${OPENSPEC_WAIT_TIMEOUT:-1800}"
if [ -n "$MERGER" ]; then
  echo "$MERGER" > "$LOG_DIR/merger.stop"
  wait "$MERGER"
  MERGER=""
fi
echo "== done"
