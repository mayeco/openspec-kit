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
for lock in cycle dispatch visual_qa; do # the judgment of a cycle; a cycle's dispatch; a visual QA session
  label="$(echo "$lock" | tr '[:lower:]_' '[:upper:] ') LOCK"
  if [ -d "$LOG/$lock.lock" ]; then
    echo "$label: pid $(cat "$LOG/$lock.lock/pid" 2>/dev/null) ($(( (NOW - $(mtime "$LOG/$lock.lock")) / 60 )) min old)"
  else
    echo "$label: none"
  fi
done

AGENTS="$(ruby "$ROOT/bin/lib/agents.rb" list 2>/dev/null)"
ROLES="$(for role in plan build cycle; do
  engine="$(ruby "$ROOT/bin/lib/agents.rb" engine "$role" 2>/dev/null)"; printf '%s: %s, ' "$role" "$(printf '%s' "${engine:-first on PATH}" | tr ',' '>')"
done)"
echo "AGENTS: ${AGENTS:-none selected (no config/agents.yaml)} (${ROLES%, }; permissions: $(ruby "$ROOT/bin/lib/agents.rb" permissions 2>/dev/null))"

if [ -f "$LOG/cycle/state.json" ]; then
  ruby -rjson -e 'c = JSON.parse(File.read(ARGV[0], encoding: "UTF-8")).fetch("last_cycle", {})
    puts "LAST CYCLE: #{c["outcome"] || "none"} (finished #{c["finished_at"] || "-"}, report #{c["report_path"] || "-"})"' \
    "$LOG/cycle/state.json" 2>/dev/null || echo "LAST CYCLE: log/cycle/state.json is unreadable"
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
ruby "$ROOT/bin/visual_qa.rb" status 2>/dev/null
if [ -f "$ROOT/config/agent_proposals.json" ]; then
  ruby -rjson -e 'p = JSON.parse(File.read(ARGV[0], encoding: "UTF-8")) rescue (puts "proposals: unreadable"; exit)
    waiting = Array(p).select { |i| i["status"] == "proposed" }.map { |i| i["change_name"] }
    puts "proposals waiting for approval: #{waiting.empty? ? "none" : waiting.join(", ")}"' "$ROOT/config/agent_proposals.json"
fi
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
