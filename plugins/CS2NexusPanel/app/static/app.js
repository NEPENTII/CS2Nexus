(() => {
'use strict';
const app = document.getElementById('app');
const $id = id => document.getElementById(id);
let T = {}, lang = 'en', me = null, mapsAvail = {}, timers = [];
const KNOWN = { de_dust2: 'Dust II', de_mirage: 'Mirage', de_inferno: 'Inferno', de_nuke: 'Nuke', de_overpass: 'Overpass', de_ancient: 'Ancient',
  de_anubis: 'Anubis', de_vertigo: 'Vertigo', de_train: 'Train', de_cache: 'Cache', de_jura: 'Jura', de_grail: 'Grail', de_dogtown: 'Dogtown',
  cs_office: 'Office', cs_italy: 'Italy', ar_baggage: 'Baggage', ar_shoots: 'Shoots', ar_pool_day: 'Pool Day' };

// ---------------------------------------------------------------- helpers
function el(tag, props, ...kids) {
  const n = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') n.className = v;
    else if (k === 'text') n.textContent = v;
    else if (k.startsWith('on')) n.addEventListener(k.slice(2), v);
    else if (k === 'style') n.setAttribute('style', v);
    else n.setAttribute(k, v === true ? '' : v);
  }
  for (const c of kids.flat()) if (c != null && c !== false) n.append(c.nodeType ? c : document.createTextNode(String(c)));
  return n;
}
const t = (key, vars) => {
  let s = T[key] ?? key;
  if (vars) for (const [k, v] of Object.entries(vars)) s = s.replaceAll('{' + k + '}', v);
  return s;
};
const clear = n => { while (n.firstChild) n.removeChild(n.firstChild); };
const absDate = ts => new Intl.DateTimeFormat(lang, { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(ts * 1000));
function ago(ts) {
  const s = Math.max(0, Math.floor(Date.now() / 1000 - ts));
  if (s < 60) return t('time.now');
  if (s < 3600) return t('time.min', { n: Math.floor(s / 60) });
  if (s < 86400) return t('time.hour', { n: Math.floor(s / 3600) });
  return t('time.day', { n: Math.floor(s / 86400) });
}
function dur(sec) {
  const m = Math.floor(sec / 60), h = Math.floor(m / 60);
  if (m < 1) return t('dur.less');
  if (h < 1) return t('dur.min', { n: m });
  return m % 60 ? t('dur.hourmin', { h, m: m % 60 }) : t('dur.hour', { h });
}
const normMap = m => String(m || '').toLowerCase().replace(/\\/g, '/').split('/').pop().replace(/[^a-z0-9_-]/g, '');
function prettyMap(m) {
  const n = normMap(m);
  if (!n) return '';
  if (KNOWN[n]) return KNOWN[n];
  return n.replace(/^(de|cs|ar|dm|gg|fy|aim|surf|kz|bhop)_/, '').split(/[_-]/).filter(Boolean).map(w => w[0].toUpperCase() + w.slice(1)).join(' ');
}
function mapArt(map, extra) {
  const n = normMap(map);
  let h = 0; for (const ch of n) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  h = h % 360;
  const art = el('div', { class: 'art ' + (extra || ''), style: `background:linear-gradient(135deg,hsl(${h} 34% 30%),hsl(${(h + 45) % 360} 40% 18%))` },
    el('div', { class: 'art-ph', text: prettyMap(map) }));
  const file = mapsAvail[n];
  if (file) {
    const img = el('img', { src: '/maps/' + encodeURIComponent(file), alt: '', loading: 'lazy' });
    img.addEventListener('error', () => img.remove());
    art.append(img);
    art.querySelector('.art-ph').style.display = 'none';
    img.addEventListener('error', () => { art.querySelector('.art-ph').style.display = ''; });
  }
  return art;
}
async function api(path, opts) {
  const o = Object.assign({ credentials: 'same-origin' }, opts || {});
  if (o.body !== undefined) {
    o.method = 'POST'; o.headers = { 'Content-Type': 'application/json', 'X-NX': '1' }; o.body = JSON.stringify(o.body);
  }
  const r = await fetch(path, o);
  let data = null; try { data = await r.json(); } catch (_) {}
  return { status: r.status, data };
}
function copyText(text) {
  if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(text);
  const ta = el('textarea', { style: 'position:fixed;opacity:0' }); ta.value = text; document.body.append(ta); ta.select();
  try { document.execCommand('copy'); } finally { ta.remove(); }
  return Promise.resolve();
}
function stopTimers() { timers.forEach(clearInterval); timers = []; }
function every(ms, fn) { timers.push(setInterval(() => { if (!document.hidden) fn(); }, ms)); }
function go(path, replace) {
  if (location.pathname !== path) history[replace ? 'replaceState' : 'pushState'](null, '', path);
  route();
}

// ---------------------------------------------------------------- language
async function loadLang(code) {
  try {
    const r = await fetch('/static/i18n/' + encodeURIComponent(code) + '.json');
    if (!r.ok) throw 0;
    T = await r.json(); lang = code;
  } catch (_) {
    if (code !== 'en') return loadLang('en');
  }
  document.documentElement.lang = lang;
  document.documentElement.dir = T._dir || 'ltr';
  document.querySelectorAll('[data-i18n]').forEach(n => { n.textContent = t(n.dataset.i18n); });
}
async function setupLangPicker() {
  try {
    const list = await (await fetch('/static/i18n/languages.json')).json();
    const codes = Object.keys(list);
    const sel = $id('lang');
    if (codes.length < 2) return;
    codes.forEach(c => sel.append(el('option', { value: c, text: list[c], selected: c === lang })));
    sel.hidden = false;
    sel.addEventListener('change', async () => { localStorage.setItem('nx_lang', sel.value); await loadLang(sel.value); route(); });
  } catch (_) {}
}

// ---------------------------------------------------------------- header
function paintHeader() {
  $id('loginBtn').hidden = !!me;
  $id('who').hidden = !me;
  if (me) $id('whoName').textContent = me.name || '';
}

// ---------------------------------------------------------------- server rows (landing and "not on a server")
function serverRow(s) {
  const max = Math.min(s.max || 0, 32);
  const ticks = el('div', { class: 'ticks', 'aria-hidden': 'true' });
  for (let i = 0; i < max; i++) ticks.append(el('i', { class: i < s.players ? 'f' : '' }));
  const side = el('div', { class: 'srv-side' },
    el('div', { class: 'count', text: s.online ? t('server.players.short', { n: s.players, max: s.max || '?' }) : '' }), ticks);
  if (s.port) {
    const cmd = `connect ${location.hostname}:${s.port}`;
    const b = el('button', { class: 'copy', type: 'button', text: t('server.connect') });
    b.addEventListener('click', () => copyText(cmd).then(() => { b.textContent = t('server.copied'); setTimeout(() => { b.textContent = t('server.connect'); }, 1500); }));
    side.append(b);
  }
  return el('article', { class: 'srv' }, mapArt(s.map, 'cut'),
    el('div', { class: 'srv-main' }, el('div', { class: 'srv-name', text: s.name }),
      el('div', { class: 'srv-sub' }, el('span', { class: 'dot' + (s.online ? ' on' : '') }),
        el('span', { text: s.online ? (prettyMap(s.map) || t('server.online')) : t('server.offline') }))),
    side);
}
function paintServers(box, list) {
  clear(box);
  if (!list.length) { box.append(el('p', { class: 'muted', text: t('landing.empty') })); return; }
  list.forEach(s => box.append(serverRow(s)));
}
async function loadMaps() { try { mapsAvail = (await api('/api/maps')).data.maps || {}; } catch (_) {} }

// ---------------------------------------------------------------- landing
async function renderLanding() {
  clear(app);
  const box = el('div', { class: 'servers' });
  app.append(el('section', {}, el('h1', { class: 'section-title', text: t('landing.title') }), el('p', { class: 'lead', text: t('landing.lead') }), el('div', { style: 'height:16px' }), box));
  const refresh = async () => {
    const r = await api('/api/servers').catch(() => null);
    if (r && r.data) paintServers(box, r.data.servers || []);
  };
  await loadMaps(); await refresh(); every(10000, refresh);
}

// ---------------------------------------------------------------- login
function renderLogin(notice) {
  clear(app);
  const err = el('p', { class: 'err', role: 'alert' });
  const input = el('input', { class: 'code-in', id: 'code', type: 'text', maxlength: '9', autocomplete: 'off', autocapitalize: 'characters', spellcheck: 'false', 'aria-describedby': 'codeerr', placeholder: 'XXXX-XXXX' });
  err.id = 'codeerr';
  const btn = el('button', { class: 'btn btn-primary', type: 'submit', text: t('login.submit') });
  input.addEventListener('input', () => {
    let v = input.value.toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 8);
    input.value = v.length > 4 ? v.slice(0, 4) + '-' + v.slice(4) : v;
  });
  const form = el('form', { class: 'field' }, el('label', { for: 'code', text: t('login.code') }), input, err, btn);
  form.addEventListener('submit', async ev => {
    ev.preventDefault();
    const code = input.value.replace(/[^A-Z0-9]/g, '');
    if (code.length !== 8) { err.textContent = t('login.error.empty'); return; }
    btn.disabled = true; btn.textContent = t('login.busy'); err.textContent = '';
    try {
      const r = await api('/api/auth/login', { body: { code } });
      if (r.data && r.data.ok) { await refreshMe(); go('/me', true); return; }
      err.textContent = (r.data && r.data.error) || t('login.error.network');
    } catch (_) { err.textContent = t('login.error.network'); }
    btn.disabled = false; btn.textContent = t('login.submit');
  });
  app.append(el('section', { class: 'login' },
    notice ? el('p', { class: 'notice', text: notice }) : null,
    el('h1', { text: t('login.title') }),
    el('ol', { class: 'steps' },
      el('li', {}, el('span', { text: t('login.step1') })),
      el('li', {}, el('span', { text: t('login.step2') })),
      el('li', {}, el('span', { text: t('login.step3') }))),
    form, el('a', { class: 'link', href: '/', text: t('login.back') })));
  input.focus();
}

// ---------------------------------------------------------------- dashboard
async function refreshMe() {
  const r = await api('/api/me').catch(() => null);
  if (r && r.status === 200 && r.data && r.data.steam) { me = r.data; return true; }
  if (r && r.status === 401) me = null;
  return false;
}

function playerRow(p) {
  return el('div', { class: 'prow' + (p.me ? ' me' : '') },
    el('span', { class: 'pn', text: p.name + (p.me ? ' (' + t('me.you') + ')' : '') }),
    el('span', { class: 'pj', title: absDate(p.joined), text: t('me.joined', { when: ago(p.joined) }) }),
    el('span', { class: 'pk', text: `${p.kills} / ${p.deaths}` }));
}
function teamBox(cls, title, players, score) {
  const h = el('h3', {}, el('span', { text: title }), el('span', { text: score != null ? String(score) : String(players.length) }));
  const box = el('div', { class: 'team ' + cls }, h);
  players.forEach(p => box.append(playerRow(p)));
  return box;
}
function paintNow(box, servers) {
  clear(box);
  const o = me.online;
  if (!o) {
    const last = me.servers[0];
    const off = el('div', { class: 'off' }, el('h2', { text: t('me.notOnServer') }),
      el('p', { class: 'muted', text: last ? t('me.lastPlayed', { server: last.name, when: ago(last.last_played) }) : t('me.neverPlayed') }),
      el('p', { class: 'muted', text: t('me.notOnServer.hint') }));
    const list = el('div', { class: 'servers' }); paintServers(list, servers || []);
    box.append(off, list);
    return;
  }
  const ct = o.players.filter(p => p.team === 3), tt = o.players.filter(p => p.team === 2), other = o.players.filter(p => p.team !== 2 && p.team !== 3);
  const art = el('div', { class: 'now-art' }, mapArt(o.map), el('div', { class: 'shade' }),
    el('div', { class: 'now-info' },
      el('div', { class: 'now-kick', text: o.warmup ? t('me.warmup') : o.in_match ? t('me.inMatch') : t('me.online') }),
      el('div', { class: 'now-name', text: o.name }),
      el('div', { class: 'now-sub', text: prettyMap(o.map) }),
      el('div', { class: 'now-sub', text: t('server.players', { n: o.players.length, max: o.max || '?' }) })));
  const board = el('div', { class: 'board' });
  const live = o.in_match && !o.warmup;
  if (ct.length) board.append(teamBox('ct', t('me.team.ct'), ct, live ? o.score_ct : null));
  if (tt.length) board.append(teamBox('t', t('me.team.t'), tt, live ? o.score_t : null));
  if (other.length) board.append(teamBox('o', t('me.team.other'), other, null));
  box.append(el('div', { class: 'now' }, art, board));
}
function fact(label, value, sub) {
  return el('div', { class: 'fact' }, el('dt', { text: label }), el('dd', {}, value, sub ? el('small', { text: sub }) : null));
}
function paintFacts(box) {
  clear(box);
  const m = me.matches, o = me.online;
  box.append(
    fact(t('me.facts.first'), absDate(me.first_seen), ago(me.first_seen)),
    fact(t('me.facts.login'), me.last_login ? absDate(me.last_login) : t('me.facts.first.login'), me.last_login ? ago(me.last_login) : ''),
    fact(t('me.facts.last'), o ? t('me.online') : me.servers.length ? absDate(me.last_seen) : t('me.facts.none'), !o && me.servers.length ? ago(me.last_seen) : ''),
    fact(t('me.facts.time'), me.playtime ? dur(me.playtime) : t('me.facts.none')),
    fact(t('me.facts.matches'), m.total ? String(m.total) : t('me.facts.none'), m.total ? t('me.facts.record', { w: m.wins, l: m.losses, d: m.draws }) : ''));
}
function paintPlays(box) {
  clear(box);
  const max = Math.max(1, ...me.servers.map(s => s.seconds));
  me.servers.forEach(s => box.append(el('div', { class: 'play' },
    el('span', { class: 'nm', text: s.name }), el('span', { class: 'tm', text: dur(s.seconds) }),
    el('div', { class: 'bar2' }, el('i', { style: `width:${Math.max(2, Math.round(s.seconds / max * 100))}%` })),
    el('span', { class: 'meta', text: t('me.servers.sessions', { n: s.sessions }) + ', ' + t('me.servers.last', { when: ago(s.last_played) }) }))));
}

// ---- matches
const MS = { items: [], more: false, openId: null, cache: {} };
function splitBar(m) {
  const tot = m.score_ct + m.score_t;
  let ctw = tot ? m.score_ct / tot * 100 : 50;
  if (tot && m.score_ct && m.score_t) ctw = Math.min(88, Math.max(12, ctw));
  return el('div', { class: 'split' },
    el('div', { class: 'split-bar' }, el('b', { class: 'sct', style: `flex:${ctw} 1 0`, text: String(m.score_ct) }), el('b', { class: 'st', style: `flex:${100 - ctw} 1 0`, text: String(m.score_t) })),
    el('div', { class: 'split-flag' }, el('span', { text: m.team === 3 ? t('match.side.mine') : '' }), el('span', { class: 'r', text: m.team === 2 ? t('match.side.mine') : '' })));
}
function resultText(r) { return r === 'win' ? t('match.win') : r === 'loss' ? t('match.loss') : r === 'draw' ? t('match.draw') : t('match.spectator'); }
function detailTable(d, team, cls, title) {
  const rows = d.players.filter(p => p.team === team);
  if (!rows.length) return null;
  const head = el('tr', {}, el('th', { text: t('match.col.player') }), ...['k', 'd', 'a', 'dmg', 'mvp', 'score'].map(k => el('th', { text: t('match.col.' + k) })));
  const body = rows.map(p => el('tr', { class: (p.me ? 'me ' : '') + (p.left_early ? 'gone' : '') },
    el('td', { text: p.name + (p.left_early ? ' (' + t('match.left') + ')' : '') }), el('td', { text: p.kills }), el('td', { text: p.deaths }), el('td', { text: p.assists }),
    el('td', { text: p.damage }), el('td', { text: p.mvps }), el('td', { text: p.score })));
  return el('div', {}, el('div', { class: 'tt ' + cls, text: title }), el('div', { class: 'table-wrap' }, el('table', {}, el('thead', {}, head), el('tbody', {}, body))));
}
async function toggleDetail(m, holder, row) {
  if (MS.openId === m.id) { MS.openId = null; clear(holder); row.setAttribute('aria-expanded', 'false'); return; }
  document.querySelectorAll('.match .detail').forEach(n => n.remove());
  document.querySelectorAll('.mrow[aria-expanded="true"]').forEach(n => n.setAttribute('aria-expanded', 'false'));
  MS.openId = m.id; row.setAttribute('aria-expanded', 'true');
  let d = MS.cache[m.id];
  if (!d) { const r = await api('/api/me/matches/' + m.id).catch(() => null); d = r && r.data && r.data.players ? r.data : null; if (d) MS.cache[m.id] = d; }
  if (!d || MS.openId !== m.id) return;
  clear(holder);
  holder.append(el('div', { class: 'detail' }, detailTable(d, 3, 'ct', t('me.team.ct')), detailTable(d, 2, 't', t('me.team.t'))));
}
function matchItem(m) {
  const holder = el('div', {});
  const row = el('button', { class: 'mrow', type: 'button', 'aria-expanded': 'false', title: t('match.details') },
    mapArt(m.map, 'cut'),
    el('div', { class: 'minfo' }, el('div', { class: 'mmap', text: prettyMap(m.map) || m.map }), el('div', { class: 'msub', text: m.server }), el('div', { class: 'msub', text: absDate(m.ended) + ', ' + t('match.rounds', { n: m.rounds }) })),
    splitBar(m),
    el('div', { class: 'mkda', text: t('match.kda', { k: m.kills, d: m.deaths, a: m.assists }) }),
    el('div', { class: 'mres ' + (m.result || 'none'), text: resultText(m.result) }));
  row.addEventListener('click', () => toggleDetail(m, holder, row));
  return el('article', { class: 'match' }, row, holder);
}
async function loadMatches(box, moreBtn, reset) {
  if (reset) { MS.items = []; MS.openId = null; }
  const r = await api('/api/me/matches?limit=20&offset=' + MS.items.length).catch(() => null);
  if (!r || !r.data || !r.data.matches) return;
  const got = r.data.matches;
  MS.items.push(...got); MS.more = got.length === 20;
  if (reset) clear(box);
  if (!MS.items.length) { box.append(el('p', { class: 'muted', text: t('me.matches.empty') })); }
  got.forEach(m => box.append(matchItem(m)));
  moreBtn.hidden = !MS.more;
}

async function renderDash() {
  clear(app);
  const nowBox = el('section', { 'aria-label': t('me.now') });
  const factsBox = el('dl', { class: 'facts' });
  const playsBox = el('div', { class: 'plays' });
  const matchBox = el('div', { class: 'matches' });
  const moreBtn = el('button', { class: 'btn more', type: 'button', text: t('me.matches.more'), hidden: true });
  const playsSec = el('section', {}, el('h2', { class: 'section-title', text: t('me.servers') }), playsBox);
  app.append(nowBox, el('section', {}, factsBox), playsSec,
    el('section', {}, el('h2', { class: 'section-title', text: t('me.matches') }), matchBox, el('div', { style: 'height:12px' }), moreBtn));
  let servers = [];
  const paint = () => { paintNow(nowBox, servers); paintFacts(factsBox); paintPlays(playsBox); playsSec.hidden = !me.servers.length; paintHeader(); };
  const refresh = async () => {
    const ok = await refreshMe();
    if (!me) { stopTimers(); go('/login', true); renderLogin(t('error.session')); return; }
    if (ok && !me.online) { const r = await api('/api/servers').catch(() => null); if (r && r.data) servers = r.data.servers; }
    if (ok) paint();
  };
  await loadMaps();
  const r = await api('/api/servers').catch(() => null); if (r && r.data) servers = r.data.servers;
  paint();
  moreBtn.addEventListener('click', () => loadMatches(matchBox, moreBtn, false));
  await loadMatches(matchBox, moreBtn, true);
  every(5000, refresh);
}

// ---------------------------------------------------------------- router
async function route() {
  stopTimers();
  paintHeader();
  const p = location.pathname;
  if (me) { if (p !== '/me') history.replaceState(null, '', '/me'); return renderDash(); }
  if (p === '/login') return renderLogin();
  if (p !== '/') history.replaceState(null, '', '/');
  return renderLanding();
}

document.addEventListener('click', ev => {
  const a = ev.target.closest('a[href^="/"]');
  if (a && !ev.metaKey && !ev.ctrlKey && !ev.shiftKey && a.target !== '_blank' && !a.getAttribute('href').startsWith('/static')) { ev.preventDefault(); go(a.getAttribute('href')); }
});
window.addEventListener('popstate', route);
$id('whoBtn').addEventListener('click', () => {
  const m = $id('whoMenu'); m.hidden = !m.hidden; $id('whoBtn').setAttribute('aria-expanded', String(!m.hidden));
});
document.addEventListener('click', ev => { if (!ev.target.closest('#who')) { $id('whoMenu').hidden = true; $id('whoBtn').setAttribute('aria-expanded', 'false'); } });
$id('logoutBtn').addEventListener('click', async () => {
  await api('/api/auth/logout', { body: {} }).catch(() => {});
  me = null; $id('whoMenu').hidden = true; go('/', true);
});

(async function boot() {
  await loadLang(localStorage.getItem('nx_lang') || 'en');
  setupLangPicker();
  await refreshMe();
  route();
})();
})();
