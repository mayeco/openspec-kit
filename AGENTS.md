# AGENTS.md

Guide for any AI agent working in this repository: Claude Code, Codex, GitHub Copilot, Hermes, OpenCode, Google Antigravity, whether a person drives it or the pipeline runs it. Read `MEMORY.md` next: it holds the conventions and lessons learned here. `README.md` describes the product and `ROADMAP.md` what comes next.

## 1. What this repository is

The umbrella of the application, built specification first with [OpenSpec](https://openspec.dev) and an orchestration kit that lets AI agents specify, build, verify and integrate it.

```text
.
├── openspec/specs/          canonical behavior: what the application does today
├── openspec/changes/        changes in progress, and archive/ once integrated
├── repos/<name>/            the application's code, one git submodule per repository
│   └── repo.config.yaml     its base branch, gates, regression suite, dev command, env_script
├── config/                  settings the scripts read: agents.yaml, pipeline.yaml, cycle.yaml,
│                            exploration.yaml, jev_policy.yaml; the backlog and the proposals
├── bin/  config/templates/  the kit: scripts and templates (replaced on upgrade)
├── .agents/skills/          the kit's skills (openspec-kit-*) and OpenSpec's
├── MEMORY.md                long-term memory
├── log/  .worktrees/        runtime state (git-ignored)
└── INSTALL.md  SCHEDULING.md  how the kit is installed and scheduled
```

## 2. How the application changes

1. Work is queued in `config/agent_backlog.json` (`change_name`, `priority`, `description`): by a person, by the scheduled cycle when it finds a defect, or from an approved proposal (`config/agent_proposals.json`).
2. `bin/openspec_dispatcher.rb` takes each item into its own worktree (`.worktrees/worker-<change>`, branch `feat/spec-<change>`). A **plan** agent writes the OpenSpec change (`proposal.md`, `specs/`, `design.md`, `tasks.md`) until `openspec validate --strict` passes. A **build** agent then implements the tasks in `repos/`, with tests, until every task is checked and the gates pass. Several changes build at once.
3. `bin/openspec_merger.rb` integrates each finished change: it rebases it, runs the gates again, archives it with `openspec archive` (the only way `openspec/specs/` changes) and pushes.
4. Every hour the cycle (`bin/run_cycle.sh`) verifies what was integrated, explores the application, queues defects, proposes improvements and roadmap features, and curates `MEMORY.md`. A visual QA session in an agent app tests the application in a browser.

Anything that fails is quarantined in `log/blocked/<change>.json` with a reason, and waits for a person; the rest keeps going.

## 3. Rules for every agent

- **Specification first.** Behavior is described in `openspec/specs/`. A change to behavior is an OpenSpec change under `openspec/changes/<change>/`; never edit `openspec/specs/` by hand.
- **Tests prove behavior.** Every behavior change comes with automated tests that assert what its scenarios name.
- **Run a repository's commands in its environment**: `bash bin/repo_exec.sh <name> <command>` (one test file, a linter, a console, the application). It loads the toolchain the repository pins and, when changes build in parallel, its own test database. `bash bin/run_gates.sh` runs the gates of what you changed.
- **Never edit the kit**: `bin/`, `config/templates/`, the `openspec-kit-*` skills, `INSTALL.md`, `SCHEDULING.md`. An upgrade replaces them and the preflight fails while they differ.
- **Never write secrets** into the repository, the backlog, the memory, the reports or a prompt.
- **English** for code, specifications, commits and documentation, unless the project's conventions below say otherwise.

### When the pipeline runs you (plan, build, cycle, visual QA)

Your prompt says which role you have and what you may write. In short:
- Never commit, push, pull, rebase, reset or switch branches: the scripts do.
- Never edit `repos/*/repo.config.yaml`, a repository's `env_script` or CI configuration: the merger blocks it.
- A plan or build agent writes only in `openspec/changes/<its change>/` and `repos/`; it leaves lessons in that change's `handoff.md`, not in `MEMORY.md`.
- The cycle and the visual QA session write only `MEMORY.md`, the backlog and the proposals. Anything else uncommitted pauses the system.
- When a decision needs a person, write the question to `openspec/changes/<change>/.needs-human` and stop.

### When a person drives you

Use the skills; they hold the procedures and call the scripts:

| The person asks | Skill | Script |
| :--- | :--- | :--- |
| To set the application up, or add a repository | `openspec-kit-init` | `ruby bin/app_setup.rb status`, `add-repo`, `repo` |
| What a setting does, or to change one | `openspec-kit-config` | `ruby bin/kit_config.rb show`, `check`, `set` |
| How it is going, what it did, what needs them | `openspec-kit-status` | `ruby bin/cycle_progress.rb`, `bash bin/cycle_status.sh` |
| To unblock, approve, pause or run the cycle | `openspec-kit-cycle` ("Operating the cycle") | `bin/run_cycle.sh`, `bin/proposals.rb` |
| To specify or build a change by hand | `openspec-propose`, `openspec-apply-change` | `openspec` |

Commit, push, approve a proposal or a risky change, or change a setting only when the person asks. A setting must be committed and pushed right away: the next cycle pauses on uncommitted files outside its scope.

## 4. Project conventions

{{PROJECT_CONVENTIONS}}
