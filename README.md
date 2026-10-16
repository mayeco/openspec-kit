# {{PROJECT_NAME}}

{{PROJECT_DESCRIPTION}}

## Repositories

| Path | Purpose | Base branch |
| :--- | :--- | :--- |
| `repos/{{REPO_NAME}}` | {{REPO_PURPOSE}} | `{{BASE_BRANCH}}` |

## Getting started

{{GETTING_STARTED}}

## How this project is developed

Changes are specified with [OpenSpec](https://openspec.dev) and built by AI agents:

- Behavior lives in `openspec/specs/`. Each change is proposed, specified, built and archived under `openspec/changes/`.
- Work is queued in `config/agent_backlog.json`. `ruby bin/openspec_dispatcher.rb` plans and builds each item in an isolated worktree, and `ruby bin/openspec_merger.rb` integrates it once the quality gates pass. Each repository declares its gates in `repos/<name>/repo.config.yaml`; `bash bin/run_gates.sh` runs them.
- An hourly cycle verifies what was integrated, looks for defects and improvements, queues new work and curates `MEMORY.md`, the project's long-term memory. Schedule it in the Claude or Hermes app with `.claude/skills/openspec-cycle/references/routine-prompt.md` as the prompt; the `openspec-cycle` skill explains how to operate it.
- `bash bin/cycle_status.sh` shows the state of the pipeline at any time.

The orchestration kit lives in `bin/`, `templates/`, `config/repo.template.yaml` and the agent skills directories, and `.openspec-kit.lock` records its version. Do not edit those files here: an upgrade replaces them.

## Documentation

See [docs/](docs/README.md).
