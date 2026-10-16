#!/usr/bin/env bash
# ==============================================================================
# bin/agent_exec.sh - Engine-agnostic headless agent adapter
# ==============================================================================
# Usage: bin/agent_exec.sh <workdir> <prompt-file> [engine]
#
# Selects the engine from argument $3, $AGENT_ENGINE (claude|hermes|opencode|codex|stub)
# or the first engine found on PATH. Every invocation is bounded by a wall-clock
# timeout. The exit code is the engine's exit code (124 = timeout).
# Callers MUST NOT trust the agent's own success claim: verify post-conditions
# (openspec validate, task counts, quality gates) after every call.
set -euo pipefail

WORKDIR="${1:?usage: agent_exec.sh <workdir> <prompt-file> [engine]}"
PROMPT_FILE="${2:?usage: agent_exec.sh <workdir> <prompt-file> [engine]}"
PROMPT="$(cat "$PROMPT_FILE")"
LIMIT="${AGENT_TIMEOUT_SECONDS:-3600}"

ENGINE="${3:-${AGENT_ENGINE:-}}"
if [ -z "$ENGINE" ]; then
  for candidate in claude hermes opencode codex; do
    if command -v "$candidate" >/dev/null 2>&1; then ENGINE="$candidate"; break; fi
  done
fi

# macOS ships without GNU timeout; Homebrew coreutils installs it as gtimeout.
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
# GNU timeout moves itself into a new process group, so INT/TERM sent to our
# group (dispatcher shutdown, a scheduler stopping the cycle) would never reach
# the agent and would orphan it. Run timeout in the background and forward
# those signals.
TIMEOUT_PID=""
forward_signal() { [ -n "$TIMEOUT_PID" ] && kill -TERM "$TIMEOUT_PID" 2>/dev/null; }
bounded() {
  if [ -z "$TIMEOUT_BIN" ]; then "$@"; return; fi
  "$TIMEOUT_BIN" --kill-after=60 "$LIMIT" "$@" &
  TIMEOUT_PID=$!
  trap forward_signal INT TERM
  local rc=0
  # A trapped signal makes wait return early (status > 128): keep waiting until timeout exits.
  while :; do
    wait "$TIMEOUT_PID" && rc=0 || rc=$?
    kill -0 "$TIMEOUT_PID" 2>/dev/null || break
  done
  return "$rc"
}

# Agents may edit files, run gates, inspect git state and query read-only cycle
# helpers. They MUST NOT commit, push, switch branches or rewrite canonical
# specs; the dispatcher and run_cycle.sh own commits, and only the merger holds
# push credentials.
# Jev (a calibrated judge, not an engine) is allowed for read-only questions only;
# auth, config, update and batch subcommands stay denied by omission.
CLAUDE_ALLOWED="${CLAUDE_ALLOWED_TOOLS:-Read Edit Write Glob Grep Bash(openspec *) Bash(git status *) Bash(git diff *) Bash(git log *) Bash(git show *) Bash(git rev-parse *) Bash(bash bin/run_gates.sh *) Bash(bash bin/cycle_status.sh *) Bash(bash bin/completed_since.sh *) Bash(jev noul *) Bash(jev choice *) Bash(jev score *) Bash(jev eval *) Bash(jev validate *)}"
CLAUDE_DENIED="${CLAUDE_DISALLOWED_TOOLS:-Bash(git commit *) Bash(git push *) Bash(git rebase *) Bash(git reset *) Bash(git checkout *) Bash(git switch *) Bash(rm -rf *)}"

cd "$WORKDIR"
case "$ENGINE" in
  claude)
    bounded claude -p "$PROMPT" \
      --output-format json \
      --permission-mode acceptEdits \
      --allowedTools "$CLAUDE_ALLOWED" \
      --disallowedTools "$CLAUDE_DENIED" \
      --max-budget-usd "${AGENT_MAX_BUDGET_USD:-5}" \
      --no-session-persistence
    ;;
  hermes)
    # --yolo disables approval prompts: run inside a sandbox/container only.
    bounded hermes -z "$PROMPT" --yolo --accept-hooks
    ;;
  opencode)
    bounded opencode run --format json "$PROMPT"
    ;;
  codex)
    bounded codex exec --full-auto "$PROMPT"
    ;;
  stub)
    # Deterministic fake agent for orchestrator tests (see section 15).
    bounded bash "${AGENT_STUB:?AGENT_STUB must point to a stub script}" "$PROMPT_FILE"
    ;;
  *)
    echo "agent_exec: no AI engine available (set AGENT_ENGINE)" >&2
    exit 127
    ;;
esac
