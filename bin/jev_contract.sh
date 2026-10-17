#!/usr/bin/env bash
# ==============================================================================
# bin/jev_contract.sh - Contract and calibration check for the Jev judgment layer
# ==============================================================================
# Usage: bin/jev_contract.sh [--live]
#
# Offline (default; free, needs no key):
#   - every config/templates/jev/*.yaml passes `jev validate --strict`;
#   - every gate's asserts dry-run against its question file (jev rejects a
#     condition that names a missing question, exit 2);
#   - every routing rule names an existing question and option;
#   - the policy pins a versioned model id.
# --live (about 15 API calls, well under $0.001):
#   - the key is accepted and the pinned model answers;
#   - the canary: an obvious yes passes (exit 0), an obvious no fails (exit 10);
#   - each gate's known-good and known-bad fixture lands on the right side of
#     the policy. A right answer below the routing confidence is a WARN: the
#     rule would not fire, so tune the threshold or the question.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
LIVE=0; [ "${1:-}" = "--live" ] && LIVE=1
FIX=config/templates/jev/fixtures
# An application's policy; the kit's own source tree keeps it as a seed.
POLICY=config/jev_policy.yaml
[ -f "$POLICY" ] || POLICY=seeds/config/jev_policy.yaml
FAILURES=0

check() { if "${@:2}" >/dev/null 2>&1; then echo "  PASS  $1"; else echo "  FAIL  $1"; FAILURES=$((FAILURES + 1)); fi; }
policy_get() { ruby -ryaml -rjson -e 'v = YAML.safe_load_file(ARGV[0]).dig(*ARGV[1..]); puts(v.is_a?(String) ? v : JSON.generate(v))' "$POLICY" "$@"; }
MODEL="$(policy_get model)"

# Builds "--assert <cond>" pairs for a gate (bash 3.2 compatible: no mapfile).
assert_args() {
  ASSERT_ARGS=()
  while IFS= read -r cond; do [ -n "$cond" ] && ASSERT_ARGS+=(--assert "$cond"); done \
    < <(ruby -ryaml -e 'puts Array(YAML.safe_load_file(ARGV[0]).dig("gates", ARGV[1], "assert"))' "$POLICY" "$1")
}
ask() { # <question-file> <state-file> [extra args...] -> JSON on stdout; exit code is jev's
  local file="$1" state="$2"; shift 2
  jev eval -f "$file" --state-file "$state" --model "$MODEL" -o json --quiet --no-input "$@"
}
field() { ruby -rjson -e 'd = JSON.parse(STDIN.read); puts d.dig(*ARGV)' "$@"; }

echo "== Offline contract"
check "jev is installed" command -v jev
for f in config/templates/jev/*.yaml; do
  check "$(basename "$f") passes jev validate --strict" jev validate -f "$f" --strict -o json --quiet
done
check "policy pins a versioned model ($MODEL)" bash -c "[[ '$MODEL' =~ ^jev-[0-9]+\.[0-9]+\.[0-9]+$ ]]"
for gate in plan_review failure_triage repair_progress scenario_coverage change_risk proposal_review; do
  file="$(policy_get gates "$gate" file)"
  fixture="$(ls "$FIX/$gate".*.json | head -1)"
  assert_args "$gate"
  check "$gate: asserts and state dry-run against $file" \
    jev eval -f "$file" --state-file "$fixture" --dry-run -o json --quiet ${ASSERT_ARGS[@]+"${ASSERT_ARGS[@]}"}
done
check "routing rules name existing questions and options" ruby -ryaml -e '
  policy = YAML.safe_load_file(ARGV[0])
  ok = policy["gates"].all? do |_, gate|
    questions = YAML.safe_load_file(gate["file"])["questions"]
    rules = [gate["rerun_when"], gate["escalate_when"], *Array(gate["block_when"])].compact
    rules.all? do |r|
      q = questions[r["question"]]
      q && (r["choice"] ? q["type"] == "choice" && q["criteria"].key?(r["choice"]) : q["type"] == "noul")
    end
  end
  exit(ok ? 0 : 1)' "$POLICY"

if [ "$LIVE" -eq 1 ]; then
  echo "== Live calibration (model $MODEL)"
  check "API accepts the key" bash -c 'jev auth status -o json --quiet | grep -q "\"ok\": true"'

  CANARY=(--assert "all_gates_passed >= 0.8" --assert "reports_failure <= 0.2")
  # The canary carries its own passing gate log as `state`.
  OUT="$(jev eval -f config/templates/jev/canary.yaml --model "$MODEL" -o json --quiet --no-input "${CANARY[@]}" 2>/dev/null)"; RC=$?
  check "canary: obvious yes passes (exit $RC, model $(printf '%s' "$OUT" | field model))" test "$RC" -eq 0
  check "canary: answered by the pinned model" test "$(printf '%s' "$OUT" | field model)" = "$MODEL"
  ask config/templates/jev/canary.yaml "$FIX/canary.failing.log" "${CANARY[@]}" >/dev/null 2>&1; RC=$?
  check "canary: obvious no fails the gate (exit $RC, expected 10)" test "$RC" -eq 10

  assert_args plan_review
  ask config/templates/jev/plan_review.yaml "$FIX/plan_review.good.json" "${ASSERT_ARGS[@]}" > /tmp/jev_good.$$ 2>&1; RC=$?
  check "plan_review: good plan passes (exit $RC)" test "$RC" -eq 0
  [ "$RC" -ne 0 ] && field gate conditions < /tmp/jev_good.$$ 2>/dev/null | sed 's/^/          /'
  ask config/templates/jev/plan_review.yaml "$FIX/plan_review.bad.json" "${ASSERT_ARGS[@]}" > /tmp/jev_bad.$$ 2>&1; RC=$?
  check "plan_review: vague, bundled plan fails (exit $RC)" test "$RC" -eq 10
  rm -f /tmp/jev_good.$$ /tmp/jev_bad.$$

  triage() { # <fixture> <expected choice> <rule name for the confidence threshold or "">
    local out choice conf min
    out="$(ask config/templates/jev/failure_triage.yaml "$FIX/failure_triage.$1.json" 2>/dev/null)"
    choice="$(printf '%s' "$out" | field answers cause choice)"
    conf="$(printf '%s' "$out" | field answers cause confidence)"
    check "failure_triage: $1 log classified as $2 (got $choice @ $conf)" test "$choice" = "$2"
    if [ -n "$3" ]; then
      min="$(policy_get gates failure_triage "$3" min_confidence)"
      ruby -e 'exit(ARGV[0].to_f >= ARGV[1].to_f ? 0 : 1)' "${conf:-0}" "$min" \
        || echo "  WARN  confidence $conf is below $3.min_confidence $min: the rule would not fire"
    fi
  }
  triage flaky environment_or_flaky rerun_when
  triage defect implementation_defect ""

  risk() { # <fixture> <expect block: yes|no>
    local out fired
    out="$(ask config/templates/jev/change_risk.yaml "$FIX/change_risk.$1.json" 2>/dev/null)"
    fired="$(printf '%s' "$out" | ruby -ryaml -rjson -e '
      answers = JSON.parse(STDIN.read)["answers"]
      rules = YAML.safe_load_file(ARGV[0]).dig("gates", "change_risk", "block_when")
      hit = rules.select do |r|
        a = answers[r["question"]] or next false
        r["choice"] ? a["choice"] == r["choice"] && a["confidence"] >= r["min_confidence"].to_f : a["noul"] >= r["min"].to_f
      end
      summary = answers.map { |k, a| a["type"] == "choice" ? "#{k}=#{a["choice"]}@#{a["confidence"]}" : "#{k}=#{a["noul"]}" }
      puts "#{hit.empty? ? "no" : "yes"} (#{summary.join(", ")})"' "$POLICY")"
    check "change_risk: $1-risk fixture blocks=$2 (got $fired)" test "${fired%% *}" = "$2"
  }
  risk low no
  risk high yes

  assert_args proposal_review
  ask config/templates/jev/proposal_review.yaml "$FIX/proposal_review.good.json" "${ASSERT_ARGS[@]}" > /tmp/jev_prop.$$ 2>&1; RC=$?
  check "proposal_review: scoped roadmap feature is approved (exit $RC)" test "$RC" -eq 0
  [ "$RC" -ne 0 ] && field gate conditions < /tmp/jev_prop.$$ 2>/dev/null | sed 's/^/          /'
  ask config/templates/jev/proposal_review.yaml "$FIX/proposal_review.bad.json" "${ASSERT_ARGS[@]}" >/dev/null 2>&1; RC=$?
  check "proposal_review: bundled, risky proposal waits for a human (exit $RC)" test "$RC" -eq 10
  rm -f /tmp/jev_prop.$$

  passes_and_fails() { # <gate> <good fixture> <bad fixture> <what passes> <what fails>
    local out
    assert_args "$1"
    out="$(ask "config/templates/jev/$1.yaml" "$FIX/$1.$2.json" "${ASSERT_ARGS[@]}" 2>&1)"; RC=$?
    check "$1: $4 (exit $RC)" test "$RC" -eq 0
    [ "$RC" -ne 0 ] && printf '%s' "$out" | field gate conditions 2>/dev/null | sed 's/^/          /'
    ask "config/templates/jev/$1.yaml" "$FIX/$1.$3.json" "${ASSERT_ARGS[@]}" >/dev/null 2>&1; RC=$?
    check "$1: $5 (exit $RC)" test "$RC" -eq 10
  }
  passes_and_fails scenario_coverage good bad "tests asserting every scenario pass" "a scenario without a real test goes back for repair"
  passes_and_fails repair_progress converging stalled "narrower failures spend another round" "the same failures again stop the repairs"
fi

echo "========================================================================"
if [ "$FAILURES" -eq 0 ]; then echo "jev contract: PASS"; else echo "jev contract: FAIL ($FAILURES)"; fi
exit "$FAILURES"
