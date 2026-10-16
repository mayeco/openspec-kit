---
name: openspec-cycle
description: Scheduled cycle of the OpenSpec orchestration kit. A scheduled task (Claude or Hermes app) launches `bin/run_cycle.sh --detach`; the script then starts a judgment agent that verifies what the merger integrated, triages blocked changes, explores for defects and improvements, queues backlog items, curates MEMORY.md and writes the cycle report. Use when the scheduled routine fires, when you are the SCHEDULED CYCLE agent, or when asked to run, check, pause, resume, unblock or reset the cycle.
---

# OpenSpec cycle: verify, triage, explore, queue, remember

Paths are relative to the umbrella root, the directory that contains `bin/run_cycle.sh`. One cycle runs every hour. It never waits for the work it queues: the dispatcher and the merger run at the end of the same cycle, and the next cycle verifies what they integrated.

Everything the cycle writes is in English: the report, `state.json` (journal included), `MEMORY.md`, backlog items and the final message.

## Who does what

| Part | Run by | Does |
| :--- | :--- | :--- |
| Scheduled task | Claude app or Hermes app, with `references/routine-prompt.md` as its prompt | Runs `bash bin/run_cycle.sh --detach`, reports the line it prints, ends |
| `bin/run_cycle.sh` | Detached script | Pause switch, cycle lock, preflight, drains the merge queue, syncs the checkout, starts the judgment agent, scope guard, commits and pushes `MEMORY.md` and the backlog, then runs the dispatcher with a merger beside it |
| Judgment agent | `claude` or `hermes` (`AGENT_ENGINE_CYCLE`), started by the script with `templates/cycle_prompt.md` | The judgment procedure below, and nothing else |

The script owns every step that must not depend on a model remembering it. The judgment agent never commits, pushes, dispatches or merges.

## State

Under `log/cycle/` (git-ignored) and `config/cycle.yaml` (versioned):

| File | Purpose |
| :--- | :--- |
| `config/cycle.yaml` | Settings a human edits: QA budget, failure limit, exploration areas and caps, the application's QA skills. The cycle only reads it |
| `log/cycle/state.json` | The cycle's memory between runs. The script creates it from `references/state.template.json` on the first cycle |
| `log/cycle/reports/<stamp>.md` | One report per cycle (`<stamp>` = `YYYYMMDD-HHMM`, UTC), from `references/report.template.md` |
| `log/cycle/cycle-<stamp>.log` | The script's own log of the cycle: preflight, merge, sync, judgment, record, dispatch |
| `log/cycle.lock/` | Present while a cycle runs; holds the PID of the script |
| `log/PAUSE` | Kill switch: while it exists no cycle runs and the dispatcher starts nothing new |

`state.json` fields: `last_cycle` (`started_at`, `finished_at`, `umbrella_sha`, `outcome`, `report_path`), `consecutive_failures`, `test_baseline` (`measured_at`, `passing`, `failing`, `known_failures`), `exploration_state` (`next_area`, `history`), `verified` (`change: date`), `needs_triage`, `notes_for_next_cycle` (read, act on, then clear), `journal` (one line per cycle, keep the last 30).

Durable knowledge does not go to `state.json`: conventions, pitfalls and lessons go to `MEMORY.md`, which every PLAN and BUILD agent reads first.

## Hard rules for the judgment agent

- Write only `MEMORY.md`, `config/agent_backlog.json`, files under `log/cycle/`, and `log/PAUSE`. The script checks this after you exit: any other write pauses the system and nothing is recorded.
- Never commit, push, pull, switch branches, or start or stop the dispatcher or the merger.
- Never edit `repos/**`, `openspec/**`, `bin/**`, `templates/**` or skills. Never create change directories: the dispatcher's PLAN phase writes the OpenSpec artifacts of every backlog item.
- Never delete blocked records or approval files; only a human approves a `risk_review` (`log/approved/<change>`).
- Local hosts only. Never read `.env*`, key files or credentials, and never pass them to Jev.
- Finish within `qa_time_budget_minutes` plus ten minutes. When the budget runs out, record what is left in `state.json` and write the report.
- Keep a list of every command you run, in order and with all parameters: it goes into the report.

## Asking Jev

Jev is a calibrated judge: it answers a typed question with a probability, never with text. Use it when a yes/no or pick-one judgment cannot be settled by running code. It is optional: if `jev` is missing or fails, decide yourself and say so in the report.
- Yes/no: `jev noul "<question>" --true "<what yes means>" --false "<what no means>" --state-file <file> --model <model> --field noul`
- Pick one: `jev choice "<question>" --option <a> --option <b> --option other --state-file <file> --model <model> --field choice`
- `<model>` is the `model` in `config/jev_policy.yaml`. Read a noul as: 0.7 or more = yes, 0.3 or less = no, anything in between = cannot tell. Never pass secrets as state.

## Judgment procedure

### 1. Orient

- Read `MEMORY.md`, `config/cycle.yaml`, `log/cycle/state.json` and the output of `bash bin/cycle_status.sh`.
- Act on `notes_for_next_cycle`, then clear it.
- `last_cycle.umbrella_sha` is null on the first cycle: there is nothing to verify yet, so skip step 2 and set it at the end.

### 2. Verify delivered work

- Run `bash bin/completed_since.sh <last_cycle.umbrella_sha>`: it lists the changes the merger integrated since then, the child commits behind them, their completed tasks and the lessons in their `handoff.md`.
- Verify each integrated change with the `openspec-qa` skill ("Verify integrated changes"). Record each verdict in `verified`; a broken scenario is a regression and becomes a `fix-<short-name>` backlog item with `"priority": "critical"` and the evidence in `description`.
- Review the `jev.answer` events in `log/events.jsonl` since the last cycle: note gates whose answers sit inside the abstain band or contradict what happened. That is calibration evidence for the report.

### 3. Triage blocked changes

- For each `log/blocked/<change>.json`, read `reason` and `details` and the worker log under `log/workers/`, and write a diagnosis and the recommended human action into the report.
- For `gate_failure`, the dispatcher's own question file gives a second opinion: `jev eval -f templates/jev/failure_triage.yaml --state-file <log excerpt> --model <model> --field answers.cause`.
- For `risk_review`, list what Jev flagged; only a human approves it.
- Create `log/PAUSE` (one line saying why) only for a systemic failure: the same reason blocking three or more changes, or gates failing on the base branch.
- Count the cycle as failed in `consecutive_failures` when everything the previous dispatch started ended blocked; reset it when something was integrated. At `max_consecutive_failures`, queue nothing and say in the report that a human is needed.

### 4. Explore and queue

- Explore `config.exploration.areas[exploration_state.next_area]` with the `openspec-qa` skill ("Explore one area"), using at least `exploration.minutes` of the budget. Advance `next_area` (wrapping around) and add `{area, date, findings}` to `history` (keep the last 30).
- Queue at most `exploration.max_new_backlog_items_per_cycle` findings, as `openspec-qa` "Record a finding" describes: duplicates checked, evaluated with `templates/jev/task_priority.yaml`, and only when `actionable_impact >= 0.7` and `urgency` is not `cannot_tell`. Everything else goes to `needs_triage` and the report.

### 5. Curate memory

- Fold the `handoff.md` lessons that `completed_since.sh` reported into `MEMORY.md`. Keep durable, non-obvious facts only; merge duplicates; delete entries that turned out to be wrong.
- Never copy task progress, diffs, debug output or this cycle's state into `MEMORY.md`.

### 6. Report and state

- Write `log/cycle/reports/<stamp>.md` from `references/report.template.md`, including "Commands executed".
- Update `state.json`: `last_cycle` (`started_at`, `finished_at`, `umbrella_sha` = current `git rev-parse HEAD`, `outcome`, `report_path`), `test_baseline` when measured, and one `journal` line (`<stamp> <outcome>: <one sentence>`). Check that it parses: `ruby -rjson -e 'JSON.parse(File.read("log/cycle/state.json"))'`.
- End with five lines: the outcome first (`verified`, `regression found`, `blocked`, `paused` or `nothing to do`), then anything that needs a human, then the report path.

## Operating the cycle

- **Schedule it**: in the Claude app (or the Hermes app) create a task that runs every hour in the umbrella root, with `references/routine-prompt.md` as its prompt. The agent of the task only launches the cycle and ends.
- **Choose the judgment engine**: `AGENT_ENGINE_CYCLE` (`claude`, `hermes`, `opencode`, `codex`), falling back to `AGENT_ENGINE`, then `claude`. To set it, prefix the command in the routine prompt (`AGENT_ENGINE_CYCLE=hermes bash bin/run_cycle.sh --detach`).
- **Run one now**: `bash bin/run_cycle.sh --detach`; or `bash bin/run_cycle.sh` in a terminal to watch it.
- **Watch**: `bash bin/cycle_status.sh`, `log/cycle/cycle-<stamp>.log`, `log/cycle/reports/`, `log/events.jsonl`.
- **Pause / resume**: `echo "<reason>" > log/PAUSE` / `rm log/PAUSE`.
- **Unblock a change**: read `log/blocked/<change>.json` and `log/workers/<change>.log`. Fix the cause in `.worktrees/worker-<change>` (OpenSpec artifacts) or on `feat/spec-<change>` inside the child repository (code), delete `.needs-human` if present, then `rm log/blocked/<change>.json`. The next dispatcher run resumes the change.
- **Approve a `risk_review`**: review the diff, `touch log/approved/<change>`, then `rm log/blocked/<change>.json`.
- **Abandon a change**: `git worktree remove --force .worktrees/worker-<change>`, `git branch -D feat/spec-<change>`, `rm log/blocked/<change>.json`, and remove its item from `config/agent_backlog.json`.
- **Tune**: `config/cycle.yaml` (budget, areas, caps, QA skills) and `config/jev_policy.yaml`.
- **Start over**: delete `log/cycle/state.json`; the next cycle recreates it from the template.
