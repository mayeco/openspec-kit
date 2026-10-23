'use strict';
// ---------------------------------------------------------------------------
// Executions (every kind in one timeline), agent runs (follow, continue, re-run,
// stop), jobs and the agents.
// ---------------------------------------------------------------------------

const EXEC_KINDS = [['all', 'All'], ['cycle', 'Cycles'], ['plan', 'PLAN'], ['build', 'BUILD'], ['agent', 'Agent runs'], ['job', 'Jobs'], ['visual', 'Visual QA']];

route('/executions', async (ctx) => {
  ctx.crumbs([['Executions']]);
  ctx.title('Executions');
  const q = ctx.query.get('q') || '';
  const kind = ctx.query.get('kind') || 'all';
  const change = ctx.query.get('change') || '';
  const d = await api('/api/executions', { params: qparams() });
  const opts = EXEC_KINDS.map(([v, l]) => ({ value: v, label: l, count: d.counts[v] ?? 0 }));
  ctx.show(pageHead('Executions', 'Everything that ran, newest first: scheduled cycles, the PLAN and BUILD prompt of each change, agent runs, jobs and visual QA sessions.') +
    (change ? alertBox(`Showing only <b>${esc(change)}</b>. <a href="${esc(withParams({ change: null, page: null }))}">Show everything</a>`) + '<br>' : '') +
    `<div class="filters">${chips(opts, 'kind', kind)}${searchForm(q, 'Search title, change, agent or status')}</div>` +
    `<div class="card">${d.executions.length ? byDay(d.executions, (e) => execRow(e)) : empty('No execution matches.')}${pager(d, 'executions')}</div>`);
});

// ---- agent runs ---------------------------------------------------------------------
const RUN_STATUS = [['all', 'All'], ['running', 'Running'], ['ok', 'Succeeded'], ['failed', 'Failed'], ['stopped', 'Stopped']];

route('/runs', async (ctx) => {
  ctx.crumbs([['Runs']]);
  ctx.title('Runs');
  const q = ctx.query.get('q') || '';
  const status = ctx.query.get('status') || 'all';
  const agent = ctx.query.get('agent') || '';
  const d = await api('/api/runs', { params: qparams() });
  const opts = RUN_STATUS.map(([v, l]) => ({ value: v, label: l, count: d.counts[v] ?? 0 }));
  const agents = `<select data-nav="agent"><option value="">All agents</option>${Object.keys(d.agents).map((a) => `<option ${a === agent ? 'selected' : ''} value="${esc(a)}">${esc(a)} (${d.agents[a]})</option>`).join('')}</select>`;
  const rows = d.runs.map((r) => `<tr><td class="nowrap">${when(r.started_at)}</td><td><a href="/runs/${enc(r.id)}"><b>${esc(r.title)}</b></a>${r.relation ? `<div class="muted small">${esc(r.relation)} of <a href="/runs/${enc(r.parent)}">${esc(r.parent)}</a></div>` : ''}</td>` +
    `<td>${esc(r.agent)}</td><td>${r.change ? changeLink(r.change) : '<span class="muted">root</span>'}</td><td>${runBadge(r)}</td><td>${span(r.duration_seconds)}</td></tr>`).join('');
  ctx.show(pageHead('Runs', 'Messages you sent to an agent from the portal. Open one to follow its output, continue it with a follow-up or run it again.', '<a class="btn" href="/runs/new">New run</a>') +
    `<div class="filters">${chips(opts, 'status', status)}<div class="row">${agents}${searchForm(q, 'Search prompt, agent or change')}</div></div>` +
    `<div class="card">${d.runs.length ? `<table><thead><tr><th>Started</th><th>Run</th><th>Agent</th><th>Where</th><th>Status</th><th>Took</th></tr></thead><tbody>${rows}</tbody></table>` : empty('No run yet. Start one with <a href="/runs/new">New run</a>.')}${pager(d, 'runs')}</div>`);
});

async function agentCatalog() { return (await api('/api/agents')).catalog; }
const agentOptions = (cat, sel) => cat.agents.map((a) => `<option value="${esc(a.name)}" ${a.name === sel ? 'selected' : ''}>${esc(a.name)} (${esc(a.label)})${a.installed ? '' : ' — not on PATH'}</option>`).join('');

Forms['new-run'] = async (form) => {
  const f = new FormData(form);
  const change = f.get('change');
  const body = { agent: f.get('agent'), prompt: f.get('prompt'), async: true };
  const d = change ? await post(`/api/changes/${enc(change)}/agent`, body) : await post('/api/agents/message', body);
  toast('Run started');
  navigate(`/runs/${enc(d.id)}`);
};

route('/runs/new', async (ctx) => {
  ctx.crumbs([['Runs', '/runs'], ['New run']]);
  ctx.title('New run');
  const [cat, ch] = await Promise.all([agentCatalog(), api('/api/changes', { params: { per: 200, sort: 'name' } })]);
  const withWt = ch.changes.filter((c) => c.has_worktree);
  const pre = ctx.query.get('change') || '';
  ctx.show(pageHead('New run', 'Send a prompt to an agent. It runs in the background: the next page follows its output.') +
    `<div class="card"><form data-form="new-run"><label class="field"><span>Agent</span><select name="agent" style="width:100%">${agentOptions(cat, cat.selected[0])}</select></label>` +
    `<label class="field"><span>Run in</span><select name="change" style="width:100%"${withWt.length ? '' : ' disabled'}><option value="">The project root</option>${withWt.map((c) => `<option value="${esc(c.change_name)}" ${c.change_name === pre ? 'selected' : ''}>worktree of ${esc(c.change_name)}</option>`).join('')}</select></label>` +
    `<p class="muted small" style="margin:-4px 0 14px">${withWt.length ? `The project root, or the worktree of one of ${withWt.length} change${withWt.length === 1 ? '' : 's'}.` : 'No change has a worktree right now, so the agent runs in the project root. A worktree appears here while its change is being worked on.'}</p>` +
    `<label class="field"><span>Prompt</span><textarea name="prompt" rows="10" required placeholder="Write the instruction for the agent…"></textarea></label><button type="submit">Run in the background</button></form></div>`);
});

function runHead(r) {
  const running = r.status === 'running';
  const parent = r.parent_run ? `<a href="/runs/${enc(r.parent_run.id)}">${esc(r.parent_run.title)}</a>` : (r.parent ? esc(r.parent) : '');
  return `<div class="page-head"><div><h1>${esc(r.title || r.id)}</h1><div class="row" style="margin-top:6px">${badge(r.status)}${running ? '<span class="spinner"></span>' : ''}` +
    `<span class="badge info">${esc(r.agent)}</span>${r.code != null && !running ? `<span class="muted small">exit ${r.code}</span>` : ''}</div>` +
    `<div class="sub">started ${ago(r.started_at)} · ${running ? 'running for ' : 'took '}${span(r.duration_seconds)} · ` +
    `${r.change ? `worktree of ${changeLink(r.change)}` : (r.workdir ? `<code>${esc(r.workdir)}</code>` : 'the project root')}${parent ? ` · ${esc(r.relation)} of ${parent}` : ''}</div></div>` +
    `<div class="row">${running ? '<button class="danger" data-act="stop-run" data-id="' + esc(r.id) + '">Stop</button>' : `<button class="secondary" data-act="rerun" data-id="${esc(r.id)}">Run again</button>`}</div></div>`;
}
Actions['stop-run'] = async (b) => { await post(`/api/runs/${enc(b.dataset.id)}/stop`); toast('Stopping…'); };
Actions.rerun = async (b) => { const d = await post(`/api/runs/${enc(b.dataset.id)}/rerun`); toast('Started again'); navigate(`/runs/${enc(d.id)}`); };
Forms['continue-run'] = async (form) => {
  const f = new FormData(form);
  const d = await post(`/api/runs/${enc(form.dataset.id)}/continue`, { prompt: f.get('prompt'), agent: f.get('agent'), context: f.get('context') === 'on', async: true });
  toast('Follow-up started');
  navigate(`/runs/${enc(d.id)}`);
};

route('/runs/:id', async (ctx) => {
  const id = ctx.params.id;
  const [r, cat] = await Promise.all([api(`/api/runs/${enc(id)}`), agentCatalog()]);
  ctx.crumbs([['Runs', '/runs'], [r.title || id]]);
  ctx.title(r.title || `Run ${id}`);
  const chain = [...(r.parent_run ? [r.parent_run] : []), ...r.children];
  ctx.show(`<div id="run-head">${runHead(r)}</div>` +
    `<div class="card"><header><h2>Prompt</h2></header>${viewerSlot('prompt-view')}</div>` +
    `<div class="card"><header><h2>Output</h2><span class="muted small" id="out-note"></span></header>${viewerSlot('out-view')}</div>` +
    `<div class="card"><header><h2>Continue this run</h2></header><form data-form="continue-run" data-id="${esc(id)}">` +
    `<label class="field"><span>Follow-up</span><textarea name="prompt" rows="5" required placeholder="Ask for a fix, a clarification or the next step…"></textarea></label>` +
    `<div class="row"><select name="agent">${agentOptions(cat, r.agent === 'auto' ? cat.selected[0] : r.agent)}</select>` +
    `<label class="check"><input type="checkbox" name="context" checked> include the previous prompt and output as context</label><button type="submit">Send follow-up</button></div></form></div>` +
    (chain.length ? `<div class="card"><header><h2>Related runs</h2></header>${chain.map((x) => `<div class="list-row"><span class="when">${ago(x.started_at)}</span>${badge(x.id === r.parent ? 'parent' : x.relation || 'child', 'info')}<div class="what"><a href="/runs/${enc(x.id)}">${esc(x.title)}</a></div>${badge(x.status)}</div>`).join('')}</div>` : ''));
  await logViewer($('#prompt-view'), 'run', `${id}.prompt.md`, { md: 'source' });
  const out = await mountViewer($('#out-view'), {
    name: `${id}.out.log`, follow: true, raw: `/api/logs/raw?kind=run&name=${enc(`${id}.out.log`)}`,
    load: async () => { const x = await api(`/api/runs/${enc(id)}`); return { content: x.output || '', size: x.output_size, truncated: x.output_truncated }; },
  });
  if (r.status === 'running') {
    const tick = async () => {
      const x = await api(`/api/runs/${enc(id)}`);
      $('#run-head').innerHTML = runHead(x);
      out.update({ content: x.output || '', size: x.output_size, truncated: x.output_truncated });
      if (x.status !== 'running') { View.cleanup(); refreshSummary(); }
    };
    ctx.poll(tick, 2000);
  }
});

// ---- jobs -----------------------------------------------------------------------------
route('/jobs', async (ctx) => {
  ctx.crumbs([['Jobs']]);
  ctx.title('Jobs');
  const status = ctx.query.get('status') || 'all';
  const d = await api('/api/jobs', { params: qparams() });
  const opts = [['all', 'All'], ['running', 'Running'], ['ok', 'Succeeded'], ['failed', 'Failed'], ['stopped', 'Stopped'], ['finished', 'Finished']]
    .filter(([v]) => v === 'all' || v === status || d.counts[v]).map(([v, l]) => ({ value: v, label: l, count: d.counts[v] ?? 0 }));
  ctx.show(pageHead('Jobs', 'Dispatcher, merger, gates and other kit commands started from the portal.') + `<div class="filters">${chips(opts, 'status', status)}</div>` +
    `<div class="card">${d.jobs.length ? `<table><thead><tr><th>Started</th><th>Job</th><th>Status</th><th>Took</th><th>Output</th></tr></thead><tbody>${d.jobs.map((j) =>
      `<tr><td class="nowrap">${when(j.started_at)}</td><td><a href="/jobs/${enc(j.id)}"><b>${esc(j.kind)}</b></a><div class="muted small mono">${esc(j.command)}</div></td><td>${badge(j.status)}</td><td>${span(j.duration_seconds)}</td><td>${bytes(j.output_size)}</td></tr>`).join('')}</tbody></table>${pager(d, 'jobs')}` : empty('No job started from the portal yet.')}</div>`);
});

function jobHead(j) {
  const running = j.status === 'running';
  return `<div class="page-head"><div><h1>${esc(j.kind)}</h1><div class="row" style="margin-top:6px">${badge(j.status)}${running ? '<span class="spinner"></span>' : ''}${j.code != null && !running ? `<span class="muted small">exit ${j.code}</span>` : ''}</div>` +
    `<div class="sub"><code>${esc(j.command)}</code><br>started ${ago(j.started_at)} · ${running ? 'running for ' : 'took '}${span(j.duration_seconds)}</div></div>` +
    `<div class="row">${running ? `<button class="danger" data-act="stop-job" data-id="${esc(j.id)}">Stop</button>` : ''}</div></div>`;
}
Actions['stop-job'] = async (b) => { await post(`/api/jobs/${enc(b.dataset.id)}/stop`); toast('Stopping…'); };

route('/jobs/:id', async (ctx) => {
  const id = ctx.params.id;
  const j = await api(`/api/jobs/${enc(id)}`);
  ctx.crumbs([['Jobs', '/jobs'], [j.kind]]);
  ctx.title(`Job ${j.kind}`);
  ctx.show(`<div id="job-head">${jobHead(j)}</div><div class="card"><header><h2>Output</h2></header>${viewerSlot('out-view')}</div>`);
  const out = await mountViewer($('#out-view'), {
    name: `${id}.out.log`, follow: true, raw: `/api/logs/raw?kind=job&name=${enc(`${id}.out.log`)}`,
    load: async () => { const x = await api(`/api/jobs/${enc(id)}`); return { content: x.output || '', size: x.output_size, truncated: x.output_truncated }; },
  });
  if (j.status === 'running') {
    ctx.poll(async () => {
      const x = await api(`/api/jobs/${enc(id)}`);
      $('#job-head').innerHTML = jobHead(x);
      out.update({ content: x.output || '', size: x.output_size, truncated: x.output_truncated });
      if (x.status !== 'running') { View.cleanup(); refreshSummary(); }
    }, 2000);
  }
});

// ---- agents -----------------------------------------------------------------------------
Actions.ping = async (b) => {
  const d = await post('/api/agents/ping', { agent: b.dataset.name });
  toast(`${b.dataset.name}: ${d.status}${d.latency_ms ? ` (${d.latency_ms} ms)` : ''}`, d.status !== 'ok');
  await showOutput(`Ping ${b.dataset.name}`, JSON.stringify(d, null, 2));
};

route('/agents', async (ctx) => {
  ctx.crumbs([['Agents']]);
  ctx.title('Agents');
  const d = await api('/api/agents');
  const c = d.catalog;
  const rows = c.agents.map((a) => `<tr><td><b>${esc(a.name)}</b><div class="muted small">${esc(a.label)}</div></td><td>${a.selected ? badge('selected', 'ok') : '<span class="muted">no</span>'}</td>` +
    `<td>${a.installed ? badge('on PATH', 'ok') : badge('missing', 'warn')}</td><td>${esc(a.roles.join(', ') || '–')}</td><td>${a.in_use ? badge(String(a.in_use), 'warn') : '0'}</td>` +
    `<td class="actions"><button class="small secondary" data-act="ping" data-name="${esc(a.name)}">Ping</button> <a class="btn small ghost" href="/runs/new">Message</a></td></tr>`).join('');
  ctx.show(pageHead('Agents', `Order <code>${esc(c.order)}</code> · permissions <code>${esc(c.permissions)}</code>${c.configured ? '' : ' · no config/agents.yaml yet'}`, '<a class="btn" href="/runs/new">New run</a>') +
    `<div class="card"><table><thead><tr><th>Agent</th><th>Selected</th><th>Installed</th><th>Roles</th><th>In use</th><th></th></tr></thead><tbody>${rows}</tbody></table></div>` +
    `<div class="card"><header><h2>Latest runs</h2><a href="/runs">All runs →</a></header>${d.runs.map((r) => `<div class="list-row"><span class="when">${ago(r.started_at)}</span><div class="what trunc"><a href="/runs/${enc(r.id)}">${esc(r.title)}</a><small>${esc(r.agent)}${r.change ? ` · ${esc(r.change)}` : ''}</small></div>${badge(r.status)}</div>`).join('') || empty('No run yet.')}</div>`);
});
