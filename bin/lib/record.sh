# shellcheck shell=bash
# ==============================================================================
# bin/lib/record.sh - What an agent session may write, how it is recorded, locks
# ==============================================================================
# Sourced by bin/run_cycle.sh (the headless judgment, in .worktrees/_cycle) and
# bin/visual_qa.sh (the visual QA session of an agent app, which writes its
# findings in the main checkout and records them from .worktrees/_visual_qa).
# The caller sets ROOT, LOG_DIR and BASE.

# The versioned paths an agent session may write: the memory (MEMORY.md, and
# memory/ for lessons of one repository or capability), the backlog, its history
# of integrated items, and the proposals. log/cycle/ and log/PAUSE are
# git-ignored; everything else belongs to the merger or to humans.
SCOPE=(MEMORY.md memory config/agent_backlog.json config/agent_history.json config/agent_proposals.json)
# What the record step commits: that scope, and the agents' prompts, which
# bin/proposals.rb edits after the scope guard when a prompt proposal is approved.
# The scope guard runs first, so an agent's own edit of a prompt is never recorded.
RECORDED=("${SCOPE[@]}" config/prompts)

# Serializes checkout sync and record commits between the cycle and the visual
# session. A lock whose owner died is taken over; one with no pid yet is being
# taken, so it is stale only once it stays without one. Past 30 minutes
# (OPENSPEC_RECORD_LOCK_SECONDS, for one manual run) behind a live owner the
# command does not run, rather than run unlocked.
with_record_lock() { # <command...>
  local lock="$LOG_DIR/record.lock" pid waited=0 nopid=0 rc limit="${OPENSPEC_RECORD_LOCK_SECONDS:-1800}"
  mkdir -p "$LOG_DIR"
  until mkdir "$lock" 2>/dev/null; do
    pid="$(cat "$lock/pid" 2>/dev/null || true)"
    if [ -z "$pid" ]; then nopid=$((nopid + 1)); else nopid=0; fi
    if [ "$nopid" -ge 3 ] || { [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; }; then
      rm -rf "$lock"; nopid=0; continue
    fi
    waited=$((waited + 1))
    if [ "$waited" -ge "$limit" ]; then echo "record lock: held by pid ${pid:-unknown} for ${limit}s; not running $1" >&2; return 1; fi
    sleep 1
  done
  echo "$$" > "$lock/pid"
  "$@"
  rc=$?
  rm -rf "$lock"
  return "$rc"
}

# Fails, and pauses the system for a human, when the session wrote anything else.
scope_guard() { # <who>
  local outside
  outside="$(git status --porcelain --ignore-submodules=all -- . "${SCOPE[@]/#/:!}")"
  [ -z "$outside" ] && return 0
  echo "$1: the agent wrote outside its scope; nothing recorded, pausing for a human:"
  echo "$outside"
  echo "scope violation in $1" > "$LOG_DIR/PAUSE"
  return 1
}

# Keeps a commit under refs/openspec/unpublished/<worktree>-<stamp>-<commit>, where
# no reset of the worktree can reach it, and says so.
keep_unpublished() { # <dir> <commit> <why>
  local keep
  keep="refs/openspec/unpublished/$(basename "$1")-$(date -u +%Y%m%dT%H%M%SZ)-$(git -C "$1" rev-parse --short "$2")"
  git -C "$1" update-ref "$keep" "$2" && echo "$3; kept as $keep"
}

# Commits the recorded paths that changed and publishes them on the base branch.
# Fails when the commit could not be published: it stays in the worktree, and the
# next prepare_session_worktree there publishes it before anything is reset. A
# commit git refuses (an index.lock a git that died left behind) is built through
# a temporary index instead and kept under refs/openspec/unpublished/.
record() { # <commit message>
  [ -n "$(git status --porcelain -- "${RECORDED[@]}")" ] || { echo "record: nothing to record"; return 0; }
  # git add aborts on a pathspec that matches nothing: stage existing or tracked paths only.
  local stage=() p attempt pushed=1 index tree commit
  for p in "${RECORDED[@]}"; do
    if [ -e "$p" ] || git ls-files --error-unmatch -- "$p" >/dev/null 2>&1; then stage+=("$p"); fi
  done
  if ! { git add -A -- "${stage[@]}" && git commit --quiet -m "$1"; }; then
    index="$(mktemp -d)"
    GIT_INDEX_FILE="$index/index" git read-tree HEAD && GIT_INDEX_FILE="$index/index" git add -A -- "${stage[@]}" &&
      tree="$(GIT_INDEX_FILE="$index/index" git write-tree)" && commit="$(git commit-tree "$tree" -p HEAD -m "$1")" &&
      keep_unpublished "$(pwd)" "$commit" "record: git refused the commit"
    rm -rf "$index"
    return 1
  fi
  for attempt in 1 2 3; do
    # The merger or the other session may have pushed meanwhile; reconcile on rebase.
    git push --quiet origin "HEAD:$BASE" && { pushed=0; break; }
    ruby bin/proposals.rb rebase "$BASE" && git push --quiet origin "HEAD:$BASE" && { pushed=0; break; }
    sleep $((attempt * 5))
  done
  git submodule update --init --quiet
  [ "$pushed" -eq 0 ] || echo "record: not published; kept in $(pwd) for the next session to publish"
  return "$pushed"
}

# One line per uncommitted file of the scope in <dir>, with the hash of what it
# holds: what bin/proposals.rb carry takes from there, compared again once recorded.
scope_edits() { # <dir>
  local f
  { git -C "$1" diff --name-only HEAD -- "${SCOPE[@]}"; git -C "$1" ls-files -o --exclude-standard -- "${SCOPE[@]}"; } |
    sort -u | while IFS= read -r f; do
      printf '%s %s\n' "$(git -C "$1" hash-object -- "$f" 2>/dev/null || echo deleted)" "$f"
    done
}

# Once a session recorded the edits it carried from the main checkout, the main
# checkout drops them, unless they changed since (scope_edits): what changed is
# carried again by the next session, and merging it twice changes nothing.
release_scope_edits() { # <scope_edits of the main checkout before the carry>
  local p
  [ -n "$1" ] && [ "$(scope_edits "$ROOT")" = "$1" ] || return 0
  for p in "${SCOPE[@]}"; do
    git -C "$ROOT" checkout -q HEAD -- "$p" 2>/dev/null || true
    git -C "$ROOT" clean -fdq -- "$p" 2>/dev/null || true
  done
}

# A record its session could not publish is the one commit on top of what origin
# has; it is published before its worktree is reset, or kept under
# refs/openspec/unpublished/ when that fails too, so a reset never loses it. So is
# one whose base origin no longer has (a rewritten history): there is nothing to
# rebase it onto. Succeeds only when it published one: its worktree's HEAD is
# then the new base.
publish_leftover_record() { # <worktree> <base-ref>
  local wt="$1" ref="$2"
  git -C "$wt" rev-parse -q --verify HEAD~1 >/dev/null || return 1
  git -C "$wt" merge-base --is-ancestor HEAD "$ref" && return 1
  case "$(git -C "$wt" log -1 --format=%s)" in "chore(memory): "*) ;; *) return 1 ;; esac
  if ! git -C "$wt" merge-base --is-ancestor HEAD~1 "$ref"; then
    keep_unpublished "$wt" HEAD "the record an earlier session left in $wt sits on a base origin no longer has"
    return 1
  fi
  if (cd "$wt" && { git push --quiet origin "HEAD:$BASE" || { ruby bin/proposals.rb rebase "$BASE" && git push --quiet origin "HEAD:$BASE"; }; }); then
    echo "published the record an earlier session left in $wt"
    return 0
  fi
  keep_unpublished "$wt" HEAD "could not publish the record an earlier session left in $wt"
  return 1
}

# Resets an agent session's worktree (.worktrees/_cycle, .worktrees/_visual_qa) to
# <base-ref>, its log/ a link to the main log/ (locks, queues and events stay
# shared) and its child repositories at the recorded pointers. A directory there
# that is not a worktree of its own is replaced: git would act on the main
# checkout instead, and check it out by force.
prepare_session_worktree() { # <worktree> <base-ref>
  local wt="$1" ref="$2" exclude="$ROOT/.git/info/exclude"
  mkdir -p "$(dirname "$wt")" "$(dirname "$exclude")"
  if [ -d "$wt" ] && [ "$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$wt" && pwd -P)" ]; then
    # The worktree is this session's alone and is prepared under its locks: an index.lock
    # (its own or a child repository's) no git touched for 10 minutes was left by one that
    # died, and would refuse every command below. A younger one stays, and stops this.
    find "$(git -C "$wt" rev-parse --absolute-git-dir)" -name index.lock -mmin +10 2>/dev/null | while IFS= read -r lock; do
      rm -f "$lock" && echo "removed $lock, which no git had touched for 10 minutes"
    done
    if publish_leftover_record "$wt" "$ref"; then ref="$(git -C "$wt" rev-parse HEAD)"; fi
  else
    rm -rf "$wt"
    git -C "$ROOT" worktree prune
    git -C "$ROOT" worktree add --detach --quiet "$wt" "$ref" || return 1
  fi
  grep -qx '/log' "$exclude" 2>/dev/null || printf '\n/log\n' >> "$exclude"
  git -C "$wt" rebase --abort 2>/dev/null || true
  rm -rf "$wt/log"
  git -C "$wt" checkout --quiet --force --detach "$ref" || return 1
  git -C "$wt" clean -fdq
  git -C "$wt" update-index --skip-worktree log/.keep 2>/dev/null || true
  rm -rf "$wt/log" && ln -s "$LOG_DIR" "$wt/log"
  git -C "$wt" submodule update --init --recursive --force --quiet || return 1
  git -C "$wt" submodule foreach --quiet --recursive 'git rebase --abort 2>/dev/null || true; git clean -fdq'
}

# A visual QA session holds log/visual_qa.lock while an agent app tests in the
# browser. It has no process to watch, so the lock carries its start and a
# time-to-live; past it the lock is stale. Prints the session's stamp when live.
visual_session() {
  local lock="$LOG_DIR/visual_qa.lock" started ttl
  [ -d "$lock" ] || return 1
  started="$(cat "$lock/started" 2>/dev/null || echo 0)"
  ttl="$(cat "$lock/ttl" 2>/dev/null || echo 0)"
  [ $(( $(date +%s) - started )) -lt "$ttl" ] || return 1
  cat "$lock/stamp" 2>/dev/null || echo unknown
}
