---
name: openspec-kit-cycle
description: Scheduled cycle of the OpenSpec orchestration kit. A scheduled task (Claude, Hermes or another agent app) launches `bin/run_cycle.sh --detach`; the script then starts a judgment agent that verifies what the merger integrated, triages blocked changes, explores with the strategy the script picked from config/exploration.yaml, queues defects, proposes improvements and roadmap features, curates MEMORY.md and writes the cycle report, also while an earlier dispatch is still building. Use when the scheduled routine fires, when you are the SCHEDULED CYCLE agent, or when asked to run, check, pause, resume, unblock, reset or tune the cycle, its strategies, its roadmap or its proposals.
---

# OpenSpec cycle: verify, triage, explore, queue, remember

Paths are relative to the umbrella root, the directory that contains `bin/run_cycle.sh`. One cycle runs every hour. It never waits for the work it queues: the dispatcher and the merger run at the end of the same cycle, and the next cycle verifies what they integrated. A dispatch can outlast the hour; the next cycle then still verifies, explores and queues, and leaves the dispatch to the one that runs.

Everything the cycle writes is in English: the report, `state.json` (journal included), `MEMORY.md`, backlog items, proposals and the final message.

## Who does what

| Part | Run by | Does |
| :--- | :--- | :--- |
| Scheduled task | Claude app, Hermes app or another agent app, with `references/routine-prompt.md` as its prompt | Runs `bash bin/run_cycle.sh --detach`, reports the line it prints, ends. The prompt never changes: the scripts read every setting from `config/` |
| `bin/run_cycle.sh` | Detached script | Pause switch, cycle lock, preflight, drains the merge queue, syncs the checkout, renders this cycle's prompt (`bin/cycle_prompt.rb`: the next exploration strategy, whether a dispatch is running, the roadmap and approval settings), starts the judgment agent, scope guard, reviews the proposals (`bin/proposals.rb`), commits and pushes `MEMORY.md`, the backlog and the proposals, releases the cycle lock, then runs the dispatcher with a merger beside it unless a dispatch is already running |
| Judgment agent | The `cycle` role of `config/agents.yaml`, started headless by the script with `log/cycle/prompt-<stamp>.md` (`config/templates/cycle_prompt.md` plus "This cycle") | The judgment procedure below, and nothing else. It has no browser |
| Visual QA session | A scheduled task of an agent app with a browser, with the `openspec-kit-visual-qa` skill | Checks in the browser what the cycle queued and explores the strategies with `needs: browser`. While it holds `log/visual_qa.lock` the cycle does not judge |

The script owns every step that must not depend on a model remembering it. The judgment agent never commits, pushes, dispatches or merges.

## State

Under `log/cycle/` (git-ignored) and `config/` (versioned):

| File | Purpose |
| :--- | :--- |
| `config/cycle.yaml` | Settings a human edits: QA budget, failure limit, exploration caps, the roadmap, who approves proposals, the application's QA skills. The cycle only reads it |
| `config/exploration.yaml` | The exploration strategies (slug, name, kind, directive) and their order. The script picks one per cycle |
| `ROADMAP.md` (`roadmap.file`) | The features to build, in priority order. The cycle proposes the next ones |
| `config/agent_proposals.json` | Proposals: improvements, missing capabilities and roadmap features waiting for approval, then queued and integrated. The judgment adds them; `bin/proposals.rb` and humans approve them |
| `log/cycle/state.json` | The cycle's memory between runs. The script creates it from `config/templates/cycle_state.json` on the first cycle |
| `log/cycle/reports/<stamp>.md` | One report per cycle (`<stamp>` = `YYYYMMDD-HHMM`, UTC), from `references/report.template.md` |
| `log/cycle/cycle-<stamp>.log` | The script's own log of the cycle: preflight, merge, sync, plan, judgment, proposals, record, dispatch |
| `log/cycle/prompt-<stamp>.md` | The prompt the judgment agent got, with this cycle's plan |
| `log/cycle/strategy_state.json` | Where the strategy rotation stands; the script owns it |
| `log/cycle.lock/` | Present while a cycle judges, from preflight to record; holds the PID of the script |
| `log/dispatch.lock/` | Present while a cycle's dispatch runs; holds the PID of the script |
| `log/cycle/visual_queue.json` | Checks waiting for the visual QA session: integrated changes and requests |
| `log/PAUSE` | Kill switch: while it exists no cycle runs and the dispatcher starts nothing new |

`state.json` fields: `last_cycle` (`started_at`, `finished_at`, `umbrella_sha`, `outcome`, `report_path`), `consecutive_failures`, `test_baseline` (`measured_at`, `passing`, `failing`, `known_failures`), `exploration_state` (`history`: `{strategy, date, findings}`, keep the last 30), `verified` (`change: date`), `needs_triage`, `notes_for_next_cycle` (read, act on, then clear), `journal` (one line per cycle, keep the last 30).

Durable knowledge does not go to `state.json`: conventions, pitfalls and lessons go to `MEMORY.md`, which every PLAN and BUILD agent reads first.

## Hard rules for the judgment agent

- Write only `MEMORY.md`, `config/agent_backlog.json`, `config/agent_proposals.json`, files under `log/cycle/`, and `log/PAUSE`. The script checks this after you exit: any other write pauses the system and nothing is recorded.
- Never commit, push, pull, switch branches, or start or stop the dispatcher or the merger.
- Never edit `repos/**`, `openspec/**`, `bin/**`, `config/templates/**` or skills. Never create change directories: the dispatcher's PLAN phase writes the OpenSpec artifacts of every backlog item.
- Never delete blocked records or approval files; only a human approves a `risk_review` (`log/approved/<change>`).
- Add proposals with `"status": "proposed"` only. Never approve, reject or delete a proposal, and never move one into the backlog: the script and humans do that.
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

- Read "This cycle" at the end of your prompt: the script's plan for this cycle (strategy, dispatch, roadmap, approval). Then read `MEMORY.md`, `config/cycle.yaml`, `log/cycle/state.json`, `config/agent_proposals.json` and the output of `bash bin/cycle_status.sh`.
- Act on `notes_for_next_cycle`, then clear it.
- `last_cycle.umbrella_sha` is null on the first cycle: there is nothing to verify yet, so skip step 2 and set it at the end.

### 2. Verify delivered work

- Run `bash bin/completed_since.sh <last_cycle.umbrella_sha>`: it lists the changes the merger integrated since then, the child commits behind them, their completed tasks and the lessons in their `handoff.md`.
- Verify each integrated change with the `openspec-kit-qa` skill ("Verify integrated changes"). Record each verdict in `verified`; a broken scenario is a regression and becomes a `fix-<short-name>` backlog item with `"priority": "critical"` and the evidence in `description`.
- Run `ruby bin/jev_report.rb --since 24h`: it puts each gate's answers beside what happened to the changes it judged. Note gates whose answers sit inside the abstain band, or that would have stopped changes that integrated well or let through ones that were blocked. That is calibration evidence for the report.

### 3. Triage blocked changes

- For each `log/blocked/<change>.json`, read `reason` and `details` and the worker log under `log/workers/`, and write a diagnosis and the recommended human action into the report.
- For `gate_failure`, the dispatcher's own question file gives a second opinion: `jev eval -f config/templates/jev/failure_triage.yaml --state-file <log excerpt> --model <model> --field answers.cause`.
- For `risk_review`, list what Jev flagged; only a human approves it.
- For `scenario_coverage`, name the scenarios Jev found without a test that asserts their outcome; for `repair_stalled`, say what kept failing across the repairs, which usually means the plan or a test is wrong rather than the code.
- Create `log/PAUSE` (one line saying why) only for a systemic failure: the same reason blocking three or more changes, or gates failing on the base branch.
- Count the cycle as failed in `consecutive_failures` when everything the previous dispatch started ended blocked; reset it when something was integrated. While a dispatch is still running, leave the count as it is. At `max_consecutive_failures`, queue and propose nothing and say in the report that a human is needed.

### 4. Explore, queue and propose

- Explore with the strategy of "This cycle" and its directive, using the `openspec-kit-qa` skill ("Explore one area") and at least `exploration.minutes` of the budget. Add `{strategy, date, findings}` to `exploration_state.history` (keep the last 30). The script picks the next strategy; never choose another one.
- You run headless. When only a browser can confirm something (a rendered page, a flow, the console), queue a check for the visual QA session, if "This cycle" says it is on: `ruby bin/visual_qa.rb request "<what to check, where, and why>" [--change <name>]`.
- Record at most `exploration.max_new_backlog_items_per_cycle` findings, as `openspec-kit-qa` "Record a finding" describes. Defects and regressions go to the backlog: duplicates checked, evaluated with `config/templates/jev/task_priority.yaml`, and only when `actionable_impact >= 0.7` and `urgency` is not `cannot_tell`. Improvements and missing capabilities go to `config/agent_proposals.json`. Everything else goes to `needs_triage` and the report.

### 5. Propose from the roadmap

- Follow the "Roadmap" line of "This cycle": it names the file and the caps, or says to skip this step.
- Read the roadmap in order. A feature is taken when `openspec/specs/`, an archived change, an active change, the backlog or a proposal already covers it. Propose the first features that are not taken, each as one cohesive change with acceptance hints from the roadmap, with `"source": "roadmap"`.
- Never propose a feature the roadmap does not list, and never rewrite the roadmap: a human owns it.

### 6. Curate memory

- Fold the `handoff.md` lessons that `completed_since.sh` reported into `MEMORY.md`. Keep durable, non-obvious facts only; merge duplicates; delete entries that turned out to be wrong.
- Never copy task progress, diffs, debug output or this cycle's state into `MEMORY.md`.

### 7. Report and state

- Write `log/cycle/reports/<stamp>.md` from `references/report.template.md`, including "Commands executed".
- Update `state.json`: `last_cycle` (`started_at`, `finished_at`, `umbrella_sha` = current `git rev-parse HEAD`, `outcome`, `report_path`), `test_baseline` when measured, and one `journal` line (`<stamp> <outcome>: <one sentence>`). Check that it parses: `ruby -rjson -e 'JSON.parse(File.read("log/cycle/state.json"))'`.
- End with five lines: the outcome first (`verified`, `regression found`, `blocked`, `paused` or `nothing to do`), then anything that needs a human (proposals waiting for approval included), then the report path.

## Operating the cycle

- **Schedule it**: the cycle is headless, so any scheduler works: a crontab line (`0 * * * * cd <umbrella> && bash bin/run_cycle.sh --detach`), launchd, or a task of the Claude app (or the Hermes app, or another agent app) that runs every hour in the umbrella root with `references/routine-prompt.md` as its prompt, whose agent only launches the cycle and ends. Never add settings to the prompt: the scripts read them from `config/`.
- **Visual QA**: schedule the `openspec-kit-visual-qa` skill's routine prompt as a separate task of an agent app that can drive a browser. `visual_qa` in `config/cycle.yaml` turns it on or off.
- **Choose the agents**: `config/agents.yaml`, written by `install.sh`, lists the agents this application uses (`claude`, `codex`, `copilot`, `hermes`, `opencode`) and the one that runs each role: `plan`, `build` and `cycle` (this judgment). Edit a role there, or change the agents with `bin/install.sh upgrade <app> --agents <list>` from a checkout of the release, which installs their skills. `AGENT_ENGINE_<ROLE>` or `AGENT_ENGINE` override a role for one manual run, never in the scheduled task.
- **Run one now**: `bash bin/run_cycle.sh --detach`; or `bash bin/run_cycle.sh` in a terminal to watch it. A cycle that starts while a dispatch runs judges and records, and does not dispatch.
- **Agent permissions**: `permissions` in `config/agents.yaml`. `all` (the default) lets agents run any command, which live QA needs (servers, `curl`, browsers), except the git commands only the scripts run; `restricted` limits Claude Code to reading, editing, `openspec`, git inspection, the gates and Jev, and keeps Codex in its sandbox.
- **Exploration strategies**: edit `config/exploration.yaml`: add, remove, reorder or disable strategies (`enabled: false`), and set `order: rotation` or `random`. Name your own modules, screens and paths in each directive. `kind` decides where findings go: `defects` to the backlog, `improvements` and `features` to proposals.
- **Roadmap**: keep `ROADMAP.md` (or the file `roadmap.file` names) in priority order. `roadmap.max_new_per_cycle` and `roadmap.max_open` limit how fast it is proposed.
- **Proposals**: `ruby bin/proposals.rb list`; `ruby bin/proposals.rb approve <change>` or `reject <change>`; the next cycle queues what is approved. `proposals.approval` in `config/cycle.yaml` is `jev` (Jev approves what passes `proposal_review` in `config/jev_policy.yaml`, the rest waits for you), `human` or `auto`. To have Jev review a proposal again, delete its `review`.
- **Watch**: `bash bin/cycle_status.sh`, `log/cycle/cycle-<stamp>.log`, `log/cycle/reports/`, `log/events.jsonl`.
- **Pause / resume**: `echo "<reason>" > log/PAUSE` / `rm log/PAUSE`.
- **Unblock a change**: read `log/blocked/<change>.json` and `log/workers/<change>.log`. Fix the cause in `.worktrees/worker-<change>` (OpenSpec artifacts) or on `feat/spec-<change>` inside the child repository (code), delete `.needs-human` if present, then `rm log/blocked/<change>.json`. The next dispatcher run resumes the change.
- **Approve a `risk_review`**: review the diff, `touch log/approved/<change>`, then `rm log/blocked/<change>.json`.
- **Abandon a change**: `git worktree remove --force .worktrees/worker-<change>`, `git branch -D feat/spec-<change>`, `rm log/blocked/<change>.json`, and remove its item from `config/agent_backlog.json`.
- **Tune**: `config/cycle.yaml` (budget, caps, roadmap, approval, QA skills), `config/pipeline.yaml` (base branch, workers, limits), `config/exploration.yaml` and `config/jev_policy.yaml`. The `openspec-kit-config` skill explains every setting and changes one safely (`ruby bin/kit_config.rb show`, `check`, `set`).
- **Start over**: delete `log/cycle/state.json` (and `log/cycle/strategy_state.json` to restart the rotation); the next cycle recreates it from the template.
