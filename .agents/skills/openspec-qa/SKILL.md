---
name: openspec-qa
description: Verification and proactive exploration method of the OpenSpec orchestration kit. Checks that integrated changes meet their scenarios (tests, gates, code reading, live reproduction with the application's own QA skills, Jev for THEN clauses), sweeps for regressions around what changed, explores one area per cycle for defects and improvements, and records findings as evidence-backed backlog items. Use from the openspec-cycle judgment procedure, or when asked to verify an integrated change or to hunt for defects.
---

# OpenSpec QA: verify what was delivered, find what is missing

The pipeline's own gates only run the tests of the repositories a change touched, and they only prove what the agent thought to test. This method is where unexpected breakage, missed requirements and drift between `openspec/specs/` and the code are found. It finds and documents; fixes always go through the backlog and the dispatcher.

## Inputs

- `bash bin/completed_since.sh <sha>`: changes integrated since `<sha>` (commit trailer `OpenSpec-Change`), the child-repo commits behind each pointer move, completed tasks and `handoff.md` lessons.
- `config/cycle.yaml`: `qa.skills` (the application's own QA skills, for example browser or API sweeps), `exploration.areas`, `exploration.minutes`, `exploration.max_new_backlog_items_per_cycle`.
- `MEMORY.md`: conventions and known pitfalls of this workspace.
- `log/cycle/state.json`: `test_baseline`, `verified`, `needs_triage`.

## Rules

- Read-only on code and specifications. When run by the cycle, write only what the `openspec-cycle` hard rules allow: `config/agent_backlog.json`, `MEMORY.md`, `log/cycle/**`.
- Save evidence (command output, response bodies, screenshots) under `log/cycle/evidence/<stamp>/`, never under `repos/` or `openspec/`.
- Local hosts only. Never read `.env*`, key files or credentials, and never send them to Jev.
- Reproduce a defect twice, from a clean start, before recording it. Not reproducible: `needs_triage` with the evidence.

## Verify integrated changes

For each change listed under "Integrated changes":

1. Read its archived `proposal.md` (`openspec/changes/archive/<date>-<change>/`) and every requirement it added or modified in `openspec/specs/<capability>/spec.md`, with all their scenarios.
2. Read the child commits behind it: `git -C repos/<repo> show --stat <sha>`, then the relevant hunks. Find the test that asserts each scenario's THEN clause. A scenario without a test that asserts it is a finding.
3. Run the gates of the touched repositories: `bash bin/run_gates.sh --repo <repo>`.
4. When a THEN clause must be compared with observed behavior (a status code, a response body, a stored value, a log line, a rendered element), reproduce the WHEN, preferably with the skills in `qa.skills`. Save the output, then ask Jev whether it satisfies the clause:
   `jev noul "Does this output satisfy: <THEN clause>?" --true "<what satisfying looks like>" --false "<what not satisfying looks like>" --state-file <output> --model <model> --field noul`.
   Record the probability. "Cannot tell" is a finding for a human, never a pass.
5. Verdict per change: `VERIFIED`, `REGRESSION` (with evidence: steps, expected, actual) or `NOT VERIFIABLE` (say what is missing: a key, an external service, a seed).

## Regression sweep

- Map the files the integrated changes touched to the behavior that uses them: handlers to their routes, models to their forms and endpoints, jobs to their triggers. Exercise those paths, not only the new ones.
- Once per cycle in which anything was integrated, run every gate: `bash bin/run_gates.sh --all`. Compare the failures with `test_baseline` in `state.json`: a failure that is not in the baseline is a regression. Update the baseline.

## Explore one area

Spend at least `exploration.minutes` on the area the cycle picked. Look for:
- unhandled errors and stack traces in logs;
- missing validation, missing authorization, and records of one tenant or user reachable from another;
- requirements in `openspec/specs/` that the code does not implement, and behavior the code has that no requirement describes (drift);
- missing tests for existing requirements;
- slow queries and requests;
- confusing or broken flows, missing translations and accessibility basics (labels, headings, focus), when the application has a user interface and `qa.skills` can reach it.

## Record a finding

1. Check for duplicates first: `openspec list --json` (active changes), `config/agent_backlog.json`, and `openspec/changes/archive/`. Already tracked: add the new evidence to the report instead.
2. Draft the backlog item:
   `{"change_name": "<kebab-case>", "priority": "<urgency>", "impact_score": <actionable_impact>, "description": "<why, evidence, reproduction steps, acceptance hints>", "depends_on": [...], "locks": [...]}`.
   A regression is named `fix-<short-name>` and is `critical`. Write the description for the PLAN agent that will turn it into a proposal: what is wrong, where, how to reproduce it, and what correct looks like.
3. Evaluate the draft: `jev eval -f templates/jev/task_priority.yaml --state-file <draft.json> --model <model> -o json`. Queue it only when `actionable_impact >= 0.7` and `urgency` is not `cannot_tell`; set `priority` to `urgency.choice` and `impact_score` to `actionable_impact.noul`. Otherwise keep it in `needs_triage` and in the report.
4. Append it to `config/agent_backlog.json`, which must stay valid JSON. Never create a change directory: the dispatcher's PLAN phase does that.
