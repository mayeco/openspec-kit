#!/usr/bin/env bash
# ==============================================================================
# bin/visual_qa.sh - Opens and closes the visual QA session of an agent app
# ==============================================================================
# Usage: bin/visual_qa.sh begin | end
#
# The headless cycle (bin/run_cycle.sh, under crontab or any scheduler) cannot
# use a browser. A scheduled task of an agent app that can (Claude, Hermes) runs
# this session with the fixed prompt of the openspec-kit-visual-qa skill:
#   begin  takes log/visual_qa.lock, synchronises the checkout, prepares
#          .worktrees/_visual_qa, checks the services the repositories require and
#          runs their service.prepare, claims the queued checks (bin/visual_qa.rb)
#          and writes the session's plan; prints one line
#   end    returns unfinished checks to the queue, applies the scope guard,
#          reviews proposals, records the memory, the backlog and the proposals,
#          and releases the lock
# The agent tests between the two, in its own session: its commands run in
# .worktrees/_visual_qa, on the slot visual_qa.slot names (false, the default: none,
# so the ports and databases of the main checkout), while the headless cycle judges in
# .worktrees/_cycle (OPENSPEC_SLOT=98), so the two run in parallel and reconcile
# the memory, the backlog and the proposals when they record.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
export PATH="${OPENSPEC_PATH_PREFIX:-/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin}:$PATH"
export GIT_TERMINAL_PROMPT=0
BASE="$(ruby "$ROOT/bin/lib/settings.rb" get base_branch)"   # config/pipeline.yaml
LOG_DIR="$ROOT/log"
CYCLE_DIR="$LOG_DIR/cycle"
LOCK="$LOG_DIR/visual_qa.lock"
WORKTREE_BASE="${OPENSPEC_WORKTREE_BASE:-$ROOT/.worktrees}"
VISUAL_WT="$WORKTREE_BASE/_visual_qa"
mkdir -p "$CYCLE_DIR/reports"
# shellcheck source=lib/record.sh
. "$ROOT/bin/lib/record.sh"   # SCOPE, with_record_lock, scope_guard, record, visual_session

setting() { # <key> <default>: a value of visual_qa in config/cycle.yaml
  ruby -ryaml -e 'v = ((YAML.safe_load_file("config/cycle.yaml") rescue {}) || {}).dig("visual_qa", ARGV[0]); puts(v.nil? ? ARGV[1] : v)' "$1" "$2"
}
# visual_qa.slot as a slot number, or nothing for false: false, FALSE, "false", "" or no
# value. bin/kit_config.rb check reports anything else, which counts as false here too.
visual_slot() {
  ruby -ryaml -e 'v = ((YAML.safe_load_file("config/cycle.yaml") rescue {}) || {}).dig("visual_qa", "slot")
    v = v.strip if v.is_a?(String)
    puts v if (v.is_a?(Integer) && v.positive?) || (v.is_a?(String) && v.match?(/\A[1-9][0-9]*\z/))'
}

prepare_visual_worktree() {
  local base_ref
  git -C "$ROOT" fetch --quiet origin "$BASE" 2>/dev/null || true
  base_ref="$(git -C "$ROOT" rev-parse --verify --quiet "origin/$BASE" || git -C "$ROOT" rev-parse HEAD)"
  prepare_session_worktree "$VISUAL_WT" "$base_ref"
}

# Each repository's service.prepare (repo.config.yaml) readies .worktrees/_visual_qa for
# the browser: dependencies the clone lacks, a database to migrate and seed, local
# configuration linked from the main checkout (OPENSPEC_MAIN_ROOT). It runs through the
# repository's env_script, on the session's slot. The last line says which one failed.
prepare_services() {
  local cfg rel cmd slot
  slot="$(cat "$LOCK/slot" 2>/dev/null || true)"
  for cfg in "$VISUAL_WT"/repos/*/repo.config.yaml; do
    [ -f "$cfg" ] || continue
    rel="repos/$(basename "$(dirname "$cfg")")"
    cmd="$(ruby -ryaml -e 'v = ((YAML.safe_load_file(ARGV[0]) rescue {}) || {}).dig("service", "prepare"); puts v if v.is_a?(String)' "$cfg")"
    [ -n "${cmd//[[:space:]]/}" ] || continue
    echo "---- [prepare] $rel: $cmd"
    if ! OPENSPEC_SLOT="$slot" OPENSPEC_MAIN_ROOT="$ROOT" bash "$VISUAL_WT/bin/repo_exec.sh" "$VISUAL_WT/$rel" bash -c "$cmd"; then
      echo "service.prepare of $rel failed"
      return 1
    fi
  done
}

case "${1:-}" in
  begin)
    if [ -f "$LOG_DIR/PAUSE" ]; then echo "visual-qa: paused ($(head -1 "$LOG_DIR/PAUSE"))"; exit 0; fi
    if [ "$(setting enabled false)" != true ]; then echo "visual-qa: disabled (visual_qa.enabled in config/cycle.yaml)"; exit 0; fi
    if stamp="$(visual_session)"; then echo "visual-qa: session $stamp is still running"; exit 0; fi
    begin_session() {
      # Asked again under the lock: a session that began while this one waited is live.
      if stamp="$(visual_session)"; then echo "visual-qa: session $stamp is still running"; return 0; fi
      # A stale lock (past its time-to-live) belongs to a session that died: its checks go back.
      if [ -f "$LOCK/stamp" ]; then ruby bin/visual_qa.rb release "$(cat "$LOCK/stamp")" >/dev/null 2>&1; fi
      rm -rf "$LOCK"
      mkdir "$LOCK" 2>/dev/null || { echo "visual-qa: another session is starting"; return 0; }
      STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
      echo "$STAMP" > "$LOCK/stamp"
      echo "$$" > "$LOCK/pid"
      date +%s > "$LOCK/started"
      echo $(( ($(setting minutes 40) + 30) * 60 )) > "$LOCK/ttl"
      # The slot bin/repo_exec.sh gives the session's commands: none while visual_qa.slot is false.
      visual_slot > "$LOCK/slot"
      bash bin/sync_repos.sh > "$CYCLE_DIR/visual-$STAMP.sync.log" 2>&1 || echo "visual-qa: sync reported a problem (see log/cycle/visual-$STAMP.sync.log)"
      prepare_visual_worktree >> "$CYCLE_DIR/visual-$STAMP.sync.log" 2>&1 || { rm -rf "$LOCK"; return 1; }
      if ! bash bin/check_ai_engines.sh --services >> "$CYCLE_DIR/visual-$STAMP.sync.log" 2>&1; then
        echo "visual-qa: $(tail -1 "$CYCLE_DIR/visual-$STAMP.sync.log")"; rm -rf "$LOCK"; return 1
      fi
      prepare_services >> "$CYCLE_DIR/visual-$STAMP.sync.log" 2>&1 || {
        echo "visual-qa: $(tail -1 "$CYCLE_DIR/visual-$STAMP.sync.log") (see log/cycle/visual-$STAMP.sync.log)"; rm -rf "$LOCK"; return 1
      }
      # The plan through the worktree's log/ link, so that take names it relative to the root.
      ruby "$VISUAL_WT/bin/visual_qa.rb" take "$STAMP" "$VISUAL_WT/log/cycle/visual-$STAMP.md" || { rm -rf "$LOCK"; return 1; }
    }
    with_record_lock begin_session || exit 1
    ;;
  end)
    STAMP="$(cat "$LOCK/stamp" 2>/dev/null || true)"
    [ -n "$STAMP" ] || { echo "visual-qa: no session is open"; exit 1; }
    ruby bin/visual_qa.rb release "$STAMP"
    if ! scope_guard "visual QA $STAMP" || { [ -d "$VISUAL_WT" ] && ! (cd "$VISUAL_WT" && scope_guard "visual QA $STAMP"); }; then
      rm -rf "$LOCK"; exit 1
    fi
    # The findings were written in the main checkout: carried into .worktrees/_visual_qa
    # with a three-way merge and recorded from there, the main checkout keeps them until
    # they are published. Without that worktree they are recorded where they are.
    end_session() {
      local target="$ROOT" edits
      edits="$(scope_edits "$ROOT")"
      if [ -d "$VISUAL_WT" ]; then
        target="$VISUAL_WT"
        if [ -n "$edits" ] && ! (cd "$VISUAL_WT" && ruby bin/proposals.rb carry "$ROOT"); then
          echo "visual-qa: could not carry the findings into .worktrees/_visual_qa; they stay in the main checkout"
          target=""
        fi
      fi
      if [ -n "$target" ]; then
        (cd "$target" && ruby bin/proposals.rb review) || echo "visual-qa: proposal review failed; proposals left as they were"
        if (cd "$target" && record "chore(memory): visual QA $STAMP") && [ "$target" = "$VISUAL_WT" ]; then
          release_scope_edits "$edits"
        fi
      fi
      rm -rf "$LOCK"
      bash bin/sync_repos.sh >/dev/null 2>&1 || true
    }
    with_record_lock end_session || { echo "visual-qa: session $STAMP not recorded; run end again"; exit 1; }
    echo "visual-qa: session $STAMP closed"
    ;;
  *)
    sed -n '2,21p' "$0"; exit 2 ;;
esac
