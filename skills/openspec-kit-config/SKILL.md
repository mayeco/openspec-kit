---
name: openspec-kit-config
description: Explains and changes the settings of an application built with the OpenSpec orchestration kit. Covers the agents, their roles and permissions (config/agents.yaml), the base branch, parallelism and limits (config/pipeline.yaml), and the cycle's budget, roadmap, proposal approval and visual QA (config/cycle.yaml). Also covers the exploration strategies (config/exploration.yaml), the Jev gates (config/jev_policy.yaml), each child repository's repo.config.yaml and the environment overrides. Use when asked what a setting does, how the system is configured or why it behaves a certain way. Also use to change a setting, an agent's role, a strategy, a gate, the approval mode or the visual session.
---

# OpenSpec kit configuration: understand it, change it safely

Paths are relative to the application's root, the directory that holds `bin/kit_config.rb`. That script knows each setting: what it does, its default, and which script reads it and when. Answer from its output, never from memory.

## Understand

1. Show the settings. Add a topic for one area, or `--json` for exact values:
   ```bash
   ruby bin/kit_config.rb show                 # agents, pipeline, cycle, exploration, jev, repos, env
   ruby bin/kit_config.rb show cycle
   ```
2. Check them. It reports invalid values, typos, and what would stop the next cycle:
   ```bash
   ruby bin/kit_config.rb check                # ends with config: OK or config: FAIL
   ```
3. Explain in the person's language, organized by their question rather than by file. For each setting, say:
   - what it changes in the pipeline;
   - its value, and whether that value is the default;
   - when a change takes effect;
   - what changing it would cause.

| The question | The settings |
| :--- | :--- |
| Who plans, builds, judges? | `agents.roles.plan`, `.build`, `.cycle`; the agents themselves: `agents.agents` |
| What may agents run? | `agents.permissions`: `all`, or `restricted` |
| How long does a cycle spend, and on what? | `cycle.qa_time_budget_minutes`, `cycle.exploration.minutes`, the strategies of `config/exploration.yaml` and their `order` |
| How much new work per cycle? | `cycle.exploration.max_new_backlog_items_per_cycle`, `cycle.roadmap.max_new_per_cycle`, `cycle.roadmap.max_open` |
| Who approves proposals? | `cycle.proposals.approval` (`jev`, `human`, `auto`), and with `jev`, `jev.gates.proposal_review.mode` |
| Is there a browser session? | `cycle.visual_qa.enabled`, `.minutes`, `.max_items_per_session`; its schedule (`SCHEDULING.md`) |
| How strict is Jev? | `jev.gates.<gate>.mode` (`off`, `advisory`, `enforce`), the gate's thresholds, `jev.on_unavailable`. What each gate answered, and what `enforce` would have stopped: `ruby bin/jev_report.rb` |
| What runs before a change merges? | The `gates` of each `repos/<name>/repo.config.yaml` (fast: after every BUILD and again at merge); its `regression` commands run once per cycle |
| Which branch? | `pipeline.base_branch` for the application, `base_branch` in each child repository's `repo.config.yaml` |
| How many changes at once, and how long may things take? | `pipeline.dispatch.workers`, `pipeline.dispatch.wait_seconds`, `pipeline.limits.agent_seconds`, `.agent_budget_usd`, `.gate_seconds`, `.lease_seconds` |
| What happens to conflicts and to low items? | `pipeline.dispatch.conflict_rebuilds` (automatic rebuilds on the new base before `rebase_conflict`), `pipeline.dispatch.aging_hours` (one priority up per that many hours waiting) |
| When does it run? | The schedules (`SCHEDULING.md`), not a setting |

## Change

1. **Confirm first.** Tell the person the setting, its old and new value, and the effect. Change it only after they agree.
2. **A plain value** (a number, true or false, a mode, a role, the order, the base branch): use `set`. It keeps the file's comments, writes `"off"` quoted (YAML reads a bare `off` as false), and refuses an invalid value or a role for an agent that is not installed:
   ```bash
   ruby bin/kit_config.rb set cycle.proposals.approval human --dry-run
   ruby bin/kit_config.rb set cycle.proposals.approval human
   ```
3. **A list or a text**: edit the file with your edit tool, keeping its comments and style, then run `ruby bin/kit_config.rb check`. This covers the strategies, Jev's thresholds and `qa.skills`. Never rewrite a YAML file through a YAML library: it drops the comments that document every setting.
   - **Strategy**: `slug` (kebab-case, unique), `name`, `kind` (`defects` go to the backlog; `improvements` and `features` become proposals), `directive` (name the application's own modules, screens, flows and paths, as concretely as you would brief a person), optional `needs: browser` (only the visual session runs it) and `enabled: false`.
   - **Jev threshold or question**: decide it from `ruby bin/jev_report.rb --gate <gate>` (each question's scores against its threshold, and what enforce would have stopped beside what happened). Then run `bash bin/jev_contract.sh` (needs the `jev` CLI). Then run `bash bin/jev_contract.sh --live` to recalibrate against the real model; it costs about 11 calls.
4. **Commit and push it, with the person's OK**: `git add <file> && git commit -m "chore(config): <what>" && git push origin <base-branch>`.
   - The cycle's judgment and the visual session may only leave `MEMORY.md`, the backlog and the proposals uncommitted. When either one finds anything else uncommitted, its scope guard pauses the whole system.
   - So commit right after editing. Edit while `bash bin/cycle_status.sh` shows no cycle judging and no visual session.
   - If the system paused itself this way, commit the change, then `rm log/PAUSE`.
5. **Say when it takes effect**: `set` prints which script reads it. Every script reads its settings on each run, so the next cycle, dispatch or agent call uses the new value.

## What is not changed here

| To change | Do |
| :--- | :--- |
| The agents an application uses | `<release>/bin/install.sh upgrade <app> --agents LIST [--plan A --build A --cycle A]`, from a checkout of the release. It installs or removes their skills, on a branch for review |
| A child repository's gates, dev command, base branch or `env_script` | Edit `repos/<name>/repo.config.yaml` in the child repository, commit there and push to its base branch, then commit the new pointer in the application. The pipeline's agents may never change these files: the merger blocks it. The `openspec-kit-init` skill sets them up |
| An environment variable (`show env`) | Only for one manual run, such as a test or a retry; never in a scheduled prompt or a crontab line. Each setting of `config/pipeline.yaml` has one that overrides it, and `check` warns while one is set |
| `bin/`, `config/templates/`, the `openspec-kit-*` skills, `INSTALL.md`, `SCHEDULING.md` | Never edit them: they are the kit's. An upgrade replaces them, and the preflight fails while they differ. A need there is a change to the framework |
| `<file>.new` next to a setting after an upgrade | The new template. Merge what you need into the file, then delete the `.new` |

## Common changes

| The person wants | Run |
| :--- | :--- |
| To approve every proposal themselves | `set cycle.proposals.approval human` |
| Jev to block risky changes | Read what it answered first, `ruby bin/jev_report.rb --gate change_risk`, then `set jev.gates.change_risk.mode enforce` |
| No browser session | `set cycle.visual_qa.enabled false` |
| Another installed agent to judge | `set agents.roles.cycle codex` |
| Agents limited to an allowlist | `set agents.permissions restricted` |
| Strategies in random order | `set exploration.order random` |
| Shorter cycles | `set cycle.qa_time_budget_minutes 30` |
| The application works on `main` | `set pipeline.base_branch main` |
| More changes built at once | `set pipeline.dispatch.workers 3` |
