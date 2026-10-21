#!/usr/bin/env bash
# ==============================================================================
# bin/check_ai_engines.sh - Autonomous AI engine and judge preflight
# ==============================================================================
# Verifies the deterministic toolchain (git, openspec, ruby), that the services
# each child repository requires answer (requires: of its repo.config.yaml), that
# each agent engine the application selected (config/agents.yaml; without it,
# every supported engine that is installed) authenticates and answers a live ping,
# that the installed kit matches its .openspec-kit.lock, and that the Jev judge
# passes its offline contract and a live known-answer canary.
# Exit 0 when the toolchain is complete, the kit has not drifted, every required
# service answers, the engine of every role (plan, build, cycle) works, the Jev
# question files are valid, and (only with JEV_REQUIRED=1) the judge is OK.
#   bash bin/check_ai_engines.sh --services   # the required services only (bin/visual_qa.sh begin)
set -o pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
export PATH="${OPENSPEC_PATH_PREFIX:-/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin}:$PATH"
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
# A cold start of an agent CLI can take a minute or more: a ping waits up to 3 minutes.
bounded() { if [ -n "$TIMEOUT_BIN" ]; then "$TIMEOUT_BIN" 180 "$@"; else "$@"; fi; }
within() { # <seconds> <command...>: exit 124 once it ran that long, its process group killed
  if [ -n "$TIMEOUT_BIN" ]; then "$TIMEOUT_BIN" "$@"; return; fi
  ruby -e '
    pid = Process.spawn(*ARGV.drop(1), pgroup: true)
    deadline = Time.now + ARGV[0].to_i
    until (done = Process.wait2(pid, Process::WNOHANG))
      if Time.now > deadline
        begin; Process.kill("KILL", -pid); rescue StandardError; end
        exit 124
      end
      sleep 0.1
    end
    exit(done[1].exitstatus || 1)' "$@"
}

# What the gates of each child repository need running (a database, a search engine):
# requires: of its repo.config.yaml, name => command, each run through its env_script
# and given 30 seconds. One that fails stops the cycle before it judges or dispatches,
# and the next cycle checks again: it heals once the service is back.
SERVICES_DOWN=""
check_services() {
  local cfg rel name cmd out any=0
  for cfg in repos/*/repo.config.yaml; do
    [ -f "$cfg" ] || continue
    rel="$(dirname "$cfg")"
    while IFS=$'\t' read -r name cmd; do
      [ -n "$name" ] || continue
      any=1
      if out="$(within 30 bash bin/repo_exec.sh "$ROOT/$rel" bash -c "$cmd" 2>&1)"; then
        echo "  $rel $name: OK"
      else
        echo "  $rel $name: DOWN ($cmd: $(printf '%s' "$out" | grep -v '^[[:space:]]*$' | tail -1 | cut -c1-160))"
        SERVICES_DOWN="$SERVICES_DOWN $rel:$name"
      fi
    done < <(ruby -ryaml -e '
      r = ((YAML.safe_load_file(ARGV[0]) rescue {}) || {})["requires"]
      r = r.each_with_index.to_h { |c, i| ["check-#{i + 1}", c] } if r.is_a?(Array)
      (r.is_a?(Hash) ? r : {}).each { |k, v| puts "#{k}\t#{v}" if v.is_a?(String) && !v.strip.empty? }' "$cfg")
  done
  [ "$any" -eq 1 ] || echo "  none required"
}
services_down_line() { echo "preflight: FAIL (a service a repository requires is down:$SERVICES_DOWN; start it, the next run checks again)"; }

if [ "${1:-}" = --services ]; then
  echo "== Services"; check_services
  if [ -n "$SERVICES_DOWN" ]; then services_down_line; exit 1; fi
  echo "preflight: OK (services)"; exit 0
fi
AUTH_ERRORS="Not logged in|authentication_error|Invalid API key|Please run /login|401 Unauthorized|No authentication information found|No models available|No API key for"

echo "== Toolchain ($(date -u +%Y-%m-%dT%H:%M:%SZ), $(uname -sm))"
MISSING=0
for tool in git openspec ruby; do
  if command -v "$tool" >/dev/null 2>&1; then
    echo "  $tool: $("$tool" --version 2>/dev/null | head -1)"
  else
    echo "  $tool: NOT FOUND"; MISSING=1
  fi
done

echo "== Kit"
# Kit files are replaced by upgrades and never edited in place: drift fails the preflight.
KIT_OK=1
ruby bin/openspec_kit.rb verify . 2>&1 | sed 's/^/  /'
[ "${PIPESTATUS[0]}" -eq 0 ] || KIT_OK=0

echo "== Services"
check_services

echo "== Agent engines"
# The agents config/agents.yaml selects, plus any engine an AGENT_ENGINE* override
# gives a role; without the file, every supported engine that is installed.
SELECTED="$(ruby bin/lib/agents.rb list 2>/dev/null)"
ROLES=""
for role in plan build cycle; do
  engine="$(ruby bin/lib/agents.rb engine "$role" 2>/dev/null)"   # claude,hermes: in order of preference
  ROLES="$ROLES $role:${engine:-first-available}"
  [ -n "$SELECTED" ] && [ -n "$engine" ] && SELECTED="$SELECTED ${engine//,/ }"
done
SELECTED=" $SELECTED "
WORKING=""
probe() { # <name> <command...>, with @EXTRA@ where agent_exec.sh puts the agent's extra_args
  local name="$1"; shift
  [ "$SELECTED" = "  " ] || [[ "$SELECTED" == *" $name "* ]] || return 0
  command -v "$name" >/dev/null 2>&1 || { echo "  $name: not installed"; return; }
  # The ping runs as the pipeline's calls do: with the application's extra_args (a model the
  # agent only answers with, for example), in the same place.
  local extra=() cmd=() arg
  while IFS= read -r -d '' arg; do extra+=("$arg"); done < <(ruby bin/lib/agents.rb extra-args "$name" 2>/dev/null)
  for arg in "$@"; do
    if [ "$arg" = @EXTRA@ ]; then cmd+=(${extra[@]+"${extra[@]}"}); else cmd+=("$arg"); fi
  done
  local out rc=0
  out="$(bounded "${cmd[@]}" 2>&1)" || rc=$?
  if printf '%s' "$out" | grep -qiE "$AUTH_ERRORS"; then
    echo "  $name: FAILED (authentication)"
  elif [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    # It answered with an error (a missing model, a spent budget): output alone is no proof.
    echo "  $name: FAILED (exit $rc: $(printf '%s' "$out" | sed $'s/\033\\[[0-9;]*m//g' | grep -v '^[[:space:]]*$' | tail -1 | cut -c1-160))"
  elif [ "$rc" -eq 0 ] && [ -n "$out" ]; then
    echo "  $name: OK"; WORKING="$WORKING $name"
  else
    echo "  $name: WARN (empty response or timeout)"
  fi
}
# A ping in a real workspace costs Claude Code about $0.07 (its context), so its cap is $0.50.
probe claude   claude -p "Reply with the single word: pong" --max-budget-usd 0.50 --no-session-persistence @EXTRA@
probe codex    codex exec @EXTRA@ "Reply with the single word: pong"
probe copilot  copilot -p "Reply with the single word: pong" --silent @EXTRA@
probe hermes   hermes -z "Reply with the single word: pong" @EXTRA@
probe opencode opencode run @EXTRA@ "Reply with the single word: pong"
probe agy      agy -p "Reply with the single word: pong" --print-timeout 170s @EXTRA@
probe kilo     kilo run --agent code @EXTRA@ "Reply with the single word: pong"
probe cline    cline --yolo @EXTRA@ "Reply with the single word: pong"
probe pi       pi -p --no-session @EXTRA@ -- "Reply with the single word: pong"
probe omp      omp -p --no-session @EXTRA@ "Reply with the single word: pong"
probe crush    crush run --quiet @EXTRA@ "Reply with the single word: pong"

# Every role must have a working engine among its list (stub: the kit's own tests).
# agent_exec.sh falls back along the list, so a dead fallback is only a warning.
ROLE_FAIL=""
for pair in $ROLES; do
  role="${pair%%:*}"; list="${pair#*:}"
  [ "$list" = first-available ] && continue
  ok=""; down=""
  for engine in ${list//,/ }; do
    if [ "$engine" = stub ] || [[ " $WORKING " == *" $engine "* ]]; then ok="${ok:-$engine}"; else down="$down $engine"; fi
  done
  if [ -z "$ok" ]; then ROLE_FAIL="$ROLE_FAIL $pair"
  elif [ -n "$down" ]; then echo "  $role: WARN runs on $ok; not working in its list:$down"
  fi
done
echo "  roles:$ROLES"
echo "  order: $(ruby bin/lib/agents.rb order 2>/dev/null)"

# Jev is a judge, not an agent engine: it answers typed questions with
# probabilities and never writes code, so it does not count toward WORKING.
echo "== Judge (jev)"
JUDGE=off   # ok | off | missing | invalid | auth | drift | unavailable
if [ "${JEV_DISABLED:-0}" = 1 ]; then
  echo "  jev: disabled (JEV_DISABLED=1)"
elif ! command -v jev >/dev/null 2>&1; then
  echo "  jev: not installed (brew install shaharia-lab/tap/jev)"; JUDGE=missing
elif [ ! -f config/templates/jev/canary.yaml ]; then
  echo "  jev: config/templates/jev/ not installed; skipped"
else
  JUDGE=ok
  JEV_MODEL="${JEV_MODEL:-$(ruby -ryaml -e 'puts((YAML.safe_load_file(ARGV[0]) || {})["model"] || "jev-latest")' config/jev_policy.yaml 2>/dev/null || echo jev-latest)}"
  echo "  jev: CLI $(jev version -o json 2>/dev/null | ruby -rjson -e 'puts JSON.parse(STDIN.read)["version"]' 2>/dev/null), model ${JEV_MODEL}"

  # 1. Offline and free: every question file must pass strict validation.
  for f in config/templates/jev/*.yaml; do
    if ! jev validate -f "$f" --strict -o json --quiet >/dev/null 2>&1; then
      echo "  jev: INVALID question file $f (see: jev validate -f $f --strict)"; JUDGE=invalid
    fi
  done

  # 2. Live canary: an obvious yes and an obvious no in one call (about $0.00002).
  if [ "$JUDGE" = ok ]; then
    OUT="$(bounded jev eval -f config/templates/jev/canary.yaml --model "$JEV_MODEL" -o json --quiet --no-input \
             --assert "all_gates_passed >= 0.8" --assert "reports_failure <= 0.2" 2>&1)"
    RC=$?
    SUMMARY="$(printf '%s' "$OUT" | ruby -rjson -e '
      begin
        d = JSON.parse(STDIN.read); a = d.fetch("answers", {})
        puts "yes=#{a.dig("all_gates_passed", "noul")} no=#{a.dig("reports_failure", "noul")} answered_by=#{d["model"]} #{d["latency_ms"]}ms"
      rescue StandardError
        puts "unparseable response"
      end' 2>/dev/null)"
    case "$RC" in
      0)        echo "  jev: OK (canary $SUMMARY)" ;;
      10)       echo "  jev: FAILED (canary answered wrong: $SUMMARY; enforce gates must not be trusted)"; JUDGE=drift ;;
      3)        echo "  jev: FAILED (authentication: run 'jev auth login' or export TYPESAFE_API_KEY)"; JUDGE=auth ;;
      5|6|124)  echo "  jev: UNAVAILABLE (rate limit, network or timeout; exit $RC)"; JUDGE=unavailable ;;
      *)        echo "  jev: ERROR (exit $RC: $(printf '%s' "$OUT" | tail -c 240))"; JUDGE=unavailable ;;
    esac
  fi
fi

echo "========================================================================"
if [ "$MISSING" -eq 1 ]; then echo "preflight: FAIL (toolchain incomplete)"; exit 1; fi
if [ "$KIT_OK" -eq 0 ]; then echo "preflight: FAIL (kit differs from .openspec-kit.lock: upgrade or reinstall it)"; exit 1; fi
if [ -n "$SERVICES_DOWN" ]; then services_down_line; exit 1; fi
if [ -z "$WORKING" ]; then echo "preflight: FAIL (no working AI engine)"; exit 1; fi
if [ -n "$ROLE_FAIL" ]; then echo "preflight: FAIL (no engine of a role is working:$ROLE_FAIL)"; exit 1; fi
if [ "$JUDGE" = invalid ]; then echo "preflight: FAIL (invalid Jev question files: a framework bug)"; exit 1; fi
if [ "${JEV_REQUIRED:-0}" = 1 ] && [ "$JUDGE" != ok ]; then
  echo "preflight: FAIL (JEV_REQUIRED=1 and the judge is ${JUDGE})"; exit 1
fi
echo "preflight: OK (engines:${WORKING}; roles:${ROLES}; judge: ${JUDGE})"
