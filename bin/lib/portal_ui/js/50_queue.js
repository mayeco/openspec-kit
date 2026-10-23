'use strict';
// ---------------------------------------------------------------------------
// Queue: backlog, proposals, blocked changes, integrated history, dispatch plan.
// ---------------------------------------------------------------------------

function queueTabs(active) {
  const c = State.summary?.counts || {};
  return tabs([
    { key: 'backlog', label: 'Backlog', count: c.backlog, href: '/queue/backlog' },
    { key: 'proposals', label: 'Proposals', count: c.proposals, href: '/queue/proposals' },
    { key: 'blocked', label: 'Blocked', count: c.blocked, href: '/queue/blocked' },
    { key: 'history', label: 'Integrated', href: '/queue/history' },
    { key: 'plan', label: 'Dispatch plan', href: '/queue/plan' },
  ], active);
}

Forms['backlog-add'] = async (form) => {
  const f = Object.fromEntries(new FormData(form));
  await post('/api/backlog', f);
  toast(`Queued ${f.change_name}`);
  afterAction();
};
Actions['backlog-remove'] = async (b) => {
  if (!(await confirmDialog(`Remove ${b.dataset.name} from the backlog?`, { ok: 'Remove', danger: true }))) return;
  await api(`/api/backlog/${enc(b.dataset.name)}`, { method: 'DELETE' });
  toast(`Removed ${b.dataset.name}`);
  afterAction();
};
Actions.decide = async (b) => {
  await post(`/api/proposals/${enc(b.dataset.name)}/${b.dataset.decision}`);
  toast(`${b.dataset.name}: ${b.dataset.decision}d`);
  afterAction();
};
Actions['review-proposals'] = async () => { await post('/api/proposals/review'); toast('Proposals reviewed'); afterAction(); };

async function queueBacklog(ctx) {
  const { backlog } = await api('/api/backlog');
  const pg = slicePage(backlog, ctx.query, 25);
  ctx.show(pageHead('Queue', 'What waits to be planned and built.') + queueTabs('backlog') +
    `<details class="card" style="margin-bottom:16px"><summary><b>+ Add an item to the backlog</b></summary><form data-form="backlog-add" style="margin-top:12px">` +
    `<div class="row"><label class="field grow"><span>Change name (kebab-case)</span><input name="change_name" required></label>` +
    `<label class="field"><span>Priority</span><select name="priority">${['normal', 'high', 'critical', 'low'].map((p) => `<option>${p}</option>`).join('')}</select></label>` +
    `<label class="field grow"><span>Depends on (comma separated)</span><input name="depends_on"></label></div>` +
    `<label class="field"><span>Description and acceptance criteria</span><textarea name="description" rows="4" required></textarea></label><button type="submit">Add to the backlog</button></form></details>` +
    `<div class="card">${pg.items.length ? `<table><thead><tr><th>Change</th><th>Priority</th><th>Queue status</th><th>Description</th><th></th></tr></thead><tbody>${pg.items.map((i) =>
      `<tr><td>${changeLink(i.change_name)}${i.depends_on ? `<div class="muted small">depends on ${esc(i.depends_on.join(', '))}</div>` : ''}</td><td>${badge(i.priority || 'normal', '')}</td>` +
      `<td data-plan="${esc(i.change_name)}"><span class="muted small">…</span></td><td><div class="desc">${esc(i.description)}</div></td>` +
      `<td class="actions"><button class="small danger" data-act="backlog-remove" data-name="${esc(i.change_name)}">Remove</button></td></tr>`).join('')}</tbody></table>${pager(pg, 'items')}` : empty('config/agent_backlog.json is empty.')}</div>`);
  if (!pg.items.length) return;
  api('/api/plan').then((plan) => {
    if (!ctx.live()) return;
    const by = Object.fromEntries((plan.items || []).map((r) => [r.change, r]));
    $$('[data-plan]').forEach((td) => {
      const r = by[td.dataset.plan];
      td.innerHTML = r ? `${badge(r.state, r.next ? 'ok' : '')}${r.counts_as && r.counts_as !== r.priority ? ` <span class="muted small">counts as ${esc(r.counts_as)}</span>` : ''}<div class="muted small">${esc(r.why || '')}</div>` : '<span class="muted small">–</span>';
    });
  }).catch(() => {});
}

async function queueProposals(ctx) {
  const { proposals } = await api('/api/proposals');
  const pg = slicePage(proposals, ctx.query, 25);
  ctx.show(pageHead('Queue', 'Improvements and roadmap features waiting for an approval.', '<button class="secondary" data-act="review-proposals">Run review</button>') + queueTabs('proposals') +
    `<div class="card">${pg.items.length ? `<table><thead><tr><th>Proposal</th><th>Status</th><th>Source</th><th>Description</th><th></th></tr></thead><tbody>${pg.items.map((p) => {
      const acts = ['proposed', 'approved'].includes(p.status) ? `<button class="small success" data-act="decide" data-name="${esc(p.change_name)}" data-decision="approve">Approve</button> <button class="small danger" data-act="decide" data-name="${esc(p.change_name)}" data-decision="reject">Reject</button>` : '';
      return `<tr><td>${changeLink(p.change_name)}</td><td>${badge(p.status)}</td><td>${esc(p.source || '–')}</td><td><div class="desc">${esc(p.description || '')}</div></td><td class="actions">${acts}</td></tr>`;
    }).join('')}</tbody></table>${pager(pg, 'proposals')}` : empty('No proposal.')}</div>`);
}

async function queueBlocked(ctx) {
  const { blocked } = await api('/api/blocked');
  const pg = slicePage(blocked, ctx.query, 10);
  ctx.show(pageHead('Queue', 'Quarantined changes and questions waiting for a person. Unblocking removes the record and the change runs again.') + queueTabs('blocked') +
    (pg.items.map((b) => `<div class="card"><header><div class="row">${changeLink(b.change_name)} ${badge(b.reason)}${b.approved ? badge('risk approved', 'ok') : ''}<span class="muted small">${b.blocked_at ? ago(b.blocked_at) : ''}</span></div>` +
      `<div class="row"><a class="btn small ghost" href="/changes/${enc(b.change_name)}">Open</a><a class="btn small secondary" href="/changes/${enc(b.change_name)}/continue">Continue</a></div></header>` +
      `${b.needs_human ? `<div class="alert warn"><b>Question for a person</b><br>${esc(b.needs_human)}</div><br>` : ''}<p class="muted">${esc(b.retry_note || '')}</p>` +
      `${b.details ? `<details><summary>Failure details</summary><pre class="plain" style="margin-top:8px">${esc(b.details)}</pre></details>` : ''}` +
      `<div class="row" style="margin-top:12px">${unblockBtn(b.change_name, 'Unblock', { reset: false })}${unblockBtn(b.change_name, 'Unblock + reset retries', { cls: 'secondary small' })}${unblockBtn(b.change_name, 'Approve risk & unblock', { approve: true, cls: 'secondary small' })}</div></div>`).join('') || `<div class="card">${empty('No blocked change.')}</div>`) + pager(pg, 'blocked'));
}

async function queueHistory(ctx) {
  const q = ctx.query.get('q') || '';
  const d = await api('/api/history', { params: qparams() });
  ctx.show(pageHead('Queue', 'Changes that were integrated (config/agent_history.json), newest first.') + queueTabs('history') +
    `<div class="filters"><span class="muted">${d.total} integrated</span>${searchForm(q, 'Search name or description')}</div>` +
    `<div class="card">${d.history.length ? `<table><thead><tr><th>Change</th><th>Priority</th><th>Integrated</th><th>Description</th></tr></thead><tbody>${d.history.map((h) =>
      `<tr><td>${changeLink(h.change_name)}</td><td>${badge(h.priority || 'normal', 'ok')}</td><td>${when(h.integrated_at)}</td><td><div class="desc">${esc(h.description || '')}</div></td></tr>`).join('')}</tbody></table>${pager(d, 'changes')}` : empty('Nothing integrated yet.')}</div>`);
}

async function queuePlan(ctx) {
  ctx.show(pageHead('Queue', 'What the dispatcher would start next and why each pending item waits.') + queueTabs('plan') + loading('Asking the dispatcher (dry run)…'));
  const d = await api('/api/plan');
  const items = d.items || [];
  ctx.show(pageHead('Queue', 'What the dispatcher would start next and why each pending item waits.', '<button class="secondary" data-act="reload">Run again</button>') + queueTabs('plan') +
    (d.error ? alertBox(esc(d.error), 'err') : `<div class="card">${items.length ? `<table><thead><tr><th>Change</th><th>State</th><th>Counts as</th><th>Why</th></tr></thead><tbody>${items.map((r) =>
      `<tr><td>${changeLink(r.change)}</td><td>${badge(r.state, r.next ? 'ok' : undefined)}${r.next ? ' <span class="muted small">next</span>' : ''}</td><td>${esc(r.counts_as || '–')}</td><td class="small">${esc(r.why || '')}</td></tr>`).join('')}</tbody></table>` : empty('Nothing is waiting.')}</div>`) +
    `<details class="card" style="margin-top:16px"><summary>Raw result</summary><pre class="plain" style="margin-top:8px">${esc(JSON.stringify(d, null, 2))}</pre></details>`);
}

route('/queue/:tab?', async (ctx) => {
  const tab = ctx.params.tab || 'backlog';
  const fn = { backlog: queueBacklog, proposals: queueProposals, blocked: queueBlocked, history: queueHistory, plan: queuePlan }[tab];
  if (!fn) throw new Error(`Unknown queue tab ${tab}`);
  ctx.crumbs([['Queue', '/queue/backlog'], [tab[0].toUpperCase() + tab.slice(1)]]);
  ctx.title(`Queue · ${tab}`);
  if (!State.summary) await refreshSummary();
  await fn(ctx);
});
