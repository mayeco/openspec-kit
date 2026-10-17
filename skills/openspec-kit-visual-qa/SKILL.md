---
name: openspec-kit-visual-qa
description: Visual QA session of the OpenSpec orchestration kit, run by a scheduled task of an agent app that can drive a browser (Claude, Hermes). Opens the session with bin/visual_qa.sh, checks in the running application every change the merger integrated and every request the headless cycle queued, explores the strategies that need a browser, records defects in the backlog and improvements as proposals, and closes the session. Use when the visual QA routine fires, or when asked to test the application in a browser, to request a visual check, or to inspect the visual QA queue.
---

# OpenSpec visual QA: test what users see

Paths are relative to the umbrella root, the directory that contains `bin/visual_qa.sh`. The headless cycle (`bin/run_cycle.sh`) runs from crontab or any scheduler and cannot open a browser. This session can: a scheduled task of an agent app runs it with `references/routine-prompt.md`, a few times a day or every hour.

Everything it writes is in English.

## Who does what

| Part | Run by | Does |
| :--- | :--- | :--- |
| Headless cycle | `bin/run_cycle.sh` | Queues every change the merger integrated (`ruby bin/visual_qa.rb enqueue-integrated`), except the ones that only touch terminal programs (`kind: cli` in their `repo.config.yaml`); its judgment asks for checks only a browser can make (`ruby bin/visual_qa.rb request`); it does not judge while a session holds `log/visual_qa.lock` |
| `bash bin/visual_qa.sh begin` | This session | Takes the lock (refused while a cycle judges), synchronises the checkout, claims up to `visual_qa.max_items_per_session` queued checks, picks the next strategy with `needs: browser` of `config/exploration.yaml`, writes the plan `log/cycle/visual-<stamp>.md` |
| You | The agent app's own browser, desktop and the application's QA skills (`qa.skills`) | The procedure below |
| `bash bin/visual_qa.sh end` | This session | Returns the checks you did not close to the queue, applies the scope guard, reviews proposals, commits and pushes `MEMORY.md`, the backlog and the proposals, releases the lock |

## Hard rules

- Write only `MEMORY.md`, `config/agent_backlog.json`, `config/agent_proposals.json`, files under `log/cycle/`, and `log/PAUSE` (one line saying why, only for a systemic failure). `end` checks this: any other write pauses the system and nothing is recorded. Application servers write their own logs and caches inside `repos/`, which is fine; never edit files there.
- Never commit, push, pull, switch branches, or start or stop the dispatcher or the merger.
- Local hosts only. Never read `.env*`, key files or credentials, and never type real credentials into the application: use the test users its QA skills or seeds create.
- Add proposals with `"status": "proposed"` only; never change an existing proposal's status.
- Always run `end`, also when the budget runs out or something breaks.

## Procedure

### 1. Start the application

- Read the plan, `MEMORY.md` and `config/cycle.yaml` (`qa.skills`).
- Start each repository's application that the checks need with its dev command, through its environment: `bash bin/repo_exec.sh repos/<name> <service.dev_command>` (see its `repo.config.yaml`). Wait for `service.health_endpoint`. Use the application's QA skills to seed data and sign in when it has them.

### 2. Check the queued items

For each item under "Check in the browser":
- A `verify` item is a change the merger integrated: read its archived `proposal.md` (`openspec/changes/archive/<date>-<change>/`) and the requirements it added or modified in `openspec/specs/`. Reproduce each scenario's WHEN in the browser and compare what you see with its THEN: pages, forms, messages, redirects, the console and failed network requests. Then walk the screens around it for regressions.
- A `request` item says what the headless cycle could not confirm: check exactly that.
- Save screenshots and console or network excerpts under `log/cycle/evidence/visual-<stamp>/`.
- Close it: `ruby bin/visual_qa.rb done <id> <verdict> "<one line of evidence>"`, with `verified`, `regression` (also record it, step 4), `not-visual` (the change has nothing to see) or `cannot-verify` (say what is missing).

### 3. Explore

Spend the rest of the budget on the plan's strategy, following its directive, as a user would: complete flows end to end, try wrong inputs and edge cases, and watch the console, the network and the server logs.

### 4. Record findings

As `openspec-kit-qa` "Record a finding" describes, at most the number the plan gives: reproduce each defect twice; defects and regressions go to `config/agent_backlog.json` (a regression is `fix-<short-name>`, `critical`); improvements and missing capabilities go to `config/agent_proposals.json` with `"source": "exploration"` and the strategy's slug. Put the reproduction steps and the evidence paths in the description.

### 5. Report and close

- Write `log/cycle/reports/visual-<stamp>.md`: each check with its verdict and evidence, what you explored, findings recorded and not recorded (and why), and every command you ran.
- Fold durable lessons into `MEMORY.md` (how to start the application, test users, flaky screens), never session details.
- Stop the servers you started, then run `bash bin/visual_qa.sh end`.

## Operating

- **Schedule it**: in the Claude app (or the Hermes app) create a task in the umbrella root with `references/routine-prompt.md` as its prompt, every hour or a few times a day. The app must be open and the computer awake; while it is not, checks wait in the queue.
- **Enable or disable**: `visual_qa.enabled` in `config/cycle.yaml`. Off: the headless cycle explores every strategy itself and queues nothing.
- **Which strategies need a browser**: `needs: browser` in `config/exploration.yaml`.
- **Watch**: `bash bin/cycle_status.sh` (VISUAL QA LOCK and the queue), `ruby bin/visual_qa.rb status`, `log/cycle/visual_queue.json`, `log/cycle/reports/visual-*.md`.
- **Ask for a check by hand**: `ruby bin/visual_qa.rb request "<what to check and where>" [--change <name>]`.
- **A session that died**: its lock expires after `visual_qa.minutes` plus 30 minutes; the next `begin` returns its unclosed checks to the queue and takes over.
