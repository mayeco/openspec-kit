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

`init` copies the kit (`bin/`, `templates/`, `ops/`, `config/repo.template.yaml`) and creates the seed files your application then owns: `openspec/config.yaml`, `config/jev_policy.yaml`, `MEMORY.md`, `memory/cycle_memory.json` and `config/agent_backlog.json`. It also adds `.worktrees/` and `log/` to `.gitignore`, runs `openspec init`, and records the release in `.openspec-kit.lock`.

Then fill the `{{...}}` placeholders in `openspec/config.yaml`, add your child repositories under `repos/` (each with a `repo.config.yaml` based on `config/repo.template.yaml`), and commit.

## Upgrade

```bash
git -C openspec-kit fetch --tags && git -C openspec-kit checkout v<new-version>
./openspec-kit/install.sh upgrade ../my-app
```

The upgrade runs on a new branch `kit-upgrade-v<version>` and commits there for review. It replaces kit files and removes the ones the release dropped. When a seed template changed, it writes `<file>.new` next to your file instead of overwriting it. It refuses to run while the dispatcher or merger is running, and stops if kit files were edited in place (`--force` discards those edits).

## Verify

`bash bin/check_ai_engines.sh` (the preflight of every cycle) runs `ruby bin/openspec_kit.rb verify`: it fails when a kit file differs from `.openspec-kit.lock`, and warns when an installed tool differs from the release's verified toolchain (`OPENSPEC_STRICT_TOOLCHAIN=1` makes that a failure).

## Documentation

The specification of this release is `docs/DEV_FRK.md` in the workbench at the commit named in `MANIFEST.json` (`source_commit`).
