#!/usr/bin/env bash
# ==============================================================================
# bin/sync_repos.sh - Bring the operator's main checkout up to date with origin
# ==============================================================================
# Usage: bin/sync_repos.sh [--publish]
#
# Default (pull-only, safe while the merger runs): fast-forward the umbrella,
# move clean detached child repos to the recorded pointers, fast-forward child
# repos that a human has on a branch. Never pushes.
#
# --publish (opt-in, human-driven workflow): additionally push child branches
# that are ahead of their upstream and record the new pointers in one umbrella
# commit. Refused while the dispatcher or merger is running, because they are
# the only writers of base branches in autonomous mode.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBLISH=0
[ "${1:-}" = "--publish" ] && PUBLISH=1
export GIT_TERMINAL_PROMPT=0 GIT_MERGE_AUTOEDIT=no
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=15}"

ATTENTION=""
PUBLISHED=""
flag() { ATTENTION="${ATTENTION:+$ATTENTION; }$1"; }

live_lock() { # <lockfile> -> prints the PID if a live process owns it
  local pid
  pid="$(sed -nE 's/.*pid=([0-9]+).*/\1/p' "$1" 2>/dev/null | head -1)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && echo "$pid"
}

if [ "$PUBLISH" -eq 1 ]; then
  for lock in "$ROOT/log/locks/dispatcher.lock" "$ROOT/log/locks/merger.lock"; do
    if pid="$(live_lock "$lock")"; then
      echo "Refused: $(basename "$lock") held by live PID ${pid}; --publish would race the autonomous writers."
      exit 0
    fi
  done
fi

echo "== Umbrella"
git -C "$ROOT" fetch --quiet origin 2>/dev/null || true
# The merger brings the backlog and history of the main checkout to exactly what it
# pushed (bin/openspec_merger.rb), and origin may have moved on since. A file that
# holds a version origin published after HEAD loses nothing when restored to HEAD,
# so the fast-forward below brings it in.
BACKLOG_FILES=(config/agent_backlog.json config/agent_history.json)
published_since_head() { # <file>: succeeds when it holds a version of it in HEAD..@{u}
  local blob c
  blob="$(git -C "$ROOT" hash-object -- "$1" 2>/dev/null)" || return 1
  for c in $(git -C "$ROOT" rev-list 'HEAD..@{u}' -- "$1" 2>/dev/null); do
    [ "$(git -C "$ROOT" rev-parse -q --verify "$c:$1" 2>/dev/null)" = "$blob" ] && return 0
  done
  return 1
}
if git -C "$ROOT" merge-base --is-ancestor HEAD '@{u}' 2>/dev/null &&
   [ -z "$(GIT_OPTIONAL_LOCKS=0 git -C "$ROOT" status --porcelain --ignore-submodules=all -- . "${BACKLOG_FILES[@]/#/:!}")" ]; then
  dirty=()
  for f in "${BACKLOG_FILES[@]}"; do
    [ -n "$(GIT_OPTIONAL_LOCKS=0 git -C "$ROOT" status --porcelain -- "$f")" ] || continue
    published_since_head "$f" || { dirty=(); break; }
    dirty+=("$f")
  done
  for f in "${dirty[@]+"${dirty[@]}"}"; do
    git -C "$ROOT" checkout -q HEAD -- "$f" 2>/dev/null || rm -f "$ROOT/$f"
  done
fi
if [ -n "$(GIT_OPTIONAL_LOCKS=0 git -C "$ROOT" status --porcelain --ignore-submodules=all)" ]; then
  echo "  root: local changes present; skipping pull"
  flag "root dirty"
else
  BRANCH="$(git -C "$ROOT" symbolic-ref -q --short HEAD || echo detached)"
  if git -C "$ROOT" fetch --quiet origin && git -C "$ROOT" merge --ff-only --quiet '@{u}' 2>/dev/null; then
    echo "  root: up to date with origin [${BRANCH}]"
  else
    echo "  root: cannot fast-forward [${BRANCH}]"
    flag "root diverged"
  fi
fi

sync_child() {
  local path="$1" dir="$ROOT/$1" branch ahead behind
  if [ -n "$(GIT_OPTIONAL_LOCKS=0 git -C "$dir" status --porcelain 2>/dev/null)" ]; then
    echo "  ${path}: SKIPPED (uncommitted changes)"; return
  fi
  branch="$(git -C "$dir" symbolic-ref -q --short HEAD || true)"
  if [ -z "$branch" ]; then
    # Detached is the normal submodule state: follow the umbrella's pointer.
    git -C "$ROOT" submodule update --init --quiet -- "$path" && echo "  ${path}: at recorded pointer" \
      || { echo "  ${path}: ATTENTION (submodule update failed)"; flag "${path} update failed"; }
    return
  fi
  if ! git -C "$dir" fetch --quiet origin 2>/dev/null || ! git -C "$dir" rev-parse -q --verify '@{u}' >/dev/null; then
    echo "  ${path}: ATTENTION (fetch failed or no upstream for ${branch})"; flag "${path} no upstream"; return
  fi
  ahead="$(git -C "$dir" rev-list --count '@{u}..HEAD')"
  behind="$(git -C "$dir" rev-list --count 'HEAD..@{u}')"
  if [ "$behind" -gt 0 ] && [ "$ahead" -eq 0 ]; then
    git -C "$dir" merge --ff-only --quiet '@{u}' && echo "  ${path}: pulled ${behind} commit(s)"
  elif [ "$behind" -gt 0 ]; then
    echo "  ${path}: ATTENTION (diverged: ${ahead} ahead, ${behind} behind)"; flag "${path} diverged"; return
  fi
  if [ "$ahead" -gt 0 ]; then
    if [ "$PUBLISH" -eq 1 ] && git -C "$dir" push --quiet origin "HEAD:${branch}"; then
      echo "  ${path}: pushed ${ahead} commit(s)"; PUBLISHED="$PUBLISHED $path"
    else
      echo "  ${path}: ${ahead} unpushed commit(s) on ${branch}"; flag "${path} unpushed"
    fi
  else
    echo "  ${path}: up to date [${branch}]"
  fi
}

echo "== Child repositories"
while IFS= read -r path; do
  [ -n "$path" ] && sync_child "$path"
done < <(git -C "$ROOT" config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null | awk '$2 ~ /^repos\// {print $2}')

if [ "$PUBLISH" -eq 1 ] && [ -n "$PUBLISHED" ]; then
  # shellcheck disable=SC2086
  git -C "$ROOT" add $PUBLISHED && git -C "$ROOT" commit --quiet -m "chore(repos): update pointers for${PUBLISHED}" \
    && git -C "$ROOT" push --quiet origin HEAD && echo "  root: recorded pointers for${PUBLISHED}" \
    || flag "root pointer push failed"
fi

echo "========================================================================"
if [ -z "$ATTENTION" ]; then echo "result: ok"; else echo "result: attention (${ATTENTION})"; fi
