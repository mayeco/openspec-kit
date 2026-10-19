---
name: openspec-kit-status
description: How the autonomous pipeline of the OpenSpec orchestration kit is going, read-only. Reports what runs now (a cycle, a dispatch, a visual QA session, changes in flight), what the cycles did in a period (changes integrated or blocked, proposals, visual checks, agent time), what is pending, how far the roadmap got, the system's health and what needs a person. Use when asked how the cycle, the pipeline or the project is going, what it did or is doing, whether it is running, or what is waiting for a human.
---

# OpenSpec kit status: how is it going?

Read-only. Never approve, unblock, pause, resume, edit or start anything here; operating the cycle is the `openspec-kit-cycle` skill's job ("Operating the cycle"). Paths are relative to the application's root, the directory that holds `bin/cycle_progress.rb`.

## Gather

1. Run the report for the period the person asks about (24 hours when they do not say):
   ```bash
   ruby bin/cycle_progress.rb --since 24h        # or 90m, 7d, 2026-10-01
   ```
   Add `--json` when you need exact figures or lists. Every number you give comes from this output; never estimate one.
2. When something looks stuck, add the instant snapshot: `bash bin/cycle_status.sh` (locks, processes, worktrees, child repositories).
   When the person asks what comes next, or why an item has not started: `ruby bin/openspec_dispatcher.rb --dry-run` (`--json` for exact fields). It is read-only and works while a dispatch runs: every pending item in the order it would start, its priority after aging, how long it waited, and what holds it (building, waiting for the merger, blocked and its retry, a dependency and that dependency's state, a capability in use, or already ended by the running dispatch, so it starts in the next one).
3. For the judgment's own account of the last cycle (what it verified, found and proposed), read the newest file in `log/cycle/reports/` (visual sessions: `visual-*.md`).
4. For one change: `log/blocked/<change>.json` (`reason`, `details`), `log/workers/<change>.log`, its archived proposal in `openspec/changes/archive/`, and its `repairs.md` (what each repair round was asked to fix and whether it then passed).
5. When the person asks whether an edit of the agents' prompts or of the memory helped: `ruby bin/prompt_report.rb --since 30d` (`--by memory` for the memory). Say how many changes each version started; a version with a few says little.

## Answer

Short, in the person's language, in four blocks:

1. **Now**: running or idle; what runs (a cycle judging, a dispatch and its changes in flight, a visual session); paused and why.
2. **Done** in the period: the changes integrated, by name; how many cycles ran and how they ended; visual checks and their verdicts; proposals made, approved, integrated.
3. **Pending**: the backlog by state, proposals waiting, the visual queue, roadmap progress.
4. **Needs you**: one line per item, with the command that resolves it:
   - a blocked change: read its reason; for `risk_review`, review the diff, `touch log/approved/<change>`, then `rm log/blocked/<change>.json`. One the report shows with an automatic retry still to come (`retry 1 of 1 at <time>`) needs nobody yet: say when it runs again;
   - a proposal waiting: `ruby bin/proposals.rb approve <change>` or `reject <change>`; for a prompt proposal, read it first with `ruby bin/proposals.rb show <change>`;
   - a pause: fix the reason, then `rm log/PAUSE`;
   - a visual check that could not verify: what was missing, from its note.

Add one line on health only when something is off: consecutive failures near the limit, a failing preflight, cycles that stop before the end, or no cycle in a period when the cycle is scheduled hourly.

## Reading the signals

| Cycle outcome | Means |
| :--- | :--- |
| `done` | Judged, recorded and dispatched |
| `judged; an earlier dispatch was still running` | Normal: it verified and queued, and left building to the dispatch in progress |
| `dispatched only (visual QA session running)` | Normal: the visual session held the judgment that hour |
| `paused` | `log/PAUSE` exists; nothing runs until a person removes it |
| `scope violation` | The judgment wrote outside its scope; the system paused itself and recorded nothing |
| `preflight failed` | An agent CLI was not logged in, a kit file was edited, or a tool was missing; see the cycle's log |
| `stopped before the end` | The process died (killed, the computer slept); the next cycle continues. Repeated: read `log/cycle/cycle-<stamp>.log` |
| `running (<step>)` | The newest cycle is still at that step |

- No cycle at all in the last hours: the scheduler is not firing (crontab, the agent app closed, the computer asleep); `SCHEDULING.md` has the checks.
- Changes integrated but the roadmap does not move: its items are not proposed yet, or the proposals wait for approval.
- Many changes blocked for the same reason: a systemic problem; say so first.
