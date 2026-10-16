#!/usr/bin/env bash
# ==============================================================================
# bin/cycle_status.sh - Read-only snapshot of guards, queues and repositories
# ==============================================================================
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$ROOT/log"
NOW="$(date +%s)"
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo "$NOW"; }

echo "== Guards"
if [ -f "$LOG/PAUSE" ]; then echo "PAUSED: YES ($(head -1 "$LOG/PAUSE"))"; else echo "PAUSED: NO"; fi
if [ -d "$LOG/cycle.lock" ]; then
  echo "CYCLE LOCK: pid $(cat "$LOG/cycle.lock/pid" 2>/dev/null) ($(( (NOW - $(mtime "$LOG/cycle.lock")) / 60 )) min old)"
else
  echo "CYCLE LOCK: none"
fi

echo "== Processes"
for name in dispatcher merger; do
  lock="$LOG/locks/$name.lock"
  pid="$(sed -nE 's/.*pid=([0-9]+).*/\1/p' "$lock" 2>/dev/null | head -1)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then echo "RUNNING: $name (pid $pid)"; else echo "IDLE: $name"; fi
done
[ -f "$LOG/merger_state.json" ] && echo "MERGER STATE: $(tr -d '\n ' < "$LOG/merger_state.json" | cut -c1-160)"

echo "== Queues"
echo "ready_to_merge: $(find "$LOG/ready_to_merge" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
for f in "$LOG"/blocked/*.json; do
  [ -f "$f" ] || continue
  ruby -rjson -e 'b = JSON.parse(File.read(ARGV[0], encoding: "UTF-8")); puts "BLOCKED: #{b["change_name"]} reason=#{b["reason"]} since=#{b["blocked_at"]}"' "$f"
done
for f in "$LOG"/locks/*.lock; do
  case "$(basename "$f")" in dispatcher.lock|merger.lock) continue ;; esac
  [ -f "$f" ] && echo "LEASE: $(basename "$f" .lock)"
done

echo "== Worktrees"
git -C "$ROOT" worktree list | sed 's/^/  /'

echo "== Repositories"
printf '  %-22s %-24s %s\n' "root" "$(git -C "$ROOT" branch --show-current)" "$(git -C "$ROOT" rev-parse --short HEAD)"
git -C "$ROOT" config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null | awk '$2 ~ /^repos\// {print $2}' | while read -r p; do
  d="$ROOT/$p"
  [ -e "$d/.git" ] || { printf '  %-22s not initialized\n' "$p"; continue; }
  printf '  %-22s %-24s %s dirty=%s\n' "$p" "$(git -C "$d" branch --show-current 2>/dev/null || true)" \
    "$(git -C "$d" rev-parse --short HEAD)" "$(GIT_OPTIONAL_LOCKS=0 git -C "$d" status --porcelain | wc -l | tr -d ' ')"
done
