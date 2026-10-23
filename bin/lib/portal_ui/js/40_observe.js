'use strict';
// ---------------------------------------------------------------------------
// Observe: cycles and their reports, visual QA and the event stream.
// ---------------------------------------------------------------------------

route('/cycles', async (ctx) => {
  ctx.crumbs([['Cycles']]);
  ctx.title('Cycles');
  const q = ctx.query.get('q') || '';
  const d = await api('/api/cycles', { params: qparams() });
  const rows = d.cycles.map((c) => {
    const n = enc(c.stamp);
    const links = [c.report_files.length ? `<a href="/cycles/${n}/report">Report</a>` : '', c.prompt_file ? `<a href="/cycles/${n}/prompt">Prompt</a>` : '', `<a href="/cycles/${n}/log">Log</a>`].filter(Boolean).join(' · ');
    return `<tr><td class="nowrap"><a href="/cycles/${n}"><b>${esc(new Date(c.at).toLocaleString())}</b></a><div class="muted small">${ago(c.at)}</div></td>` +
      `<td>${badge(c.outcome)}${c.running ? ' <span class="spinner"></span>' : ''}</td><td>${esc(c.strategy || '–')}</td><td class="small">${esc(c.engine || '–')}</td><td class="small nowrap">${links}</td></tr>`;
  }).join('');
  ctx.show(pageHead('Cycles', 'The scheduled headless judgment runs. Each one has its execution log, the prompt it was given and the report it wrote.') +
    `<div class="filters"><span class="muted">${d.total} cycles</span>${searchForm(q, 'Search outcome, strategy or agent')}</div>` +
    `<div class="card">${d.cycles.length ? `<table><thead><tr><th>Started</th><th>Outcome</th><th>Strategy</th><th>Judge agents</th><th>Open</th></tr></thead><tbody>${rows}</tbody></table>` : empty('No cycle matches.')}${pager(d, 'cycles')}</div>`);
});

// A page with tabs of files: cycles and visual QA sessions share it.
function fileTabsPage(ctx, { tabs: defs, active, headHtml }) {
  const base = ctx.path.split('/').slice(0, 3).join('/');
  ctx.show(headHtml + tabs(defs.map((t) => ({ ...t, href: `${base}/${t.key}` })), active) + viewerSlot());
}

route('/cycles/:stamp/:tab?', async (ctx) => {
  const c = await api(`/api/cycles/${enc(ctx.params.stamp)}`);
  const defs = [c.report_files.length && { key: 'report', label: 'Report', kind: 'report', file: c.report_files[Number(ctx.query.get('r')) || 0] },
    c.prompt_file && { key: 'prompt', label: 'Prompt', kind: 'cycle', file: c.prompt_file },
    { key: 'log', label: 'Execution log', kind: 'cycle', file: c.log_file }].filter(Boolean);
  const tab = defs.find((t) => t.key === ctx.params.tab) || defs[0];
  ctx.crumbs([['Cycles', '/cycles'], [new Date(c.at).toLocaleString(), `/cycles/${enc(c.stamp)}`], [tab.label]]);
  ctx.title(`Cycle ${new Date(c.at).toLocaleString()} · ${tab.label}`);
  const nav = `<div class="row">${c.newer ? `<a class="btn small ghost" href="/cycles/${enc(c.newer)}/${tab.key}">← Newer</a>` : ''}${c.older ? `<a class="btn small ghost" href="/cycles/${enc(c.older)}/${tab.key}">Older →</a>` : ''}</div>`;
  const head = `<div class="page-head"><div><h1>Cycle ${esc(new Date(c.at).toLocaleString())}</h1><div class="row" style="margin-top:6px">${badge(c.outcome)}${c.strategy ? `<span class="badge info">${esc(c.strategy)}</span>` : ''}` +
    `<span class="muted small">${esc(c.engine || '')}</span></div><div class="sub">${esc(c.preflight || '')}</div></div>${nav}</div>`;
  fileTabsPage(ctx, { tabs: defs, active: tab.key, headHtml: head });
  const extra = tab.key === 'report' && c.report_files.length > 1 ? `<div class="chips" style="margin-bottom:10px">${c.report_files.map((f, i) => `<a href="/cycles/${enc(c.stamp)}/report?r=${i}" class="${i === (Number(ctx.query.get('r')) || 0) ? 'active' : ''}">${esc(f)}</a>`).join('')}</div>` : '';
  if (extra) $('#viewer').insertAdjacentHTML('beforebegin', extra);
  const v = await logViewer($('#viewer'), tab.kind, tab.file, { follow: tab.key === 'log' });
  if (c.running && tab.key === 'log') ctx.poll(() => v.refresh(), 4000);
});

// ---- visual QA ------------------------------------------------------------------------
route('/visual', async (ctx) => {
  ctx.crumbs([['Visual QA']]);
  ctx.title('Visual QA');
  const d = await api('/api/visual', { params: { per: 1 } });
  const items = d.queue.items || [];
  const status = ctx.query.get('status') || 'all';
  const counts = items.reduce((a, i) => ({ ...a, [i.status]: (a[i.status] || 0) + 1 }), {});
  const shown = status === 'all' ? items : items.filter((i) => i.status === status);
  const pg = slicePage(shown, ctx.query, 25);
  const opts = [['all', 'All'], ...Object.keys(counts).sort().map((s) => [s, label(s)])].map(([v, l]) => ({ value: v, label: l, count: v === 'all' ? items.length : counts[v] }));
  ctx.show(pageHead('Visual QA', `Browser checks queued for the visual session. ${d.enabled ? 'Enabled.' : 'Disabled (visual_qa.enabled in config/cycle.yaml).'}`,
    `${kitBtn('Begin session', '/api/actions/visual_qa', { body: { op: 'begin' }, cls: 'secondary' })}${kitBtn('End session', '/api/actions/visual_qa', { body: { op: 'end' }, cls: 'secondary' })}`) +
    tabs([{ key: 'queue', label: 'Queue', count: items.length, href: '/visual' }, { key: 'sessions', label: 'Sessions', count: d.total, href: '/visual/sessions' }], 'queue') +
    `<form data-form="visual-request" class="row" style="margin-bottom:14px"><input name="what" class="grow" placeholder="Ask for a check in the browser…" required><button type="submit">Queue check</button></form>` +
    `<div class="filters">${chips(opts, 'status', status)}</div><div class="card">${pg.items.length ? `<table><thead><tr><th>#</th><th>Status</th><th>What to check</th><th>Change</th><th>Created</th></tr></thead><tbody>${pg.items.map((i) =>
      `<tr><td>${i.id}</td><td>${badge(i.status)}${i.verdict ? `<div class="muted small">${esc(i.verdict)}</div>` : ''}</td><td><div class="desc">${esc(i.detail || i.kind || '')}</div>${i.note ? `<div class="muted small">${esc(i.note)}</div>` : ''}</td><td>${i.change ? changeLink(i.change) : '–'}</td><td>${when(i.created_at)}</td></tr>`).join('')}</tbody></table>${pager(pg, 'checks')}` : empty('The queue is empty.')}</div>`);
});
Forms['visual-request'] = async (form) => {
  await post('/api/actions/visual_qa', { op: 'request', what: new FormData(form).get('what') });
  toast('Check queued');
  render();
};

route('/visual/sessions', async (ctx) => {
  ctx.crumbs([['Visual QA', '/visual'], ['Sessions']]);
  ctx.title('Visual QA sessions');
  const d = await api('/api/visual', { params: qparams() });
  ctx.show(pageHead('Visual QA sessions', 'Each session plans its checks, runs them in a browser and writes a report.') +
    tabs([{ key: 'queue', label: 'Queue', count: (d.queue.items || []).length, href: '/visual' }, { key: 'sessions', label: 'Sessions', count: d.total, href: '/visual/sessions' }], 'sessions') +
    `<div class="card">${d.sessions.length ? `<table><thead><tr><th>Started</th><th>Open</th></tr></thead><tbody>${d.sessions.map((s) => {
      const n = enc(s.stamp);
      return `<tr><td>${when(s.at)}<div class="muted small">${esc(new Date(s.at).toLocaleString())}</div></td><td><a href="/visual/${n}/plan">Plan</a>${s.report_file ? ` · <a href="/visual/${n}/report">Report</a>` : ''}${s.sync_log ? ` · <a href="/visual/${n}/sync">Sync log</a>` : ''}</td></tr>`;
    }).join('')}</tbody></table>${pager(d, 'sessions')}` : empty('No visual QA session recorded yet.')}</div>`);
});

route('/visual/:stamp/:tab?', async (ctx) => {
  const d = await api('/api/visual', { params: { per: 200 } });
  const s = d.sessions.find((x) => x.stamp === ctx.params.stamp);
  if (!s) throw new Error('Visual QA session not found');
  const defs = [{ key: 'plan', label: 'Plan', kind: 'cycle', file: s.plan_file }, s.report_file && { key: 'report', label: 'Report', kind: 'report', file: s.report_file },
    s.sync_log && { key: 'sync', label: 'Sync log', kind: 'cycle', file: s.sync_log }].filter(Boolean);
  const tab = defs.find((t) => t.key === ctx.params.tab) || defs[0];
  ctx.crumbs([['Visual QA', '/visual'], ['Sessions', '/visual/sessions'], [new Date(s.at).toLocaleString(), `/visual/${enc(s.stamp)}`], [tab.label]]);
  ctx.title(`Visual QA ${new Date(s.at).toLocaleString()} · ${tab.label}`);
  fileTabsPage(ctx, { tabs: defs, active: tab.key, headHtml: pageHead(`Visual QA session ${esc(new Date(s.at).toLocaleString())}`) });
  await logViewer($('#viewer'), tab.kind, tab.file);
});

// ---- events -----------------------------------------------------------------------------
route('/events', async (ctx) => {
  ctx.crumbs([['Events']]);
  ctx.title('Events');
  const q = ctx.query.get('q') || '';
  const event = ctx.query.get('event') || '';
  const change = ctx.query.get('change') || '';
  const d = await api('/api/events', { params: qparams() });
  const types = `<select data-nav="event"><option value="">All events</option>${Object.entries(d.event_types).map(([k, n]) => `<option value="${esc(k)}" ${k === event ? 'selected' : ''}>${esc(k)} (${n})</option>`).join('')}</select>`;
  ctx.show(pageHead('Events', `The orchestrator's event stream (log/events.jsonl): the last ${d.window.toLocaleString()} events, newest first.`) +
    (change ? alertBox(`Showing only <b>${esc(change)}</b>. <a href="${esc(withParams({ change: null, page: null }))}">Show everything</a>`) + '<br>' : '') +
    `<div class="filters"><div class="row">${types}</div>${searchForm(q, 'Search any field')}</div>` +
    `<div class="card">${d.events.length ? `<table><thead><tr><th>Time</th><th>Event</th><th>Change</th><th>Context</th></tr></thead><tbody>${d.events.map((e) =>
      `<tr><td class="nowrap">${when(e.ts)}<div class="muted small">${esc((e.ts || '').replace('T', ' ').slice(0, 19))}</div></td><td><code>${esc(e.event)}</code></td><td>${e.change ? changeLink(e.change) : '–'}</td>` +
      `<td><div class="small">${esc(eventContext(e).slice(0, 220))}</div><details><summary class="muted small">raw</summary><pre class="plain">${esc(JSON.stringify(e, null, 2))}</pre></details></td></tr>`).join('')}</tbody></table>${pager(d, 'events')}` : empty('No event matches (or log/events.jsonl does not exist yet).')}</div>`);
});
