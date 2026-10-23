'use strict';
// ---------------------------------------------------------------------------
// Shared actions (buttons with data-act) and row renderers used by several pages.
// ---------------------------------------------------------------------------

const afterAction = async () => { await refreshSummary(); render(); };

// A kit action: POST data-url with data-body; a job opens its page, anything else shows its output.
Actions.kit = async (b) => {
  const title = b.dataset.title || b.textContent.trim();
  if (b.dataset.confirm && !(await confirmDialog(b.dataset.confirm, { ok: title, danger: b.dataset.danger === '1' }))) return;
  const d = await post(b.dataset.url, b.dataset.body ? JSON.parse(b.dataset.body) : {});
  if (d.job) { toast(`${title}: started`); navigate(`/jobs/${enc(d.job.id)}`); return; }
  await showOutput(title, d.output ?? JSON.stringify(d, null, 2));
  afterAction();
};
const kitBtn = (text, url, { body, cls = '', confirm, danger } = {}) =>
  `<button class="${cls}" data-act="kit" data-url="${esc(url)}"${body ? ` data-body="${esc(JSON.stringify(body))}"` : ''}${confirm ? ` data-confirm="${esc(confirm)}"` : ''}${danger ? ' data-danger="1"' : ''}>${esc(text)}</button>`;

Actions.reclaim = async (b) => { await post(`/api/worktrees/${enc(b.dataset.name)}/reclaim_lease`); toast(`Reclaimed the lock of ${b.dataset.name}`); afterAction(); };
Actions.unblock = async (b) => {
  const d = b.dataset;
  await post(`/api/blocked/${enc(d.name)}/unblock`, { approve_risk: d.approve === '1', reset_retries: d.reset !== '0' });
  toast(`Unblocked ${d.name}`);
  afterAction();
};
const reclaimBtn = (name) => `<button class="danger small" data-act="reclaim" data-name="${esc(name)}">Reclaim stale lock</button>`;
const unblockBtn = (name, text = 'Unblock', { approve = false, reset = true, cls = 'small' } = {}) =>
  `<button class="${cls}" data-act="unblock" data-name="${esc(name)}" data-approve="${approve ? 1 : 0}" data-reset="${reset ? 1 : 0}">${esc(text)}</button>`;
const mergeBtn = (cls = 'success small') => (State.summary?.processes.paused
  ? kitBtn('Resume & merge', '/api/actions/resume_and_merge', { cls })
  : kitBtn('Run merger', '/api/actions/merge', { cls }));

// ---- rows -------------------------------------------------------------------
function execRow(e, { clockTime = true } = {}) {
  const sub = [];
  if (e.phase) sub.push(`<code>${esc(e.phase)}</code>`);
  if (e.agent) sub.push(esc(e.agent));
  if (e.change && e.kind !== 'plan' && e.kind !== 'build') sub.push(`change ${changeLink(e.change)}`);
  if (e.size) sub.push(bytes(e.size));
  return `<div class="list-row"><span class="when" title="${esc(new Date(e.at).toLocaleString())}">${clockTime ? clock(e.at) : ago(e.at)}</span>${kindBadge(e.kind)}` +
    `<div class="what trunc"><a href="${esc(e.href)}">${esc(e.title)}</a>${sub.length ? `<small>${sub.join(' · ')}</small>` : ''}</div>${e.status ? badge(e.status) : ''}</div>`;
}

function eventContext(e) {
  return Object.entries(e).filter(([k]) => !['ts', 'event', 'change'].includes(k))
    .map(([k, v]) => `${k}=${typeof v === 'object' ? JSON.stringify(v) : v}`).join(' ');
}
function eventRow(e) {
  const ctx = eventContext(e);
  return `<div class="list-row"><span class="when" title="${esc(e.ts)}">${e.ts ? clock(e.ts) : ''}</span><code>${esc(e.event)}</code>` +
    `<div class="what trunc">${e.change ? changeLink(e.change) : ''} <span class="muted small">${esc(ctx.slice(0, 160))}</span></div></div>`;
}

// Rows grouped under a heading per day.
function byDay(items, render) {
  let day = '';
  return items.map((i) => {
    const d = dayLabel(i.at);
    const head = d !== day ? `<div class="day">${esc(d)}</div>` : '';
    day = d;
    return head + render(i);
  }).join('');
}
