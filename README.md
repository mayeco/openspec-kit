# OpenSpec Orchestration Kit

The runtime of the OpenSpec autonomous multi-agent framework: a parallel dispatcher, a single-writer merger, diff-aware quality gates, a calibrated judge (Jev) and a scheduled cycle. An application umbrella installs it, then plans and builds its changes through OpenSpec with any supported agent CLI (Claude Code, Hermes, OpenCode).

This repository is **generated**: every release is built and tested by the framework's workbench. Do not edit it or send changes here: change the workbench and publish a new release. `MANIFEST.json` lists every file with its checksum, the workbench commit it was built from and the toolchain it was verified with.

## Requirements

git ≥ 2.40, Ruby ≥ 3.1, the `openspec` CLI, `jq`, at least one agent CLI, and optionally the `jev` CLI. On macOS, `brew install coreutils` provides `timeout`.

## Start an application

```bash
git clone --branch v<version> <this-repository> openspec-kit
./openspec-kit/install.sh init ../my-app
```

`init` copies the kit and creates the seed files your application then owns:
- **Kit** (replaced on upgrade): `bin/`, `templates/`, `config/repo.template.yaml`, and the skills `openspec-cycle` and `openspec-qa` in `.claude/skills/`, `.hermes/skills/`, `.agents/skills/` and `.opencode/skills/`.
- **Seeds** (yours from then on): `MEMORY.md`, `config/cycle.yaml`, `config/jev_policy.yaml` and `config/agent_backlog.json`.

It also adds `.worktrees/` and `log/` to `.gitignore` and runs `openspec init`, which creates `openspec/config.yaml` for your project. The framework's authoring rules are not in that file: they travel with the kit in `templates/authoring_rules.md`, and the dispatcher adds them to every agent prompt. Finally, `init` records the release in `.openspec-kit.lock`.

Then describe your project in `openspec/config.yaml`, add your child repositories under `repos/` (each with a `repo.config.yaml` based on `config/repo.template.yaml`), and commit.

## Schedule the cycle

Create a task in the Claude app (or the Hermes app) that runs every hour in the application root, with `.claude/skills/openspec-cycle/references/routine-prompt.md` as its prompt. The task only runs `bash bin/run_cycle.sh --detach` and ends. The cycle then works on its own: it merges, verifies, explores, records `MEMORY.md` and the backlog, and dispatches. It keeps its state and reports in `log/cycle/`. The `openspec-cycle` skill explains how to operate it.

## Upgrade

```bash
git -C openspec-kit fetch --tags && git -C openspec-kit checkout v<new-version>
./openspec-kit/install.sh upgrade ../my-app
```

The upgrade runs on a new branch `kit-upgrade-v<version>` and commits there for review. It replaces kit files and removes the ones the release dropped, together with the directories left empty. A seed the release no longer ships is deleted when you never edited it, and kept (and reported) when you did. When a seed template changed, it writes `<file>.new` next to your file instead of overwriting it. It refuses to run while the dispatcher or merger is running, and stops if kit files were edited in place (`--force` discards those edits).

## Verify

`bash bin/check_ai_engines.sh` (the preflight of every cycle) runs `ruby bin/openspec_kit.rb verify`: it fails when a kit file differs from `.openspec-kit.lock`, and warns when an installed tool differs from the release's verified toolchain (`OPENSPEC_STRICT_TOOLCHAIN=1` makes that a failure).

## Documentation

The specification of this release is `docs/DEV_FRK.md` in the workbench at the commit named in `MANIFEST.json` (`source_commit`).
