'use strict';
// ---------------------------------------------------------------------------
// Core: helpers, API client, router with browser history, shared components.
// Every view has its own URL; pages are registered with route() in the other files.
// ---------------------------------------------------------------------------

const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const enc = encodeURIComponent;
const encPath = (p) => String(p).split('/').map(enc).join('/');
const label = (s) => String(s ?? '').replace(/_/g, ' ');

// ---- time and size ----------------------------------------------------------
function span(sec) {
  if (sec == null) return '–';
  if (sec < 60) return `${sec}s`;
  const m = Math.round(sec / 60);
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h${m % 60 ? ` ${m % 60}m` : ''}`;
  const d = Math.floor(h / 24);
  return `${d}d${h % 24 ? ` ${h % 24}h` : ''}`;
}
function ago(iso) {
  const t = new Date(iso).getTime();
  if (Number.isNaN(t)) return esc(iso);
  const s = Math.round((Date.now() - t) / 1000);
  if (s < 0) return `in ${span(-s)}`;
  return s < 45 ? 'just now' : `${span(s)} ago`;
}
const when = (iso) => (iso ? `<time datetime="${esc(iso)}" title="${esc(new Date(iso).toLocaleString())}">${ago(iso)}</time>` : '<span class="muted">–</span>');
const clock = (iso) => new Date(iso).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
function dayLabel(iso) {
  const d = new Date(iso);
  const days = Math.round((new Date().setHours(0, 0, 0, 0) - new Date(d).setHours(0, 0, 0, 0)) / 86400000);
  if (days === 0) return 'Today';
  if (days === 1) return 'Yesterday';
  return d.toLocaleDateString(undefined, { weekday: 'long', month: 'short', day: 'numeric', year: days > 300 ? 'numeric' : undefined });
}
function bytes(n) {
  n = Number(n) || 0;
  if (n < 1024) return `${n} B`;
  if (n < 1048576) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / 1048576).toFixed(1)} MB`;
}

// ---- badges -----------------------------------------------------------------
function tone(s) {
  s = String(s || '').toLowerCase();
  if (/(fail|error|blocked|stale|stopped|violation|rejected|needs.human|preflight failed|unknown|regression|cannot|missing)/.test(s)) return 'err';
  if (/^(ok|done|verified|integrated|ready|active|reported|approved|pass|success|idle|closed|finished|enabled)/.test(s)) return 'ok';
  if (/(run|flight|worktree|queued|proposed|pending|progress|planned|judged|paused|waiting|held|open)/.test(s)) return 'warn';
  return '';
}
const badge = (text, cls) => `<span class="badge ${cls ?? tone(text)}">${esc(label(text))}</span>`;
const kindBadge = (k) => badge(k, { plan: 'plan', build: 'build', cycle: 'info', agent: 'info', job: '', visual: 'info' }[k] ?? '');

// ---- API --------------------------------------------------------------------
async function api(path, { method = 'GET', body, params } = {}) {
  let url = path;
  if (params) {
    const p = new URLSearchParams();
    Object.entries(params).forEach(([k, v]) => { if (v !== undefined && v !== null && v !== '') p.set(k, v); });
    const s = p.toString();
    if (s) url += `?${s}`;
  }
  const res = await fetch(url, { method, headers: body !== undefined ? { 'Content-Type': 'application/json' } : {}, body: body !== undefined ? JSON.stringify(body) : undefined });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const err = new Error(data.error || `HTTP ${res.status}`);
    err.status = res.status;
    throw err;
  }
  return data;
}
const post = (path, body = {}) => api(path, { method: 'POST', body });
// The query string of the current URL as API params (page, per, q, ...), plus overrides.
const qparams = (extra = {}) => ({ ...Object.fromEntries(new URLSearchParams(location.search)), ...extra });

// ---- router and history -----------------------------------------------------
const routes = [];
const Actions = {};
const Forms = {};
const View = { timers: [], cleanup() { this.timers.forEach(clearInterval); this.timers = []; } };
class Stale extends Error {}
let token = 0;
let curKey = 0;
let keySeq = 0;
const scrolls = {};

function route(pattern, handler) {
  const keys = [];
  // One pass, so the keys keep the order of the capture groups: /:name, /:name? (optional) and /*name (the rest).
  const src = pattern.replace(/\/(?::([a-z_]+)(\?)?|\*([a-z_]+))/gi, (_, name, optional, rest) => {
    keys.push(name || rest);
    if (rest) return '/(.+)';
    return optional ? '(?:/([^/]+))?' : '/([^/]+)';
  });
  routes.push({ re: new RegExp(`^${src}/?$`), keys, handler });
}

function withParams(patch) {
  const p = new URLSearchParams(location.search);
  Object.entries(patch).forEach(([k, v]) => {
    if (v === null || v === undefined || v === '' || v === 'all' || (k === 'page' && Number(v) === 1)) p.delete(k);
    else p.set(k, v);
  });
  const s = p.toString();
  return location.pathname + (s ? `?${s}` : '');
}

function navigate(url, { replace = false } = {}) {
  if (url === location.pathname + location.search) return render();
  scrolls[curKey] = window.scrollY;
  curKey = ++keySeq;
  history[replace ? 'replaceState' : 'pushState']({ k: curKey }, '', url);
  return render({ top: true });
}

async function render(opts = {}) {
  View.cleanup();
  const my = ++token;
  const live = () => my === token;
  const path = location.pathname.replace(/\/+$/, '') || '/';
  const ctx = {
    path, query: new URLSearchParams(location.search), params: {}, live,
    // A page that was left while it loaded must not paint (or mount anything) over the page that replaced it.
    show(html) { if (!live()) throw new Stale(); $('#view').innerHTML = html; return true; },
    title(t) { if (live()) { document.title = `${t} · OpenSpec Kit`; Recent.add(location.pathname + location.search, t); } },
    crumbs(list) { if (live()) setCrumbs(list); },
    poll(fn, ms = 8000) { View.timers.push(setInterval(() => { if (live() && !document.hidden) Promise.resolve(fn()).catch(() => {}); }, ms)); },
  };
  highlightNav(path);
  const hit = routes.map((r) => ({ r, m: r.re.exec(path) })).find((x) => x.m);
  try {
    if (!hit) {
      ctx.crumbs([['Not found']]); ctx.title('Not found');
      ctx.show(`<div class="empty"><h1>Page not found</h1><p>${esc(path)}</p><a class="btn" href="/">Go to the dashboard</a></div>`);
    } else {
      hit.r.keys.forEach((k, i) => { ctx.params[k] = hit.m[i + 1] === undefined ? undefined : decodeURIComponent(hit.m[i + 1]); });
      ctx.show(loading());
      await hit.r.handler(ctx);
    }
  } catch (e) {
    if (e instanceof Stale || !live()) return;
    if (e.status === 404) {
      setCrumbs([['Not found']]);
      document.title = 'Not found · OpenSpec Kit';
      ctx.show(`<div class="empty"><h1>Not found</h1><p>${esc(e.message)}</p><a class="btn" href="/changes">Back to changes</a></div>`);
      return;
    }
    ctx.show(`<div class="alert err"><b>Could not load this page</b><p>${esc(e.message)}</p><button data-act="reload">Retry</button></div>`);
  }
  if (!live()) return;
  if (opts.scroll != null) window.scrollTo(0, opts.scroll);
  else if (opts.top) window.scrollTo(0, 0);
}

function highlightNav(path) {
  let best = null;
  $$('#nav a').forEach((a) => {
    const h = a.getAttribute('href');
    const hit = h === '/' ? path === '/' : path === h || path.startsWith(`${h}/`);
    if (hit && (!best || h.length > best.getAttribute('href').length)) best = a;
  });
  $$('#nav a').forEach((a) => a.classList.toggle('active', a === best));
}

function setCrumbs(list) {
  $('#crumbs').innerHTML = [['Home', '/'], ...list].map(([text, href], i, all) => (
    i === all.length - 1 ? `<span class="here">${esc(text)}</span>` : `<a href="${esc(href)}">${esc(text)}</a><span class="sep">/</span>`
  )).join('');
}

// ---- recently opened pages ---------------------------------------------------
// Kept in this browser (localStorage), newest first, one entry per address; the /recent page lists it.
const Recent = {
  key: 'portal.recent',
  max: 100,
  sections: { changes: 'Changes', executions: 'Executions', queue: 'Queue', cycles: 'Cycles', visual: 'Visual QA', events: 'Events', agents: 'Agents', runs: 'Runs', jobs: 'Jobs', system: 'System' },
  section(path) { return this.sections[path.split('?')[0].split('/')[1]] || 'Other'; },
  read() {
    try {
      return (JSON.parse(localStorage.getItem(this.key)) || []).filter((r) => r.path !== '/' && !r.path.startsWith('/recent') && r.title !== 'Not found')
        .map((r) => ({ ...r, section: this.section(r.path) }));
    } catch { return []; }
  },
  add(path, title) {
    if (path === '/' || path.startsWith('/recent') || title === 'Not found') return;
    try {
      const list = this.read().filter((r) => r.path !== path).map(({ path: p, title: t, at }) => ({ path: p, title: t, at }));
      list.unshift({ path, title, at: new Date().toISOString() });
      localStorage.setItem(this.key, JSON.stringify(list.slice(0, this.max)));
    } catch { /* storage unavailable */ }
  },
  clear() { try { localStorage.removeItem(this.key); } catch { /* storage unavailable */ } },
};

// ---- small components -------------------------------------------------------
const loading = (text = 'Loading…') => `<div class="empty"><span class="spinner"></span>${esc(text)}</div>`;
const empty = (text) => `<div class="empty">${text}</div>`;
const alertBox = (text, cls = '') => `<div class="alert ${cls}">${text}</div>`;

function pageHead(title, sub = '', actions = '') {
  return `<div class="page-head"><div><h1>${title}</h1>${sub ? `<div class="sub">${sub}</div>` : ''}</div><div class="row">${actions}</div></div>`;
}

function tabs(items, active) {
  return `<div class="tabs">${items.map((t) => (
    `<a href="${esc(t.href)}" class="${t.key === active ? 'active' : ''}">${esc(t.label)}${t.count != null ? `<small>${t.count}</small>` : ''}</a>`
  )).join('')}</div>`;
}

function chips(options, key, current) {
  const cur = current || 'all';
  return `<div class="chips">${options.map((o) => (
    `<a href="${esc(withParams({ [key]: o.value, page: null }))}" class="${o.value === cur ? 'active' : ''}">${esc(o.label)}${o.count != null ? `<small>${o.count}</small>` : ''}</a>`
  )).join('')}</div>`;
}

function searchForm(q, placeholder) {
  return `<form data-form="search"><input type="search" name="q" value="${esc(q)}" placeholder="${esc(placeholder)}">` +
    `<button class="secondary" type="submit">Search</button>${q ? `<a class="btn ghost" href="${esc(withParams({ q: null, page: null }))}">Clear</a>` : ''}</form>`;
}

function pager(d, noun = 'items') {
  if (!d || !d.total) return '';
  const from = (d.page - 1) * d.per + 1;
  const to = Math.min(d.total, d.page * d.per);
  const link = (n, text = n) => `<a href="${esc(withParams({ page: n }))}">${text}</a>`;
  const nums = [];
  for (let n = 1; n <= d.pages; n++) {
    if (n === 1 || n === d.pages || Math.abs(n - d.page) <= 2) nums.push(n);
    else if (nums[nums.length - 1] !== '…') nums.push('…');
  }
  const body = nums.map((n) => (n === '…' ? '<span class="off">…</span>' : n === d.page ? `<span class="cur">${n}</span>` : link(n))).join('');
  const sizes = [10, 25, 50, 100].map((n) => `<option ${n === d.per ? 'selected' : ''}>${n}</option>`).join('');
  return `<div class="pager"><span>${from}–${to} of ${d.total} ${noun}</span>` +
    `<div class="pages">${d.page > 1 ? link(d.page - 1, '‹ Prev') : '<span class="off">‹ Prev</span>'}${body}${d.page < d.pages ? link(d.page + 1, 'Next ›') : '<span class="off">Next ›</span>'}</div>` +
    `<label class="row">Per page <select data-nav="per">${sizes}</select></label></div>`;
}

// Page of an in-memory list, in the shape pager() expects.
function slicePage(items, query, def = 25) {
  const per = Math.min(200, Math.max(1, Number(query.get('per')) || def));
  const pages = Math.max(1, Math.ceil(items.length / per));
  const page = Math.min(pages, Math.max(1, Number(query.get('page')) || 1));
  return { items: items.slice((page - 1) * per, page * per), page, per, total: items.length, pages };
}

const changeLink = (name, tab = '') => `<a href="/changes/${enc(name)}${tab ? `/${tab}` : ''}"><b>${esc(name)}</b></a>`;
const runBadge = (r) => badge(r.status);
const progressBar = (done, total) => (total ? `<div class="row"><div class="progress"><i style="width:${Math.round((done / total) * 100)}%"></i></div><span class="muted small">${done}/${total}</span></div>` : '<span class="muted small">no tasks yet</span>');

function toast(msg, err = false) {
  const el = $('#toast');
  el.textContent = msg;
  el.className = err ? 'err' : '';
  el.style.display = 'block';
  clearTimeout(toast.t);
  toast.t = setTimeout(() => { el.style.display = 'none'; }, err ? 7000 : 3500);
}

// ---- dialogs ----------------------------------------------------------------
function modal({ title, body, buttons = [{ label: 'Close', value: null, cls: 'secondary' }] }) {
  return new Promise((resolve) => {
    const root = $('#modal-root');
    const back = document.createElement('div');
    back.className = 'modal-back';
    back.innerHTML = `<div class="modal" role="dialog" aria-modal="true"><header><h2>${esc(title)}</h2><button class="icon" data-close>✕</button></header>` +
      `<div class="body">${body}</div><footer>${buttons.map((b, i) => `<button class="${b.cls || ''}" data-btn="${i}">${esc(b.label)}</button>`).join('')}</footer></div>`;
    root.appendChild(back);
    const done = (v) => { back.remove(); document.removeEventListener('keydown', onKey); resolve(v); };
    const onKey = (e) => { if (e.key === 'Escape') done(null); };
    document.addEventListener('keydown', onKey);
    back.addEventListener('click', (e) => {
      if (e.target === back || e.target.closest('[data-close]')) return done(null);
      const b = e.target.closest('[data-btn]');
      if (b) done(buttons[Number(b.dataset.btn)].value === 'input' ? ($('textarea,input', back)?.value ?? '') : buttons[Number(b.dataset.btn)].value);
    });
    $('textarea,input', back)?.focus();
  });
}
const confirmDialog = (text, { ok = 'Confirm', danger = false, title = 'Are you sure?' } = {}) =>
  modal({ title, body: `<p>${esc(text)}</p>`, buttons: [{ label: 'Cancel', value: false, cls: 'secondary' }, { label: ok, value: true, cls: danger ? 'danger' : '' }] });
const promptDialog = (text, { placeholder = '', ok = 'OK', multiline = false, help = '' } = {}) =>
  modal({ title: text, body: (help ? `<p class="muted">${esc(help)}</p>` : '') + (multiline ? `<textarea rows="5" placeholder="${esc(placeholder)}"></textarea>` : `<input placeholder="${esc(placeholder)}">`),
    buttons: [{ label: 'Cancel', value: null, cls: 'secondary' }, { label: ok, value: 'input' }] });
const showOutput = (title, text) => modal({ title, body: `<pre class="plain">${esc(text)}</pre>` });

async function copyText(text) {
  try { await navigator.clipboard.writeText(text); } catch {
    const t = Object.assign(document.createElement('textarea'), { value: text });
    document.body.appendChild(t); t.select(); document.execCommand('copy'); t.remove();
  }
  toast('Copied');
}

// ---- Markdown (safe: everything is escaped first) ---------------------------
function renderMarkdown(src) {
  const inline = (t) => esc(t)
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\*\*([^*]+)\*\*/g, '<b>$1</b>')
    .replace(/(^|[^*\w])\*([^*\s][^*]*)\*/g, '$1<i>$2</i>')
    .replace(/\[([^\]]+)\]\((https?:\/\/[^)\s]+|\/[^)\s]*)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');
  const lines = String(src).replace(/\r/g, '').split('\n');
  const out = [];
  const isBlockStart = (l) => /^(```|#{1,4}\s|>|\s*([-*+]|\d+\.)\s|---+\s*$)/.test(l);
  for (let i = 0; i < lines.length;) {
    const l = lines[i];
    let m;
    if ((m = /^```/.exec(l))) {
      const buf = [];
      for (i++; i < lines.length && !/^```/.test(lines[i]); i++) buf.push(lines[i]);
      i++;
      out.push(`<pre><code>${esc(buf.join('\n'))}</code></pre>`);
    } else if ((m = /^(#{1,4})\s+(.*)$/.exec(l))) {
      out.push(`<h${m[1].length}>${inline(m[2])}</h${m[1].length}>`); i++;
    } else if (/^---+\s*$/.test(l)) {
      out.push('<hr>'); i++;
    } else if (l.includes('|') && /^\s*\|?\s*:?-{2,}/.test(lines[i + 1] || '')) {
      const cells = (row) => row.trim().replace(/^\||\|$/g, '').split('|').map((c) => c.trim());
      const head = cells(l);
      const rows = [];
      for (i += 2; i < lines.length && lines[i].includes('|'); i++) rows.push(cells(lines[i]));
      out.push(`<table><thead><tr>${head.map((c) => `<th>${inline(c)}</th>`).join('')}</tr></thead><tbody>${rows.map((r) => `<tr>${r.map((c) => `<td>${inline(c)}</td>`).join('')}</tr>`).join('')}</tbody></table>`);
    } else if (/^>/.test(l)) {
      const buf = [];
      for (; i < lines.length && /^>/.test(lines[i]); i++) buf.push(lines[i].replace(/^>\s?/, ''));
      out.push(`<blockquote>${inline(buf.join(' '))}</blockquote>`);
    } else if ((m = /^(\s*)([-*+]|\d+\.)\s+(.*)$/.exec(l))) {
      const ordered = /\d/.test(m[2]);
      const items = [];
      for (; i < lines.length; i++) {
        const li = /^(\s*)([-*+]|\d+\.)\s+(.*)$/.exec(lines[i]);
        if (!li) break;
        const task = /^\[([ xX])\]\s+(.*)$/.exec(li[3]);
        items.push(`<li class="${task ? 'task' : ''}" style="margin-left:${Math.floor(li[1].length / 2) * 16}px">${task ? `${task[1] === ' ' ? '☐' : '☑'} ${inline(task[2])}` : inline(li[3])}</li>`);
      }
      out.push(`<${ordered ? 'ol' : 'ul'}>${items.join('')}</${ordered ? 'ol' : 'ul'}>`);
    } else if (!l.trim()) {
      i++;
    } else {
      const buf = [];
      for (; i < lines.length && lines[i].trim() && !isBlockStart(lines[i]); i++) buf.push(lines[i]);
      if (!buf.length) { buf.push(lines[i]); i++; }
      out.push(`<p>${inline(buf.join(' '))}</p>`);
    }
  }
  return out.join('\n');
}

// ---- text viewer: find, wrap, copy, raw, Markdown, truncated files ---------
function highlight(text, q) {
  if (!q) return { html: esc(text), n: 0 };
  const re = new RegExp(q.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi');
  let out = '';
  let last = 0;
  let n = 0;
  let m;
  while (n < 2000 && (m = re.exec(text))) {
    if (!m[0]) { re.lastIndex++; continue; }
    out += `${esc(text.slice(last, m.index))}<mark data-i="${n}">${esc(m[0])}</mark>`;
    last = m.index + m[0].length;
    n++;
  }
  return { html: out + esc(text.slice(last)), n };
}

// Fills `el` with a viewer. opts: load(full) -> {content,size,truncated}, name, raw (url), md ('rendered'|'source'), follow, wrap.
function mountViewer(el, opts) {
  const isMd = /\.md$/i.test(opts.name || '');
  const st = { data: null, full: false, mode: isMd ? (opts.md || 'rendered') : 'source', q: '', n: 0, cur: -1, wrap: !!opts.wrap };
  el.innerHTML = `<div class="viewer"><div class="vbar">
    ${isMd ? '<button class="small secondary" data-v="mode">Source</button>' : ''}
    <input type="search" data-v="find" placeholder="Find in file…">
    <span class="info" data-v="count"></span>
    <button class="small ghost" data-v="prev" title="Previous match">↑</button><button class="small ghost" data-v="next" title="Next match">↓</button>
    <label class="check"><input type="checkbox" data-v="wrap" ${st.wrap ? 'checked' : ''}> Wrap</label>
    <span class="grow"></span><span class="info" data-v="info"></span>
    <button class="small ghost" data-v="full" hidden>Load full file</button>
    <button class="small ghost" data-v="copy">Copy</button>
    ${opts.raw ? `<a class="btn small ghost" href="${esc(opts.raw)}" target="_blank" rel="noopener">Raw</a><a class="btn small ghost" href="${esc(opts.raw)}&download=1" download>Download</a>` : ''}
  </div><div data-v="body"></div></div>`;
  const root = $('.viewer', el);
  const q$ = (n) => $(`[data-v=${n}]`, el);

  function paint() {
    const d = st.data;
    if (!d) return;
    const body = q$('body');
    const prevScroll = $('pre', body);
    const atBottom = prevScroll && prevScroll.scrollHeight - prevScroll.scrollTop - prevScroll.clientHeight < 40;
    const prevTop = prevScroll ? prevScroll.scrollTop : 0;
    const md = st.mode === 'rendered' && isMd;
    root.classList.toggle('wrap', st.wrap);
    q$('find').hidden = md; q$('prev').hidden = md; q$('next').hidden = md; q$('count').hidden = md;
    if (isMd) q$('mode').textContent = md ? 'Source' : 'Rendered';
    if (md) {
      body.innerHTML = `<div class="md">${renderMarkdown(d.content)}</div>`;
    } else {
      const h = highlight(d.content, st.q);
      st.n = h.n;
      body.innerHTML = `<pre>${h.html || '<span class="muted">(empty)</span>'}</pre>`;
      q$('count').textContent = st.q ? `${h.n}${h.n >= 2000 ? '+' : ''} match${h.n === 1 ? '' : 'es'}` : '';
      const pre = $('pre', body);
      if (st.q && st.n) jump(0);
      else if (opts.follow && (atBottom || !prevScroll)) pre.scrollTop = pre.scrollHeight;
      else pre.scrollTop = prevTop;
    }
    const lines = d.content ? d.content.split('\n').length : 0;
    q$('info').textContent = `${lines} lines · ${bytes(d.size)}${d.truncated ? ' · showing the end' : ''}`;
    q$('full').hidden = !d.truncated;
  }
  function jump(i) {
    const marks = $$('mark', q$('body'));
    if (!marks.length) return;
    st.cur = (i + marks.length) % marks.length;
    marks.forEach((m, k) => m.classList.toggle('cur', k === st.cur));
    marks[st.cur].scrollIntoView({ block: 'center' });
  }
  async function refresh(full = st.full) {
    st.full = full;
    st.data = await opts.load(full);
    paint();
  }
  el.addEventListener('input', (e) => {
    if (e.target.dataset.v === 'find') { st.q = e.target.value; clearTimeout(st.t); st.t = setTimeout(paint, 250); }
    if (e.target.dataset.v === 'wrap') { st.wrap = e.target.checked; paint(); }
  });
  el.addEventListener('keydown', (e) => { if (e.target.dataset.v === 'find' && e.key === 'Enter') { e.preventDefault(); jump(st.cur + (e.shiftKey ? -1 : 1)); } });
  el.addEventListener('click', (e) => {
    const b = e.target.closest('[data-v]');
    if (!b) return;
    if (b.dataset.v === 'mode') { st.mode = st.mode === 'rendered' ? 'source' : 'rendered'; paint(); }
    if (b.dataset.v === 'prev') jump(st.cur - 1);
    if (b.dataset.v === 'next') jump(st.cur + 1);
    if (b.dataset.v === 'copy' && st.data) copyText(st.data.content);
    if (b.dataset.v === 'full') { b.disabled = true; refresh(true).catch((err) => toast(err.message, true)).finally(() => { b.disabled = false; }); }
  });
  return refresh(false).then(() => ({ refresh: () => refresh(), update: (d) => { st.data = d; paint(); } }), (e) => {
    el.innerHTML = alertBox(esc(e.message), 'warn');
    return { refresh: async () => {}, update: () => {} };
  });
}
const viewerSlot = (id = 'viewer') => `<div id="${id}">${loading()}</div>`;
// A viewer fed by GET /api/logs.
const logViewer = (el, kind, name, extra = {}) => mountViewer(el, {
  name, raw: `/api/logs/raw?kind=${enc(kind)}&name=${enc(name)}`, ...extra,
  load: (full) => api('/api/logs', { params: { kind, name, tail: full ? 0 : 300000 } }),
});

// ---- global state: summary, sidebar, top bar -------------------------------
const State = { summary: null };
const NAV = [
  { items: [{ href: '/', label: 'Dashboard' }, { href: '/recent', label: 'Recent' }] },
  { group: 'Work', items: [
    { href: '/changes', label: 'Changes', badge: (c) => [c.blocked + c.ready + c.stale, c.blocked + c.stale ? 'err' : 'warn'] },
    { href: '/executions', label: 'Executions' },
    { href: '/queue', label: 'Queue', badge: (c) => [c.proposals, 'warn'] },
  ] },
  { group: 'Observe', items: [{ href: '/cycles', label: 'Cycles' }, { href: '/visual', label: 'Visual QA' }, { href: '/events', label: 'Events' }] },
  { group: 'Agents', items: [
    { href: '/agents', label: 'Agents' },
    { href: '/runs', label: 'Runs', badge: (c) => [c.running_runs, 'ok'] },
    { href: '/jobs', label: 'Jobs', badge: (c) => [c.running_jobs, 'ok'] },
  ] },
  { group: 'System', items: [
    { href: '/system/health', label: 'Health' }, { href: '/system/settings', label: 'Settings' }, { href: '/system/setup', label: 'Setup' },
    { href: '/system/reports', label: 'Reports' }, { href: '/system/prompts', label: 'Prompt templates' }, { href: '/system/recovery', label: 'Recovery state' },
  ] },
];

function buildNav() {
  $('#nav').innerHTML = NAV.map((g) => `<div class="group">${g.group ? `<span>${g.group}</span>` : ''}${g.items.map((i) => (
    `<a href="${i.href}" data-badge="${i.badge ? NAV.flatMap((x) => x.items).indexOf(i) : ''}">${esc(i.label)}<span class="count" hidden></span></a>`
  )).join('')}</div>`).join('');
}

function applySummary(s) {
  State.summary = s;
  $('#app-name').textContent = s.app_name;
  const paused = s.processes.paused;
  const pill = $('#pause-pill');
  const state = paused ? `PAUSED${s.processes.pause_reason ? `: ${s.processes.pause_reason}` : ''}` : 'ACTIVE';
  pill.textContent = state;
  pill.title = state;
  pill.className = `badge ${paused ? 'err' : 'ok'}`;
  // On a narrow screen only the icon shows (play when paused, stop when active); the words and the reason are in the tooltip.
  const btn = $('#btn-pause');
  const action = paused ? 'Resume the kit' : 'Pause the kit';
  btn.innerHTML = `<span class="ico" aria-hidden="true">${paused ? '▶' : '■'}</span><span class="txt">${paused ? 'Resume' : 'Pause'}</span>`;
  btn.title = paused && s.processes.pause_reason ? `${action} (paused: ${s.processes.pause_reason})` : action;
  btn.setAttribute('aria-label', btn.title);
  btn.className = paused ? 'success' : 'danger';
  const flat = NAV.flatMap((g) => g.items);
  $$('#nav a').forEach((a) => {
    const item = a.dataset.badge === '' ? null : flat[Number(a.dataset.badge)];
    const c = $('.count', a);
    const [n, cls] = item?.badge ? item.badge(s.counts) : [0, ''];
    c.hidden = !n;
    c.textContent = n;
    c.className = `count ${cls}`;
  });
}
async function refreshSummary() {
  try { applySummary(await api('/api/summary')); } catch { /* the page shows its own errors */ }
}

Actions.back = () => history.back();
Actions.forward = () => history.forward();
Actions.reload = () => render();
Actions['toggle-nav'] = () => document.body.classList.toggle('nav-open');
Actions['toggle-pause'] = async () => {
  if (State.summary?.processes.paused) {
    const why = State.summary.processes.pause_reason;
    const go = await confirmDialog(`${why ? `It was paused: ${why}. ` : ''}Once resumed, the scheduled cycle, the dispatcher and the merger can start again at their next run.`, { ok: 'Resume', title: 'Resume the kit?' });
    if (!go) return;
    await post('/api/actions/resume');
    toast('Resumed');
  } else {
    const reason = await promptDialog('Pause the kit', { placeholder: 'Reason (optional)', ok: 'Pause', help: 'While paused (log/PAUSE), the kit\'s scripts do not start new cycles or merges. You can resume it from the top bar.' });
    if (reason === null) return;
    await post('/api/actions/pause', { reason });
    toast('Paused');
  }
  await refreshSummary();
  render();
};
Actions.copy = (b) => copyText(b.dataset.text);
Forms.search = (form) => navigate(withParams({ q: new FormData(form).get('q').trim(), page: null }));
// An exact change name opens that change; anything else searches the changes.
Forms.goto = async (form) => {
  const q = new FormData(form).get('q').trim();
  form.reset();
  if (!q) return;
  try {
    await api(`/api/changes/${enc(q)}`);
    navigate(`/changes/${enc(q)}`);
  } catch {
    navigate(`/changes?q=${enc(q)}`);
  }
};

// ---- global events ----------------------------------------------------------
async function runAction(btn, fn) {
  btn.disabled = true;
  try { await fn(); } catch (e) { toast(e.message || String(e), true); } finally { btn.disabled = false; }
}
document.addEventListener('click', (ev) => {
  if (!ev.target.closest('#sidebar') && !ev.target.closest('[data-act=toggle-nav]')) document.body.classList.remove('nav-open');
  const a = ev.target.closest('a[href]');
  if (a && !a.target && !a.hasAttribute('download') && a.origin === location.origin && !/^\/(api|assets)\//.test(a.pathname) &&
      !ev.metaKey && !ev.ctrlKey && !ev.shiftKey && ev.button === 0) {
    ev.preventDefault();
    navigate(a.pathname + a.search + a.hash);
    return;
  }
  const b = ev.target.closest('[data-act]');
  if (b && Actions[b.dataset.act]) {
    ev.preventDefault();
    runAction(b, () => Actions[b.dataset.act](b, ev));
  }
});
document.addEventListener('submit', (ev) => {
  const f = ev.target.closest('[data-form]');
  if (!f || !Forms[f.dataset.form]) return;
  ev.preventDefault();
  const btn = $('button[type=submit]', f);
  runAction(btn || f, () => Forms[f.dataset.form](f, ev));
});
document.addEventListener('change', (ev) => {
  const s = ev.target.closest('[data-nav]');
  if (s) navigate(withParams({ [s.dataset.nav]: s.value, page: null }));
});
document.addEventListener('keydown', (ev) => {
  if (ev.key === '/' && !/^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName)) { ev.preventDefault(); $('#goto-input').focus(); }
});
window.addEventListener('popstate', (e) => {
  scrolls[curKey] = window.scrollY;
  curKey = e.state?.k ?? 0;
  render({ scroll: scrolls[curKey] ?? 0 });
});

function boot() {
  history.scrollRestoration = 'manual';
  history.replaceState({ k: 0 }, '');
  buildNav();
  refreshSummary();
  setInterval(() => { if (!document.hidden) refreshSummary(); }, 8000);
  render();
}
window.addEventListener('DOMContentLoaded', boot);
