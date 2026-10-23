'use strict';
// ---------------------------------------------------------------------------
// Dashboard: what is running, what needs a person, what just happened.
// ---------------------------------------------------------------------------

function attentionHtml(d) {
  const rows = [];
  d.blocked.forEach((b) => rows.push(
    `<div class="list-row"><div class="what">${changeLink(b.change_name)} ${badge(b.reason)}${b.approved ? ' ' + badge('risk approved', 'ok') : ''}` +
    `<small>${esc(b.needs_human ? `question: ${b.needs_human}` : (b.retry_note || ''))}</small></div>` +
    `<div class="row">${unblockBtn(b.change_name, 'Unblock')}<a class="btn small secondary" href="/changes/${enc(b.change_name)}/continue">Continue</a></div></div>`));
  d.processes.leases.filter((l) => !l.alive).forEach((l) => rows.push(
    `<div class="list-row"><div class="what">${changeLink(l.change)} ${badge('stale lock', 'err')}<small>worker pid ${esc(l.pid)} died</small></div>${reclaimBtn(l.change)}</div>`));
  if (d.ready.length) {
    rows.push(`<div class="list-row"><div class="what">${badge('ready to merge', 'ok')} ${d.ready.map((n) => changeLink(n)).join(', ')}` +
      `<small>${d.processes.paused ? 'the kit is paused: the merger will not run' : 'waiting for the merger'}</small></div>${mergeBtn()}</div>`);
  }
  return rows.length ? rows.join('') : empty('Nothing needs a person right now.');
}

function runningHtml(d) {
  const p = d.processes;
  const rows = [];
  d.in_flight.filter((l) => l.alive).forEach((l) => rows.push(
    `<div class="list-row"><span class="dot warn pulse"></span><div class="what">${changeLink(l.change)}<small>pid ${esc(l.pid)} · since ${ago(l.acquired_at)}</small></div>${progressBar(l.done, l.total)}</div>`));
  p.portal_runs.forEach((r) => rows.push(
    `<div class="list-row"><span class="dot warn pulse"></span><div class="what"><a href="/runs/${enc(r.id)}">${esc(r.title)}</a><small>agent run · ${esc(r.agent)}</small></div>${when(r.started_at)}</div>`));
  p.portal_jobs.forEach((j) => rows.push(
    `<div class="list-row"><span class="dot warn pulse"></span><div class="what"><a href="/jobs/${enc(j.id)}">${esc(j.kind)}</a><small>job · ${esc(j.command)}</small></div>${when(j.started_at)}</div>`));
  p.agents_in_use.forEach((a) => rows.push(
    `<div class="list-row"><span class="dot warn"></span><div class="what">${esc(a.agent)}<small>agent process pid ${esc(a.pid)}</small></div></div>`));
  const guards = [
    ...p.locks.map((l) => [`${l.name} lock`, l.held]), ...p.daemons.map((x) => [x.name, x.running]), ['visual QA', p.visual_qa.open],
  ].map(([n, on]) => `<span class="badge ${on ? 'warn' : 'ok'}">${esc(n)}: ${on ? 'busy' : 'idle'}</span>`).join(' ');
  return (rows.join('') || empty('Idle: no change, run or job is in progress.')) + `<div class="row" style="margin-top:12px">${guards}</div>`;
}

function dashboardHtml(d) {
  const c = d.counts;
  const lc = d.last_cycle;
  const tile = (href, n, text, cls = '') => `<a class="tile ${cls}" href="${href}"><b>${n}</b><span>${text}</span></a>`;
  return pageHead('Dashboard', `${esc(d.app_name)} — ${d.processes.paused ? `paused: ${esc(d.processes.pause_reason || '')}` : 'running'}`,
    `${kitBtn('Run cycle', '/api/actions/cycle', { cls: 'secondary' })}${kitBtn('Dispatcher', '/api/actions/dispatch', { cls: 'secondary', confirm: 'Start the dispatcher?' })}` +
    `${kitBtn('Merger', '/api/actions/merge', { cls: 'secondary' })}${kitBtn('Sync repos', '/api/actions/sync', { cls: 'secondary' })}<a class="btn ghost" href="/queue/plan">Dispatch plan</a>`) +
    `<div class="tiles">` +
    tile('/changes?state=in_flight', c.in_flight, 'in flight', c.in_flight ? 'ok' : '') +
    tile('/changes?state=ready_to_merge', c.ready, 'ready to merge', c.ready ? 'warn' : '') +
    tile('/queue/blocked', c.blocked, 'blocked', c.blocked ? 'err' : '') +
    tile('/changes?state=stale_lock', c.stale, 'stale locks', c.stale ? 'err' : '') +
    tile('/queue/blocked', c.needs_human, 'need a human', c.needs_human ? 'err' : '') +
    tile('/queue/backlog', c.backlog, 'in the backlog') +
    tile('/queue/proposals', c.proposals, 'proposals to review', c.proposals ? 'warn' : '') +
    (lc ? tile(`/cycles/${enc(lc.stamp)}`, lc.running ? 'running' : clock(lc.at), `last cycle · ${ago(lc.at)}<br><small>${esc(label(lc.outcome))}</small>`, lc.running ? 'ok' : '') : '') +
    `</div>` +
    `<div class="grid two"><div class="card"><header><h2>Needs attention</h2><a href="/changes?state=attention">All →</a></header>${attentionHtml(d)}</div>` +
    `<div class="card"><header><h2>Running now</h2><a href="/changes?state=active">Active changes →</a></header>${runningHtml(d)}</div></div>` +
    `<div class="grid two" style="margin-top:16px"><div class="card"><header><h2>Latest executions</h2><a href="/executions">All executions →</a></header>` +
    `${d.executions.map((e) => execRow(e, { clockTime: false })).join('') || empty('No executions yet.')}</div>` +
    `<div class="card"><header><h2>Latest events</h2><a href="/events">All events →</a></header>${d.events.map(eventRow).join('') || empty('No events in log/events.jsonl yet.')}</div></div>`;
}

route('/', async (ctx) => {
  ctx.crumbs([]);
  ctx.title('Dashboard');
  const load = async () => {
    const d = await api('/api/dashboard');
    applySummary(d);
    ctx.show(dashboardHtml(d));
  };
  await load();
  ctx.poll(load, 8000);
});
