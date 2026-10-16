#!/usr/bin/env bash
# ==============================================================================
# bin/run_cycle.sh - Deterministic wrapper for one scheduled autonomous cycle
# ==============================================================================
# Owns everything that must not depend on an LLM remembering to do it: PATH,
# the re-entrancy lock, the pause switch, preflight, sync, the write-scope
# guard, recording memory, and dispatch. The agent runs once, for judgment
# only (verify, triage, explore, propose, curate memory), using
# templates/cron_routine_prompt.md.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
# launchd and cron start with a minimal PATH: Homebrew, ~/.local/bin and Ruby shims are missing.
export PATH="${OPENSPEC_PATH_PREFIX:-/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin}:$PATH"
export CI=1 NONINTERACTIVE=1 GIT_TERMINAL_PROMPT=0
BASE="${OPENSPEC_BASE_BRANCH:-master}"
LOG_DIR="$ROOT/log"
LOCK="$LOG_DIR/cycle.lock"   # a directory: mkdir is atomic everywhere (macOS has no flock(1))
mkdir -p "$LOG_DIR"

if [ -f "$LOG_DIR/PAUSE" ]; then echo "cycle: paused ($(head -1 "$LOG_DIR/PAUSE"))"; exit 0; fi

if ! mkdir "$LOCK" 2>/dev/null; then
  OWNER="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [ -n "$OWNER" ] && kill -0 "$OWNER" 2>/dev/null; then echo "cycle: already running (pid $OWNER)"; exit 0; fi
  echo "cycle: reclaiming stale lock (pid ${OWNER:-unknown})"
  rm -rf "$LOCK" && mkdir "$LOCK" || exit 1
fi
echo "$$" > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
exec > >(tee -a "$LOG_DIR/cycle-$STAMP.log") 2>&1

# The routine may write only these paths; everything else belongs to the merger or to humans.
SCOPE=(MEMORY.md memory config/agent_backlog.json)

DEFAULT_ENGINE="${AGENT_ENGINE:-claude}"
ENGINE_CYCLE="${AGENT_ENGINE_CYCLE:-$DEFAULT_ENGINE}"

echo "== preflight"; bash bin/check_ai_engines.sh || exit 1
echo "== sync";      bash bin/sync_repos.sh
echo "== judgment";  bash bin/agent_exec.sh "$ROOT" templates/cron_routine_prompt.md "$ENGINE_CYCLE" || echo "cycle: agent exited non-zero"

echo "== scope guard"
OUTSIDE="$(git status --porcelain --ignore-submodules=all -- . "${SCOPE[@]/#/:!}")"
if [ -n "$OUTSIDE" ]; then
  echo "cycle: agent wrote outside its scope; nothing recorded, pausing for a human:"; echo "$OUTSIDE"
  echo "scope violation in cycle $STAMP" > "$LOG_DIR/PAUSE"
  exit 1
fi

echo "== record"
if [ -n "$(git status --porcelain -- "${SCOPE[@]}")" ]; then
  # git add aborts on a pathspec that matches nothing (e.g. no memory/ yet): stage existing or tracked paths only.
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
echo "== dispatch";  ruby bin/openspec_dispatcher.rb --workers "${OPENSPEC_WORKERS:-2}" --wait "${OPENSPEC_WAIT_TIMEOUT:-1800}"
echo "== done"
