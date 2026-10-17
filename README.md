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
- `config/agents.yaml` lists the AI agents the project uses and the one that runs each role: `plan` (specifies each item), `build` (implements it) and `cycle` (reviews the work). The scripts read it.
- `ROADMAP.md` lists the features to build, in priority order; the cycle proposes the next ones as it goes.
- An hourly cycle verifies what was integrated, looks for defects and improvements, queues new work and curates `MEMORY.md`, the project's long-term memory. It runs headless: schedule `bash bin/run_cycle.sh --detach` with crontab, or with an agent app using the `references/routine-prompt.md` of the `openspec-kit-cycle` skill as the prompt. A visual QA session tests the application in a browser: schedule it in the Claude or Hermes app with the `references/routine-prompt.md` of the `openspec-kit-visual-qa` skill. The skills explain how to operate both.
- `bash bin/cycle_status.sh` shows the state of the pipeline at any time.

The orchestration kit lives in `bin/`, `config/templates/` and the `openspec-kit-*` skills of `.agents/skills/` (copied into the other agents' skills directories), and `.openspec-kit.lock` records its version. Do not edit those files here: an upgrade replaces them.
