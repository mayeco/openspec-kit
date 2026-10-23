# frozen_string_literal: true

# ==============================================================================
# bin/lib/portal_ui.rb
#
# Single-page operator interface for bin/portal.rb: Overview & Active Worktrees,
# Changes & Prompts (with per-worker actions), Agents & Message Box, Health
# Check, Backlog/Proposals/Quarantine, Settings & Setup, and the Agentic
# Observatory view of log/.
# ==============================================================================

module OpenSpecPortal
  PORTAL_HTML = <<~'HTML'
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>OpenSpec Kit Portal</title>
      <style>
        :root {
          --bg: #0f172a; --panel: #1e293b; --border: #334155; --text: #f8fafc;
          --muted: #94a3b8; --accent: #38bdf8; --ok: #22c55e; --warn: #f59e0b; --err: #ef4444;
        }
        * { box-sizing: border-box; }
        body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: var(--bg); color: var(--text); font-size: 14px; }
        header { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; padding: 12px 20px; background: #020617; border-bottom: 1px solid var(--border); gap: 10px; }
        header h1 { margin: 0; font-size: 18px; display: flex; align-items: center; gap: 10px; }
        .badge { padding: 3px 8px; border-radius: 999px; font-size: 12px; font-weight: 600; background: var(--border); color: var(--text); display: inline-block; }
        .badge.ok { background: rgba(34,197,94,0.2); color: #4ade80; border: 1px solid #22c55e; }
        .badge.warn { background: rgba(245,158,11,0.2); color: #fbbf24; border: 1px solid #f59e0b; }
        .badge.err { background: rgba(239,68,68,0.2); color: #f87171; border: 1px solid #ef4444; }
        nav { display: flex; flex-wrap: wrap; gap: 6px; padding: 10px 20px; background: var(--panel); border-bottom: 1px solid var(--border); }
        nav button { background: transparent; color: var(--muted); border: 1px solid transparent; padding: 6px 12px; border-radius: 6px; cursor: pointer; font-weight: 600; }
        nav button.active, nav button:hover { color: var(--text); background: rgba(56,189,248,0.12); border-color: var(--accent); }
        main { padding: 20px; max-width: 1440px; margin: 0 auto; }
        .tab { display: none; }
        .tab.active { display: block; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(360px, 1fr)); gap: 16px; margin-bottom: 16px; }
        .card { background: var(--panel); border: 1px solid var(--border); border-radius: 8px; padding: 16px; margin-bottom: 16px; }
        .card h2, .card h3 { margin-top: 0; font-size: 15px; border-bottom: 1px solid var(--border); padding-bottom: 8px; display: flex; justify-content: space-between; align-items: center; gap: 8px; flex-wrap: wrap; }
        button, .btn { background: #2563eb; color: #fff; border: none; padding: 6px 11px; border-radius: 6px; cursor: pointer; font-size: 12px; font-weight: 600; }
        button:hover { opacity: 0.92; }
        button.secondary { background: #475569; }
        button.danger { background: #dc2626; }
        button.success { background: #16a34a; }
        input, select, textarea { background: #0f172a; color: var(--text); border: 1px solid var(--border); border-radius: 6px; padding: 8px 10px; font-size: 13px; width: 100%; font-family: inherit; }
        textarea { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; resize: vertical; }
        pre { background: #020617; border: 1px solid var(--border); border-radius: 6px; padding: 12px; overflow-x: auto; font-size: 12px; line-height: 1.45; color: #e2e8f0; max-height: 440px; white-space: pre-wrap; word-break: break-word; }
        table { width: 100%; border-collapse: collapse; font-size: 13px; }
        th, td { text-align: left; padding: 8px; border-bottom: 1px solid var(--border); vertical-align: top; }
        th { color: var(--muted); font-weight: 600; }
        .row { display: flex; gap: 6px; align-items: center; flex-wrap: wrap; }
        .muted { color: var(--muted); font-size: 12px; }
        .ctx-note { color: var(--muted); font-size: 12px; margin: -4px 0 10px 0; line-height: 1.4; }
        #toast { position: fixed; bottom: 16px; right: 16px; background: #020617; border: 1px solid var(--accent); padding: 10px 14px; border-radius: 8px; display: none; z-index: 50; max-width: 420px; }
      </style>
    </head>
    <body>
      <header>
        <h1>
          <span>OpenSpec Kit Portal</span>
          <span id="app-name" class="badge">loading...</span>
          <span id="pause-badge" class="badge">checking...</span>
        </h1>
        <div class="row">
          <input id="pause-reason" placeholder="Pause reason (optional)" style="width: 200px;" />
          <button id="btn-pause" class="danger" onclick="pauseSystem()">Pause</button>
          <button id="btn-resume" class="success" onclick="resumeSystem()">Resume</button>
          <button id="btn-resume-merge" class="success" onclick="resumeAndMerge()">Resume &amp; Drain Merge Queue</button>
          <button onclick="runCycle()">Run Cycle (--detach)</button>
          <button class="secondary" onclick="refreshAll()">Refresh</button>
        </div>
      </header>
      <nav>
        <button id="nav-overview" class="active" onclick="showTab('overview', this)">Overview &amp; Processes</button>
        <button id="nav-work" onclick="showTab('work', this)">Backlog, Proposals &amp; Blocked</button>
        <button id="nav-changes" onclick="showTab('changes', this)">Changes &amp; Prompts</button>
        <button id="nav-agents" onclick="showTab('agents', this)">Agents &amp; Send Message</button>
        <button id="nav-health" onclick="showTab('health', this)">Health Check</button>
        <button id="nav-config" onclick="showTab('config', this)">Settings &amp; Setup</button>
        <button id="nav-logs" onclick="showTab('logs', this)">Agentic Observatory (log/)</button>
      </nav>
      <main>
        <section id="tab-overview" class="tab active">
          <div class="grid">
            <div class="card">
              <h2>Processes, Locks &amp; Running Agents</h2>
              <div id="processes-box">Loading...</div>
            </div>
            <div class="card">
              <h2>Kit Actions</h2>
              <div class="row" style="margin-bottom:10px;">
                <button onclick="triggerAction('/api/actions/cycle')">Start Cycle</button>
                <button onclick="triggerAction('/api/actions/dispatch')">Run Dispatcher</button>
                <button class="secondary" onclick="dryRunDispatch()">Dispatcher Dry-Run</button>
                <button onclick="triggerAction('/api/actions/merge')">Run Merger</button>
                <button class="secondary" onclick="triggerAction('/api/actions/sync')">Sync Repos</button>
              </div>
              <div class="row" style="margin-bottom:10px;">
                <input id="gate-repo" placeholder="Repo name (blank = --all)" style="width:180px;" />
                <label class="row muted"><input type="checkbox" id="gate-reg" style="width:auto;" /> --regression</label>
                <button onclick="runGates()">Run Gates</button>
              </div>
              <div class="row">
                <button class="secondary" onclick="visualAction('begin')">Visual QA Begin</button>
                <button class="secondary" onclick="visualAction('end')">Visual QA End</button>
                <input id="visual-req" placeholder="Request browser check..." style="width:190px;" />
                <button onclick="visualRequest()">Queue Visual Check</button>
              </div>
              <pre id="action-output" style="margin-top:10px;">Ready.</pre>
            </div>
          </div>
          <div class="card">
            <h2>Active Worktrees &amp; Stalled Workers (.worktrees/worker-*) <button class="secondary" onclick="loadStatus()">Refresh</button></h2>
            <p class="ctx-note">Cross-references every isolated worker worktree with active leases (checking if the PID is alive), ready_to_merge manifests, .needs-human escalations, quarantine records and capability/lock holds.</p>
            <div id="worktrees-box">Loading...</div>
          </div>
          <div class="grid">
            <div class="card">
              <h2>Cycle Progress (24h)</h2>
              <div id="progress-box">Loading...</div>
            </div>
            <div class="card">
              <h2>Instant Snapshot (bin/cycle_status.sh)</h2>
              <pre id="snapshot-box">Loading...</pre>
            </div>
          </div>
        </section>

        <section id="tab-changes" class="tab">
          <div class="grid">
            <div class="card">
              <h2>Changes &amp; Executions <button class="secondary" onclick="loadChanges()">Refresh</button></h2>
              <p class="ctx-note">Click any change to inspect every PLAN / BUILD execution prompt, repair round, OpenSpec artifact and worker log, or run actions on its worktree.</p>
              <div id="changes-list-box">Loading...</div>
            </div>
            <div class="card">
              <h2>Prompt Templates (config/prompts/)</h2>
              <p class="ctx-note">Application-owned prompt seeds filled by bin/lib/prompts.rb on every PLAN, BUILD and cycle call.</p>
              <div id="prompt-templates-box">Loading...</div>
            </div>
          </div>
          <div class="card" id="change-detail-card">
            <h2>Change Execution Detail: <span id="detail-change-title" class="badge">select a change</span></h2>
            <div id="change-detail-meta" style="margin-bottom:12px;"></div>
            <div id="detail-worker-actions" style="margin-bottom:14px;padding:12px;background:#020617;border:1px solid var(--border);border-radius:6px;">
              <div class="row" style="margin-bottom:8px;">
                <strong>Worker Worktree Actions:</strong>
                <button onclick="validateWorker()">Validate Specs in Worktree</button>
                <button onclick="gatesWorker()">Run Gates in Worktree</button>
                <button class="success" onclick="triggerAction('/api/actions/merge')">Integrate Now (Run Merger)</button>
                <button class="danger" onclick="resetWorker()">Reset Worker Worktree</button>
              </div>
              <div class="row">
                <select id="worker-agent-select" style="width:180px;"></select>
                <input id="worker-agent-prompt" placeholder="Send prompt to agent inside .worktrees/worker-<change>..." style="flex:1;min-width:260px;" />
                <button onclick="runWorkerAgent(false)">Run Agent on Worktree</button>
                <button class="secondary" onclick="runWorkerAgent(true)">Run in Background</button>
              </div>
              <pre id="detail-worker-action-output" style="display:none;margin-top:8px;max-height:220px;"></pre>
            </div>
            <div class="grid">
              <div>
                <h3>Execution &amp; Plan Prompts (log/workers/&lt;change&gt;/*.prompt.md)</h3>
                <div id="detail-prompts-list" class="row" style="margin-bottom:8px;"></div>
                <pre id="detail-prompt-viewer">Select a change and one of its PLAN / BUILD prompts above.</pre>
              </div>
              <div>
                <h3>OpenSpec Artifacts, Repairs, Jev States &amp; Worker Log</h3>
                <div id="detail-artifacts-list" class="row" style="margin-bottom:8px;"></div>
                <pre id="detail-artifact-viewer">Select an artifact (proposal.md, design.md, tasks.md, repairs.md, handoff.md) or worker log.</pre>
              </div>
            </div>
          </div>
        </section>

        <section id="tab-agents" class="tab">
          <div class="grid">
            <div class="card">
              <h2>Send a Message to an Agent</h2>
              <div style="margin-bottom:10px;">
                <label class="muted">Select Agent CLI</label>
                <select id="agent-select"></select>
              </div>
              <div style="margin-bottom:10px;">
                <label class="muted">Prompt / Message</label>
                <textarea id="agent-prompt" rows="5" placeholder="Write a message or instruction for the agent..."></textarea>
              </div>
              <div class="row">
                <button onclick="sendAgentMessage(false)">Run Agent &amp; Wait</button>
                <button class="secondary" onclick="sendAgentMessage(true)">Run in Background</button>
              </div>
              <pre id="agent-response" style="margin-top:10px;">Agent output will appear here.</pre>
            </div>
            <div class="card">
              <h2>Available Agents (<span id="agent-meta" class="muted"></span>)</h2>
              <div id="agents-table">Loading...</div>
            </div>
          </div>
          <div class="card">
            <h2>Recent Agent Runs <button class="secondary" onclick="loadAgents()">Refresh</button></h2>
            <div id="agent-runs-box">Loading...</div>
          </div>
        </section>

        <section id="tab-health" class="tab">
          <div class="card">
            <h2>Health Check &amp; Preflight (bin/check_ai_engines.sh)</h2>
            <div class="row" style="margin-bottom:12px;">
              <button onclick="runHealth(false)">Run Full Preflight (Toolchain, Kit, Services, Agents, Jev)</button>
              <button class="secondary" onclick="runHealth(true)">Check Required Services Only (--services)</button>
            </div>
            <pre id="health-output">Run a health check or ping an individual agent below.</pre>
          </div>
          <div class="card">
            <h2>Individual Agent Pings</h2>
            <div id="agent-pings-box" class="row">Loading...</div>
          </div>
        </section>

        <section id="tab-work" class="tab">
          <div class="card">
            <h2>Active Worktrees &amp; Stalled Workers (.worktrees/worker-*) <button class="secondary" onclick="loadWork()">Refresh</button></h2>
            <p class="ctx-note">Every worker worktree currently on disk, its phase, checked tasks, and why it is waiting, held, ready to merge or stalled.</p>
            <div id="worktrees-work-box">Loading...</div>
          </div>
          <div class="grid">
            <div class="card">
              <h2>
                <span>Backlog (config/agent_backlog.json)</span>
                <span class="row">
                  <button onclick="toggleBacklogForm()">+ Add Item to Backlog</button>
                  <button class="secondary" onclick="loadWork()">Refresh</button>
                </span>
              </h2>
              <div id="backlog-form-box" style="display:none;margin-bottom:12px;padding:12px;background:#020617;border:1px solid var(--border);border-radius:6px;">
                <div class="row" style="margin-bottom:8px;">
                  <input id="bl-name" placeholder="change-name (kebab-case)" style="width:48%;" />
                  <select id="bl-prio" style="width:48%;">
                    <option value="normal">normal</option>
                    <option value="high">high</option>
                    <option value="critical">critical</option>
                    <option value="low">low</option>
                  </select>
                </div>
                <input id="bl-deps" placeholder="depends_on (comma-separated, optional)" style="margin-bottom:8px;" />
                <textarea id="bl-desc" rows="3" placeholder="Description and acceptance criteria..." style="margin-bottom:8px;"></textarea>
                <div class="row">
                  <button onclick="addBacklog()">Add to Backlog</button>
                  <button class="secondary" onclick="toggleBacklogForm()">Cancel</button>
                </div>
              </div>
              <div id="backlog-box">Loading...</div>
            </div>
            <div class="card">
              <h2>Quarantined / Blocked Changes (log/blocked/ &amp; .needs-human)</h2>
              <div id="blocked-box">Loading...</div>
            </div>
          </div>
          <div class="grid">
            <div class="card">
              <h2>Proposals (config/agent_proposals.json) <button class="secondary" onclick="reviewProposals()">Run Review</button></h2>
              <div id="proposals-box">Loading...</div>
            </div>
            <div class="card">
              <h2>Integrated History (config/agent_history.json)</h2>
              <div id="history-box">Loading...</div>
            </div>
          </div>
        </section>

        <section id="tab-config" class="tab">
          <div class="grid">
            <div class="card">
              <h2>Change a Setting (bin/kit_config.rb set)</h2>
              <div class="row" style="margin-bottom:8px;">
                <input id="cfg-key" placeholder="e.g. pipeline.dispatch.workers or cycle.proposals.approval" />
                <input id="cfg-val" placeholder="New value" />
              </div>
              <div class="row">
                <button onclick="setConfig(false)">Set Setting</button>
                <button class="secondary" onclick="setConfig(true)">Dry Run</button>
                <button class="secondary" onclick="loadConfig()">Validate Config (check)</button>
              </div>
              <p class="muted">Remember to commit and push config changes before the next cycle so the scope guard does not pause the system.</p>
              <pre id="cfg-check-box">Loading...</pre>
            </div>
            <div class="card">
              <h2>Application Setup Checklist (bin/app_setup.rb status)</h2>
              <div id="setup-box">Loading...</div>
            </div>
          </div>
          <div class="card">
            <h2>Effective Settings (bin/kit_config.rb show)</h2>
            <pre id="cfg-show-box">Loading...</pre>
          </div>
        </section>

        <section id="tab-logs" class="tab">
          <div class="card">
            <h2>Artifact &amp; Telemetry Inspector: <span id="obs-viewer-title" class="badge">select any cycle, worker or event artifact below</span></h2>
            <pre id="log-viewer">Click any cycle report, rendered prompt, worker log, Jev evaluation state or event stream below to inspect it with full context.</pre>
          </div>
          <div class="grid">
            <div class="card">
              <h2>1. Scheduled Autonomous Cycles (log/cycle/) <button class="secondary" onclick="loadReports()">Refresh</button></h2>
              <p class="ctx-note" id="obs-cycles-ctx">Hourly headless judgment runs (.worktrees/_cycle): each cycle verifies integrated work, triages blockers, explores a strategy, proposes improvements and curates MEMORY.md.</p>
              <div id="obs-cycles-box">Loading...</div>
            </div>
            <div class="card">
              <h2>2. Visual QA Browser Sessions (log/cycle/visual_queue.json)</h2>
              <p class="ctx-note" id="obs-visual-ctx">Browser verification queue and visual QA sessions (.worktrees/_visual_qa) run by an agent app with a browser.</p>
              <div id="obs-visual-box">Loading...</div>
            </div>
          </div>
          <div class="grid">
            <div class="card">
              <h2>3. Worker Execution Timelines by Change (log/workers/)</h2>
              <p class="ctx-note">Isolated PLAN and BUILD worker executions: each change records its execution stream (&lt;change&gt;.log), every rendered PLAN/BUILD/repair prompt (*.prompt.md) and Jev gate inputs (jev-*.state.json).</p>
              <div id="obs-workers-box">Loading...</div>
            </div>
            <div class="card">
              <h2>4. Self-Healing &amp; Recovery State (log/)</h2>
              <p class="ctx-note">Automatic retry counters (log/blocked_retries.json), engine quota deferrals (log/deferrals.json), healed block history (log/blocked/history/) and rebase conflict rebuilds (log/rebuilds/).</p>
              <div id="obs-recovery-box">Loading...</div>
            </div>
          </div>
          <div class="grid">
            <div class="card">
              <h2>5. Orchestrator Event Stream (log/events.jsonl) <button class="secondary" onclick="viewLog('events','events.jsonl')">View Raw JSONL</button></h2>
              <p class="ctx-note">Structured lifecycle telemetry emitted by the dispatcher, merger, proposal reviewer and Jev judge.</p>
              <div id="obs-events-box">Loading...</div>
            </div>
            <div class="card">
              <h2>6. Jev Calibration &amp; Prompt Version Reports</h2>
              <p class="ctx-note">Evidence from bin/jev_report.rb and bin/prompt_report.rb comparing gate scores, prompt versions and memory versions against change outcomes.</p>
              <pre id="reports-box">Loading...</pre>
            </div>
          </div>
        </section>
      </main>
      <div id="toast"></div>
      <script>
        const esc = (s) => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
        const changeLink = (name) => `<a href="#" style="color:var(--accent);font-weight:700;" onclick="openChangeDetail('${esc(name)}');return false;">${esc(name)}</a>`;
        const changeBtn = (name) => `<button class="secondary" onclick="openChangeDetail('${esc(name)}')">Inspect Prompts &amp; Detail</button>`;
        function toast(msg) {
          const el = document.getElementById('toast');
          el.textContent = msg;
          el.style.display = 'block';
          setTimeout(() => { el.style.display = 'none'; }, 4000);
        }
        function showTab(name, btn) {
          document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
          document.querySelectorAll('nav button').forEach(b => b.classList.remove('active'));
          document.getElementById('tab-' + name).classList.add('active');
          if (btn) btn.classList.add('active');
        }
        async function api(path, opts = {}) {
          const headers = Object.assign({ 'Content-Type': 'application/json' }, opts.headers || {});
          const res = await fetch(path, Object.assign({}, opts, { headers }));
          const data = await res.json().catch(() => ({}));
          if (!res.ok) throw new Error(data.error || ('HTTP ' + res.status));
          return data;
        }
        function renderWorktreesTable(wts, paused) {
          if (!wts || !wts.length) return '<p class="muted">No active worker worktrees (.worktrees/worker-*), leases or ready_to_merge manifests.</p>';
          let html = '<table><tr><th>Change</th><th>Phase &amp; Tasks</th><th>Status</th><th>Diagnosis</th><th>Actions</th></tr>';
          wts.forEach(w => {
            const stClass = w.status === 'READY_TO_MERGE' ? 'ok' : ((w.status === 'STALE_LEASE' || w.status === 'QUARANTINED' || w.status === 'NEEDS_HUMAN') ? 'err' : 'warn');
            const tasks = w.tasks_total > 0 ? `${w.tasks_done}/${w.tasks_total} tasks` : (w.has_proposal ? 'plan written' : 'no artifacts yet');
            let acts = changeBtn(w.change_name);
            if (w.status === 'READY_TO_MERGE') {
              acts += paused
                ? ` <button class="success" onclick="resumeAndMerge()">Resume &amp; Merge</button>`
                : ` <button class="success" onclick="triggerAction('/api/actions/merge')">Integrate Now (Run Merger)</button>`;
            }
            if (w.status === 'STALE_LEASE') {
              acts += ` <button class="danger" onclick="reclaimLease('${esc(w.change_name)}')">Reclaim Stale Lock</button>`;
            }
            if (w.status === 'QUARANTINED' || w.status === 'NEEDS_HUMAN') {
              acts += ` <button onclick="unblockChange('${esc(w.change_name)}', false, true)">Unblock + Reset Retries</button>`;
            }
            html += `<tr>
              <td>${changeLink(w.change_name)}</td>
              <td><code>${esc(w.phase)}</code><br/><span class="muted">${esc(tasks)}</span></td>
              <td><span class="badge ${stClass}">${esc(w.status)}</span></td>
              <td>${esc(w.diagnosis || '-')}</td>
              <td class="row">${acts}</td>
            </tr>`;
          });
          html += '</table>';
          return html;
        }
        async function loadStatus() {
          try {
            const d = await api('/api/status');
            document.getElementById('app-name').textContent = d.app_name;
            const pb = document.getElementById('pause-badge');
            const p = d.processes;
            if (p.paused) {
              pb.textContent = 'PAUSED: ' + (p.pause_reason || 'yes');
              pb.className = 'badge err';
            } else {
              pb.textContent = 'ACTIVE';
              pb.className = 'badge ok';
            }
            let html = '<table><tr><th>Component</th><th>State</th><th>Details</th></tr>';
            p.locks.forEach(l => {
              const st = l.held ? `<span class="badge warn">LOCKED (pid ${esc(l.pid)})</span>` : '<span class="badge ok">idle</span>';
              html += `<tr><td>${esc(l.name)} lock</td><td>${st}</td><td>${l.held ? (l.age_seconds + 's old, alive=' + l.alive) : '-'}</td></tr>`;
            });
            p.daemons.forEach(dm => {
              const st = dm.running ? `<span class="badge warn">RUNNING (pid ${esc(dm.pid)})</span>` : '<span class="badge ok">idle</span>';
              html += `<tr><td>${esc(dm.name)}</td><td>${st}</td><td>${esc(dm.started_at || '-')}</td></tr>`;
            });
            const v = p.visual_qa;
            html += `<tr><td>visual QA</td><td>${v.open ? '<span class="badge warn">OPEN</span>' : '<span class="badge ok">closed</span>'}</td><td>${esc(v.stamp || '-')}${v.slot ? ' (slot ' + esc(v.slot) + ')' : ''}</td></tr>`;
            const leaseHtml = p.leases.map(x => {
              const lbadge = x.alive ? `<span class="badge warn">pid ${esc(x.pid)}</span>` : `<span class="badge err">stale pid ${esc(x.pid)}</span> <button class="danger" onclick="reclaimLease('${esc(x.change)}')">Reclaim Stale Lock</button>`;
              return `${changeLink(x.change)} ${lbadge} ${changeBtn(x.change)}`;
            }).join(', ') || 'none';
            html += `<tr><td>changes in flight</td><td>${p.leases.length}</td><td>${leaseHtml}</td></tr>`;
            html += `<tr><td>agents in use now</td><td>${p.agents_in_use.length}</td><td>${p.agents_in_use.map(x => esc(x.agent) + ' (pid ' + esc(x.pid) + ')').join(', ') || 'none'}</td></tr>`;
            html += '</table>';
            document.getElementById('processes-box').innerHTML = html;
            const wtHtml = renderWorktreesTable(d.worktrees || [], p.paused);
            const wtBox = document.getElementById('worktrees-box');
            if (wtBox) wtBox.innerHTML = wtHtml;
            const wtWorkBox = document.getElementById('worktrees-work-box');
            if (wtWorkBox) wtWorkBox.innerHTML = wtHtml;
            document.getElementById('snapshot-box').textContent = d.snapshot || '';
            const pr = d.progress;
            const readyHtml = pr.now.ready_to_merge.map(c => {
              const act = p.paused
                ? `<button class="success" onclick="resumeAndMerge()">Resume &amp; Merge</button>`
                : `<button class="success" onclick="triggerAction('/api/actions/merge')">Integrate Now</button>`;
              return `${changeLink(c)} ${changeBtn(c)} ${act}`;
            }).join(' ') || 'none';
            let phtml = `<table>
              <tr><th>Integrated (24h)</th><td>${pr.period.integrated.length} (${pr.period.integrated.map(i => `${changeLink(i.change)} ${changeBtn(i.change)}`).join(' ') || 'none'})</td></tr>
              <tr><th>Cycles (24h)</th><td>${pr.period.cycles.length}</td></tr>
              <tr><th>Agent Calls</th><td>${pr.period.agent_calls} calls (${pr.period.agent_minutes} min)</td></tr>
              <tr><th>Ready to Merge</th><td>${readyHtml}</td></tr>
              <tr><th>Last Cycle</th><td>${pr.health.last_cycle ? esc(pr.health.last_cycle.at + ' - ' + pr.health.last_cycle.outcome) : 'none yet'}</td></tr>
            </table>`;
            document.getElementById('progress-box').innerHTML = phtml;
          } catch (e) { toast(e.message); }
        }
        async function pauseSystem() {
          const reason = document.getElementById('pause-reason').value;
          await api('/api/actions/pause', { method: 'POST', body: JSON.stringify({ reason }) });
          toast('System paused');
          loadStatus();
        }
        async function resumeSystem() {
          await api('/api/actions/resume', { method: 'POST', body: '{}' });
          toast('System resumed');
          loadStatus();
        }
        async function resumeAndMerge() {
          const d = await api('/api/actions/resume_and_merge', { method: 'POST', body: '{}' });
          document.getElementById('action-output').textContent = JSON.stringify(d, null, 2);
          toast('System resumed & merger started to drain ready_to_merge');
          loadStatus();
          loadWork();
        }
        async function reclaimLease(name) {
          await api(`/api/worktrees/${encodeURIComponent(name)}/reclaim_lease`, { method: 'POST', body: '{}' });
          toast('Reclaimed stale lock for ' + name);
          loadStatus();
          loadWork();
          loadChanges();
        }
        async function runCycle() {
          const d = await api('/api/actions/cycle', { method: 'POST', body: '{}' });
          document.getElementById('action-output').textContent = d.output || 'Cycle launched';
          toast(d.output || 'Cycle launched');
          loadStatus();
        }
        async function triggerAction(url) {
          const d = await api(url, { method: 'POST', body: '{}' });
          document.getElementById('action-output').textContent = JSON.stringify(d, null, 2);
          toast('Action started');
          loadStatus();
        }
        async function dryRunDispatch() {
          const d = await api('/api/actions/dispatch', { method: 'POST', body: JSON.stringify({ dry_run: true }) });
          document.getElementById('action-output').textContent = JSON.stringify(d, null, 2);
        }
        async function runGates() {
          const repo = document.getElementById('gate-repo').value;
          const regression = document.getElementById('gate-reg').checked;
          const d = await api('/api/actions/gates', { method: 'POST', body: JSON.stringify({ repo, regression }) });
          document.getElementById('action-output').textContent = JSON.stringify(d, null, 2);
          toast('Gates started in background');
        }
        async function visualAction(op) {
          const d = await api('/api/actions/visual_qa', { method: 'POST', body: JSON.stringify({ op }) });
          document.getElementById('action-output').textContent = d.output || JSON.stringify(d, null, 2);
          loadStatus();
        }
        async function visualRequest() {
          const what = document.getElementById('visual-req').value;
          if (!what) return toast('Enter what to check in the browser');
          const d = await api('/api/actions/visual_qa', { method: 'POST', body: JSON.stringify({ op: 'request', what }) });
          document.getElementById('visual-req').value = '';
          document.getElementById('action-output').textContent = JSON.stringify(d.queue, null, 2);
          toast('Visual check queued');
        }
        async function loadAgents() {
          const d = await api('/api/agents');
          const c = d.catalog;
          document.getElementById('agent-meta').textContent = `order: ${c.order}, permissions: ${c.permissions}`;
          ['agent-select', 'worker-agent-select'].forEach(selId => {
            const sel = document.getElementById(selId);
            if (!sel) return;
            const cur = sel.value;
            sel.innerHTML = '';
            c.agents.forEach(a => {
              const opt = document.createElement('option');
              opt.value = a.name;
              opt.textContent = `${a.name} (${a.label})${a.selected ? ' [selected]' : ''}${a.installed ? '' : ' [not on PATH]'}`;
              sel.appendChild(opt);
            });
            if (cur) sel.value = cur;
            else if (c.selected[0]) sel.value = c.selected[0];
          });

          let tbl = '<table><tr><th>Agent</th><th>Selected</th><th>Installed</th><th>Roles</th><th>In Use</th><th>Action</th></tr>';
          let pings = '';
          c.agents.forEach(a => {
            tbl += `<tr>
              <td><strong>${esc(a.name)}</strong><br/><span class="muted">${esc(a.label)}</span></td>
              <td>${a.selected ? '<span class="badge ok">yes</span>' : '<span class="muted">no</span>'}</td>
              <td>${a.installed ? '<span class="badge ok">PATH</span>' : '<span class="badge warn">missing</span>'}</td>
              <td>${esc(a.roles.join(', ') || '-')}</td>
              <td>${a.in_use > 0 ? `<span class="badge warn">${a.in_use}</span>` : '0'}</td>
              <td><button class="secondary" onclick="pingAgent('${esc(a.name)}')">Ping</button></td>
            </tr>`;
            pings += `<button class="secondary" onclick="pingAgent('${esc(a.name)}')">Ping ${esc(a.name)}</button>`;
          });
          tbl += '</table>';
          document.getElementById('agents-table').innerHTML = tbl;
          document.getElementById('agent-pings-box').innerHTML = pings;

          let rhtml = '<table><tr><th>ID</th><th>Agent</th><th>Status</th><th>Workdir</th><th>Prompt</th><th>Output</th></tr>';
          d.runs.forEach(r => {
            const badge = r.status === 'ok' ? 'ok' : (r.status === 'running' ? 'warn' : 'err');
            rhtml += `<tr>
              <td><code>${esc(r.id)}</code></td>
              <td>${esc(r.agent)}</td>
              <td><span class="badge ${badge}">${esc(r.status)}</span></td>
              <td class="muted">${esc(r.workdir || '.')}</td>
              <td>${esc(r.prompt)}</td>
              <td><pre style="margin:0;max-height:110px;">${esc(r.output)}</pre></td>
            </tr>`;
          });
          rhtml += '</table>';
          document.getElementById('agent-runs-box').innerHTML = d.runs.length ? rhtml : '<p class="muted">No agent runs yet.</p>';
        }
        async function sendAgentMessage(asyncMode) {
          const agent = document.getElementById('agent-select').value;
          const prompt = document.getElementById('agent-prompt').value;
          if (!prompt.trim()) return toast('Write a message for the agent first');
          document.getElementById('agent-response').textContent = 'Running ' + agent + '...';
          try {
            const d = await api('/api/agents/message', { method: 'POST', body: JSON.stringify({ agent, prompt, async: asyncMode }) });
            document.getElementById('agent-response').textContent = asyncMode ? ('Started run ' + d.id + ' (pid ' + d.pid + ')') : (d.output || ('Exit ' + d.code));
            loadAgents();
            loadStatus();
          } catch (e) {
            document.getElementById('agent-response').textContent = 'Error: ' + e.message;
          }
        }
        async function pingAgent(agent) {
          document.getElementById('health-output').textContent = 'Pinging ' + agent + '...';
          const d = await api('/api/agents/ping', { method: 'POST', body: JSON.stringify({ agent }) });
          const text = JSON.stringify(d, null, 2);
          document.getElementById('health-output').textContent = text;
          document.getElementById('agent-response').textContent = text;
          toast(`${agent}: ${d.status}`);
        }
        async function runHealth(services) {
          document.getElementById('health-output').textContent = 'Running check_ai_engines.sh...';
          const d = await api('/api/health', { method: 'POST', body: JSON.stringify({ services }) });
          document.getElementById('health-output').textContent = d.output || d.summary;
          toast(d.summary);
        }
        async function loadWork() {
          const [bl, pr, bk, wts] = await Promise.all([api('/api/backlog'), api('/api/proposals'), api('/api/blocked'), api('/api/worktrees')]);
          const wtWorkBox = document.getElementById('worktrees-work-box');
          if (wtWorkBox) wtWorkBox.innerHTML = renderWorktreesTable(wts.worktrees || [], bl.dry_run && bl.dry_run.paused);
          const dryByChange = {};
          ((bl.dry_run && bl.dry_run.items) || []).forEach(r => { dryByChange[r.change] = r; });
          let bhtml = '<table><tr><th>Change</th><th>Priority</th><th>Queue Status</th><th>Description</th><th>Action</th></tr>';
          bl.backlog.forEach(i => {
            const dr = dryByChange[i.change_name] || {};
            const prioLabel = (dr.counts_as && dr.counts_as !== i.priority) ? `${i.priority} &rarr; ${dr.counts_as}` : (i.priority || 'normal');
            const stBadge = dr.state === 'building' ? 'warn' : (dr.state === 'blocked' ? 'err' : (dr.next ? 'ok' : ''));
            bhtml += `<tr>
              <td>${changeLink(i.change_name)}${i.depends_on ? '<br/><span class="muted">depends: ' + esc(i.depends_on.join(', ')) + '</span>' : ''}</td>
              <td><span class="badge">${prioLabel}</span></td>
              <td>${dr.state ? `<span class="badge ${stBadge}">${esc(dr.state)}</span>` : '-'}<br/><span class="muted">${esc(dr.why || '')}</span></td>
              <td>${esc(i.description)}</td>
              <td class="row">
                ${changeBtn(i.change_name)}
                <button class="danger" onclick="deleteBacklog('${esc(i.change_name)}')">Remove</button>
              </td>
            </tr>`;
          });
          bhtml += '</table>';
          document.getElementById('backlog-box').innerHTML = bl.backlog.length ? bhtml : '<p class="muted">config/agent_backlog.json is empty.</p>';

          let hhtml = '<table><tr><th>Change</th><th>Priority</th><th>Integrated At</th><th>Description</th><th>Action</th></tr>';
          (bl.history || []).forEach(h => {
            hhtml += `<tr>
              <td>${changeLink(h.change_name)}</td>
              <td><span class="badge ok">${esc(h.priority || 'normal')}</span></td>
              <td class="muted">${esc(h.integrated_at || '-')}</td>
              <td>${esc(h.description || '')}</td>
              <td class="row">${changeBtn(h.change_name)}</td>
            </tr>`;
          });
          hhtml += '</table>';
          const hbox = document.getElementById('history-box');
          if (hbox) hbox.innerHTML = (bl.history && bl.history.length) ? hhtml : '<p class="muted">No integrated changes in config/agent_history.json yet.</p>';

          let phtml = '<table><tr><th>Proposal</th><th>Status</th><th>Source</th><th>Description</th><th>Actions</th></tr>';
          pr.proposals.forEach(p => {
            const act = (p.status === 'proposed' || p.status === 'approved')
              ? `<button class="success" onclick="decideProposal('${esc(p.change_name)}','approve')">Approve</button>
                 <button class="danger" onclick="decideProposal('${esc(p.change_name)}','reject')">Reject</button>`
              : '';
            phtml += `<tr>
              <td>${changeLink(p.change_name)}</td>
              <td><span class="badge">${esc(p.status)}</span></td>
              <td>${esc(p.source || '-')}</td>
              <td>${esc(p.description || '')}</td>
              <td class="row">${changeBtn(p.change_name)} ${act}</td>
            </tr>`;
          });
          phtml += '</table>';
          document.getElementById('proposals-box').innerHTML = pr.proposals.length ? phtml : '<p class="muted">No proposals.</p>';

          let khtml = '<table><tr><th>Change</th><th>Reason &amp; Details</th><th>Retry</th><th>Actions</th></tr>';
          bk.blocked.forEach(b => {
            const nh = b.needs_human ? `<div style="margin-top:6px;padding:6px;background:rgba(245,158,11,0.12);border:1px solid var(--warn);border-radius:4px;"><strong>.needs-human question:</strong><br/>${esc(b.needs_human)}</div>` : '';
            const det = b.details ? `<details style="margin-top:6px;"><summary style="cursor:pointer;color:var(--accent);font-size:12px;">Show failure details</summary><pre style="margin-top:6px;max-height:180px;">${esc(b.details)}</pre></details>` : '';
            khtml += `<tr>
              <td>${changeLink(b.change_name)}</td>
              <td><span class="badge err">${esc(b.reason)}</span>${nh}${det}</td>
              <td>${esc(b.retry_note || '-')}</td>
              <td class="row">
                ${changeBtn(b.change_name)}
                <button onclick="unblockChange('${esc(b.change_name)}', false, false)">Unblock</button>
                <button class="secondary" onclick="unblockChange('${esc(b.change_name)}', false, true)">Unblock + Reset Retries</button>
                <button class="secondary" onclick="unblockChange('${esc(b.change_name)}', true, true)">Approve Risk &amp; Unblock</button>
              </td>
            </tr>`;
          });
          khtml += '</table>';
          document.getElementById('blocked-box').innerHTML = bk.blocked.length ? khtml : '<p class="muted">No blocked changes.</p>';
        }
        function toggleBacklogForm() {
          const box = document.getElementById('backlog-form-box');
          if (!box) return;
          box.style.display = (box.style.display === 'none' || !box.style.display) ? 'block' : 'none';
        }
        async function addBacklog() {
          const change_name = document.getElementById('bl-name').value;
          const priority = document.getElementById('bl-prio').value;
          const depends_on = document.getElementById('bl-deps').value;
          const description = document.getElementById('bl-desc').value;
          await api('/api/backlog', { method: 'POST', body: JSON.stringify({ change_name, priority, depends_on, description }) });
          document.getElementById('bl-name').value = '';
          document.getElementById('bl-deps').value = '';
          document.getElementById('bl-desc').value = '';
          const box = document.getElementById('backlog-form-box');
          if (box) box.style.display = 'none';
          toast('Queued ' + change_name);
          loadWork();
        }
        async function deleteBacklog(name) {
          await api('/api/backlog/' + encodeURIComponent(name), { method: 'DELETE' });
          toast('Removed ' + name);
          loadWork();
        }
        async function decideProposal(name, decision) {
          await api(`/api/proposals/${encodeURIComponent(name)}/${decision}`, { method: 'POST', body: '{}' });
          toast(`${name}: ${decision}d`);
          loadWork();
        }
        async function reviewProposals() {
          await api('/api/proposals/review', { method: 'POST', body: '{}' });
          toast('Proposals reviewed');
          loadWork();
        }
        async function unblockChange(name, approve_risk, reset_retries = true) {
          await api(`/api/blocked/${encodeURIComponent(name)}/unblock`, { method: 'POST', body: JSON.stringify({ approve_risk, reset_retries }) });
          toast('Unblocked ' + name);
          loadWork();
          loadStatus();
        }
        async function loadConfig() {
          const [cfg, setup] = await Promise.all([api('/api/config'), api('/api/setup')]);
          document.getElementById('cfg-check-box').textContent = JSON.stringify(cfg.check, null, 2);
          document.getElementById('cfg-show-box').textContent = JSON.stringify(cfg.show, null, 2);
          let shtml = '<table><tr><th>Section</th><th>State</th><th>Item</th></tr>';
          Object.entries(setup.sections || {}).forEach(([sec, items]) => {
            items.forEach(i => {
              const b = i.state === 'ok' ? 'ok' : (i.state === 'warn' ? 'warn' : 'err');
              shtml += `<tr><td>${esc(sec)}</td><td><span class="badge ${b}">${esc(i.state)}</span></td><td>${esc(i.what)}${i.fix ? '<br/><code class="muted">' + esc(i.fix) + '</code>' : ''}</td></tr>`;
            });
          });
          shtml += '</table>';
          document.getElementById('setup-box').innerHTML = shtml;
        }
        async function setConfig(dry_run) {
          const key = document.getElementById('cfg-key').value;
          const value = document.getElementById('cfg-val').value;
          await api('/api/config/set', { method: 'POST', body: JSON.stringify({ key, value, dry_run }) });
          toast((dry_run ? 'Validated ' : 'Updated ') + key);
          loadConfig();
        }
        async function loadReports() {
          const [rep, logs] = await Promise.all([api('/api/reports'), api('/api/logs')]);
          document.getElementById('reports-box').textContent = JSON.stringify(rep, null, 2);
          const obs = logs.observatory || {};

          const cyc = obs.cycles || {};
          const lastC = (cyc.state && cyc.state.last_cycle) || {};
          let chtml = `<div style="margin-bottom:8px;"><span class="badge">last outcome: ${esc(lastC.outcome || 'none')}</span> <span class="muted">finished: ${esc(lastC.finished_at || '-')}</span> `;
          if (cyc.cron_log) chtml += `<button class="secondary" onclick="viewLog('cycle','cron.log')">View cron.log</button>`;
          chtml += `</div>`;
          if ((cyc.runs || []).length) {
            chtml += '<table><tr><th>Cycle</th><th>Outcome &amp; Strategy</th><th>Agent</th><th>Artifacts</th></tr>';
            cyc.runs.forEach(r => {
              const b = r.outcome === 'done' ? 'ok' : (r.outcome && r.outcome.includes('running') ? 'warn' : 'err');
              let btns = `<button class="secondary" onclick="viewLog('cycle','${esc(r.log_file)}')">Execution Log</button>`;
              if (r.prompt_file) btns += ` <button class="secondary" onclick="viewLog('cycle','${esc(r.prompt_file)}')">Cycle Prompt</button>`;
              if (r.report_file) btns += ` <button onclick="viewLog('report','${esc(r.report_file)}')">Judgment Report</button>`;
              chtml += `<tr>
                <td><code>${esc(r.stamp)}</code></td>
                <td><span class="badge ${b}">${esc(r.outcome)}</span>${r.strategy ? '<br/><span class="muted">strategy: ' + esc(r.strategy) + '</span>' : ''}</td>
                <td>${esc(r.engine || '-')}</td>
                <td class="row">${btns}</td>
              </tr>`;
            });
            chtml += '</table>';
          } else {
            chtml += '<p class="muted">No scheduled cycle runs recorded in log/cycle/ yet.</p>';
          }
          document.getElementById('obs-cycles-box').innerHTML = chtml;

          const vis = obs.visual_qa || {};
          const vitems = (vis.queue && vis.queue.items) || [];
          let vhtml = `<div style="margin-bottom:8px;"><span class="badge ${vis.enabled ? 'ok' : 'warn'}">${vis.enabled ? 'enabled' : 'disabled'}</span> <span class="muted">${vitems.length} item(s) in visual_queue.json</span></div>`;
          if ((vis.sessions || []).length) {
            vhtml += '<table><tr><th>Session</th><th>Artifacts</th></tr>';
            vis.sessions.forEach(s => {
              let btns = `<button class="secondary" onclick="viewLog('cycle','${esc(s.plan_file)}')">Browser Plan</button>`;
              if (s.report_file) btns += ` <button onclick="viewLog('report','${esc(s.report_file)}')">Visual Report</button>`;
              if (s.sync_log) btns += ` <button class="secondary" onclick="viewLog('cycle','${esc(s.sync_log)}')">Sync Log</button>`;
              vhtml += `<tr><td><code>${esc(s.stamp)}</code></td><td class="row">${btns}</td></tr>`;
            });
            vhtml += '</table>';
          } else {
            vhtml += '<p class="muted">No visual QA sessions recorded yet.</p>';
          }
          document.getElementById('obs-visual-box').innerHTML = vhtml;

          const wrk = (obs.workers && obs.workers.items) || [];
          let whtml = '';
          if (wrk.length) {
            whtml = '<table><tr><th>Change</th><th>State</th><th>Worker Stream &amp; Prompts</th><th>Jev Gate Inputs</th></tr>';
            wrk.forEach(w => {
              let pbtns = changeBtn(w.change_name);
              if (w.worker_log) pbtns += ` <button class="secondary" onclick="viewLog('worker','${esc(w.worker_log)}')">${esc(w.worker_log)}</button>`;
              (w.prompts || []).forEach(p => {
                const short = p.split('/').pop().replace('.prompt.md', '');
                pbtns += ` <button class="secondary" onclick="viewLog('worker','${esc(p)}')">${esc(short)}</button>`;
              });
              const jbtns = (w.jev_states || []).map(j => {
                const short = j.split('/').pop().replace('.state.json', '');
                return `<button class="secondary" onclick="viewLog('worker','${esc(j)}')">${esc(short)}</button>`;
              }).join(' ') || '<span class="muted">none</span>';
              whtml += `<tr>
                <td>${changeLink(w.change_name)}</td>
                <td><span class="badge">${esc(w.state)}</span></td>
                <td class="row">${pbtns}</td>
                <td class="row">${jbtns}</td>
              </tr>`;
            });
            whtml += '</table>';
          } else {
            whtml = '<p class="muted">No worker executions recorded in log/workers/ yet.</p>';
          }
          document.getElementById('obs-workers-box').innerHTML = whtml;

          const rec = obs.recovery_state || {};
          const defs = Object.entries(rec.deferrals || {}).map(([c, n]) => `${c} (${n}/3)`).join(', ') || 'none';
          const rets = Object.entries(rec.blocked_retries || {}).map(([c, r]) => `${c} (retries: ${r.retries})`).join(', ') || 'none';
          const rebs = (rec.rebuilds || []).map(r => `${r.change_name} (${r.count || 0})`).join(', ') || 'none';
          const bhist = (rec.blocked_history || []).map(h => `${h.file}: ${h.reason}`).join(', ') || 'none';
          document.getElementById('obs-recovery-box').innerHTML = `<table>
            <tr><th>Engine Deferrals (log/deferrals.json)</th><td>${esc(defs)}</td></tr>
            <tr><th>Automatic Retry Counters (log/blocked_retries.json)</th><td>${esc(rets)}</td></tr>
            <tr><th>Healed Quarantine History (log/blocked/history/)</th><td>${esc(bhist)}</td></tr>
            <tr><th>Conflict Rebuilds (log/rebuilds/)</th><td>${esc(rebs)}</td></tr>
          </table>`;

          const evs = (obs.events && obs.events.recent) || [];
          if (evs.length) {
            let ehtml = '<div style="max-height:280px;overflow-y:auto;"><table><tr><th>Time</th><th>Event</th><th>Change</th><th>Context</th></tr>';
            evs.slice(0, 35).forEach(e => {
              const ctx = [e.phase && `phase=${e.phase}`, e.engine && `engine=${e.engine}`, e.reason && `reason=${e.reason}`, e.gate && `gate=${e.gate} (${e.status})`, e.prompt_version && `prompt=${e.prompt_version}`].filter(Boolean).join(', ');
              ehtml += `<tr>
                <td class="muted">${esc((e.ts || '').slice(0, 19).replace('T', ' '))}</td>
                <td><code>${esc(e.event)}</code></td>
                <td>${e.change ? changeLink(e.change) : '-'}</td>
                <td class="muted">${esc(ctx || '-')}</td>
              </tr>`;
            });
            ehtml += '</table></div>';
            document.getElementById('obs-events-box').innerHTML = ehtml;
          } else {
            document.getElementById('obs-events-box').innerHTML = '<p class="muted">No events in log/events.jsonl yet.</p>';
          }
        }
        async function viewLog(kind, name) {
          showTab('logs', document.getElementById('nav-logs'));
          const titleEl = document.getElementById('obs-viewer-title');
          if (titleEl) titleEl.textContent = `${kind}: ${name}`;
          const d = await api(`/api/logs?kind=${encodeURIComponent(kind)}&name=${encodeURIComponent(name)}`);
          document.getElementById('log-viewer').textContent = d.content || '';
        }
        let currentChangeDetail = null;
        async function loadChanges() {
          const d = await api('/api/changes');
          let chtml = '<table><tr><th>Change</th><th>State</th><th>Prompts</th><th>Description</th><th>Action</th></tr>';
          d.changes.forEach(c => {
            const b = c.state === 'integrated' ? 'ok' : ((c.state === 'blocked' || c.state === 'stale_lock') ? 'err' : 'warn');
            const reclaimBtn = c.state === 'stale_lock' ? ` <button class="danger" onclick="reclaimLease('${esc(c.change_name)}')">Reclaim Stale Lock</button>` : '';
            chtml += `<tr>
              <td>${changeLink(c.change_name)}</td>
              <td><span class="badge ${b}">${esc(c.state)}</span>${c.blocked_reason ? '<br/><span class="muted">' + esc(c.blocked_reason) + '</span>' : ''}</td>
              <td>${c.prompt_count} prompt(s)</td>
              <td>${esc(c.description || '-')}</td>
              <td class="row">${changeBtn(c.change_name)}${reclaimBtn}</td>
            </tr>`;
          });
          chtml += '</table>';
          document.getElementById('changes-list-box').innerHTML = d.changes.length ? chtml : '<p class="muted">No changes recorded yet.</p>';

          let thtml = '<table><tr><th>Role</th><th>File &amp; Version</th><th>Placeholders</th><th>View</th></tr>';
          window.portalPromptTemplates = {};
          (d.templates || []).forEach(t => {
            window.portalPromptTemplates[t.role] = t;
            thtml += `<tr>
              <td><strong>${esc(t.role.toUpperCase())}</strong></td>
              <td><code>${esc(t.path)}</code><br/><span class="muted">version: ${esc(t.version || '-')}</span></td>
              <td><span class="muted">${esc((t.placeholders || []).map(p => '{{' + p + '}}').join(', ') || 'none')}</span></td>
              <td class="row">
                <button class="secondary" onclick="showPromptTemplate('${esc(t.role)}', false)">Template</button>
                <button class="secondary" onclick="showPromptTemplate('${esc(t.role)}', true)">Sample Render</button>
              </td>
            </tr>`;
          });
          thtml += '</table>';
          document.getElementById('prompt-templates-box').innerHTML = thtml;
        }
        function showPromptTemplate(role, rendered) {
          const t = (window.portalPromptTemplates || {})[role];
          if (!t) return;
          document.getElementById('detail-change-title').textContent = `${t.path} (${rendered ? 'sample render' : 'template'})`;
          document.getElementById('detail-prompt-viewer').textContent = rendered ? t.rendered : t.raw;
        }
        async function openChangeDetail(name) {
          showTab('changes', document.getElementById('nav-changes'));
          const d = await api('/api/changes/' + encodeURIComponent(name));
          currentChangeDetail = d;
          document.getElementById('detail-change-title').textContent = d.change_name;
          const outBox = document.getElementById('detail-worker-action-output');
          if (outBox) outBox.style.display = 'none';
          let meta = '';
          if (d.item) meta += `<span class="badge">priority: ${esc(d.item.priority || 'normal')}</span> <span class="muted">${esc(d.item.description || '')}</span> `;
          if (d.blocked) meta += `<span class="badge err">BLOCKED: ${esc(d.blocked.reason)}</span> `;
          if (d.worktree_exists) meta += `<span class="badge ok">worktree: .worktrees/worker-${esc(d.change_name)}</span> `;
          if (d.artifact_source) meta += `<span class="badge ok">artifacts: ${esc(d.artifact_source)}</span> `;
          if (d.events && d.events.length) meta += `<span class="muted">${d.events.length} event(s)</span>`;
          document.getElementById('change-detail-meta').innerHTML = meta;

          const plist = document.getElementById('detail-prompts-list');
          let pbtns = '';
          if (d.rendered_prompts && d.rendered_prompts.plan) {
            pbtns += `<button class="secondary" onclick="selectRenderedChangePrompt('plan')">[PLAN] Rendered Prompt (${esc(d.change_name)})</button> `;
          }
          if (d.rendered_prompts && d.rendered_prompts.build) {
            pbtns += `<button class="secondary" onclick="selectRenderedChangePrompt('build')">[BUILD] Rendered Prompt (${esc(d.change_name)})</button> `;
          }
          if (d.prompts && d.prompts.length) {
            pbtns += d.prompts.map((p, idx) =>
              `<button class="${p.role === 'plan' ? 'secondary' : ''}" onclick="selectChangePrompt(${idx})">[${esc(p.role.toUpperCase())}] ${esc(p.phase)} (${esc(p.file)})</button>`
            ).join(' ');
            plist.innerHTML = pbtns;
            selectChangePrompt(d.prompts.length - 1);
          } else {
            plist.innerHTML = pbtns || '<span class="muted">No prompts available.</span>';
            if (d.rendered_prompts && d.rendered_prompts.plan) selectRenderedChangePrompt('plan');
            else document.getElementById('detail-prompt-viewer').textContent = 'No prompt executed yet for ' + d.change_name + '.';
          }

          const alist = document.getElementById('detail-artifacts-list');
          const keys = Object.keys(d.artifacts || {});
          let abtns = keys.map(k => `<button class="secondary" onclick="selectChangeArtifact('${esc(k)}')">${esc(k)}</button>`).join(' ');
          if (d.worker_log) abtns += ` <button class="secondary" onclick="selectChangeWorkerLog()">worker.log</button>`;
          if (d.events && d.events.length) abtns += ` <button class="secondary" onclick="selectChangeEvents()">events (${d.events.length})</button>`;
          if (d.jev_states && d.jev_states.length) {
            d.jev_states.forEach((j, idx) => {
              abtns += ` <button class="secondary" onclick="selectChangeJev(${idx})">${esc(j.file)}</button>`;
            });
          }
          alist.innerHTML = abtns || '<span class="muted">No artifacts or worker logs yet.</span>';
          if (keys.length) selectChangeArtifact(keys[0]);
          else if (d.worker_log) selectChangeWorkerLog();
          else document.getElementById('detail-artifact-viewer').textContent = 'No artifacts yet.';
        }
        function selectChangePrompt(idx) {
          if (!currentChangeDetail || !currentChangeDetail.prompts[idx]) return;
          const p = currentChangeDetail.prompts[idx];
          document.getElementById('detail-prompt-viewer').textContent = `# File: log/workers/${currentChangeDetail.change_name}/${p.file}\n# Role: ${p.role.toUpperCase()} | Phase: ${p.phase}\n\n` + p.content;
        }
        function selectRenderedChangePrompt(role) {
          if (!currentChangeDetail || !currentChangeDetail.rendered_prompts || !currentChangeDetail.rendered_prompts[role]) return;
          document.getElementById('detail-prompt-viewer').textContent = `# Rendered config/prompts/${role}.md for change: ${currentChangeDetail.change_name}\n\n` + currentChangeDetail.rendered_prompts[role];
        }
        function selectChangeArtifact(key) {
          if (!currentChangeDetail || !currentChangeDetail.artifacts) return;
          document.getElementById('detail-artifact-viewer').textContent = currentChangeDetail.artifacts[key] || '';
        }
        function selectChangeWorkerLog() {
          if (!currentChangeDetail) return;
          document.getElementById('detail-artifact-viewer').textContent = currentChangeDetail.worker_log || '';
        }
        function selectChangeEvents() {
          if (!currentChangeDetail) return;
          document.getElementById('detail-artifact-viewer').textContent = JSON.stringify(currentChangeDetail.events, null, 2);
        }
        function selectChangeJev(idx) {
          if (!currentChangeDetail || !currentChangeDetail.jev_states[idx]) return;
          document.getElementById('detail-artifact-viewer').textContent = currentChangeDetail.jev_states[idx].content;
        }
        async function validateWorker() {
          if (!currentChangeDetail) return toast('Select a change first');
          const out = document.getElementById('detail-worker-action-output');
          out.style.display = 'block';
          out.textContent = 'Running openspec validate --strict in worktree...';
          const d = await api(`/api/changes/${encodeURIComponent(currentChangeDetail.change_name)}/validate`, { method: 'POST', body: '{}' });
          out.textContent = d.output || (d.ok ? 'Valid' : 'Invalid');
          toast(d.ok ? 'Spec validation passed' : 'Spec validation failed');
        }
        async function gatesWorker() {
          if (!currentChangeDetail) return toast('Select a change first');
          const out = document.getElementById('detail-worker-action-output');
          out.style.display = 'block';
          const d = await api(`/api/changes/${encodeURIComponent(currentChangeDetail.change_name)}/gates`, { method: 'POST', body: '{}' });
          out.textContent = JSON.stringify(d, null, 2);
          toast('Gates started in worktree');
        }
        async function resetWorker() {
          if (!currentChangeDetail) return toast('Select a change first');
          const name = currentChangeDetail.change_name;
          const out = document.getElementById('detail-worker-action-output');
          out.style.display = 'block';
          await api(`/api/changes/${encodeURIComponent(name)}/reset`, { method: 'POST', body: '{}' });
          out.textContent = `Reset .worktrees/worker-${name}, feat/spec-${name} and quarantine/dispatch state.`;
          toast('Reset worker ' + name);
          openChangeDetail(name);
          loadStatus();
          loadWork();
        }
        async function runWorkerAgent(asyncMode) {
          if (!currentChangeDetail) return toast('Select a change first');
          const name = currentChangeDetail.change_name;
          const agent = document.getElementById('worker-agent-select').value;
          const prompt = document.getElementById('worker-agent-prompt').value;
          if (!prompt.trim()) return toast('Enter a prompt for the worker worktree');
          const out = document.getElementById('detail-worker-action-output');
          out.style.display = 'block';
          out.textContent = `Running ${agent} in .worktrees/worker-${name}...`;
          const d = await api(`/api/changes/${encodeURIComponent(name)}/agent`, { method: 'POST', body: JSON.stringify({ agent, prompt, async: asyncMode }) });
          out.textContent = asyncMode ? `Started run ${d.id} (pid ${d.pid})` : (d.output || `Exit ${d.code}`);
          openChangeDetail(name);
          loadAgents();
        }
        function refreshAll() {
          loadStatus();
          loadChanges();
          loadAgents();
          loadWork();
          loadConfig();
          loadReports();
        }
        refreshAll();
        setInterval(loadStatus, 8000);
      </script>
    </body>
    </html>
  HTML
end
