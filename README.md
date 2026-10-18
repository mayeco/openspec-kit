# {{PROJECT_NAME}}

{{PROJECT_DESCRIPTION}}

## Repositories

| Path                  | Purpose          | Base branch       |
| :-------------------- | :--------------- | :---------------- |
| `repos/{{REPO_NAME}}` | {{REPO_PURPOSE}} | `{{BASE_BRANCH}}` |

## Getting started

{{GETTING_STARTED}}

## How this project is developed

Changes are specified with [OpenSpec](https://openspec.dev) and built by AI agents:

- Behavior lives in `openspec/specs/`. Each change is proposed, specified, built and archived under `openspec/changes/`.
- Work is queued in `config/agent_backlog.json`. `ruby bin/openspec_dispatcher.rb` plans and builds each item in an isolated worktree, and `ruby bin/openspec_merger.rb` integrates it once the quality gates pass. Each repository declares its gates in `repos/<name>/repo.config.yaml`, and optionally an `env_script` that prepares its toolchain; `bash bin/run_gates.sh` runs the gates, and `bash bin/repo_exec.sh repos/<name> <command>` runs any other command of a repository in its environment.
- `config/agents.yaml` lists the AI agents the project uses and, in order of preference, the ones that run each role (the next runs when one fails): `plan` (specifies each item), `build` (implements it) and `cycle` (reviews the work). With `order: random` each call starts with any agent of its role instead, so the work spreads over the agents' quotas. The scripts read it.
- `ROADMAP.md` lists the features to build, in priority order; the cycle proposes the next ones as it goes.
- An hourly cycle verifies what was integrated, looks for defects and improvements, queues new work and curates `MEMORY.md`, the project's long-term memory. It runs headless, from crontab; a visual QA session in the Claude or Hermes app tests the application in a browser. [SCHEDULING.md](SCHEDULING.md) sets both up, step by step.
- `bash bin/cycle_status.sh` shows the state of the pipeline at any time, and `ruby bin/cycle_progress.rb --since 24h` how it is going; or ask your agent, which uses the `openspec-kit-status` skill.
- `ruby bin/kit_config.rb show` explains every setting, `ruby bin/kit_config.rb check` validates them, and the `openspec-kit-config` skill changes them; `ruby bin/app_setup.rb status` lists what is left to set up, and the `openspec-kit-init` skill adds a repository.

AI agents read [AGENTS.md](AGENTS.md) first (Claude Code through `CLAUDE.md`): how this repository works, the rules they follow and the project's conventions. The orchestration kit lives in `bin/`, `config/templates/` and the `openspec-kit-*` skills of `.agents/skills/` (copied into the other agents' skills directories), and `.openspec-kit.lock` records its version. Do not edit those files here: an upgrade replaces them. [INSTALL.md](INSTALL.md) covers installing, upgrading and changing the agents.
