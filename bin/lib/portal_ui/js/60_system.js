'use strict';
// ---------------------------------------------------------------------------
// System: health checks, settings, setup, reports, prompt templates, recovery.
// ---------------------------------------------------------------------------

const jsonViewer = (el, name, value) => mountViewer(el, { name, load: async () => { const text = JSON.stringify(value, null, 2); return { content: text, size: text.length, truncated: false }; } });

route('/system', () => navigate('/system/health', { replace: true }));

// ---- health -------------------------------------------------------------------------------
Actions.health = async (b) => {
  const services = b.dataset.services === '1';
  $('#health-out').innerHTML = loading(`Running check_ai_engines.sh${services ? ' --services' : ''}… (up to a few minutes)`);
  const d = await post('/api/health', { services });
  toast(d.summary, !d.ok);
  render();
};

route('/system/health', async (ctx) => {
  ctx.crumbs([['System'], ['Health']]);
  ctx.title('Health');
  const [s, ag] = await Promise.all([api('/api/summary'), api('/api/agents')]);
  const h = s.last_health;
  ctx.show(pageHead('Health', 'The preflight the scheduled cycle runs first: toolchain, kit drift, required services, a live ping of the selected agents and the Jev canary.',
    '<button data-act="health" data-services="0">Run full preflight</button><button class="secondary" data-act="health" data-services="1">Services only</button>') +
    `<div class="card"><header><h2>Last check</h2>${h ? `${badge(h.ok ? 'ok' : 'failed')}` : ''}</header><div id="health-out">${h ? `<p><b>${esc(h.summary)}</b> <span class="muted small">${ago(h.checked_at)}${h.services_only ? ' · services only' : ''}</span></p><div id="health-view"></div>` : empty('No check has run from the portal yet.')}</div></div>` +
    `<div class="card"><header><h2>Ping one agent</h2></header><div class="row">${ag.catalog.agents.map((a) => `<button class="secondary small" data-act="ping" data-name="${esc(a.name)}">${esc(a.name)}${a.selected ? ' ★' : ''}</button>`).join('')}</div></div>`);
  if (h) await mountViewer($('#health-view'), { name: 'preflight.log', load: async () => ({ content: h.output || '', size: (h.output || '').length, truncated: false }) });
});

// ---- settings ------------------------------------------------------------------------------
Forms['config-set'] = async (form) => {
  const f = Object.fromEntries(new FormData(form));
  const dry = form.dataset.dry === '1';
  await post('/api/config/set', { key: f.key, value: f.value, dry_run: dry });
  toast(`${dry ? 'Valid: ' : 'Updated '}${f.key}`);
  if (!dry) render();
};

route('/system/settings', async (ctx) => {
  ctx.crumbs([['System'], ['Settings']]);
  ctx.title('Settings');
  const d = await api('/api/config');
  ctx.show(pageHead('Settings', 'Effective settings of config/*.yaml. Commit a change before the next cycle, or the scope guard pauses the system.') +
    `<div class="grid two"><div class="card"><header><h2>Change a setting</h2></header><form data-form="config-set"><label class="field"><span>Key</span><input name="key" required placeholder="pipeline.dispatch.workers or cycle.proposals.approval"></label>` +
    `<label class="field"><span>New value</span><input name="value" required></label><div class="row"><button type="submit">Set</button>` +
    `<button type="button" class="secondary" onclick="this.form.dataset.dry='1';this.form.requestSubmit();this.form.dataset.dry='0'">Dry run</button></div></form></div>` +
    `<div class="card"><header><h2>Validation</h2></header><div id="cfg-check"></div></div></div>` +
    `<div class="card" style="margin-top:16px"><header><h2>Effective settings</h2></header><div id="cfg-show"></div></div>`);
  await Promise.all([jsonViewer($('#cfg-check'), 'check.json', d.check), jsonViewer($('#cfg-show'), 'settings.json', d.show)]);
});

// ---- setup ---------------------------------------------------------------------------------
Forms['setup-repo'] = async (form) => {
  const f = Object.fromEntries(new FormData(form));
  await post('/api/setup/repo', f);
  toast('Repository set up');
  render();
};

route('/system/setup', async (ctx) => {
  ctx.crumbs([['System'], ['Setup']]);
  ctx.title('Setup');
  const d = await api('/api/setup');
  const sections = Object.entries(d.sections || {}).map(([sec, items]) => `<div class="card"><header><h2>${esc(label(sec))}</h2></header>${items.map((i) =>
    `<div class="list-row">${badge(i.state)}<div class="what">${esc(i.what)}${i.fix ? `<small><code>${esc(i.fix)}</code></small>` : ''}</div></div>`).join('')}</div>`).join('');
  ctx.show(pageHead('Setup', 'From installed to ready to schedule.') + sections +
    `<div class="card"><header><h2>Add or set up a child repository</h2></header><form data-form="setup-repo"><div class="row"><label class="field grow"><span>Git URL (to add a new one)</span><input name="url" placeholder="git@github.com:org/app.git"></label>` +
    `<label class="field"><span>Name</span><input name="name" placeholder="app"></label><label class="field"><span>Base branch</span><input name="branch" placeholder="main"></label></div><button type="submit">Set up</button></form></div>`);
});

// ---- reports -------------------------------------------------------------------------------
route('/system/reports', async (ctx) => {
  ctx.crumbs([['System'], ['Reports']]);
  ctx.title('Reports');
  const since = ctx.query.get('since') || '30d';
  const tab = ctx.query.get('tab') || 'jev';
  const d = await api('/api/reports', { params: { since } });
  const periods = ['7d', '30d', '90d'].map((v) => ({ value: v, label: `Last ${v.replace('d', ' days')}` }));
  ctx.show(pageHead('Reports', 'Evidence to tune the Jev gates and to keep or undo a prompt or memory edit (bin/jev_report.rb, bin/prompt_report.rb).') +
    tabs([{ key: 'jev', label: 'Jev gates', href: withParams({ tab: 'jev' }) }, { key: 'prompt', label: 'Prompt versions', href: withParams({ tab: 'prompt' }) }, { key: 'memory', label: 'Memory versions', href: withParams({ tab: 'memory' }) }], tab) +
    `<div class="filters">${chips(periods, 'since', since)}</div>${viewerSlot()}`);
  await jsonViewer($('#viewer'), `${tab}-report.json`, d[tab]);
});

// ---- prompt templates ----------------------------------------------------------------------
route('/system/prompts', async (ctx) => {
  ctx.crumbs([['System'], ['Prompt templates']]);
  ctx.title('Prompt templates');
  const { templates } = await api('/api/prompts');
  ctx.show(pageHead('Prompt templates', 'The application-owned prompts (config/prompts/) filled on every PLAN, BUILD and cycle call.') +
    `<div class="card"><table><thead><tr><th>Role</th><th>File</th><th>Placeholders</th><th></th></tr></thead><tbody>${templates.map((t) =>
      `<tr><td><b>${esc(t.role.toUpperCase())}</b></td><td><code>${esc(t.path)}</code><div class="muted small">version ${esc(t.version || '–')}</div></td>` +
      `<td class="small muted">${esc((t.placeholders || []).map((p) => `{{${p}}}`).join(' ') || 'none')}</td><td class="actions"><a class="btn small secondary" href="/system/prompts/${enc(t.role)}">Template</a> <a class="btn small ghost" href="/system/prompts/${enc(t.role)}?view=sample">Sample render</a></td></tr>`).join('')}</tbody></table></div>`);
});
route('/system/prompts/:role', async (ctx) => {
  const { templates } = await api('/api/prompts');
  const t = templates.find((x) => x.role === ctx.params.role);
  if (!t) throw new Error('Unknown prompt role');
  const view = ctx.query.get('view') === 'sample' ? 'sample' : 'template';
  ctx.crumbs([['System'], ['Prompt templates', '/system/prompts'], [t.role.toUpperCase()]]);
  ctx.title(`Prompt ${t.role} · ${view}`);
  ctx.show(pageHead(`${esc(t.role.toUpperCase())} prompt`, `<code>${esc(t.path)}</code> · version ${esc(t.version || '–')}`) +
    (t.version == null ? alertBox(`<code>${esc(t.path)}</code> is missing from this checkout. An application gets it from the kit's seeds at install; restore it, then commit it.`, 'warn') : '') +
    tabs([{ key: 'template', label: 'Template', href: withParams({ view: null }) }, { key: 'sample', label: 'Sample render', href: withParams({ view: 'sample' }) }], view) + viewerSlot());
  const text = view === 'sample' ? t.rendered : t.raw;
  await mountViewer($('#viewer'), { name: `${t.role}.md`, md: 'source', load: async () => ({ content: text, size: text.length, truncated: false }) });
});

// ---- recovery --------------------------------------------------------------------------------
route('/system/recovery', async (ctx) => {
  ctx.crumbs([['System'], ['Recovery state']]);
  ctx.title('Recovery state');
  const d = await api('/api/recovery');
  const kv = (obj, fmt) => Object.keys(obj || {}).length ? `<dl class="kv">${Object.entries(obj).map(([k, v]) => `<dt>${changeLink(k)}</dt><dd>${esc(fmt(v))}</dd>`).join('')}</dl>` : empty('None.');
  ctx.show(pageHead('Recovery state', 'What the kit does by itself to heal: engine deferrals, automatic retries, healed blocks, conflict rebuilds and the last dispatch.') +
    `<div class="grid two"><div class="card"><header><h2>Engine deferrals</h2><span class="muted small">log/deferrals.json</span></header>${kv(d.deferrals, (n) => `${n}/3`)}</div>` +
    `<div class="card"><header><h2>Automatic retries</h2><span class="muted small">log/blocked_retries.json</span></header>${kv(d.blocked_retries, (r) => `${r.retries} retries`)}</div></div>` +
    `<div class="card" style="margin-top:16px"><header><h2>Conflict rebuilds</h2><span class="muted small">log/rebuilds/</span></header>${d.rebuilds.length ? `<dl class="kv">${d.rebuilds.map((r) => `<dt>${changeLink(r.change_name)}</dt><dd>${r.count || 0} rebuilds</dd>`).join('')}</dl>` : empty('None.')}</div>` +
    `<div class="card"><header><h2>Healed quarantine history</h2><span class="muted small">log/blocked/history/</span></header>${d.blocked_history.length ? `<table><thead><tr><th>Change</th><th>Reason</th><th>Blocked</th></tr></thead><tbody>${d.blocked_history.map((h) =>
      `<tr><td>${changeLink(h.change_name || h.file)}</td><td>${badge(h.reason || '')}</td><td>${when(h.blocked_at)}</td></tr>`).join('')}</tbody></table>` : empty('None.')}</div>` +
    `<div class="card"><header><h2>Last dispatch results</h2><span class="muted small">log/dispatch_results.json</span></header><div id="dispatch-res"></div></div>`);
  await jsonViewer($('#dispatch-res'), 'dispatch_results.json', d.dispatch_results);
});
