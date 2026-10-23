'use strict';
// ---------------------------------------------------------------------------
// Changes: the index, and one change with its overview, timeline, prompts,
// artifacts, events, worker log and the place to continue it.
// ---------------------------------------------------------------------------

const CHANGE_STATES = [
  ['all', 'All'], ['active', 'Active'], ['attention', 'Needs attention'], ['in_flight', 'In flight'], ['ready_to_merge', 'Ready to merge'], ['blocked', 'Blocked'],
  ['stale_lock', 'Stale lock'], ['worktree', 'Worktree'], ['queued', 'Queued'], ['integrated', 'Integrated'], ['recorded', 'Recorded'],
];

// What a person can do about an active change, by its state.
const liveActions = (c) => [
  c.state === 'stale_lock' ? reclaimBtn(c.change_name) : '',
  c.state === 'blocked' ? unblockBtn(c.change_name, 'Unblock') : '',
  c.state === 'ready_to_merge' ? mergeBtn() : '',
  `<a class="btn small secondary" href="/changes/${enc(c.change_name)}/continue">Continue</a>`,
].filter(Boolean).join(' ');

// Phase, task progress and why each change waits: the dispatcher's dry run, slow, so it fills in after the list.
function fillLive(ctx, changes) {
  const byName = Object.fromEntries(changes.map((c) => [c.change_name, c]));
  api('/api/worktrees').then(({ worktrees }) => {
    if (!ctx.live()) return;
    const by = Object.fromEntries(worktrees.map((w) => [w.change_name, w]));
    $$('[data-live-phase]').forEach((td) => {
      const w = by[td.dataset.livePhase];
      td.innerHTML = w ? `<code>${esc(w.phase)}</code><div style="margin-top:4px">${progressBar(w.tasks_done, w.tasks_total)}</div>` : '<span class="muted small">–</span>';
    });
    $$('[data-live-why]').forEach((td) => {
      const name = td.dataset.liveWhy;
      const why = by[name]?.diagnosis || (byName[name]?.blocked_reason ? `blocked: ${label(byName[name].blocked_reason)}` : '');
      td.innerHTML = why ? esc(why) : '<span class="muted small">–</span>';
    });
  }).catch((e) => {
    if (ctx.live()) $$('[data-live-why]').forEach((td) => { td.innerHTML = `<span class="muted small">unavailable: ${esc(e.message)}</span>`; });
  });
}

route('/changes', async (ctx) => {
  ctx.crumbs([['Changes']]);
  ctx.title('Changes');
  const q = ctx.query.get('q') || '';
  const state = ctx.query.get('state') || 'all';
  const live = state === 'active';
  const sort = ctx.query.get('sort') || (live ? 'state' : 'recent');
  const d = await api('/api/changes', { params: qparams({ sort }) });
  const opts = CHANGE_STATES.filter(([v]) => v === 'all' || v === state || d.counts[v]).map(([v, l]) => ({ value: v, label: l, count: d.counts[v] ?? 0 }));
  const nameCell = (c) => `<td${live ? ' style="min-width:15rem"' : ''}><a href="/changes/${enc(c.change_name)}"><b>${esc(c.change_name)}</b></a>${c.description ? `<div class="desc">${esc(c.description)}</div>` : ''}</td>`;
  const stateCell = (c) => `<td>${badge(c.state)}${c.blocked_reason ? `<div class="muted small">${esc(c.blocked_reason)}</div>` : ''}</td>`;
  const rows = d.changes.map((c) => (live
    ? `<tr>${nameCell(c)}${stateCell(c)}<td data-live-phase="${esc(c.change_name)}"><span class="muted small">…</span></td>` +
      `<td class="small" data-live-why="${esc(c.change_name)}"><span class="muted small">asking the dispatcher…</span></td><td class="actions">${liveActions(c)}</td></tr>`
    : `<tr>${nameCell(c)}${stateCell(c)}<td>${when(c.updated_at)}</td>` +
      `<td class="small nowrap">${c.plan_count} plan · ${c.build_count} build${c.repair_count ? ` · ${c.repair_count} repair` : ''}</td>` +
      `<td class="actions"><a class="btn small secondary" href="/changes/${enc(c.change_name)}/prompts">Prompts</a> <a class="btn small ghost" href="/changes/${enc(c.change_name)}/continue">Continue</a></td></tr>`)).join('');
  const head = live ? '<th>Change</th><th>State</th><th>Phase</th><th>Why it waits</th><th></th>' : '<th>Change</th><th>State</th><th>Last activity</th><th>Runs</th><th></th>';
  ctx.show(pageHead('Changes', live
    ? 'What is in progress or waiting: a worker, a lease, a worktree, a quarantine or the merger. The reason each one waits comes from the dispatcher and arrives a few seconds after the list.'
    : 'Every change the kit has worked on, most recent first. Open one to see its prompts, artifacts and what to do next.') +
    `<div class="filters">${chips(opts, 'state', state)}<div class="row">${searchForm(q, 'Search name or description')}` +
    `<select data-nav="sort">${[['recent', 'Most recent'], ['name', 'Name'], ['prompts', 'Most prompts'], ['state', 'State']].map(([v, l]) => `<option value="${v}" ${v === sort ? 'selected' : ''}>${l}</option>`).join('')}</select></div></div>` +
    `<div class="card">${d.changes.length ? `<table><thead><tr>${head}</tr></thead><tbody>${rows}</tbody></table>` : empty(live ? 'Nothing is in progress or waiting.' : 'No change matches.')}${pager(d, 'changes')}</div>`);
  if (live && d.changes.length) fillLive(ctx, d.changes);
});

// ---- one change ---------------------------------------------------------------
const CHANGE_TABS = (d, name) => [
  { key: 'overview', label: 'Overview', href: `/changes/${enc(name)}` },
  { key: 'timeline', label: 'Timeline', href: `/changes/${enc(name)}/timeline` },
  { key: 'prompts', label: 'Prompts', count: d.prompts.length, href: `/changes/${enc(name)}/prompts` },
  { key: 'artifacts', label: 'Artifacts', count: d.artifacts.length + d.jev_states.length, href: `/changes/${enc(name)}/artifacts` },
  { key: 'events', label: 'Events', count: d.events.length, href: `/changes/${enc(name)}/events` },
  { key: 'log', label: 'Worker log', href: `/changes/${enc(name)}/log` },
  { key: 'continue', label: 'Continue', href: `/changes/${enc(name)}/continue` },
];

function changeHead(d, tab) {
  const name = d.change_name;
  let primary = '';
  if (d.state === 'blocked') primary = unblockBtn(name, 'Unblock', { cls: '' });
  else if (d.state === 'stale_lock') primary = reclaimBtn(name);
  else if (d.state === 'ready_to_merge') primary = mergeBtn('success');
  const sub = [badge(d.state), d.item?.priority ? badge(d.item.priority, '') : '', d.updated_at ? `<span class="muted small">last activity ${ago(d.updated_at)}</span>` : ''].join(' ');
  return `<div class="page-head"><div><h1>${esc(name)}</h1><div class="row" style="margin-top:6px">${sub}</div>` +
    `${d.item?.description ? `<div class="sub">${esc(d.item.description)}</div>` : ''}</div><div class="row">${primary}</div></div>${tabs(CHANGE_TABS(d, name), tab)}`;
}

async function loadChange(ctx, tab, crumb) {
  const name = ctx.params.name;
  const d = await api(`/api/changes/${enc(name)}`);
  ctx.crumbs([['Changes', '/changes'], [name, `/changes/${enc(name)}`], ...(crumb ? [crumb] : [])]);
  ctx.title(`${name}${crumb ? ` · ${crumb[0]}` : ''}`);
  return d;
}

// Prompts, events and agent runs of a change in one list, newest first.
function changeTimeline(d) {
  const items = [
    ...d.prompts.map((p) => ({ at: p.at, type: p.role, p })),
    ...d.events.map((e) => ({ at: e.ts, type: 'event', e })),
    ...d.runs.map((r) => ({ at: r.started_at, type: 'run', r })),
  ].filter((i) => i.at).sort((a, b) => (a.at < b.at ? 1 : -1));
  return items;
}
function timelineItem(d, i) {
  const name = d.change_name;
  const abs = `<small class="muted" title="${esc(i.at)}">${esc(new Date(i.at).toLocaleString())}</small>`;
  if (i.type === 'event') return `<div class="ev event"><code>${esc(i.e.event)}</code> <span class="muted small">${esc(eventContext(i.e).slice(0, 160))}</span><br>${abs}</div>`;
  if (i.type === 'run') return `<div class="ev run">${badge('agent run', 'info')} <a href="/runs/${enc(i.r.id)}"><b>${esc(i.r.title)}</b></a> ${badge(i.r.status)}<br>${abs}</div>`;
  const p = i.p;
  return `<div class="ev ${p.role}">${kindBadge(p.role)} <a href="/changes/${enc(name)}/prompts/${enc(p.file)}"><b>${esc(p.phase)}</b></a>${p.repair ? ' ' + badge('repair', 'warn') : ''} <span class="muted small">${bytes(p.size)}</span><br>${abs}</div>`;
}

route('/changes/:name', async (ctx) => {
  const d = await loadChange(ctx);
  const latest = d.prompts.slice(-4).reverse();
  const facts = [
    ['State', badge(d.state)], ['Priority', esc(d.item?.priority || '–')],
    ['Depends on', esc((d.item?.depends_on || []).join(', ') || '–')],
    ['Tasks', progressBar(d.progress.done, d.progress.total)],
    ['Worktree', d.worktree ? `<code>${esc(d.worktree)}</code>` : '<span class="muted">none</span>'],
    ['Artifacts', d.artifact_source ? `${esc(d.artifact_source)} (${d.artifacts.length} files)` : '<span class="muted">none</span>'],
    ['Worker', d.lease ? `pid ${esc(d.lease.pid)} · ${d.lease.alive ? badge('alive', 'ok') : badge('dead', 'err')} · since ${ago(d.lease.acquired_at)}` : '<span class="muted">no lease</span>'],
  ].map(([k, v]) => `<dt>${k}</dt><dd>${v}</dd>`).join('');
  let blocked = '';
  if (d.blocked) {
    const b = d.blocked;
    blocked = `<div class="card"><header><h2>Why it stopped</h2>${badge(b.reason)}</header>` +
      (b.needs_human ? `<div class="alert warn"><b>Waiting for a person</b><br>${esc(b.needs_human)}</div><br>` : '') +
      `<p class="muted">${esc(b.retry_note || '')}</p>${b.details ? `<details><summary>Failure details</summary><pre class="plain" style="margin-top:8px">${esc(b.details)}</pre></details>` : ''}` +
      `<div class="row" style="margin-top:12px">${unblockBtn(d.change_name, 'Unblock')}${unblockBtn(d.change_name, 'Unblock + reset retries', { cls: 'secondary small' })}` +
      `${unblockBtn(d.change_name, 'Approve risk & unblock', { approve: true, cls: 'secondary small' })}<a class="btn small ghost" href="/changes/${enc(d.change_name)}/continue">More options</a></div></div>`;
  }
  ctx.show(changeHead(d, 'overview') + blocked +
    `<div class="grid two" style="margin-top:16px"><div class="card"><header><h2>Status</h2></header><dl class="kv">${facts}</dl></div>` +
    `<div class="card"><header><h2>Latest prompts</h2><a href="/changes/${enc(d.change_name)}/prompts">All ${d.prompts.length} →</a></header>` +
    `${latest.map((p) => `<div class="list-row"><span class="when">${ago(p.at)}</span>${kindBadge(p.role)}<div class="what"><a href="/changes/${enc(d.change_name)}/prompts/${enc(p.file)}">${esc(p.phase)}</a></div><span class="muted small">${bytes(p.size)}</span></div>`).join('') || empty('This change has not been run yet.')}</div></div>` +
    `<div class="card"><header><h2>Recent activity</h2><a href="/changes/${enc(d.change_name)}/timeline">Full timeline →</a></header><div class="timeline">${changeTimeline(d).slice(0, 8).map((i) => timelineItem(d, i)).join('') || empty('Nothing recorded yet.')}</div></div>`);
});

route('/changes/:name/prompts/:file', async (ctx) => {
  const d = await loadChange(ctx, 'prompts', ['Prompts', `/changes/${enc(ctx.params.name)}/prompts`]);
  const file = ctx.params.file;
  const rendered = /^rendered-(plan|build)$/.exec(file);
  const idx = d.prompts.findIndex((p) => p.file === file);
  const p = d.prompts[idx];
  const list = [...d.prompts].reverse().map((x) => ({ href: `/changes/${enc(d.change_name)}/prompts/${enc(x.file)}`, label: `${x.role.toUpperCase()} · ${x.phase}`, sub: `${new Date(x.at).toLocaleString()} · ${bytes(x.size)}`, file: x.file }));
  list.push(...['plan', 'build'].map((r) => ({ href: `/changes/${enc(d.change_name)}/prompts/rendered-${r}`, label: `${r.toUpperCase()} · rendered now`, sub: 'from config/prompts today', file: `rendered-${r}` })));
  const nav = !p ? '' : `<div class="row">${idx > 0 ? `<a class="btn small ghost" href="/changes/${enc(d.change_name)}/prompts/${enc(d.prompts[idx - 1].file)}">← Older</a>` : ''}` +
    `${idx < d.prompts.length - 1 ? `<a class="btn small ghost" href="/changes/${enc(d.change_name)}/prompts/${enc(d.prompts[idx + 1].file)}">Newer →</a>` : ''}` +
    `<a class="btn small secondary" href="/changes/${enc(d.change_name)}/continue?from=${enc(file)}">Use as the base of a new prompt</a></div>`;
  ctx.show(changeHead(d, 'prompts') + `<div class="split"><div class="card filelist">${fileList(list, file)}</div><div class="stack">` +
    `<div class="row between"><div>${p ? `${kindBadge(p.role)} <b>${esc(p.phase)}</b>${p.repair ? ' ' + badge('repair', 'warn') : ''} <span class="muted small">${esc(new Date(p.at).toLocaleString())}</span>` : rendered ? `${kindBadge(rendered[1])} <b>rendered now</b>` : ''}</div>${nav}</div>` +
    `${viewerSlot()}</div></div>`);
  const kind = rendered ? 'rendered' : 'prompt';
  const name = rendered ? rendered[1] : file;
  await mountViewer($('#viewer'), {
    name: rendered ? `${rendered[1]}.md` : file, md: 'source',
    raw: rendered ? null : `/api/logs/raw?kind=worker&name=${enc(`${d.change_name}/${file}`)}`,
    load: (full) => api(`/api/changes/${enc(d.change_name)}/file`, { params: { kind, name, tail: full ? 0 : 300000 } }),
  });
});

const fileList = (items, active) => items.map((i) => `<a href="${esc(i.href)}" class="${i.file === active ? 'active' : ''}">${esc(i.label)}${i.sub ? `<small>${esc(i.sub)}</small>` : ''}</a>`).join('') || '<div class="empty small">No files.</div>';

route('/changes/:name/artifacts/*file', async (ctx) => {
  const d = await loadChange(ctx, 'artifacts', ['Artifacts', `/changes/${enc(ctx.params.name)}/artifacts`]);
  const file = ctx.params.file;
  return showArtifactPage(ctx, d, file, 'artifact', file);
});
route('/changes/:name/jev/:file', async (ctx) => {
  const d = await loadChange(ctx, 'artifacts', ['Artifacts', `/changes/${enc(ctx.params.name)}/artifacts`]);
  return showArtifactPage(ctx, d, `jev:${ctx.params.file}`, 'jev', ctx.params.file);
});
function showArtifactPage(ctx, d, active, kind, file) {
  const n = enc(d.change_name);
  const list = [...d.artifacts.map((a) => ({ href: `/changes/${n}/artifacts/${encPath(a.name)}`, label: a.name, sub: bytes(a.size), file: a.name })),
    ...d.jev_states.map((j) => ({ href: `/changes/${n}/jev/${enc(j.file)}`, label: j.file, sub: `Jev state · ${bytes(j.size)}`, file: `jev:${j.file}` }))];
  ctx.show(changeHead(d, 'artifacts') + `<div class="split"><div class="card filelist">${fileList(list, active)}</div>${viewerSlot()}</div>`);
  return mountViewer($('#viewer'), {
    name: file,
    load: (full) => api(`/api/changes/${n}/file`, { params: { kind, name: file, tail: full ? 0 : 300000 } }),
  });
}
route('/changes/:name/artifacts', async (ctx) => {
  const d = await loadChange(ctx, 'artifacts', ['Artifacts']);
  const first = d.artifacts[0];
  if (first) return navigate(`/changes/${enc(d.change_name)}/artifacts/${encPath(first.name)}`, { replace: true });
  const jev = d.jev_states[0];
  if (jev) return navigate(`/changes/${enc(d.change_name)}/jev/${enc(jev.file)}`, { replace: true });
  ctx.show(changeHead(d, 'artifacts') + `<div class="card">${empty('This change has no OpenSpec artifacts on disk (no worktree, and it is not archived).')}</div>`);
});

route('/changes/:name/prompts', async (ctx) => {
  const d = await loadChange(ctx, 'prompts', ['Prompts']);
  const n = enc(d.change_name);
  const all = [...d.prompts].reverse();
  const pg = slicePage(all, ctx.query, 25);
  ctx.show(changeHead(d, 'prompts') + `<div class="card"><header><h2>Every prompt this change was run with</h2>` +
    `<div class="row"><a class="btn small secondary" href="/changes/${n}/prompts/rendered-plan">PLAN rendered now</a><a class="btn small secondary" href="/changes/${n}/prompts/rendered-build">BUILD rendered now</a></div></header>` +
    `${all.length ? `<table><thead><tr><th>When</th><th>Role</th><th>Phase</th><th>Size</th><th></th></tr></thead><tbody>${pg.items.map((p) =>
      `<tr><td>${when(p.at)}</td><td>${kindBadge(p.role)}</td><td><a href="/changes/${n}/prompts/${enc(p.file)}"><b>${esc(p.phase)}</b></a>${p.repair ? ' ' + badge('repair', 'warn') : ''}</td><td>${bytes(p.size)}</td>` +
      `<td class="actions"><a class="btn small ghost" href="/changes/${n}/continue?from=${enc(p.file)}">Use as base</a></td></tr>`).join('')}</tbody></table>${pager(pg, 'prompts')}` : empty('No prompt was recorded for this change (log/workers/).')}</div>`);
});

route('/changes/:name/timeline', async (ctx) => {
  const d = await loadChange(ctx, 'timeline', ['Timeline']);
  const pg = slicePage(changeTimeline(d), ctx.query, 40);
  ctx.show(changeHead(d, 'timeline') + `<div class="card"><div class="timeline">${pg.items.map((i) => timelineItem(d, i)).join('') || empty('Nothing recorded yet.')}</div>${pager(pg, 'entries')}</div>`);
});

route('/changes/:name/events', async (ctx) => {
  const d = await loadChange(ctx, 'events', ['Events']);
  const pg = slicePage(d.events, ctx.query, 25);
  ctx.show(changeHead(d, 'events') + `<div class="card">${d.events.length ? `<table><thead><tr><th>Time</th><th>Event</th><th>Context</th></tr></thead><tbody>${pg.items.map((e) =>
    `<tr><td class="nowrap">${when(e.ts)}</td><td><code>${esc(e.event)}</code></td><td><div class="small">${esc(eventContext(e).slice(0, 200))}</div><details><summary class="muted small">raw</summary><pre class="plain">${esc(JSON.stringify(e, null, 2))}</pre></details></td></tr>`).join('')}</tbody></table>${pager(pg, 'events')}` : empty('No event of this change in log/events.jsonl.')}</div>`);
});

route('/changes/:name/log', async (ctx) => {
  const d = await loadChange(ctx, 'log', ['Worker log']);
  ctx.show(changeHead(d, 'log') + (d.worker_log ? `<div class="row between" style="margin-bottom:10px"><span class="muted">log/workers/${esc(d.change_name)}.log · ${bytes(d.worker_log.size)} · updated ${ago(d.worker_log.mtime)}</span></div>${viewerSlot()}` : `<div class="card">${empty('This change has no worker log.')}</div>`));
  if (!d.worker_log) return;
  const v = await logViewer($('#viewer'), 'worker', `${d.change_name}.log`, { follow: true });
  if (d.state === 'in_flight') ctx.poll(() => v.refresh(), 5000);
});

// ---- continue ---------------------------------------------------------------------
Forms['change-agent'] = async (form) => {
  const f = new FormData(form);
  const name = form.dataset.change;
  const d = await post(`/api/changes/${enc(name)}/agent`, { agent: f.get('agent'), prompt: f.get('prompt'), async: true });
  toast('Agent started');
  navigate(`/runs/${enc(d.id)}`);
};
Actions['validate-worker'] = async (b) => {
  const d = await post(`/api/changes/${enc(b.dataset.name)}/validate`);
  await showOutput(d.ok ? 'Specs are valid' : 'Spec validation failed', d.output || '(no output)');
};
Actions['reset-worker'] = async (b) => {
  if (!(await confirmDialog(`Remove .worktrees/worker-${b.dataset.name}, its branches, its quarantine record and its dispatch state? The change will start again from the backlog.`, { ok: 'Reset worker', danger: true }))) return;
  await post(`/api/changes/${enc(b.dataset.name)}/reset`);
  toast(`Reset ${b.dataset.name}`);
  afterAction();
};

route('/changes/:name/continue', async (ctx) => {
  const d = await loadChange(ctx, 'continue', ['Continue']);
  const name = d.change_name;
  const [ag, from] = await Promise.all([api('/api/agents'), ctx.query.get('from')
    ? api(`/api/changes/${enc(name)}/file`, { params: { kind: ctx.query.get('from').startsWith('rendered-') ? 'rendered' : 'prompt', name: ctx.query.get('from').replace(/^rendered-/, ''), tail: 60000 } }).catch(() => null)
    : Promise.resolve(null)]);
  const steps = [];
  if (d.blocked) {
    steps.push(`<div class="card"><header><h2>It is stopped: ${esc(label(d.blocked.reason))}</h2></header>` +
      `${d.blocked.needs_human ? `<div class="alert warn"><b>Question for a person</b><br>${esc(d.blocked.needs_human)}</div><p class="muted">Answer it by fixing the worktree (run an agent below, or edit it by hand), then unblock.</p>` : ''}` +
      `<p class="muted">${esc(d.blocked.retry_note || '')}</p><div class="row">${unblockBtn(name, 'Unblock', { cls: '' })}${unblockBtn(name, 'Unblock + reset retries', { cls: 'secondary' })}${unblockBtn(name, 'Approve risk & unblock', { approve: true, cls: 'secondary' })}</div></div>`);
  }
  if (d.state === 'stale_lock') steps.push(`<div class="card"><header><h2>Its worker died</h2></header><p class="muted">The lease points at a process that no longer exists. Reclaim it and the dispatcher will pick the change up again.</p>${reclaimBtn(name)}</div>`);
  if (d.state === 'ready_to_merge') steps.push(`<div class="card"><header><h2>Built and waiting for the merger</h2></header><p class="muted">${State.summary?.processes.paused ? 'The kit is paused, so the merger will not run until you resume.' : 'The merger integrates it on its next pass, or run it now.'}</p>${mergeBtn('success')}</div>`);
  const wt = d.worktree_exists;
  const tools = wt ? `<div class="row"><button class="secondary" data-act="validate-worker" data-name="${esc(name)}">Validate specs</button>${kitBtn('Run gates', `/api/changes/${enc(name)}/gates`, { cls: 'secondary' })}<button class="danger" data-act="reset-worker" data-name="${esc(name)}">Reset worker…</button></div>` : '<p class="muted">There is no worktree for this change, so there is nothing to validate, gate or reset.</p>';
  const agentOpts = ag.catalog.agents.map((a) => `<option value="${esc(a.name)}" ${a.name === ag.catalog.selected[0] ? 'selected' : ''}>${esc(a.name)}${a.installed ? '' : ' (not on PATH)'}</option>`).join('');
  const form = wt ? `<form data-form="change-agent" data-change="${esc(name)}"><label class="field"><span>Agent</span><select name="agent">${agentOpts}</select></label>` +
    `<label class="field"><span>Prompt${from ? ` (from ${esc(ctx.query.get('from'))}, edit it freely)` : ''}</span><textarea name="prompt" rows="${from ? 16 : 6}" placeholder="What should the agent do inside .worktrees/worker-${esc(name)}?">${esc(from?.content || '')}</textarea></label>` +
    `<button type="submit">Run in the background</button> <span class="muted small">It opens the run, where you can follow the output and continue it.</span></form>`
    : alertBox('An agent can only be started in a worktree. Use <a href="/runs/new">New run</a> to start one at the project root.');
  const runs = d.runs.length ? `<table><thead><tr><th>Started</th><th>Run</th><th>Agent</th><th>Status</th></tr></thead><tbody>${d.runs.map((r) => `<tr><td>${when(r.started_at)}</td><td><a href="/runs/${enc(r.id)}">${esc(r.title)}</a></td><td>${esc(r.agent)}</td><td>${badge(r.status)}</td></tr>`).join('')}</tbody></table>` : empty('No agent run started from the portal for this change yet.');
  ctx.show(changeHead(d, 'continue') + steps.join('') +
    `<div class="card"><header><h2>Worktree tools</h2></header>${tools}</div>` +
    `<div class="card"><header><h2>Send a prompt to an agent in the worktree</h2></header>${form}</div>` +
    `<div class="card"><header><h2>Runs for this change</h2></header>${runs}</div>`);
});
