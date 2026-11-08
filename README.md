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
- Work is queued in `config/agent_backlog.json`. `openspec-kit dispatch` plans and builds each item in an isolated worktree, and `openspec-kit merge` integrates it once the quality gates pass. Each repository declares its gates in `repos/<name>/repo.config.yaml`, and optionally an `env_script` that prepares its toolchain; `openspec-kit gates` runs the gates, and `openspec-kit exec repos/<name> <command>` runs any other command of a repository in its environment.
- `config/agents.yaml` lists the AI agents the project uses and, in order of preference, the ones that run each role (the next runs when one fails): `plan` (specifies each item), `build` (implements it) and `cycle` (reviews the work). With `order: random` each call starts with any agent of its role instead, and with `order: spread` with one no other running call is using, so the work spreads over the agents' quotas. The scripts read it.
- `ROADMAP.md` lists the features to build, in priority order; the cycle proposes the next ones as it goes.
- An hourly cycle verifies what was integrated, looks for defects and improvements, queues new work and curates `MEMORY.md`, the project's long-term memory. It runs headless, from crontab; a visual QA session in the Claude or Hermes app tests the application in a browser.
- `openspec-kit status` shows the state of the pipeline at any time, and `openspec-kit progress --since 24h` how it is going; or ask your agent, which uses the `openspec-kit-status` skill.
- `openspec-kit config show` explains every setting, `openspec-kit config check` validates them, and the `openspec-kit-config` skill changes them; `openspec-kit setup status` lists what is left to set up, and the `openspec-kit-init` skill adds a repository.

AI agents read [AGENTS.md](AGENTS.md) first (Claude Code through `CLAUDE.md`): how this repository works, the rules they follow and the project's conventions. The orchestration kit runs through `openspec-kit` (`~/.openspec-kit`) and installs its `openspec-kit-*` skills into `.agents/skills/` (copied into the other agents' skills directories); `.openspec-kit.lock` records its version. Do not edit those skill files here: an upgrade replaces them.
