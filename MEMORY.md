# Memory

Curated long-term memory for this workspace. The scheduled cycle is its only writer (`bin/run_cycle.sh`); workers record lessons in `openspec/changes/<change>/handoff.md` instead. Keep only durable, non-obvious facts: conventions, required flags, environment quirks and decisions with their reason. In-flight state, partial diffs and debug output do not belong here.

---

## 1. Project Conventions

- **Topology**: application code lives in child repositories under `repos/`; specifications live only in this umbrella's `openspec/`.
- **Quality gates**: each child repo declares its gates in `repos/<name>/repo.config.yaml`; `bash bin/run_gates.sh` runs the gates of the repos a change touched.
- **Scenarios**: every scenario header uses exactly four hashtags: `#### Scenario: <Name>`.
- **Language**: all specifications, code, comments, documentation and commits are professional English.

---

## 2. Lessons and Environment Quirks

<!-- The scheduled cycle folds the handoff.md lessons of integrated changes here. -->

---

## 3. Decisions

<!-- Decisions that are not visible in the code, each with its reason. -->
