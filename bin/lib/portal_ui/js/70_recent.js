'use strict';
// ---------------------------------------------------------------------------
// Recent: the pages opened in this browser, newest first, by day, with a filter
// per section and a search. It replaces a pop-up menu: it is a page, so it has
// room, its own address and history, and it works the same at every width.
// ---------------------------------------------------------------------------

Actions['recent-clear'] = async () => {
  if (!(await confirmDialog('Forget every page listed here? This only clears this browser\'s list.', { ok: 'Clear the list', danger: true }))) return;
  Recent.clear();
  toast('History cleared');
  render();
};

route('/recent', async (ctx) => {
  ctx.crumbs([['Recent']]);
  ctx.title('Recent');
  const q = (ctx.query.get('q') || '').trim();
  const section = ctx.query.get('section') || 'all';
  const all = Recent.read();
  const base = all.filter((r) => !q || `${r.title} ${decodeURIComponent(r.path)}`.toLowerCase().includes(q.toLowerCase()));
  const counts = base.reduce((a, r) => ({ ...a, [r.section]: (a[r.section] || 0) + 1 }), {});
  const opts = [{ value: 'all', label: 'All', count: base.length },
    ...Object.keys(counts).sort().map((s) => ({ value: s, label: s, count: counts[s] }))];
  const rows = section === 'all' ? base : base.filter((r) => r.section === section);
  const pg = slicePage(rows, ctx.query, 25);
  const row = (r) => {
    let shown = r.path;
    try { shown = decodeURIComponent(r.path); } catch { /* keep it encoded */ }
    return `<div class="list-row"><span class="when" title="${esc(new Date(r.at).toLocaleString())}">${clock(r.at)}</span><span class="badge sec">${esc(r.section)}</span>` +
      `<div class="what trunc"><a href="${esc(r.path)}">${esc(r.title)}</a><small>${esc(shown)}</small></div></div>`;
  };
  ctx.show(pageHead('Recent', 'Pages you opened lately, newest first. The list lives in this browser only.',
    all.length ? '<button class="secondary" data-act="recent-clear">Clear history</button>' : '') +
    (all.length ? `<div class="filters">${chips(opts, 'section', section)}${searchForm(q, 'Search title or address')}</div>` : '') +
    `<div class="card">${pg.items.length ? byDay(pg.items, row) : empty(all.length ? 'No page matches.' : 'Nothing opened yet: the pages you visit will be listed here.')}${pager(pg, 'pages')}</div>`);
});
