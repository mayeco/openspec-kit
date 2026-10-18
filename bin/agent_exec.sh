#!/usr/bin/env bash
# ==============================================================================
# bin/agent_exec.sh - Engine-agnostic headless agent adapter
# ==============================================================================
# Usage: bin/agent_exec.sh <workdir> <prompt-file> [engine[,engine...]]
#
# Engines: claude, codex, copilot, hermes, opencode, agy (Antigravity), and stub for the kit's tests.
# Callers pass the engines of their role from config/agents.yaml (bin/lib/agents.rb),
# in order; without them it is $AGENT_ENGINE, then the first engine found on PATH.
# Retries and fallback: an engine that fails (any exit code but 0: out of quota, not
# logged in, timed out) is tried again limits.agent_retries times
# (config/pipeline.yaml), then the next engine runs; one that is not installed is
# skipped at once, and so is one that says it is out of quota or over a usage limit,
# which a short wait does not lift. An attempt that left changes in the work directory
# is followed by one told, in its prompt, who stopped and what is there, to continue
# from that state. The caller verifies the result as always. Every
# invocation is bounded by a wall-clock timeout, limits.agent_seconds of
# config/pipeline.yaml (bin/lib/settings.rb). The exit code is the last engine's
# exit code (124 = timeout), or 75 when every engine failed and the work directory is
# as it was: no engine could work, so the caller tries again later instead of counting
# a failed attempt at the task. What agents may do is `permissions` in
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

ENGINES="${3:-${AGENT_ENGINE:-}}"
if [ -z "$ENGINES" ]; then
  for candidate in claude codex copilot hermes opencode agy; do
    if command -v "$candidate" >/dev/null 2>&1; then ENGINES="$candidate"; break; fi
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
  trap - INT TERM # a signal during a retry's wait stops this script
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

# What the work directory holds, child repositories included; log/ and other ignored
# files do not count. An engine that leaves it unchanged did no work.
tree_state() {
  { git status --porcelain=v1 --untracked-files=all 2>/dev/null
    git diff HEAD 2>/dev/null
    git submodule foreach --quiet --recursive 'git status --porcelain=v1 --untracked-files=all; git diff HEAD' 2>/dev/null
    true # outside a git checkout every command above fails; the state is then constant
  } | cksum
}

# Out of quota or credits, or over a usage limit: such limits reset in hours, so trying the
# engine again after limits.agent_retry_delay_seconds would only fail again. Only the end
# of the attempt's output is read, where an engine says why it stopped.
QUOTA_PATTERN='hit your [a-z ]*limit|usage limit|session limit|weekly limit|out of credits|credit balance is too low|insufficient_quota|quota exceeded|exceeded your current quota|reached your [a-z ]*(quota|limit)'
out_of_quota() { tail -n 40 "$ATTEMPT_OUT" | grep -qiE "$QUOTA_PATTERN"; }

# What a failed attempt left, for the next one: every changed path and the size of each change.
changes_left() {
  { git status --short --untracked-files=all 2>/dev/null
    git submodule foreach --quiet --recursive 'git status --short --untracked-files=all | sed "s#^#$displaypath: #"' 2>/dev/null
    git diff --stat HEAD 2>/dev/null
    git submodule foreach --quiet --recursive 'git diff --stat HEAD | sed "s#^#$displaypath: #"' 2>/dev/null
    true
  } | head -n 120
}

continuation_note() { # <who stopped, and how>
  cat <<NOTE

## A previous attempt stopped before finishing

$1 worked on this same task and stopped. The work directory keeps what it changed:

\`\`\`
$(changes_left)
\`\`\`

Continue from this state instead of starting over: read the changes (git diff, and inside each
repository under repos/), keep what is right, fix what is wrong and finish the rest.
NOTE
}

run_engine() { # <engine>
  local ENGINE="$1"
  if [ "$ENGINE" != stub ] && ! command -v "$ENGINE" >/dev/null 2>&1; then
    echo "agent_exec: $ENGINE is not installed" >&2
    return 127
  fi
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
    agy)
      # Google Antigravity's CLI. Its print mode gives up after --print-timeout (5 minutes by
      # default): it gets the kit's limit, which bounded enforces anyway. restricted runs its
      # terminal in Antigravity's sandbox, approving inside it, as Codex's --full-auto does.
      SANDBOX=""
      [ "$PERMISSIONS" = restricted ] && SANDBOX=--sandbox
      bounded agy -p "$PROMPT" --print-timeout "${LIMIT}s" --dangerously-skip-permissions ${SANDBOX:+"$SANDBOX"}
      ;;
    copilot)
      DENY=()
      IFS=',' read -ra RULES <<< "$COPILOT_DENIED"
      for rule in "${RULES[@]}"; do DENY+=(--deny-tool "$rule"); done
      bounded copilot -p "$PROMPT" --silent --allow-all-tools "${DENY[@]}"
      ;;
    stub)
      # Deterministic fake agent for the orchestrator's own tests.
      bounded bash "${AGENT_STUB:?AGENT_STUB must point to a stub script}" "$RUN_PROMPT_FILE"
      ;;
    *)
      echo "agent_exec: unknown engine ${ENGINE:-none} (set AGENT_ENGINE)" >&2
      return 127
      ;;
  esac
}

cd "$WORKDIR"
[ -n "$ENGINES" ] || { echo "agent_exec: no AI engine available (set AGENT_ENGINE)" >&2; exit 127; }
IFS=',' read -ra LIST <<< "$ENGINES"
RETRIES="$(ruby "$SETTINGS" get limits.agent_retries)"
RETRY_DELAY="$(ruby "$SETTINGS" get limits.agent_retry_delay_seconds)"
BASE_PROMPT="$PROMPT"
RUN_PROMPT_FILE="$(mktemp "${TMPDIR:-/tmp}/agent-prompt.XXXXXX")" # the stub reads its prompt from a file
ATTEMPT_OUT="$(mktemp "${TMPDIR:-/tmp}/agent-out.XXXXXX")" # one attempt's output, read for a usage limit
trap 'rm -f "$RUN_PROMPT_FILE" "$ATTEMPT_OUT"' EXIT
START="$(tree_state)"
rc=127
ran=0
for i in "${!LIST[@]}"; do
  engine="$(printf '%s' "${LIST[$i]}" | tr -d '[:space:]')"
  [ -n "$engine" ] || continue
  try=0
  while :; do
    printf '%s' "$PROMPT" > "$RUN_PROMPT_FILE"
    rc=0
    run_engine "$engine" > "$ATTEMPT_OUT" 2>&1 || rc=$?
    cat "$ATTEMPT_OUT"
    # Parsed by the dispatcher for its agent.exit event.
    echo "agent_exec: engine $engine exited $rc" >&2
    [ "$rc" -eq 0 ] && exit 0
    [ "$rc" -eq 127 ] && break # not installed or unknown: no point trying it again
    ran=1
    if [ "$(tree_state)" != "$START" ]; then
      reason="exit $rc"
      [ "$rc" -eq 124 ] && reason="it hit the time limit"
      PROMPT="$BASE_PROMPT
$(continuation_note "$engine ($reason)")"
    fi
    if out_of_quota; then
      echo "agent_exec: $engine is out of quota or over a usage limit; not trying it again" >&2
      break
    fi
    try=$((try + 1))
    [ "$try" -gt "$RETRIES" ] && break
    echo "agent_exec: trying $engine again ($try of $RETRIES) in ${RETRY_DELAY}s" >&2
    sleep "$RETRY_DELAY"
  done
  next="${LIST[$((i + 1))]:-}"
  [ -n "$next" ] && echo "agent_exec: $engine failed (exit $rc); trying $next" >&2
done
if [ "$ran" = 1 ] && [ "$(tree_state)" = "$START" ]; then
  echo "agent_exec: no engine could work (each failed without changing anything); exit 75: try again later" >&2
  exit 75
fi
exit "$rc"
