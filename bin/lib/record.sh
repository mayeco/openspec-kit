# shellcheck shell=bash
# ==============================================================================
# bin/lib/record.sh - What an agent session may write, how it is recorded, locks
# ==============================================================================
# Sourced by bin/run_cycle.sh (the headless judgment) and bin/visual_qa.sh (the
# visual QA session in an agent app). The caller sets ROOT, LOG_DIR and BASE and
# runs from ROOT.

# The versioned paths an agent session may write. log/cycle/ and log/PAUSE are
# git-ignored; everything else belongs to the merger or to humans.
SCOPE=(MEMORY.md config/agent_backlog.json config/agent_proposals.json)

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

# Commits the scope paths that changed and publishes them on the base branch.
record() { # <commit message>
  [ -n "$(git status --porcelain -- "${SCOPE[@]}")" ] || { echo "record: nothing to record"; return 0; }
  # git add aborts on a pathspec that matches nothing: stage existing or tracked paths only.
  local stage=() p attempt
  for p in "${SCOPE[@]}"; do
    if [ -e "$p" ] || git ls-files --error-unmatch -- "$p" >/dev/null 2>&1; then stage+=("$p"); fi
  done
  git add -A -- "${stage[@]}" && git commit --quiet -m "$1"
  for attempt in 1 2 3; do
    # Disjoint paths from the merger's commits, so this rebase cannot conflict on content.
    git pull --quiet --rebase origin "$BASE" && git push --quiet origin "HEAD:$BASE" && break
    sleep $((attempt * 5))
  done
  git submodule update --init --quiet
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
