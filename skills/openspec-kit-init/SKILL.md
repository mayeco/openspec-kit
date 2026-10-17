---
name: openspec-kit-init
description: Sets up an application right after the OpenSpec orchestration kit was installed into it. It describes the project (README.md, ROADMAP.md, openspec/config.yaml) and adds the application's code repositories as git submodules under repos/. It gives each repository its repo.config.yaml and environment script from the kit's templates, with the stack, base branch, dev command and gates it detects. Then it checks them, prepares the first commit, and leads to the preflight and the schedules. Use when asked to set up, initialize, onboard or configure a new application, to add or configure a child repository, or to say what is still missing before the cycle can run.
---

# OpenSpec kit init: from installed to ready to schedule

The kit is already installed: `.openspec-kit.lock` exists, written by `<release>/bin/install.sh init`. If it does not, follow `INSTALL.md` first. Paths are relative to the application's root.

Work with the person who owns the application. Facts about the project come from them and from the repositories themselves; never invent features, commands or constraints.

## Rules

- Never commit or push without the person's OK.
- Never edit the kit's files: `bin/`, `config/templates/`, the `openspec-kit-*` skills, `INSTALL.md` and `SCHEDULING.md`.
- In a child repository, touch only `repo.config.yaml` and its environment script. Never write secrets in them: both are committed.
- A gate must pass on the repository's base branch today. A gate that always fails blocks every change, and one that is wrong lets broken changes through.

## 1. Where it stands

```bash
ruby bin/app_setup.rb status        # --json for the exact items
```

It lists, in order, what is done (`ok`), what is left (`todo`) with the command or file that resolves it, and warnings (`warn`). It ends with the next step and this application's own crontab line. Work through the `todo` items from the top, and run it again after each step.

## 2. Describe the project

Ask the person, read the repositories, then write:

- **`README.md`**: fill in every `{{...}}`: name, description, one row per repository (path, purpose, base branch), how to get started.
- **`ROADMAP.md`**: the features to build, in priority order, each with the outcome users get and how to tell it works. Take them from the person, never invent them. While `{{...}}` remain, the cycle proposes nothing from the roadmap.
- **`openspec/config.yaml`**: under `context:`, the constraints agents cannot infer from the code: the artifacts' language, platforms, compliance, domain rules. Keep it short.
- Leave `MEMORY.md` as it is: the cycle curates it.

## 3. Add the repositories

For each code repository of the application:

```bash
ruby bin/app_setup.rb add-repo <url> [--name backend] [--branch main]   # a new submodule under repos/
ruby bin/app_setup.rb repo <name>                                       # one already under repos/
```

It delivers the kit's templates:

- **`repos/<name>/repo.config.yaml`**, from `config/templates/repo.yaml`, filled with what it detects: the stack, the base branch, the dev command, the port, the health endpoint, and the lint, typecheck, test and build gates.
- **`script/env.sh`**, from `config/templates/repo_env.sh`, with `env_script` pointing at it, when the repository pins a toolchain (`.ruby-version`, `.nvmrc`, `.node-version`, `.python-version`, `.tool-versions`, `mise.toml`).

An existing `repo.config.yaml` is kept unless `--force`. Then, for each repository:

1. **Review every value with the person.** Fill in each `{{...}}` it could not detect; the gates skip placeholders with a warning. The template also has a `secrets` gate: keep it if `gitleaks` is installed, otherwise install it or remove the gate. In `script/env.sh`, export what the repository's commands need besides the toolchain (never secrets).
2. **Prove it works:**
   ```bash
   bash bin/repo_exec.sh <name> true          # the environment loads
   bash bin/run_gates.sh --repo <name>        # every gate passes
   ```
   When a gate fails on a clean checkout, fix the command, not the application's code, or ask the person.
3. **Commit it in the child repository and push to its base branch**, with the person's OK. `add-repo` and `repo` print the exact commands.

## 4. Review the settings

```bash
ruby bin/kit_config.rb check
```

With the person, and the `openspec-kit-config` skill to explain and change each one, go through:

- **Agents**: the agent of each role and the permissions (`config/agents.yaml`).
- **Pipeline**: the base branch, how many changes build at once, the limits of agent calls and gates (`config/pipeline.yaml`).
- **Approval**: who approves proposals (`proposals.approval`: `jev`, `human` or `auto`).
- **Visual QA**: whether a visual QA session runs (`visual_qa.enabled`).
- **Jev**: its gates stay `advisory` until their answers have been read.
- **Strategies**: replace the generic ones in `config/exploration.yaml` with the application's own modules, screens and flows. `status` flags them while they are still the template's.

## 5. Commit the application

With the person's OK:

```bash
git add -A && git commit -m "chore: set up the OpenSpec kit" && git push origin <base-branch>
```

The application needs an `origin` remote: the merger and the cycle push to it. Its base branch is `base_branch` in `config/pipeline.yaml`, `master` by default; when the checkout is on another branch, `status` says so. Set it before this commit: `ruby bin/kit_config.rb set pipeline.base_branch main`.

## 6. Check and schedule

1. Run the preflight. It must end with `preflight: OK`; otherwise log in the agent CLI it names, or fix what it reports:
   ```bash
   bash bin/check_ai_engines.sh
   ```
2. Optionally, queue one small item in `config/agent_backlog.json` and run it by hand: `ruby bin/openspec_dispatcher.rb`, then `ruby bin/openspec_merger.rb` (`INSTALL.md`, section 8).
3. Run one cycle and watch it: `bash bin/run_cycle.sh`.
4. Schedule the cycle hourly, with the crontab line `status` prints, and the visual QA session in the Claude app or Hermes. `SCHEDULING.md` has every step.

When `status` has no `todo` left, the setup is done. From then on, the `openspec-kit-status` skill tells how the pipeline is going.
