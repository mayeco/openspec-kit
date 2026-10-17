#!/usr/bin/env bash
# ==============================================================================
# bin/agent_exec.sh - Engine-agnostic headless agent adapter
# ==============================================================================
# Usage: bin/agent_exec.sh <workdir> <prompt-file> [engine]
#
# Engines: claude, codex, copilot, hermes, opencode, and stub for the kit's tests.
# Callers pass the engine of their role from config/agents.yaml (bin/lib/agents.rb);
# without one it is $AGENT_ENGINE, then the first engine found on PATH. Every
# invocation is bounded by a wall-clock timeout, limits.agent_seconds of
# config/pipeline.yaml (bin/lib/settings.rb). The exit code is the engine's
# exit code (124 = timeout). What agents may do is `permissions` in
# config/agents.yaml (or $AGENT_PERMISSIONS): all, the default, or restricted.
# Callers MUST NOT trust the agent's own success claim: verify post-conditions
# (openspec validate, task counts, quality gates) after every call.
set -euo pipefail

WORKDIR="${1:?usage: agent_exec.sh <workdir> <prompt-file> [engine]}"
PROMPT_FILE="${2:?usage: agent_exec.sh <workdir> <prompt-file> [engine]}"
PROMPT="$(cat "$PROMPT_FILE")"
SETTINGS="$(dirname "$0")/lib/settings.rb"   # config/pipeline.yaml
LIMIT="$(ruby "$SETTINGS" get limits.agent_seconds)"
PERMISSIONS="$(ruby "$(dirname "$0")/lib/agents.rb" permissions)"

ENGINE="${3:-${AGENT_ENGINE:-}}"
if [ -z "$ENGINE" ]; then
  for candidate in claude codex copilot hermes opencode; do
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

# Agents MUST NOT commit, push, switch branches or rewrite canonical specs: the
# dispatcher and run_cycle.sh own commits, and only the merger holds push
# credentials. The deny rules below hold in every permission mode.
# permissions: all lets Claude Code run anything else (servers, curl, browsers),
# which live QA needs. permissions: restricted allows only CLAUDE_ALLOWED: edit
# files, run gates, inspect git state and query read-only cycle helpers. Jev (a
# calibrated judge, not an engine) is allowed there for read-only questions
# only; auth, config, update and batch subcommands stay denied by omission.
CLAUDE_ALLOWED="${CLAUDE_ALLOWED_TOOLS:-Read Edit Write Glob Grep Bash(openspec *) Bash(git status *) Bash(git diff *) Bash(git log *) Bash(git show *) Bash(git rev-parse *) Bash(bash bin/run_gates.sh *) Bash(bash bin/cycle_status.sh *) Bash(bash bin/completed_since.sh *) Bash(ruby bin/visual_qa.rb request *) Bash(jev noul *) Bash(jev choice *) Bash(jev score *) Bash(jev eval *) Bash(jev validate *)}"
CLAUDE_DENIED="${CLAUDE_DISALLOWED_TOOLS:-Bash(git commit *) Bash(git push *) Bash(git rebase *) Bash(git reset *) Bash(git checkout *) Bash(git switch *) Bash(rm -rf *)}"
# Copilot needs --allow-all-tools to run headless; deny rules take precedence over it.
COPILOT_DENIED="${COPILOT_DENIED_TOOLS:-shell(git commit),shell(git push),shell(git rebase),shell(git reset),shell(git checkout),shell(git switch)}"

cd "$WORKDIR"
case "$ENGINE" in
  claude)
    if [ "$PERMISSIONS" = restricted ]; then
      MODE=(--permission-mode acceptEdits --allowedTools "$CLAUDE_ALLOWED")
    else
      MODE=(--permission-mode bypassPermissions)
    fi
    bounded claude -p "$PROMPT" \
      --output-format json \
      "${MODE[@]}" \
      --disallowedTools "$CLAUDE_DENIED" \
      --max-budget-usd "$(ruby "$SETTINGS" get limits.agent_budget_usd)" \
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
    if [ "$PERMISSIONS" = restricted ]; then
      bounded codex exec --full-auto "$PROMPT"
    else
      bounded codex exec --dangerously-bypass-approvals-and-sandbox "$PROMPT"
    fi
    ;;
  copilot)
    DENY=()
    IFS=',' read -ra RULES <<< "$COPILOT_DENIED"
    for rule in "${RULES[@]}"; do DENY+=(--deny-tool "$rule"); done
    bounded copilot -p "$PROMPT" --silent --allow-all-tools "${DENY[@]}"
    ;;
  stub)
    # Deterministic fake agent for the orchestrator's own tests.
    bounded bash "${AGENT_STUB:?AGENT_STUB must point to a stub script}" "$PROMPT_FILE"
    ;;
  *)
    echo "agent_exec: no AI engine available (set AGENT_ENGINE)" >&2
    exit 127
    ;;
esac
