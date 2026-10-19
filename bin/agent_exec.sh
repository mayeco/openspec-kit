#!/usr/bin/env bash
# ==============================================================================
# bin/agent_exec.sh - Engine-agnostic headless agent adapter
# ==============================================================================
# Usage: bin/agent_exec.sh <workdir> <prompt-file> [engine[,engine...]]
#
# Engines: claude, codex, copilot, hermes, opencode, agy (Antigravity), kilo, cline, pi, omp (oh-my-pi),
# crush, and stub for the kit's tests.
# Callers pass the engines of their role from config/agents.yaml (bin/lib/agents.rb),
# in order; without them it is $AGENT_ENGINE, then the first engine found on PATH.
# Retries and fallback: an engine that fails (any exit code but 0: out of quota, not
# logged in, timed out) is tried again limits.agent_retries times
# (config/pipeline.yaml), then the next engine runs; one that is not installed is
# skipped at once, and so is one that says it is out of quota or over a usage limit,
# which a short wait does not lift. An attempt that left changes in the work directory
# is followed by one told, in its prompt, who stopped and what is there, to continue
# from that state. Where a call starts is `order` in config/agents.yaml (or $AGENT_ORDER):
# fallback with the first engine of the list; random with any of them; spread with one
# of those the fewest running calls use (bin/lib/agents.rb arrange). Then the others in
# the order listed. Each call registers the engine it runs in log/agents_in_use/ until
# it ends, so calls that run at once can avoid sharing an agent.
# The caller verifies the result as always. Every
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
IDLE_LIMIT="$(ruby "$SETTINGS" get limits.agent_idle_seconds)"   # 0: no watchdog
PERMISSIONS="$(ruby "$(dirname "$0")/lib/agents.rb" permissions)"
AGENTS_RB="$(cd "$(dirname "$0")" && pwd)/lib/agents.rb"   # absolute: this script cds into the work directory
ORDER="$(ruby "$AGENTS_RB" order)"   # fallback | random | spread

ENGINES="${3:-${AGENT_ENGINE:-}}"
if [ -z "$ENGINES" ]; then
  for candidate in claude codex copilot hermes opencode agy kilo cline pi omp crush; do
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
  WATCH_PID=""
  if [ "$IDLE_LIMIT" -gt 0 ]; then
    watch_idle "$TIMEOUT_PID" &
    WATCH_PID=$!
  fi
  local rc=0
  # A trapped signal makes wait return early (status > 128): keep waiting until timeout exits.
  while :; do
    wait "$TIMEOUT_PID" && rc=0 || rc=$?
    kill -0 "$TIMEOUT_PID" 2>/dev/null || break
  done
  stop_watch
  trap - INT TERM # a signal during a retry's wait stops this script
  return "$rc"
}

# The idle watchdog: an engine whose process tree uses no CPU, whose work directory does
# not change and whose output does not grow for limits.agent_idle_seconds has stalled,
# like a CLI that froze on a rate limit instead of exiting. It is stopped (TERM to timeout,
# which passes it on) and IDLE_MARK says so. CPU counts over the whole quiet stretch, so an
# engine that waits on its model while it streams stays alive.
watch_idle() { # <timeout pid>
  local pid="$1" every since=0 cpu0 cpu state0 state
  every=$(( IDLE_LIMIT / 4 )); [ "$every" -lt 1 ] && every=1; [ "$every" -gt 60 ] && every=60
  cpu0="$(tree_cpu "$pid")"; state0="$(activity_state)"
  while kill -0 "$pid" 2>/dev/null; do
    sleep "$every"
    cpu="$(tree_cpu "$pid")"; state="$(activity_state)"
    if [ $(( cpu - cpu0 )) -ge 1 ] || [ "$state" != "$state0" ]; then
      since=0; cpu0="$cpu"; state0="$state"
    else
      since=$(( since + every ))
    fi
    if [ "$since" -ge "$IDLE_LIMIT" ]; then
      echo "$since" > "$IDLE_MARK"
      kill -TERM "$pid" 2>/dev/null
      return 0
    fi
  done
}

stop_watch() {
  [ -n "${WATCH_PID:-}" ] || return 0
  kill "$WATCH_PID" 2>/dev/null; wait "$WATCH_PID" 2>/dev/null || true
  WATCH_PID=""
}

# Whole CPU seconds used so far by a process and all its descendants (ps prints M:SS.ss,
# H:MM:SS or D-HH:MM:SS, depending on the system). Where ps can (-S), each process also
# carries the CPU of its children that already exited: a build or a test run made of many
# short processes counts.
PS_SUM=""
ps -S -o time= -p $$ >/dev/null 2>&1 && PS_SUM="-S"
tree_cpu() { # <pid>
  local all="$1" frontier="$1" next p
  while [ -n "$frontier" ]; do
    next=""
    for p in $frontier; do next="$next $({ pgrep -P "$p" 2>/dev/null || true; } | tr '\n' ' ')"; done
    next="$(echo $next)"
    all="$all $next"; frontier="$next"
  done
  { ps $PS_SUM -o time= -p "$(echo $all | tr ' ' ',')" 2>/dev/null || true; } | awk '
    { t = $1; d = 0; if (index(t, "-")) { split(t, a, "-"); d = a[1]; t = a[2] }
      n = split(t, f, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + f[i]; total += d * 86400 + s }
    END { printf "%d\n", total }'
}

# What an engine changes while it works: the work directory, including the content of
# untracked files (a new file it keeps writing), and the size of its own output.
activity_state() {
  { tree_state
    { git ls-files --others --exclude-standard | git hash-object --stdin-paths; } 2>/dev/null || true
    git submodule foreach --quiet --recursive 'git ls-files --others --exclude-standard | git hash-object --stdin-paths' 2>/dev/null || true
    wc -c < "$ATTEMPT_OUT" 2>/dev/null || true
  } | cksum
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
QUOTA_PATTERN='hit your [a-z ]*limit|usage limit|session limit|weekly limit|out of credits|credit balance is too low|insufficient_quota|quota exceeded|exceeded your current quota|reached your [a-z ]*(quota|limit)|insufficient (balance|credits)'
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
  local ENGINE="$1" arg
  if [ "$ENGINE" != stub ] && ! command -v "$ENGINE" >/dev/null 2>&1; then
    echo "agent_exec: $ENGINE is not installed" >&2
    return 127
  fi
  # extra_args of config/agents.yaml: the application's own arguments for this agent (a
  # model, a provider), placed before the prompt. ${EXTRA[@]+...} keeps an empty list
  # harmless under set -u in bash 3.2.
  EXTRA=()
  while IFS= read -r -d '' arg; do EXTRA+=("$arg"); done < <(ruby "$AGENTS_RB" extra-args "$ENGINE" 2>/dev/null)
  [ "${#EXTRA[@]}" -eq 0 ] || echo "agent_exec: $ENGINE extra_args: ${EXTRA[*]}" >&2
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
        --no-session-persistence ${EXTRA[@]+"${EXTRA[@]}"}
      ;;
    hermes)
      # --yolo disables approval prompts: run inside a sandbox/container only.
      bounded hermes -z "$PROMPT" --yolo --accept-hooks ${EXTRA[@]+"${EXTRA[@]}"}
      ;;
    opencode)
      bounded opencode run --format json ${EXTRA[@]+"${EXTRA[@]}"} "$PROMPT"
      ;;
    codex)
      if [ "$PERMISSIONS" = restricted ]; then
        bounded codex exec --full-auto ${EXTRA[@]+"${EXTRA[@]}"} "$PROMPT"
      else
        bounded codex exec --dangerously-bypass-approvals-and-sandbox ${EXTRA[@]+"${EXTRA[@]}"} "$PROMPT"
      fi
      ;;
    agy)
      # Google Antigravity's CLI. Its print mode gives up after --print-timeout (5 minutes by
      # default): it gets the kit's limit, which bounded enforces anyway. restricted runs its
      # terminal in Antigravity's sandbox, approving inside it, as Codex's --full-auto does.
      SANDBOX=""
      [ "$PERMISSIONS" = restricted ] && SANDBOX=--sandbox
      bounded agy -p "$PROMPT" --print-timeout "${LIMIT}s" --dangerously-skip-permissions ${SANDBOX:+"$SANDBOX"} ${EXTRA[@]+"${EXTRA[@]}"}
      ;;
    kilo)
      # Kilo Code's CLI. run is headless; its code agent edits (the default one, ask, does
      # not). all approves every tool its rules do not deny (--auto); restricted leaves
      # Kilo's own permission rules in charge.
      if [ "$PERMISSIONS" = restricted ]; then
        bounded kilo run --agent code ${EXTRA[@]+"${EXTRA[@]}"} "$PROMPT"
      else
        bounded kilo run --agent code --auto ${EXTRA[@]+"${EXTRA[@]}"} "$PROMPT"
      fi
      ;;
    cline)
      # Cline's CLI. A prompt runs one headless turn in act mode and exits; --yolo approves
      # every tool, ends the run when the turn finishes and leaves out the spawn and team
      # tools. Cline has no sandbox and no allowlist, so restricted changes nothing for it.
      bounded cline --yolo --cwd "$PWD" ${EXTRA[@]+"${EXTRA[@]}"} "$PROMPT"
      ;;
    pi)
      # pi, the coding agent. -p runs headless and exits nonzero when the turn ends in an error;
      # pi never asks before a tool. --no-session keeps no session file. A headless run cannot
      # be asked to trust the project, so all trusts it (--approve), loading the skills of
      # .pi/skills and .agents/skills; restricted loads none of the project's extensions,
      # settings or skills (--no-approve). Its tools keep the process's permissions either way.
      if [ "$PERMISSIONS" = restricted ]; then
        bounded pi -p --no-session --no-approve ${EXTRA[@]+"${EXTRA[@]}"} -- "$PROMPT"
      else
        bounded pi -p --no-session --approve ${EXTRA[@]+"${EXTRA[@]}"} -- "$PROMPT"
      fi
      ;;
    omp)
      # oh-my-pi, a fork of pi. -p runs headless; a tool that needs an approval nobody can give
      # fails. all approves every tool (--approval-mode=yolo); restricted leaves omp's own
      # tools.approvalMode and per-tool policies in charge (omp config).
      if [ "$PERMISSIONS" = restricted ]; then
        bounded omp -p --no-session ${EXTRA[@]+"${EXTRA[@]}"} "$PROMPT"
      else
        bounded omp -p --no-session --approval-mode=yolo ${EXTRA[@]+"${EXTRA[@]}"} "$PROMPT"
      fi
      ;;
    crush)
      # Charm's Crush. run is headless and approves every permission request of its own
      # session, so restricted changes nothing for it (disabled_tools and hooks in its
      # crush.json are the way to restrict it). It reads piped stdin into the prompt: give
      # it none, so it never waits on an open pipe.
      bounded crush run --quiet ${EXTRA[@]+"${EXTRA[@]}"} "$PROMPT" </dev/null
      ;;
    copilot)
      DENY=()
      IFS=',' read -ra RULES <<< "$COPILOT_DENIED"
      for rule in "${RULES[@]}"; do DENY+=(--deny-tool "$rule"); done
      bounded copilot -p "$PROMPT" --silent --allow-all-tools "${DENY[@]}" ${EXTRA[@]+"${EXTRA[@]}"}
      ;;
    stub)
      # Deterministic fake agent for the orchestrator's own tests.
      bounded bash "${AGENT_STUB:?AGENT_STUB must point to a stub script}" "$RUN_PROMPT_FILE" ${EXTRA[@]+"${EXTRA[@]}"}
      ;;
    *)
      echo "agent_exec: unknown engine ${ENGINE:-none} (set AGENT_ENGINE)" >&2
      return 127
      ;;
  esac
}

cd "$WORKDIR"
[ -n "$ENGINES" ] || { echo "agent_exec: no AI engine available (set AGENT_ENGINE)" >&2; exit 127; }
RETRIES="$(ruby "$SETTINGS" get limits.agent_retries)"
RETRY_DELAY="$(ruby "$SETTINGS" get limits.agent_retry_delay_seconds)"
BASE_PROMPT="$PROMPT"
RUN_PROMPT_FILE="$(mktemp "${TMPDIR:-/tmp}/agent-prompt.XXXXXX")" # the stub reads its prompt from a file
ATTEMPT_OUT="$(mktemp "${TMPDIR:-/tmp}/agent-out.XXXXXX")" # one attempt's output, read for a usage limit
IDLE_MARK="$(mktemp "${TMPDIR:-/tmp}/agent-idle.XXXXXX")" # non-empty once the watchdog stopped an engine
trap 'stop_watch; rm -f "$RUN_PROMPT_FILE" "$ATTEMPT_OUT" "$IDLE_MARK"; ruby "$AGENTS_RB" release $$ 2>/dev/null' EXIT
# The engines in the order this call tries them; the first is registered as run by this call.
ARRANGED="$(ruby "$AGENTS_RB" arrange "$ENGINES" $$)" || ARRANGED="$ENGINES"
IFS=',' read -ra LIST <<< "$ARRANGED"
[ "$ORDER" = fallback ] || [ "${#LIST[@]}" -lt 2 ] || echo "agent_exec: order $ORDER: $ARRANGED" >&2
START="$(tree_state)"
rc=127
ran=0
for i in "${!LIST[@]}"; do
  engine="$(printf '%s' "${LIST[$i]}" | tr -d '[:space:]')"
  [ -n "$engine" ] || continue
  [ "$i" -eq 0 ] || ruby "$AGENTS_RB" claim "$engine" $$ 2>/dev/null || true # the fallback runs now
  try=0
  while :; do
    printf '%s' "$PROMPT" > "$RUN_PROMPT_FILE"
    rc=0
    : > "$IDLE_MARK"
    run_engine "$engine" > "$ATTEMPT_OUT" 2>&1 || rc=$?
    cat "$ATTEMPT_OUT"
    if [ -s "$IDLE_MARK" ]; then
      echo "agent_exec: $engine stalled: no CPU, no change in the work directory and no output for $(cat "$IDLE_MARK")s; stopped it" >&2
      [ "$rc" -eq 0 ] && rc=124 # whatever it printed on its way out, the attempt did not finish
    fi
    # Parsed by the dispatcher for its agent.exit event.
    echo "agent_exec: engine $engine exited $rc" >&2
    [ "$rc" -eq 0 ] && exit 0
    [ "$rc" -eq 127 ] && break # not installed or unknown: no point trying it again
    ran=1
    if [ "$(tree_state)" != "$START" ]; then
      reason="exit $rc"
      [ "$rc" -eq 124 ] && reason="it hit the time limit"
      [ -s "$IDLE_MARK" ] && reason="it stalled, doing nothing for $(cat "$IDLE_MARK")s"
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
