#!/usr/bin/env bash
# ==============================================================================
# bin/visual_qa.sh - Opens and closes the visual QA session of an agent app
# ==============================================================================
# Usage: bin/visual_qa.sh begin | end
#
# The headless cycle (bin/run_cycle.sh, under crontab or any scheduler) cannot
# use a browser. A scheduled task of an agent app that can (Claude, Hermes) runs
# this session with the fixed prompt of the openspec-kit-visual-qa skill:
#   begin  takes log/visual_qa.lock, synchronises the checkout, claims the queued
#          checks (bin/visual_qa.rb) and writes the session's plan; prints one line
#   end    returns unfinished checks to the queue, applies the scope guard,
#          reviews proposals, records MEMORY.md, the backlog and the proposals,
#          and releases the lock
# The agent tests between the two, in its own session. While the session holds
# the lock the headless cycle does not judge, and a session does not begin while
# a cycle judges: one agent at a time writes the memory, backlog and proposals.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
export PATH="${OPENSPEC_PATH_PREFIX:-/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin}:$PATH"
export GIT_TERMINAL_PROMPT=0
BASE="${OPENSPEC_BASE_BRANCH:-master}"
LOG_DIR="$ROOT/log"
CYCLE_DIR="$LOG_DIR/cycle"
LOCK="$LOG_DIR/visual_qa.lock"
mkdir -p "$CYCLE_DIR/reports"
# shellcheck source=lib/record.sh
. "$ROOT/bin/lib/record.sh"   # SCOPE, scope_guard, record, visual_session

setting() { # <key> <default>: a value of visual_qa in config/cycle.yaml
  ruby -ryaml -e 'v = ((YAML.safe_load_file("config/cycle.yaml") rescue {}) || {}).dig("visual_qa", ARGV[0]); puts(v.nil? ? ARGV[1] : v)' "$1" "$2"
}
cycle_judging() { # prints the PID of a cycle that holds log/cycle.lock
  local pid
  pid="$(cat "$LOG_DIR/cycle.lock/pid" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && echo "$pid"
}

case "${1:-}" in
  begin)
    if [ -f "$LOG_DIR/PAUSE" ]; then echo "visual-qa: paused ($(head -1 "$LOG_DIR/PAUSE"))"; exit 0; fi
    if [ "$(setting enabled false)" != true ]; then echo "visual-qa: disabled (visual_qa.enabled in config/cycle.yaml)"; exit 0; fi
    if stamp="$(visual_session)"; then echo "visual-qa: session $stamp is still running"; exit 0; fi
    # A stale lock (past its time-to-live) belongs to a session that died: its checks go back.
    if [ -f "$LOCK/stamp" ]; then ruby bin/visual_qa.rb release "$(cat "$LOCK/stamp")" >/dev/null 2>&1; fi
    rm -rf "$LOCK"
    mkdir "$LOCK" 2>/dev/null || { echo "visual-qa: another session is starting"; exit 0; }
    STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
    echo "$STAMP" > "$LOCK/stamp"
    date +%s > "$LOCK/started"
    echo $(( ($(setting minutes 40) + 30) * 60 )) > "$LOCK/ttl"
    # The cycle takes its lock first and checks this one later, so backing off here
    # when a cycle judges leaves exactly one writer.
    if pid="$(cycle_judging)"; then
      rm -rf "$LOCK"
      echo "visual-qa: a cycle is judging (pid $pid); try at the next run"; exit 0
    fi
    bash bin/sync_repos.sh > "$CYCLE_DIR/visual-$STAMP.sync.log" 2>&1 || echo "visual-qa: sync reported a problem (see log/cycle/visual-$STAMP.sync.log)"
    ruby bin/visual_qa.rb take "$STAMP" "$CYCLE_DIR/visual-$STAMP.md" || { rm -rf "$LOCK"; exit 1; }
    ;;
  end)
    STAMP="$(cat "$LOCK/stamp" 2>/dev/null || true)"
    [ -n "$STAMP" ] || { echo "visual-qa: no session is open"; exit 1; }
    ruby bin/visual_qa.rb release "$STAMP"
    if ! scope_guard "visual QA $STAMP"; then rm -rf "$LOCK"; exit 1; fi
    ruby bin/proposals.rb review || echo "visual-qa: proposal review failed; proposals left as they were"
    record "chore(memory): visual QA $STAMP"
    rm -rf "$LOCK"
    echo "visual-qa: session $STAMP closed"
    ;;
  *)
    sed -n '2,17p' "$0"; exit 2 ;;
esac
