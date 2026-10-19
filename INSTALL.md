# Installing the OpenSpec orchestration kit

The kit lets AI agents specify, build, verify and integrate an application with [OpenSpec](https://openspec.dev). It is installed from a release of this repository into the application's umbrella repository (called `xyz` below), which holds the specifications, the configuration and the application's code as child repositories under `repos/`.

## 1. Requirements

| Tool | Why | Install (macOS) |
| :--- | :--- | :--- |
| git | Everything is git: worktrees, submodules, the merger's pushes | `xcode-select --install` |
| Ruby ≥ 3.1 | The dispatcher, the merger and the installer | `brew install ruby` |
| OpenSpec CLI (verified 1.14.1) | Specifications, validation, archive | `brew install openspec` |
| At least one agent CLI, logged in | Claude Code (`claude`), Codex (`codex`), GitHub Copilot (`copilot`), Hermes (`hermes`), OpenCode (`opencode`), Google Antigravity (`agy`), Kilo Code (`kilo`: `npm install -g @kilocode/cli`), Cline (`cline`: `npm install -g cline`, then `cline auth`), pi (`pi`: `curl -fsSL https://pi.dev/install.sh | sh`, then `/login` inside it or a provider's API key), oh-my-pi (`omp`: `brew install omp`, then `omp login`), Crush (`crush`: `brew install charmbracelet/tap/crush`, then a provider in its first interactive run or `crush login`) | Their own installers |
| GNU timeout (recommended) | Bounds every agent call | `brew install coreutils` |
| The version managers your repositories use | A repository's `env_script` loads the version it pins: rbenv or RVM, nvm or fnm, pyenv, goenv (`.go-version`), mise or asdf | `brew install goenv`, ... |
| Jev (optional) | A calibrated judge for plans, failures and repairs, test coverage, risk and proposals | `brew install shaharia-lab/tap/jev`, then `jev auth login` |

## 2. Get a release

```bash
git clone --branch v<version> <release-repository-url> openspec-kit    # the latest tag, for example v2.5.0
```

A release holds `bin/` (the scripts, `bin/install.sh` included), `config/` (the templates and the default settings, `agents.yaml` among them: the install writes the agents and roles you select into it), `skills/` (the kit's skills, installed per agent), `MANIFEST.json` and the placeholder files of a new application.

## 3. Install into the application

```bash
openspec-kit/bin/install.sh init ../xyz --agents claude,hermes --plan claude --build claude --cycle hermes
```

- `--agents`: the agent CLIs the application uses: `claude`, `codex`, `copilot`, `hermes`, `opencode`, `agy` (Google Antigravity), `kilo` (Kilo Code), `cline` (Cline), `pi` (pi), `omp` (oh-my-pi), `crush` (Crush).
- `--plan`, `--build`, `--cycle`: the agents of each role. **Plan** writes the OpenSpec artifacts of each backlog item, **build** implements them, **cycle** runs the scheduled judgment (verification, exploration, triage, memory). A role is one agent (`--cycle hermes`) or several in order of preference (`--build claude,hermes`): an agent that fails (out of quota, not logged in, timed out) is tried again `limits.agent_retries` times (`config/pipeline.yaml`; never after a usage limit, which lasts hours), then the next one runs and continues from what the failed attempts left, told about it in its prompt. A role only falls back to the agents you list. When every agent of a role fails without changing anything, the change is deferred, not blocked: it runs again in the next dispatch, once the preflight finds an agent working. With one agent it takes every role and nothing is asked; with more, a role you leave out is asked on a terminal.
- `--order fallback|random|spread`: `order` in `config/agents.yaml` says where each call starts: `fallback` (the default) always starts with the role's first agent; `random` starts with any of them, then tries the others in the order listed, so the calls spread over the agents' quotas instead of draining the first one's. With `claude,opencode,hermes,kilo`, a random call may start with opencode and fall back to claude, hermes and kilo. Each call draws on its own, so calls that run at once can land on the same agent. `spread` draws only among the agents the fewest running calls use: with three changes building at once and four agents, the three go to three different agents (the agent each call runs is registered in `log/agents_in_use/` until it ends; `bash bin/cycle_status.sh` shows them). Change it later with `ruby bin/kit_config.rb set agents.order spread`.
- The target may be a new directory or an existing repository. The install refuses a target that already has the kit (use `upgrade`) and kit files that already exist with other content (unless `--force`).

What it creates in `xyz`:

```text
xyz/
├── bin/                     the kit's scripts (replaced on upgrade)
├── config/
│   ├── templates/           the kit's authoring rules, Jev questions, repo.yaml and repo_env.sh (replaced on upgrade)
│   ├── prompts/             the agents' prompts: plan.md, build.md, cycle.md (yours to edit)
│   ├── agents.yaml          the agents, each role's agents in order (fallbacks), the agents' permissions
│   ├── pipeline.yaml        the base branch, how many changes build at once, the limits of agent calls and gates
│   ├── cycle.yaml           the cycle's settings: budget, roadmap, proposal approval, visual QA
│   ├── exploration.yaml     the exploration strategies the cycle rotates through
│   ├── jev_policy.yaml      the Jev gates and thresholds
│   ├── agent_backlog.json   the work queue
│   └── agent_proposals.json proposals waiting for approval
├── .agents/skills/          the kit's skills and OpenSpec's, for every agent
├── .claude/skills/ ...      a copy for each other selected agent
├── openspec/                specifications (created by `openspec init`)
├── README.md  ROADMAP.md    placeholders to fill in
├── AGENTS.md  CLAUDE.md     the guide every agent reads; fill in its project conventions
├── MEMORY.md                long-term memory every agent reads first
├── memory/                  lessons of one repository or capability, created by the cycle when needed
├── INSTALL.md  SCHEDULING.md
├── .gitignore  log/.keep    runtime state stays out of git; log/ is kept by its .keep
└── .openspec-kit.lock       the installed release and the checksum of every kit file
```

`bin/`, `config/templates/`, the `openspec-kit-*` skills, `INSTALL.md` and `SCHEDULING.md` belong to the kit: never edit them in the application, an upgrade replaces them and the preflight fails while they differ. Everything else in `config/`, `README.md`, `ROADMAP.md`, `MEMORY.md` and `memory/` belongs to the application.

### The skills

| Skill | Used by | For |
| :--- | :--- | :--- |
| `openspec-kit-cycle` | The scheduled cycle's judgment agent | Verify, triage, explore, queue, propose, curate memory, report |
| `openspec-kit-qa` | The cycle and the visual QA session | How to verify integrated changes and record findings |
| `openspec-kit-visual-qa` | The visual QA session in an agent app | Test the running application in a browser |
| `openspec-kit-status` | Any agent you ask "how is it going?" | Report what runs, what was done and what needs you, from `bin/cycle_progress.rb` |
| `openspec-kit-init` | Any agent you ask to set the application up | Describe the project, add the child repositories with their `repo.config.yaml` and environment script, check, commit, schedule; from `bin/app_setup.rb` |
| `openspec-kit-config` | Any agent you ask about a setting | Explain every setting and change one safely, from `bin/kit_config.rb` |
| `openspec-propose`, `openspec-apply-change`, ... | The plan and build agents | OpenSpec's own workflows, generated by `openspec init` |

They go to `.agents/skills/`, the skills directory agents share, and a copy goes to the directory of each other selected agent (`.claude/skills/`, `.github/skills/`, `.hermes/skills/`, `.opencode/skills/`, `.kilocode/skills/`, `.cline/skills/`, `.pi/skills/`, `.omp/skills/`, `.crush/skills/`); Codex and Antigravity read `.agents/skills/` itself. To add or remove an agent later, see section 9.

## 4. Make it yours

Ask your agent to set the application up: the `openspec-kit-init` skill walks through this section and the next three with you. Or do it yourself; this command lists what is left at any point, with the command or file that resolves each item and this application's crontab line:

```bash
ruby bin/app_setup.rb status
```

1. Fill the `{{...}}` placeholders of `README.md`, `ROADMAP.md` and the project conventions at the end of `AGENTS.md`, the guide every agent reads (`CLAUDE.md` points Claude Code at it). The roadmap lists the features to build, in priority order; the cycle proposes the next ones.
2. Describe the project in `openspec/config.yaml` (context and rules for the agents).
3. Review the settings: `ruby bin/kit_config.rb show` explains each one (its value, its default, the script that reads it), and `ruby bin/kit_config.rb check` validates them; the `openspec-kit-config` skill changes them for you. Review `config/cycle.yaml` (time budget, roadmap caps, `proposals.approval`: `jev`, `human` or `auto`, `visual_qa`) and `config/exploration.yaml` (replace the generic strategies with your own screens, flows and paths).
4. Set the application's base branch in `config/pipeline.yaml` if it is not `master` (`ruby bin/kit_config.rb set pipeline.base_branch main`), and, there too, how many changes build at once and the limits of agent calls and gates.
5. Adjust the agents' prompts if you want: `config/prompts/plan.md` (the agent that specifies each change), `build.md` (the one that implements it) and `cycle.md` (the hourly judgment) are this application's. Each starts with a comment naming the `{{placeholders}}` the scripts fill; `ruby bin/kit_config.rb show prompts` lists them, `check` catches a broken one, and `ruby bin/lib/prompts.rb render plan change=demo goal="Add a demo"` shows what an agent would get. Commit them like a setting. An upgrade never replaces them: a changed template arrives as `<file>.new`. Once the pipeline runs, the cycle may propose an edit of a prompt when its evidence (repair rounds that keep failing the same way) argues for one: read it with `ruby bin/proposals.rb show <change>`, then `approve` or `reject` it; the next cycle applies and records it, and `ruby bin/prompt_report.rb` compares how each version of a prompt did.
6. Choose the agents' permissions in `config/agents.yaml`: `all` (default) lets agents run any command except the git commands only the scripts run; `restricted` keeps Claude Code on an allowlist.
7. With Jev: keep `config/jev_policy.yaml` in `advisory` mode until you have read its answers (`ruby bin/jev_report.rb` puts each gate's answers beside what happened to each change), and calibrate it with `bash bin/jev_contract.sh --live`.

## 5. Add the application's repositories

Each child repository is a git submodule under `repos/`, with a `repo.config.yaml` from the kit's template:

```bash
cd xyz
ruby bin/app_setup.rb add-repo <backend-repository-url> --name backend    # or: ruby bin/app_setup.rb repo backend, for one already there
```

It adds the submodule on the repository's default branch (`--branch` to choose). It writes `repos/backend/repo.config.yaml` from `config/templates/repo.yaml` with the stack, the `kind` (`web` or `cli`), the base branch, the dev command and the gates it detects (`package.json`, `Gemfile`, `pyproject.toml`, `go.mod`, `Cargo.toml`). A Go module is a web server when it uses gin, echo, chi, fiber, gorilla/mux or `net/http`'s server, and a terminal program otherwise. When the repository pins a toolchain (`.ruby-version`, `.nvmrc`, `.python-version`, `.go-version` for goenv, `.tool-versions`, ...), it also copies `config/templates/repo_env.sh` to `repos/backend/script/env.sh` and sets `env_script` to it. What it cannot tell stays a `{{...}}` placeholder, which the gates skip.

By hand, the same is:

```bash
git submodule add -b main <backend-repository-url> repos/backend
cp config/templates/repo.yaml repos/backend/repo.config.yaml
mkdir -p repos/backend/script && cp config/templates/repo_env.sh repos/backend/script/env.sh
# then set   env_script: "script/env.sh"   in repos/backend/repo.config.yaml
```

Review `repos/backend/repo.config.yaml`: `base_branch`, the dev command and the gates (setup, lint, typecheck, test, build) must be right, and every gate must pass on the base branch today. Two things matter because changes build in parallel:

- **Gates in two levels.** `gates` run after every BUILD and again at merge, so keep them fast. Each command sees `OPENSPEC_CHANGED_FILES`, the repository's changed files, so `test` can run only the related tests. `regression.test` holds the full suite, which the cycle runs once per cycle.
- **A test database and a port per worker.** Each worker's commands see `OPENSPEC_SLOT`, and the `repo_env.sh` template turns it into `TEST_ENV_NUMBER` and `PORT`. Make the test database name use it (Rails: `database: app_test<%= ENV['TEST_ENV_NUMBER'] %>` in `config/database.yml`), and let a `setup` gate create it (`RAILS_ENV=test bin/rails db:prepare`). Two changes must never run their tests against one database.

Check them through the kit, then commit both files inside the child repository and push them to its base branch:

```bash
bash bin/repo_exec.sh backend bundle exec rspec      # any command, in the repository's environment
bash bin/run_gates.sh --repo backend                 # its gates
git -C repos/backend add repo.config.yaml script/env.sh && git -C repos/backend commit -m "chore: OpenSpec kit settings"
git -C repos/backend push origin main
```

## 6. Commit and publish the umbrella

```bash
git add -A && git commit -m "chore: install the OpenSpec kit"
git push origin <base-branch>
```

The merger publishes to the base branches from now on.

## 7. Check the installation

```bash
bash bin/install.sh verify        # kit files match .openspec-kit.lock
ruby bin/kit_config.rb check      # the settings are valid; nothing would stop the next cycle
ruby bin/app_setup.rb status      # nothing left to set up
bash bin/check_ai_engines.sh      # toolchain, kit, a live ping of each selected agent, Jev; ends with preflight: OK
bash bin/cycle_status.sh          # locks, agents and roles, queues
ruby bin/cycle_progress.rb        # how it is going: now, the last 24 hours, pending, roadmap, health
```

## 8. Run work and schedule

- Queue work in `config/agent_backlog.json` (`change_name`, `priority`, `description`), then run it once by hand:
  ```bash
  ruby bin/openspec_dispatcher.rb
  ruby bin/openspec_merger.rb
  ```
- Schedule the hourly cycle (crontab) and the visual QA session (Claude app or Hermes): [SCHEDULING.md](SCHEDULING.md).

## 9. Upgrade, change agents

From a checkout of the new release tag:

```bash
git -C openspec-kit fetch --tags && git -C openspec-kit checkout v<new>
openspec-kit/bin/install.sh upgrade ../xyz                                   # move to the new release
openspec-kit/bin/install.sh upgrade ../xyz --agents claude,copilot --cycle copilot   # or change the agents
```

The upgrade refuses while the dispatcher or the merger runs, with uncommitted changes, or with kit files edited in place (`--force` discards those edits). It works on a branch `kit-upgrade-v<version>` (or `kit-agents-<agents>`): it replaces the kit, installs or removes skills per agent, writes `<file>.new` next to every setting whose template changed, and commits. Review the branch, merge what you need from the `.new` files, delete them and merge.

A role, the order or the permissions can also be changed in `config/agents.yaml`, for example `ruby bin/kit_config.rb set agents.roles.cycle claude,hermes` (claude first, hermes when claude fails) or `ruby bin/kit_config.rb set agents.order spread` (any free agent of the role first, so calls that run at once use different agents and their quotas); the scripts read it on every run.

## 10. Troubleshooting

| Symptom | Fix |
| :--- | :--- |
| `install.sh: ... is not a release (no MANIFEST.json)` | Run `init` and `upgrade` from a checkout of a release, not from inside the application |
| `--plan is required with more than one agent` | Give `--plan`, `--build` and `--cycle`, or run the install on a terminal to be asked |
| `kit: DRIFT ...` in the preflight | A kit file was edited: restore it (`upgrade --force`) or move the change into the framework |
| `preflight: FAIL (no engine of a role is working: ...)` | Every agent in that role's list failed its ping: log one in, or add a working agent to the role in `config/agents.yaml`. A `WARN` for a role only means one of its fallbacks is down. Over a usage limit, the cycles resume by themselves once it resets |
| `DEFERRED: <change>` in `bin/cycle_status.sh` | No agent of its role could work (usage limit, logged out, offline): it runs again in the next dispatch. The third time in a row it is blocked as `engine_unavailable` and `log/PAUSE` is written: read `log/workers/<change>.log` |
| `repo_exec: env_script ... does not exist` | Commit the script in the child repository, or clear `env_script` |
| `cycle: ... the agent wrote outside its scope` and `log/PAUSE` | Something besides `MEMORY.md`, `memory/`, the backlog and the proposals was uncommitted while a cycle judged (often a setting edited by hand): commit it, then `rm log/PAUSE` |
| `kit_config: ... must be one of off, advisory, enforce` | YAML reads a bare `off` as false: write `"off"`, or use `ruby bin/kit_config.rb set` |
| A change stuck in `log/blocked/<change>.json` | Read its `reason`. `bash bin/cycle_status.sh` says on its `BLOCKED` line whether the dispatcher retries it by itself: `retry 1 of 1 at <time>` for a reason that can heal on its own (a failing gate, a rejected push, a stale manifest...), once it has waited `dispatch.blocked_retry_hours`, up to `dispatch.blocked_retries` times (`config/pipeline.yaml`; 0 turns retries off); `no retries left` or `never retried: needs a person` otherwise. The `openspec-kit-cycle` skill explains how to unblock, approve or abandon it To fix it yourself, edit inside `.worktrees/worker-<change>` (the code in its `repos/<name>`, on `feat/spec-<change>`); you may leave the fix uncommitted, the dispatcher commits it when the change resumes. Then delete the record |
