# Scheduling the cycle and the visual QA session

Two scheduled jobs keep an application moving. Both run from the application's root, the directory that holds `bin/run_cycle.sh` (called `/path/to/xyz` below).

| Job | Runs | Needs | Schedule it with |
| :--- | :--- | :--- | :--- |
| **Cycle**, hourly | `bash bin/run_cycle.sh --detach`: preflight, merge, sync, the headless judgment (the `cycle` agent of `config/agents.yaml`), proposals, record, dispatch | A shell. The script starts the agents itself | **crontab** or launchd (recommended), or a task of the Claude or Hermes app |
| **Visual QA session**, every 1 to 3 hours | `bash bin/visual_qa.sh begin`, the agent tests the application in a browser, `bash bin/visual_qa.sh end` | An agent app that can drive a browser, open, on a computer that is awake | A task of the Claude app or of Hermes. Not crontab: a headless agent has no browser |

## Where the prompts are

| Prompt | Path in the application | Who uses it |
| :--- | :--- | :--- |
| Cycle task | `.agents/skills/openspec-kit-cycle/references/routine-prompt.md` | A Claude or Hermes app task that runs the cycle. **crontab needs no prompt**: it runs the script directly |
| Visual QA task | `.agents/skills/openspec-kit-visual-qa/references/routine-prompt.md` | The Claude or Hermes app task of the visual QA session |
| The judgment's own prompt | `config/prompts/cycle.md` (the application's to edit), plus "This cycle", rendered into `log/cycle/prompt-<stamp>.md` | `bin/run_cycle.sh`, for the headless judgment agent. **Never schedule it**: the script writes it each cycle |

The same files are in the skills directory of every selected agent (`.claude/skills/`, `.github/skills/`, ...). Copy the prompts as they are and never add settings to them, nor to a crontab line: the scripts read every setting from `config/` (`config/agents.yaml`, `config/pipeline.yaml`, `config/cycle.yaml`, `config/exploration.yaml`, `config/jev_policy.yaml`).

## Before you schedule

1. Install the kit, set the application up and commit it ([INSTALL.md](INSTALL.md)); `ruby bin/app_setup.rb status` must have nothing left but the schedules, and prints this application's crontab line.
2. Check the application's base branch, `base_branch` in `config/pipeline.yaml` (`master` by default). If it is another one, set it and commit:
   ```bash
   ruby bin/kit_config.rb set pipeline.base_branch main
   ```
3. Run the preflight; it must end with `preflight: OK`:
   ```bash
   bash bin/check_ai_engines.sh
   ```
4. Run one cycle by hand and watch it, then look at the state:
   ```bash
   bash bin/run_cycle.sh
   bash bin/cycle_status.sh
   ```
5. Check `roles.cycle` in `config/agents.yaml` (who judges) and `visual_qa.enabled` in `config/cycle.yaml` (on by default): `ruby bin/kit_config.rb show`.

## 1. The cycle with crontab (recommended)

1. Open your crontab:
   ```bash
   crontab -e
   ```
2. Add one line (every hour, at minute 0):
   ```text
   0 * * * * cd /path/to/xyz && mkdir -p log/cycle && /bin/bash bin/run_cycle.sh --detach >> log/cycle/cron.log 2>&1
   ```
3. Save, then check that it is there:
   ```bash
   crontab -l
   ```
4. After the next full hour, check that it fired:
   ```bash
   tail -n 5 log/cycle/cron.log      # cycle: started pid=<pid> log=log/cycle/cycle-<stamp>.log
   bash bin/cycle_status.sh
   ```

Notes:
- The script fixes `PATH` itself (`OPENSPEC_PATH_PREFIX`, default `/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin`) and runs without a locale, so cron's minimal environment is enough. Each agent CLI must already be logged in for your user.
- `ruby bin/app_setup.rb status` prints this line with the application's real path.
- `--detach` returns at once; the cycle runs in its own session and writes `log/cycle/cycle-<stamp>.log`. A cycle that fires while another one judges prints `cycle: already running` and exits.
- **macOS**: if the application lives under `~/Documents`, `~/Desktop`, `~/Downloads` or iCloud Drive, give `/usr/sbin/cron` **Full Disk Access** (System Settings › Privacy & Security). Cron does not run while the computer sleeps.

### Alternative on macOS: launchd

launchd runs a job missed during sleep at wake-up. Save as `~/Library/LaunchAgents/com.example.xyz.cycle.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.example.xyz.cycle</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string><string>-c</string>
    <string>cd /path/to/xyz &amp;&amp; mkdir -p log/cycle &amp;&amp; /bin/bash bin/run_cycle.sh --detach &gt;&gt; log/cycle/cron.log 2&gt;&amp;1</string>
  </array>
  <key>StartCalendarInterval</key><dict><key>Minute</key><integer>0</integer></dict>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.example.xyz.cycle.plist     # start
launchctl unload ~/Library/LaunchAgents/com.example.xyz.cycle.plist   # stop
```

## 2. The cycle from an agent app (alternative)

Use this when you prefer the app's scheduler to crontab. The app's agent only runs the script and ends; the script then starts the judgment agent of `roles.cycle` itself.

### Claude app (desktop)

1. Open the application's folder as a project in the Code tab.
2. Create a scheduled task in that project (Scheduled tasks › New task, or ask Claude in that project to create one):
   - **Schedule**: every hour, cron `0 * * * *` (local time).
   - **Prompt**: the full text of `.agents/skills/openspec-kit-cycle/references/routine-prompt.md`.
3. Create it from a session in Auto or Bypass permission mode, or allow `Bash(bash bin/run_cycle.sh *)` for the project: a run that waits for a permission prompt never starts the cycle.
4. Tasks run while the app is open. A task that was due while the app was closed runs at the next launch.

### Hermes

The Hermes gateway runs its scheduler; check it with `hermes cron status` (install the service once with `hermes gateway install`).

Option A, no model call: Hermes runs a script on schedule.

1. Create `~/.hermes/scripts/xyz-cycle.sh`:
   ```bash
   #!/usr/bin/env bash
   cd /path/to/xyz && mkdir -p log/cycle && bash bin/run_cycle.sh --detach
   ```
2. Schedule it:
   ```bash
   hermes cron create "0 * * * *" --name xyz-cycle --script ~/.hermes/scripts/xyz-cycle.sh --no-agent --deliver local
   ```

Option B, with an agent turn and the routine prompt:

```bash
cd /path/to/xyz
hermes cron create "0 * * * *" "$(cat .agents/skills/openspec-kit-cycle/references/routine-prompt.md)" \
  --name xyz-cycle --workdir /path/to/xyz --deliver local
```

### OpenCode

OpenCode has no scheduler of its own. Use crontab (section 1). If `roles.cycle` is `opencode`, the script calls `opencode run` for the judgment by itself.

### Google Antigravity (`agy`)

Antigravity's CLI has no scheduler of its own. Use crontab (section 1). If `roles.cycle` is `agy`, the script calls `agy -p` for the judgment by itself.

### Kilo Code (`kilo`)

Kilo's CLI has no scheduler of its own. Use crontab (section 1). If `roles.cycle` names `kilo`, the script calls `kilo run --agent code` for the judgment by itself.

### Cline (`cline`)

Use crontab (section 1): the cycle's task only runs a script, which needs no agent turn. If `roles.cycle` names `cline`, the script calls `cline --yolo` for the judgment by itself. Authenticate the provider first (`cline auth`): a run without saved credentials fails at once instead of opening a browser.

### pi (`pi`) and oh-my-pi (`omp`)

Neither has a scheduler. Use crontab (section 1). If `roles.cycle` names `pi` or `omp`, the script calls `pi -p` or `omp -p` for the judgment by itself. Sign in once in a terminal (`/login` in pi, `omp login`) or export the provider's API key where the scheduler runs.

### Crush (`crush`)

Crush has no scheduler of its own. Use crontab (section 1). If `roles.cycle` names `crush`, the script calls `crush run` for the judgment by itself. Configure a provider once in an interactive `crush` session (or export its API key where the scheduler runs).

## 3. The visual QA session

The agent app must be open, logged in and able to drive a browser, on a computer that is awake. Checks wait in the queue (`log/cycle/visual_queue.json`) while it is not.

### Claude app (desktop)

1. In the application's project, create a scheduled task:
   - **Schedule**: every 2 hours, cron `0 */2 * * *` (or `0 9-18/2 * * 1-5`, working hours only).
   - **Prompt**: the full text of `.agents/skills/openspec-kit-visual-qa/references/routine-prompt.md`.
2. Give Claude a browser: the app's built-in browser, or Claude in Chrome.
3. Create the task from a session in Auto or Bypass permission mode, or allow these commands for the project: `Bash(bash bin/visual_qa.sh *)`, `Bash(ruby bin/visual_qa.rb *)`, `Bash(bash bin/repo_exec.sh *)`, `Bash(ruby bin/proposals.rb *)`.

### Hermes

Enable Hermes's browser tools first, then:

```bash
cd /path/to/xyz
hermes cron create "0 */2 * * *" "$(cat .agents/skills/openspec-kit-visual-qa/references/routine-prompt.md)" \
  --name xyz-visual-qa --workdir /path/to/xyz --skill openspec-kit-visual-qa --deliver local
```

### OpenCode

OpenCode has no scheduler and no browser of its own. It can run the session from crontab only with a browser tool configured as an MCP server (`opencode mcp`); prefer the Claude app or Hermes.

## Check, pause and stop

| To | Do |
| :--- | :--- |
| Know how it is going | Ask your agent (the `openspec-kit-status` skill), or `ruby bin/cycle_progress.rb --since 24h`: what runs now, what was done, what is pending, the roadmap, health and what needs you |
| See the state | `bash bin/cycle_status.sh` (locks, agents, queue, proposals waiting, blocked changes) |
| Read a cycle | `log/cycle/cycle-<stamp>.log`; its report in `log/cycle/reports/`; its prompt in `log/cycle/prompt-<stamp>.md` |
| Read a visual session | `log/cycle/visual-<stamp>.md` (plan), `log/cycle/reports/visual-<stamp>.md` (report), `ruby bin/visual_qa.rb status` |
| Pause everything | `echo "reason" > log/PAUSE`; resume with `rm log/PAUSE` |
| Change a setting | Ask your agent (the `openspec-kit-config` skill), or `ruby bin/kit_config.rb set <file>.<key> <value>`; commit and push it before the next cycle |
| Turn the visual session off | `ruby bin/kit_config.rb set cycle.visual_qa.enabled false` |
| Stop a crontab job | `crontab -e` and delete the line |
| Stop a Hermes job | `hermes cron list`, then `hermes cron pause <job>` or `hermes cron remove <job>` |
| Stop a Claude app task | Disable or delete it in the app's Scheduled tasks |

## Troubleshooting

| You see | Meaning |
| :--- | :--- |
| `cycle: already running (pid N)` | A cycle is still judging; the next run picks up. Normal |
| `dispatch: already running` in a cycle's log | An earlier dispatch is still building; this cycle judged and recorded only. Normal |
| `cycle: paused (<reason>)` | `log/PAUSE` exists: fix the reason, then `rm log/PAUSE` |
| `preflight: FAIL (...)` | An agent CLI is not logged in, a kit file was edited (`bash bin/install.sh verify`), or a tool is missing |
| `visual-qa: a cycle is judging` | The visual session starts at its next run. Normal |
| `visual-qa: disabled` | `visual_qa.enabled` is not `true` in `config/cycle.yaml` |
| `scope violation` in `log/PAUSE` | A file besides `MEMORY.md`, `memory/`, the backlog and the proposals was uncommitted while a cycle or visual session ran (often a setting edited by hand): commit it, then `rm log/PAUSE` |
| `couldn't find remote ref master` in a cycle's log | `base_branch` in `config/pipeline.yaml` is not the application's branch: `ruby bin/kit_config.rb set pipeline.base_branch <branch>`, commit, push |
| Nothing in `log/cycle/cron.log` | cron does not fire: check `crontab -l`, Full Disk Access on macOS, and the path in the line |
