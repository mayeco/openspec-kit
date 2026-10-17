#!/usr/bin/env bash
# ==============================================================================
# bin/run_gates.sh - Diff-aware, stack-agnostic quality gates
# ==============================================================================
# Usage:
#   bin/run_gates.sh                     # repos changed vs HEAD (uncommitted work)
#   bin/run_gates.sh --base origin/master   # repos changed vs a base ref (committed + uncommitted)
#   bin/run_gates.sh --all               # every child repo with a repo.config.yaml
#   bin/run_gates.sh --repo backend      # explicit repo (repeatable)
#
# Gates per repo come from repos/<name>/repo.config.yaml: lint, typecheck, test,
# build, then any extra keys (e.g. secrets) in file order. Empty or un-instantiated ({{...}}) commands
# are skipped with a warning. A repository's gates run through bin/repo_exec.sh,
# so its env_script (repo.config.yaml) prepares the toolchain first. The OpenSpec
# layer is validated whenever anything under openspec/ changed. Exit 0 = all
# executed gates passed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE=""
ALL=0
REPOS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --all) ALL=1 ;;
    --base) BASE="${2:?--base needs a ref}"; shift ;;
    --repo) REPOS+=("${2:?--repo needs a name}"); shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "run_gates: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done

cd "$ROOT"

child_paths() {
  [ -f .gitmodules ] || return 0
  git config -f .gitmodules --get-regexp '^submodule\..*\.path$' | awk '$2 ~ /^repos\// {print $2}'
}

changed_paths() {
  # Tracked changes (committed since BASE plus working tree), then untracked files.
  git diff --name-only "${BASE:-HEAD}" 2>/dev/null
  git status --porcelain=v1 -uall 2>/dev/null | cut -c4-
}

CHANGED="$(changed_paths | sort -u)"

if [ "$ALL" -eq 1 ]; then
  while IFS= read -r p; do [ -n "$p" ] && REPOS+=("$(basename "$p")"); done < <(child_paths)
elif [ "${#REPOS[@]}" -eq 0 ]; then
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    if printf '%s\n' "$CHANGED" | grep -qE "^${p}(/|$)"; then REPOS+=("$(basename "$p")"); fi
  done < <(child_paths)
fi

FAILED=()
PASSED=0

run_gate() { # <label> <dir> <command>
  local label="$1" dir="$2" cmd="$3" started rc
  started=$(date +%s)
  echo "---- [gate] ${label}: ${cmd}"
  if [ "$dir" = "$ROOT" ]; then
    (cd "$dir" && bash -c "$cmd")
  else
    bash "$ROOT/bin/repo_exec.sh" "$dir" bash -c "$cmd"
  fi
  rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "---- [pass] ${label} ($(( $(date +%s) - started ))s)"
    PASSED=$((PASSED + 1))
  else
    echo "---- [FAIL] ${label} (exit ${rc})"
    FAILED+=("$label")
  fi
}

# 1. OpenSpec layer: canonical specs plus every active change touched by the diff.
if [ "$ALL" -eq 1 ] || printf '%s\n' "$CHANGED" | grep -q '^openspec/'; then
  # Quiet on success; on failure print the validator's JSON so humans and repair rounds see why.
  run_gate "openspec:specs" "$ROOT" 'out="$(openspec validate --specs --strict --json 2>&1)" || { printf "%s\n" "$out"; exit 1; }'
  for change in $(printf '%s\n' "$CHANGED" | sed -nE 's#^openspec/changes/([^/]+)/.*#\1#p' | grep -v '^archive$' | sort -u); do
    [ -d "openspec/changes/${change}" ] && run_gate "openspec:${change}" "$ROOT" \
      "out=\"\$(openspec validate '${change}' --strict --json 2>&1)\" || { printf '%s\\n' \"\$out\"; exit 1; }"
  done
fi

# 2. Child repositories: only the ones the diff touched (or all with --all).
for name in $(printf '%s\n' "${REPOS[@]+"${REPOS[@]}"}" | sort -u); do
  dir="$ROOT/repos/$name"
  cfg="$dir/repo.config.yaml"
  if [ ! -f "$cfg" ]; then
    echo "---- [warn] repos/${name}: no repo.config.yaml, no gates defined"
    continue
  fi
  while IFS=$'\t' read -r gate cmd; do
    [ -z "$gate" ] && continue
    case "$cmd" in
      *'{{'*) echo "---- [warn] repos/${name}:${gate} not instantiated (${cmd}); skipped" ;;
      *) run_gate "${name}:${gate}" "$dir" "$cmd" ;;
    esac
  done < <(ruby -ryaml -e '
    cfg = YAML.safe_load_file(ARGV[0]) || {}
    gates = cfg.fetch("gates", {}) || {}
    standard = %w[lint typecheck test build]
    (standard + (gates.keys - standard)).each do |k|
      v = gates[k]
      puts "#{k}\t#{v}" if v.is_a?(String) && !v.strip.empty?
    end' "$cfg")
done

echo "========================================================================"
if [ "${#FAILED[@]}" -eq 0 ]; then
  echo "gates: PASS (${PASSED} executed; repos: ${REPOS[*]:-none})"
  exit 0
fi
echo "gates: FAIL (${FAILED[*]})"
exit 1
