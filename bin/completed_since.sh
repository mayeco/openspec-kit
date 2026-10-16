#!/usr/bin/env bash
# ==============================================================================
# bin/completed_since.sh - What was integrated since a given umbrella commit
# ==============================================================================
# Usage: bin/completed_since.sh <BASE_SHA> [<HEAD_REF>]
# Lists integrated changes (by commit trailer), child-repo commits behind each
# pointer move, completed tasks and the lessons workers left in handoff.md.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="${1:?usage: completed_since.sh <BASE_SHA> [HEAD_REF]}"
HEAD_REF="${2:-HEAD}"

echo "== Integrated changes"
git -C "$ROOT" log --grep='^OpenSpec-Change: ' \
  --format='  %h %(trailers:key=OpenSpec-Change,valueonly,separator=%x2C) (%ar)' "${BASE}..${HEAD_REF}"

echo "== Child repository commits"
git -C "$ROOT" config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null | awk '$2 ~ /^repos\// {print $2}' | while read -r p; do
  old="$(git -C "$ROOT" rev-parse -q --verify "${BASE}:${p}" 2>/dev/null)"
  new="$(git -C "$ROOT" rev-parse -q --verify "${HEAD_REF}:${p}" 2>/dev/null)"
  [ -n "$old" ] && [ -n "$new" ] && [ "$old" != "$new" ] || continue
  echo "  ${p}:"
  git -C "$ROOT/$p" log --format='    %h %s' "${old}..${new}" 2>/dev/null || echo "    (fetch ${p} to list ${old:0:8}..${new:0:8})"
done

echo "== Archived changes, completed tasks and handoff lessons"
git -C "$ROOT" diff --name-only --diff-filter=A "${BASE}" "${HEAD_REF}" -- 'openspec/changes/archive/*/tasks.md' | while read -r f; do
  dir="$(dirname "$f")"
  echo "  $(basename "$dir"): $(git -C "$ROOT" show "${HEAD_REF}:${f}" | grep -cE '^- \[[xX]\]') task(s) complete"
  git -C "$ROOT" show "${HEAD_REF}:${dir}/handoff.md" 2>/dev/null | sed 's/^/    lesson: /'
done
