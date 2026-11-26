// Menus, lobby, controls and the game loop.
import { TILE as T, DEF, TYPES, BUILDABLE, COLORS, COLOR_NAMES, HEROES } from './data.js';
import { Sim } from './sim.js';
import { AI } from './ai.js';
import { View, Renderer } from './render.js';
import { hostRoom, joinRoom, makeCode, LOCAL } from './net.js';

const $ = id => document.getElementById(id);
const params = new URLSearchParams(location.search);
const SPEED = Math.max(1, +params.get('speed') || 1); // ?speed=8 fast-forwards a hosted game (for testing)
const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const clean = s => String(s || '').replace(/\s+/g, ' ').trim().slice(0, 12) || 'Player';

const cv = $('c');
const R = new Renderer(cv, $('mini'));
const G = { view: null, sel: new Set(), placing: null, boxMode: false, box: null, send: null, conn: null, room: null, conns: null, timer: 0, ended: false, needCenter: false, mouse: null, touch: false };
let L = null; // lobby state
window.__wc = { G, R, get L() { return L; }, drop() { const c = G.conn; if (c) { c.close(); clientClosed(c); } } };

// ---------------------------------------------------------------- screens
function show(id) {
  for (const s of ['menu', 'lobby', 'help', 'end', 'ask']) $(s).hidden = s !== id;
  $('hud').hidden = !G.view;
  if (id === 'menu') { const s = session(); $('mRejoin').hidden = !s; if (s) $('mRejoin').textContent = 'Rejoin game ' + s.code; }
}
let toastT = 0;
function toast(msg) {
  const t = $('toast');
  t.textContent = msg; t.classList.add('on');
  clearTimeout(toastT); toastT = setTimeout(() => t.classList.remove('on'), 2600);
}
const store = { get: k => { try { return localStorage.getItem(k); } catch { return null; } }, set: (k, v) => { try { localStorage.setItem(k, v); } catch { /* private mode */ } } };
$('name').value = store.get('warcamp-name') || 'Player';
const myName = () => { const n = clean($('name').value); store.set('warcamp-name', n); return n; };

// ---------------------------------------------------------------- menu and lobby
// Who this device is, so the host can give a player their base back after a dropped connection.
// It is kept per tab, so two tabs on one device are two players; the saved session carries it across a full restart.
const tab = { get: k => { try { return sessionStorage.getItem(k); } catch { return null; } }, set: (k, v) => { try { sessionStorage.setItem(k, v); } catch { /* private mode */ } } };
let TOKEN = params.get('id') || tab.get('warcamp-token') || Math.random().toString(36).slice(2) + Date.now().toString(36);
tab.set('warcamp-token', TOKEN);
const SKEY = 'warcamp-session' + (params.get('id') || '');
const prefs = () => ({
  hero: HEROES.includes(store.get('warcamp-hero')) ? store.get('warcamp-hero') : 'hero',
  color: Math.max(0, Math.min(COLORS.length - 1, +store.get('warcamp-color') || 0)),
});
const seated = s => s.kind === 'human' || s.kind === 'ai';
const freeColor = want => {
  const used = L.slots.filter(seated).map(s => s.color);
  if (want != null && !used.includes(want)) return want;
  for (let c = 0; c < COLORS.length; c++) if (!used.includes(c)) return c;
  return 0;
};
function setKind(s, kind) {
  s.kind = kind;
  delete s.color; delete s.hero;
  if (kind === 'ai') { s.color = freeColor(); s.hero = HEROES[(Math.random() * HEROES.length) | 0]; }
}
function newLobby(online, code, kinds) {
  const p = prefs();
  L = { online, host: true, code, mode: 'ffa', level: 1, you: 0, slots: [{ kind: 'human', name: myName(), token: TOKEN, hero: p.hero, color: p.color }] };
  for (const k of kinds) { const s = { kind: 'closed' }; L.slots.push(s); setKind(s, k); }
  renderLobby(); show('lobby');
}

$('mHelp').onclick = () => show('help');
$('hClose').onclick = () => show('menu');
$('mSingle').onclick = () => newLobby(false, '', ['ai', 'closed', 'closed']);
$('mHost').onclick = async () => {
  $('mMsg').textContent = 'Opening a room…';
  for (let attempt = 0; attempt < 3; attempt++) {
    const code = makeCode();
    try {
      G.room = await hostRoom(code);
      G.room.onconn = onJoin;
      $('mMsg').textContent = '';
      newLobby(true, code, ['open', 'open', 'ai']);
      return;
    } catch (e) {
      if (e && e.type === 'unavailable-id') continue; // code already in use, try another
      $('mMsg').textContent = 'Could not open a room: ' + (e && e.message || 'no connection') + '.';
      return;
    }
  }
};
function hello() { const p = prefs(); return { t: 'hello', name: myName(), token: TOKEN, hero: p.hero, color: p.color }; }
function useConn(c) {
  G.conn = c;
  c.ondata = clientMsg;
  c.onclose = () => clientClosed(c);
  c.send(hello());
}
async function join(code) {
  $('mMsg').textContent = 'Joining ' + code + '…';
  try {
    const c = await joinRoom(code);
    L = { online: true, host: false, code, mode: 'ffa', level: 1, you: -1, slots: [] };
    useConn(c);
    $('mMsg').textContent = '';
    renderLobby(); show('lobby');
  } catch (e) {
    $('mMsg').textContent = (e && e.message || 'Could not join') + '.';
  }
}
$('mJoin').onclick = () => {
  const code = $('code').value.trim().toUpperCase();
  if (code.length !== 4) { $('mMsg').textContent = 'Type the 4-letter code from the host.'; return; }
  join(code);
};
$('code').addEventListener('keydown', e => { if (e.key === 'Enter') $('mJoin').click(); });
// A game this device was in a short while ago can be picked up again from the menu.
function session() {
  try { const s = JSON.parse(store.get(SKEY) || 'null'); return s && s.code && Date.now() - s.at < 30 * 60e3 ? s : null; } catch { return null; }
}
$('mRejoin').onclick = () => { const s = session(); if (!s) return; if (s.token) { TOKEN = s.token; tab.set('warcamp-token', TOKEN); } join(s.code); };

// Host side: someone connected to the room.
function onJoin(c) {
  c.ondata = m => {
    if (!m) return;
    if (m.t === 'pick' && !G.view) {
      const s = L.slots.find(s => s.conn === c);
      if (!s) return;
      if (HEROES.includes(m.hero)) s.hero = m.hero;
      if (Number.isInteger(m.color) && m.color >= 0 && m.color < COLORS.length && !L.slots.some(o => o !== s && seated(o) && o.color === m.color)) s.color = m.color;
      return syncLobby();
    }
    if (m.t !== 'hello') return;
    const token = typeof m.token === 'string' ? m.token.slice(0, 64) : '';
    const full = () => { c.send({ t: 'full' }); setTimeout(() => c.close(), 300); };
    if (G.view) { // a game is running: only someone who was in it may come back
      const pid = token && G.tokens ? G.tokens.indexOf(token) : -1;
      if (pid < 1 || !G.attach) return full();
      return G.attach(c, pid);
    }
    const s = L.slots.find(s => s.kind === 'open');
    if (!s) return full();
    Object.assign(s, { kind: 'human', name: clean(m.name), conn: c, token, hero: HEROES.includes(m.hero) ? m.hero : 'hero' });
    s.color = freeColor(Number.isInteger(m.color) && m.color >= 0 && m.color < COLORS.length ? m.color : null);
    c.onclose = () => {
      if (G.view) return;
      const s = L.slots.find(s => s.conn === c);
      if (s) { delete s.conn; delete s.token; delete s.name; setKind(s, 'open'); syncLobby(); }
    };
    syncLobby();
  };
}
function syncLobby() {
  renderLobby();
  const slots = L.slots.map(s => ({ kind: s.kind, name: s.name, hero: s.hero, color: s.color }));
  L.slots.forEach((s, i) => s.conn && s.conn.send({ t: 'lobby', slots, mode: L.mode, level: L.level, code: L.code, you: i }));
}
function renderLobby() {
  $('lTitle').textContent = L.online ? 'Multiplayer game' : 'Single player';
  $('lCode').hidden = !L.online;
  $('lCode').innerHTML = `Room code<b>${esc(L.code)}</b>${L.host ? 'Friends type this code and tap Join.' : ''}`;
  const label = { ai: 'Computer', open: 'Waiting for a player…', closed: 'Closed' };
  $('slots').innerHTML = L.slots.map((s, i) => {
    const text = s.kind === 'human' ? esc(s.name) + (i === L.you ? ' (you)' : '') : label[s.kind];
    const hero = seated(s) && DEF[s.hero] ? `<small>${DEF[s.hero].name}</small>` : '';
    const btn = L.host && i > 0 && s.kind !== 'human' ? `<button data-slot="${i}">Change</button>` : '';
    return `<div class="slot ${seated(s) ? '' : 'off'}"><i style="background:${seated(s) ? COLORS[s.color] : '#2c3d5a'}"></i><span>${text}${hero}</span>${btn}</div>`;
  }).join('') || '<div class="slot off"><span>Connecting…</span></div>';
  const me = L.slots[L.you];
  $('pick').innerHTML = !me ? '' :
    '<div class="pl">Your hero</div><div class="heroes">' + HEROES.map(h =>
      `<button data-hero="${h}" class="${me.hero === h ? 'on' : ''}"><b>${DEF[h].name}</b><small>${DEF[h].about}</small><small><i>${DEF[h].ab.name}</i>: ${DEF[h].ab.about}</small></button>`).join('') +
    '</div><div class="pl">Your colour</div><div class="colors">' + COLORS.map((c, i) =>
      `<button data-color="${i}" style="background:${c}" class="${me.color === i ? 'on' : ''}" aria-label="${COLOR_NAMES[i]}"${L.slots.some(o => o !== me && seated(o) && o.color === i) ? ' disabled' : ''}></button>`).join('') + '</div>';
  $('lMode').value = L.mode; $('lLevel').value = L.level;
  $('lMode').disabled = $('lLevel').disabled = !L.host;
  $('lStart').hidden = !L.host;
  $('lMsg').textContent = L.host ? '' : 'Waiting for the host to start…';
}
$('pick').onclick = e => {
  const b = e.target.closest('button');
  const me = L && L.slots[L.you];
  if (!b || b.disabled || !me) return;
  const hero = b.dataset.hero || me.hero, color = b.dataset.color != null ? +b.dataset.color : me.color;
  store.set('warcamp-hero', hero); store.set('warcamp-color', color);
  if (L.host) { me.hero = hero; me.color = color; syncLobby(); }
  else if (G.conn) G.conn.send({ t: 'pick', hero, color });
};
$('slots').onclick = e => {
  const b = e.target.closest('button[data-slot]');
  if (!b || !L.host) return;
  const s = L.slots[+b.dataset.slot];
  const order = L.online ? ['open', 'ai', 'closed'] : ['ai', 'closed'];
  setKind(s, order[(order.indexOf(s.kind) + 1) % order.length]);
  syncLobby();
};
$('lMode').onchange = () => { L.mode = $('lMode').value; syncLobby(); };
$('lLevel').onchange = () => { L.level = +$('lLevel').value; syncLobby(); };
$('lBack').onclick = () => { closeNet(); show('menu'); };
$('lStart').onclick = () => {
  const ps = [], conns = [], tokens = [];
  let n = 1;
  for (const s of L.slots) {
    if (!seated(s)) continue;
    const ai = s.kind === 'ai';
    ps.push({ name: ai ? 'Computer ' + n++ : s.name, ai, team: 0, bonus: ai ? [.85, 1, 1.25][L.level] : 1, hero: s.hero || 'hero', color: s.color });
    conns.push(s.conn || null);
    tokens.push(ai ? null : s.token || null);
  }
  if (ps.length < 2) { $('lMsg').textContent = 'Add a computer or wait for a player.'; return; }
  const coop = L.mode === 'coop' && ps.some(p => p.ai) && ps.some(p => !p.ai);
  if (L.mode === 'coop' && !coop) { $('lMsg').textContent = 'Players vs computers needs at least one computer.'; return; }
  ps.forEach((p, i) => { p.team = coop ? (p.ai ? 1 : 0) : i; });
  const cfg = { seed: (Math.random() * 2 ** 31) | 0, size: 56, level: L.level, players: ps };
  G.tokens = tokens;
  conns.forEach((c, i) => c && c.send({ t: 'start', cfg, you: i }));
  startGame(cfg, 0, conns);
};

// Client side: messages from the host.
function net(msg) { const n = $('net'); n.textContent = msg; n.hidden = !msg; }
function clientMsg(m) {
  if (!m) return;
  if (m.t === 'lobby' && !G.view) { L = { online: true, host: false, code: m.code, mode: m.mode, level: m.level, you: m.you, slots: m.slots }; renderLobby(); }
  else if (m.t === 'start') {
    const back = !!G.rc;
    if (G.rc) { clearTimeout(G.rc.wait); G.rc = null; }
    net('');
    // Coming back to the same game keeps what this screen had already explored.
    if (m.resume && G.view && G.view.seed === m.cfg.seed) G.view.me = m.you; else startGame(m.cfg, m.you, null);
    for (const i of m.gone || []) if (G.view.terrain[i]) { G.view.terrain[i] = 0; G.view.dirty.push(i); }
    G.lastSnap = performance.now();
    store.set(SKEY, JSON.stringify({ code: L.code, token: TOKEN, at: Date.now() }));
    if (back || m.resume) toast('You are back in the game');
  }
  else if (m.t === 'snap') { G.lastSnap = performance.now(); if (G.view) G.view.apply(m.s); }
  else if (m.t === 'bye') {
    store.set(SKEY, '');
    closeNet();
    if (G.view && !G.ended) endScreen('Game over', 'The host ended the game.');
  }
  else if (m.t === 'full') {
    store.set(SKEY, '');
    if (G.rc) { clearTimeout(G.rc.wait); G.rc = null; }
    net('');
    if (G.view) { closeNet(); endScreen('Disconnected', 'That game has ended, or the host has gone.'); }
    else { closeNet(); show('menu'); $('mMsg').textContent = 'That game is full or has already started.'; }
  }
}
function clientClosed(c) {
  if (c !== G.conn) return;
  G.conn = null;
  if (G.view) { if (!G.ended) reconnect(); }
  else { show('menu'); $('mMsg').textContent = 'The host closed the room.'; }
}
// The connection dropped (the app was swiped away, the network blinked, the host stepped out):
// keep knocking on the room until the host lets this player back in.
function reconnect() {
  if (G.rc || !G.view || G.ended || G.conns) return;
  const rc = G.rc = { since: performance.now(), wait: 0 };
  const drop = () => { const x = G.conn; G.conn = null; if (x) { x.onclose = null; x.ondata = null; try { x.close(); } catch { /* already gone */ } } };
  drop();
  net('Connection lost. Getting you back in…');
  const attempt = async () => {
    if (G.rc !== rc) return;
    if (performance.now() - rc.since > 5 * 60e3) { G.rc = null; net(''); endScreen('Disconnected', 'Could not get back to the game.'); return; }
    try {
      const c = await joinRoom(L.code);
      if (G.rc !== rc) { c.close(); return; }
      useConn(c);
      rc.wait = setTimeout(() => { if (G.rc === rc) { drop(); attempt(); } }, 6000); // no answer yet: knock again
    } catch { setTimeout(attempt, 2500); }
  };
  attempt();
}
function closeNet() {
  clearInterval(G.timer); G.timer = 0;
  if (G.rc) { clearTimeout(G.rc.wait); G.rc = null; }
  net('');
  if (G.conns) for (const c of G.conns) c && c.close();
  if (L && L.slots) for (const s of L.slots) s.conn && s.conn.close && s.conn.close();
  if (G.room) G.room.close();
  const c = G.conn; G.conn = null; if (c) { c.onclose = null; c.close(); }
  G.room = G.conns = G.attach = G.tokens = null;
}

// ---------------------------------------------------------------- starting and ending a game
function startGame(cfg, me, conns) {
  G.view = new View(cfg, me);
  R.setView(G.view);
  R.cam.z = Math.min(innerWidth, innerHeight) < 500 ? .8 : 1;
  G.sel.clear(); G.placing = null; G.box = null; G.boxMode = false; G.ended = false; G.elim = false; G.needCenter = true;
  G.lastSnap = performance.now();
  $('bBox').classList.remove('on');
  if (conns) {
    // This device is the host: it runs the simulation and sends everyone a snapshot each tick.
    const sim = G.sim = new Sim(cfg);
    const ais = G.ais = cfg.players.map((p, i) => p.ai ? new AI(sim, i, cfg.level) : null);
    G.conns = conns;
    const hook = (c, i) => {
      c.ondata = m => { if (m && m.t === 'cmd') { try { sim.command(i, m.c); } catch { /* ignore bad input */ } } };
      c.onclose = () => {
        if (conns[i] !== c) return;
        conns[i] = null;
        // A computer keeps the base alive until the player comes back.
        if (sim.players[i].alive && sim.winner === -1) { ais[i] = new AI(sim, i, 1); toast(cfg.players[i].name + ' dropped out: a computer is holding their base'); }
      };
    };
    conns.forEach((c, i) => c && hook(c, i));
    G.attach = (c, i) => {
      const old = conns[i];
      conns[i] = c;
      if (old) { old.onclose = null; old.close(); }
      hook(c, i);
      ais[i] = null;
      c.send({ t: 'start', cfg, you: i, resume: true, gone: sim.gone });
      toast(cfg.players[i].name + ' is back');
    };
    G.send = c => sim.command(me, c);
    const emit = () => { const s = sim.snapshot(); G.view.apply(s); for (const c of conns) c && c.send({ t: 'snap', s }); };
    emit();
    let last = performance.now(), acc = 0, done = false;
    G.timer = setInterval(() => {
      const now = performance.now();
      acc += Math.min(500, now - last) * SPEED; last = now;
      for (let n = 0; acc >= 100 && !done; n++) {
        if (n >= 60) { acc = 0; break; }
        acc -= 100;
        for (const a of ais) a && a.update();
        sim.step();
        emit();
        done = sim.winner !== -1;
      }
    }, 50);
  } else {
    G.send = c => G.conn && G.conn.send({ t: 'cmd', c });
  }
  show(null);
  hudT = 0;
  awake(true);
}
// Phones: keep the screen on during a game, and take the whole screen where the browser allows it.
let wake = null;
const coarse = matchMedia('(pointer: coarse)').matches;
// iPadOS calls itself a Mac, so look for touch points as well.
const iOS = /iPad|iPhone|iPod/.test(navigator.userAgent) || (/Macintosh/.test(navigator.userAgent) && navigator.maxTouchPoints > 1);
const standalone = matchMedia('(display-mode: standalone), (display-mode: fullscreen)').matches || navigator.standalone;
async function awake(on) {
  try {
    if (on && !wake && navigator.wakeLock) { wake = await navigator.wakeLock.request('screen'); wake.addEventListener('release', () => { wake = null; }); }
    if (!on && wake) { const w = wake; wake = null; await w.release(); }
  } catch { /* not allowed here: the game still works */ }
  try {
    const el = document.documentElement;
    // Not on iOS: iPhone has no fullscreen, and iPad shows a "fake keyboard" warning when a fullscreen page is tapped quickly.
    if (on && coarse && !iOS && !standalone && !document.fullscreenElement && el.requestFullscreen) await el.requestFullscreen({ navigationUI: 'hide' });
    if (!on && document.fullscreenElement) await document.exitFullscreen();
  } catch { /* iPhone Safari has no fullscreen: installing the app gives it */ }
}
document.addEventListener('visibilitychange', () => {
  if (document.hidden || !G.view) return;
  awake(true);
  R.resize();
  if (G.conns && G.conns.some(c => c)) toast('You host this game: it pauses for everyone while you are away');
});
function endScreen(title, msg) {
  G.ended = true;
  $('eTitle').textContent = title; $('eMsg').textContent = msg;
  show('end');
}
function quit() {
  store.set(SKEY, '');
  if (G.conns) for (const c of G.conns) c && c.send({ t: 'bye' }); // the host is leaving: tell everyone, so nobody waits
  closeNet();
  G.view = null; G.sim = null; G.send = null;
  awake(false);
  $('mMsg').textContent = '';
  show('menu');
}
$('eWatch').onclick = () => show(null);
$('eMenu').onclick = quit;
$('menuBtn').onclick = () => {
  if (G.ended) return quit();
  $('askMsg').textContent = G.conns && G.conns.some(c => c) ? 'You are the host: the game ends for everyone.' : G.conn ? 'A computer will take over your base.' : 'This game will be lost.';
  show('ask');
};
$('askNo').onclick = () => show(null);
$('askYes').onclick = quit;

// ---------------------------------------------------------------- selection and orders
const ents = () => G.view.ents;
const selected = () => [...G.sel].map(id => ents().get(id)).filter(Boolean);
const myUnits = () => selected().filter(e => e.owner === G.view.me && !e.b);
const visible = e => G.view.spectating() || G.view.canSee(e);

function pick(wx, wy, pad) {
  let best = null, bd = 1e9, under = null;
  for (const e of ents().values()) {
    if (e.b && visible(e) && wx >= e.tx * T && wy >= e.ty * T && wx < (e.tx + e.size) * T && wy < (e.ty + e.size) * T) under = e;
  }
  if (under) pad = Math.min(pad, 1); // a tap on a building means the building, unless it lands right on a unit
  for (const e of ents().values()) {
    if (e.b || !visible(e)) continue;
    const d = Math.hypot(e.rx - wx, e.ry - 4 - wy);
    if (d < DEF[e.type].r + pad && d < bd) { bd = d; best = e; }
  }
  return best || under;
}
function canPlace(type, tx, ty) {
  const v = G.view, N = v.N, s = DEF[type].size;
  for (let y = ty; y < ty + s; y++) for (let x = tx; x < tx + s; x++) {
    if (x < 0 || y < 0 || x >= N || y >= N || v.terrain[y * N + x] !== 0 || !v.explored[y * N + x]) return false;
  }
  for (const e of ents().values()) if (e.b && tx < e.tx + e.size && tx + s > e.tx && ty < e.ty + e.size && ty + s > e.ty) return false;
  return true;
}
const ghostTile = (type, wx, wy) => { const s = DEF[type].size; return [Math.floor(wx / T - s / 2 + .5), Math.floor(wy / T - s / 2 + .5)]; };
function confirmPlace() {
  const p = G.placing;
  if (!p || !p.has) return;
  if (!canPlace(p.type, p.tx, p.ty)) { toast("Can't build there"); return; }
  const ids = myUnits().filter(e => e.type === 'worker').map(e => e.id);
  if (ids.length) G.send({ t: 'build', ids, b: p.type, tx: p.tx, ty: p.ty });
  G.placing = null; hudT = 0;
}
function mark(x, y, col) { if (G.touch) buzz(8); G.view.fx.push({ k: 'm', a: ['m', x, y, col], t: 0 }); }

// What a tap (or right-click) on the world means for the units that are selected.
function order(wx, wy, ent) {
  const v = G.view, us = myUnits();
  if (!us.length) return;
  const ids = us.map(e => e.id), workers = us.filter(e => e.type === 'worker').map(e => e.id), rest = us.filter(e => e.type !== 'worker').map(e => e.id);
  if (ent && !v.friendly(ent)) { G.send({ t: 'attack', ids, target: ent.id }); mark(ent.rx, ent.ry, '#f87171'); return; }
  if (ent && ent.b && !ent.built && ent.owner === v.me && workers.length) {
    G.send({ t: 'assist', ids: workers, b: ent.id });
    if (rest.length) G.send({ t: 'move', ids: rest, x: wx, y: wy });
    mark(ent.rx, ent.ry, '#fbbf24'); return;
  }
  const tx = (wx / T) | 0, ty = (wy / T) | 0, N = v.N;
  if (tx >= 0 && ty >= 0 && tx < N && ty < N && v.terrain[ty * N + tx] >= 2 && v.explored[ty * N + tx] && workers.length) {
    G.send({ t: 'harvest', ids: workers, tx, ty });
    if (rest.length) G.send({ t: 'move', ids: rest, x: wx, y: wy });
    mark((tx + .5) * T, (ty + .5) * T, '#7dd3fc'); return;
  }
  G.send({ t: 'move', ids, x: wx, y: wy });
  mark(wx, wy, '#4ade80');
}
let lastTap = { id: 0, t: 0 };
function selectEnt(e, add) {
  const now = performance.now(), v = G.view;
  if (!e.b && e.owner === v.me && lastTap.id === e.id && now - lastTap.t < 400) {
    // double tap: everything of this kind on screen
    const c = R.cam, vw = R.w / c.z, vh = R.h / c.z;
    G.sel.clear();
    for (const o of ents().values()) if (o.owner === v.me && o.type === e.type && o.rx > c.x && o.ry > c.y && o.rx < c.x + vw && o.ry < c.y + vh) G.sel.add(o.id);
  } else {
    if (!add || e.b || selected().some(o => o.b || o.owner !== v.me)) G.sel.clear();
    G.sel.add(e.id);
  }
  lastTap = { id: e.id, t: now };
  hudT = 0;
}
function tap(sx, sy, touch, add) {
  const [wx, wy] = R.toWorld(sx, sy);
  if (G.placing) {
    const [tx, ty] = ghostTile(G.placing.type, wx, wy), p = G.placing;
    if (!touch || (p.has && tx === p.tx && ty === p.ty)) { p.tx = tx; p.ty = ty; p.has = true; confirmPlace(); }
    else { p.tx = tx; p.ty = ty; p.has = true; hudT = 0; }
    return;
  }
  const e = pick(wx, wy, touch ? 16 : 6);
  if (!touch) { if (e) selectEnt(e, add); else { G.sel.clear(); hudT = 0; } return; }
  if (e && e.owner === G.view.me) return selectEnt(e, false);
  if (myUnits().length) return order(wx, wy, e);
  if (e) selectEnt(e, false); else { G.sel.clear(); hudT = 0; }
}
function selectBox(b) {
  const [x0, y0] = R.toWorld(Math.min(b.x0, b.x1), Math.min(b.y0, b.y1)), [x1, y1] = R.toWorld(Math.max(b.x0, b.x1), Math.max(b.y0, b.y1));
  const me = G.view.me, hit = [];
  for (const e of ents().values()) if (e.owner === me && !e.b && e.rx >= x0 && e.rx <= x1 && e.ry >= y0 && e.ry <= y1) hit.push(e);
  const army = hit.filter(e => e.type !== 'worker'); // a box that catches soldiers leaves the workers at work
  G.sel.clear();
  for (const e of army.length ? army : hit) G.sel.add(e.id);
  hudT = 0;
}

// ---------------------------------------------------------------- pointer input
const ptrs = new Map();
let gest = null, lp = 0;
const pos = e => { const r = cv.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top]; };
cv.addEventListener('contextmenu', e => e.preventDefault());
cv.addEventListener('pointerdown', e => {
  if (!G.view) return;
  const [x, y] = pos(e);
  G.touch = e.pointerType !== 'mouse';
  try { cv.setPointerCapture(e.pointerId); } catch { /* synthetic events */ }
  if (!G.touch) {
    if (e.button === 2) {
      if (G.placing) { G.placing = null; hudT = 0; } else { const [wx, wy] = R.toWorld(x, y); order(wx, wy, pick(wx, wy, 6)); }
      return;
    }
    gest = e.button === 1 ? { k: 'pan', lx: x, ly: y } : { k: 'box', sx: x, sy: y, mouse: true, add: e.shiftKey };
    return;
  }
  ptrs.set(e.pointerId, { x, y });
  clearTimeout(lp);
  if (ptrs.size === 2) {
    const [a, b] = [...ptrs.values()];
    gest = { k: 'pinch', d: Math.hypot(a.x - b.x, a.y - b.y) || 1, cx: (a.x + b.x) / 2, cy: (a.y + b.y) / 2 };
    G.box = null;
    return;
  }
  if (ptrs.size > 2) return;
  gest = { k: G.boxMode && !G.placing ? 'box' : 'tap', sx: x, sy: y, lx: x, ly: y };
  if (gest.k === 'tap' && !G.placing) {
    lp = setTimeout(() => { // hold still, then drag: box select
      if (gest && gest.k === 'tap') { gest.k = 'box'; G.box = { x0: gest.sx, y0: gest.sy, x1: gest.lx, y1: gest.ly }; if (navigator.vibrate) navigator.vibrate(15); }
    }, 380);
  }
});
cv.addEventListener('pointermove', e => {
  if (!G.view) return;
  const [x, y] = pos(e);
  if (e.pointerType === 'mouse') G.mouse = { x, y };
  const p = ptrs.get(e.pointerId);
  if (p) { p.x = x; p.y = y; }
  if (!gest) return;
  const c = R.cam;
  if (gest.k === 'pinch') {
    if (ptrs.size < 2) return;
    const [a, b] = [...ptrs.values()], d = Math.hypot(a.x - b.x, a.y - b.y) || 1, cx = (a.x + b.x) / 2, cy = (a.y + b.y) / 2;
    c.x -= (cx - gest.cx) / c.z; c.y -= (cy - gest.cy) / c.z;
    R.zoomAt(cx, cy, d / gest.d);
    gest.d = d; gest.cx = cx; gest.cy = cy;
  } else if (gest.k === 'pan') {
    c.x -= (x - gest.lx) / c.z; c.y -= (y - gest.ly) / c.z; gest.lx = x; gest.ly = y;
  } else if (gest.k === 'tap') {
    gest.lx = x; gest.ly = y;
    if (Math.hypot(x - gest.sx, y - gest.sy) > 10) { clearTimeout(lp); gest.k = 'pan'; }
  } else if (gest.k === 'box') {
    if (G.box || Math.hypot(x - gest.sx, y - gest.sy) > 6) G.box = { x0: gest.sx, y0: gest.sy, x1: x, y1: y };
  }
});
function pointerEnd(e, cancelled) {
  const [x, y] = pos(e);
  ptrs.delete(e.pointerId);
  clearTimeout(lp);
  const g = gest;
  if (!g || !G.view) { gest = null; G.box = null; return; }
  if (g.k === 'pinch') {
    const rest = [...ptrs.values()][0];
    gest = rest ? { k: 'pan', lx: rest.x, ly: rest.y } : null;
    return;
  }
  gest = null;
  const b = G.box; G.box = null;
  if (cancelled) return;
  if (g.k === 'tap') tap(x, y, true, false);
  else if (g.k === 'box') {
    if (b && Math.hypot(b.x1 - b.x0, b.y1 - b.y0) > 8) {
      selectBox(b);
      if (!g.mouse) { G.boxMode = false; $('bBox').classList.remove('on'); }
    } else tap(g.sx, g.sy, !g.mouse, g.add);
  }
}
cv.addEventListener('pointerup', e => pointerEnd(e, false));
cv.addEventListener('pointercancel', e => pointerEnd(e, true));
cv.addEventListener('wheel', e => { if (!G.view) return; e.preventDefault(); const [x, y] = pos(e); R.zoomAt(x, y, e.deltaY < 0 ? 1.12 : 1 / 1.12); }, { passive: false });

const mini = $('mini');
const miniJump = e => {
  if (!G.view) return;
  const r = mini.getBoundingClientRect(), W = G.view.N * T;
  R.center((e.clientX - r.left) / r.width * W, (e.clientY - r.top) / r.height * W);
};
mini.addEventListener('pointerdown', e => { mini.setPointerCapture(e.pointerId); miniJump(e); });
mini.addEventListener('pointermove', e => { if (e.buttons || e.pointerType === 'touch') miniJump(e); });

const keys = new Set();
addEventListener('keydown', e => {
  if (!G.view || e.target.tagName === 'INPUT') return;
  const k = e.key.toLowerCase();
  keys.add(k);
  if (k === 'escape') { if (G.placing) G.placing = null; else G.sel.clear(); hudT = 0; }
  if (k === 'q') $('bArmy').click();
  if (k === '.') $('bIdle').click();
});
addEventListener('keyup', e => keys.delete(e.key.toLowerCase()));
addEventListener('blur', () => keys.clear());
addEventListener('resize', () => R.resize());
addEventListener('orientationchange', () => setTimeout(() => R.resize(), 250));
if (window.visualViewport) visualViewport.addEventListener('resize', () => R.resize());
// iPhone: stop the page itself from zooming or bouncing under the game.
for (const t of ['gesturestart', 'gesturechange']) document.addEventListener(t, e => e.preventDefault());
document.addEventListener('touchmove', e => { if (G.view && !e.target.closest('#panel, .screen')) e.preventDefault(); }, { passive: false });
const buzz = ms => { if (navigator.vibrate) navigator.vibrate(ms); };

// ---------------------------------------------------------------- HUD buttons and the selection panel
$('bArmy').onclick = () => {
  G.sel.clear(); G.placing = null;
  for (const e of ents().values()) if (e.owner === G.view.me && DEF[e.type].mil) G.sel.add(e.id);
  if (!G.sel.size) toast('No army yet: train soldiers at a Barracks');
  hudT = 0;
};
let idleI = 0;
$('bIdle').onclick = () => {
  const idle = [...ents().values()].filter(e => e.owner === G.view.me && e.type === 'worker' && e.idle);
  if (!idle.length) { toast('No idle workers'); return; }
  const e = idle[idleI++ % idle.length];
  G.sel.clear(); G.sel.add(e.id); G.placing = null;
  R.center(e.x, e.y); hudT = 0;
};
$('bBox').onclick = () => { G.boxMode = !G.boxMode; $('bBox').classList.toggle('on', G.boxMode); if (G.boxMode) toast('Drag a box around your units'); };
$('bDesel').onclick = () => { G.sel.clear(); G.placing = null; hudT = 0; };

const price = d => (d.wood ? `<small class="w">▮ ${d.wood}</small>` : '') + (d.cost ? `<small>◆ ${d.cost}</small>` : '');
const btn = (act, d, off) => `<button data-act="${act}"${off ? ' disabled' : ''}>${d.name}${price(d)}</button>`;
function panelHTML() {
  const v = G.view, me = v.me, P = v.pl[me];
  if (G.placing) {
    const p = G.placing;
    return `<div class="t">Place ${DEF[p.type].name}</div><div class="d">${G.touch ? (p.has ? 'Tap the same spot again, or Build here.' : 'Tap where it should go.') : 'Click where it should go.'}</div>` +
      `<div class="acts">${p.has && G.touch ? '<button data-act="confirm">Build here</button>' : ''}<button data-act="cancel">Cancel</button></div>`;
  }
  const sel = selected();
  if (!sel.length) return '';
  const mine = sel.filter(e => e.owner === me);
  if (!mine.length) return `<div class="t">${DEF[sel[0].type].name} · ${esc(v.info[sel[0].owner].name)}</div><div class="d" id="pd"></div>`;
  const b = mine.find(e => e.b);
  if (b) {
    const d = DEF[b.type];
    let h = `<div class="t">${d.name}</div><div class="d" id="pd"></div>`;
    if (!b.built) return h + '<div class="pb"><i id="pbar"></i></div><div class="acts">' +
      `<button data-act="resume" class="go">${b.paused ? 'Resume building' : 'Send more workers'}</button>` +
      `<button data-act="cancelb" class="warn">Cancel<small>refund</small></button></div>`;
    if (d.trains) {
      h += '<div class="acts">' + d.trains.map(u => btn('train:' + u, DEF[u], P.res < DEF[u].cost || P.pop >= P.cap || b.queue.length >= 5)).join('') + '</div>';
      if (b.queue.length) h += `<div class="d">Training: ${b.queue.map(i => DEF[TYPES[i]].name).join(', ')}</div><div class="pb"><i id="pbar"></i></div>`;
      if (b.queue.length) h = h.replace('</div><div class="d">Training', '<button data-act="unqueue" class="warn">Cancel last<small>refund</small></button></div><div class="d">Training');
    }
    return h;
  }
  const count = {};
  for (const e of mine) count[e.type] = (count[e.type] || 0) + 1;
  let h = `<div class="t">${Object.entries(count).map(([t, n]) => (n > 1 ? n + ' ' : '') + DEF[t].name + (n > 1 ? 's' : '')).join(', ')}</div><div class="d" id="pd"></div><div class="acts">`;
  if (count.worker) {
    const has = t => [...ents().values()].some(e => e.owner === me && e.type === t && e.built);
    h += BUILDABLE.map(t => btn('build:' + t, DEF[t], P.res < DEF[t].cost || P.wood < (DEF[t].wood || 0) || (DEF[t].req && !has(DEF[t].req)))).join('');
  }
  const hero = mine.find(e => DEF[e.type].hero);
  if (hero) h += `<button data-act="ability" id="pab" class="go">${DEF[hero.type].ab.name}</button>`;
  return h + '<button data-act="stop">Stop</button></div>';
}
let hudT = 0, lastPanel = null, lastAlert = 0;
function updateHud() {
  const v = G.view, P = v.pl[v.me];
  $('res').textContent = '◆ ' + P.res;
  $('pop').textContent = `☗ ${P.pop}/${P.cap}`;
  $('wood').textContent = '▮ ' + P.wood;
  $('heroInfo').textContent = P.heroT > 0 ? `${DEF[v.info[v.me].hero].name} returns in ${P.heroT}s` : '';
  if (!G.conns && !G.ended && !G.rc && performance.now() - G.lastSnap > 7000) reconnect(); // the host has gone quiet
  let idle = 0;
  for (const e of ents().values()) if (e.owner === v.me && e.type === 'worker' && e.idle) idle++;
  $('idleN').textContent = idle || '';
  let army = 0;
  for (const e of ents().values()) if (e.owner === v.me && DEF[e.type].mil) army++;
  $('armyN').textContent = army || '';
  $('bDesel').disabled = !G.sel.size && !G.placing;
  const h = panelHTML();
  if (h !== lastPanel) { $('panel').innerHTML = lastPanel = h; }
  const sel = selected(), pd = $('pd'), pbar = $('pbar'), pab = $('pab');
  if (pd && sel.length) {
    const e = sel[0];
    if (sel.length > 1) pd.textContent = 'Tap the ground to move, an enemy to attack.';
    else if (e.b && !e.built) pd.textContent = e.owner !== v.me ? `Under construction ${e.prog}%` : e.paused ? `Paused at ${e.prog}%: no worker is building it` : `Under construction ${e.prog}%`;
    else if (e.b && e.owner === v.me && DEF[e.type].trains && P.pop >= P.cap) pd.textContent = 'Unit limit reached: build a Cottage.';
    else if (e.type === 'outpost' && e.owner === v.me) pd.textContent = 'Workers drop crystal here. Build it next to a far-away deposit.';
    else pd.textContent = `Health ${e.hp}/${DEF[e.type].hp}` + (DEF[e.type].req && !e.built ? '' : '');
    if (pbar) pbar.style.width = (e.prog || 0) + '%';
  }
  if (pab) {
    const hero = sel.find(e => DEF[e.type].hero);
    const cd = hero ? hero.abT : 0, name = hero ? DEF[hero.type].ab.name : '';
    pab.disabled = cd > 0;
    pab.textContent = cd > 0 ? `${name} (${cd}s)` : name;
  }
  // alerts and the end of the game
  if (v.hurt && v.tick - v.hurt.tick < 5 && performance.now() - lastAlert > 12000) {
    const c = R.cam, h = v.hurt;
    if (h.x < c.x || h.y < c.y || h.x > c.x + R.w / c.z || h.y > c.y + R.h / c.z) { lastAlert = performance.now(); toast('You are under attack!'); }
  }
  if (v.winner !== -1 && !G.ended) {
    store.set(SKEY, '');
    const won = v.winner === v.team;
    endScreen(won ? 'Victory' : 'Defeat', won ? 'Every enemy base has fallen.' : v.winner === -2 ? 'Nobody is left standing.' : 'Your side has been wiped out.');
  } else if (!P.alive && !G.elim && !G.ended) { G.elim = true; toast('Your last building fell. You can keep watching.'); }
}
$('panel').addEventListener('click', ev => {
  const b = ev.target.closest('button[data-act]');
  if (!b || b.disabled || !G.view) return;
  const [a, arg] = b.dataset.act.split(':'), me = G.view.me;
  if (a === 'build') G.placing = { type: arg, tx: 0, ty: 0, has: false };
  else if (a === 'cancel') G.placing = null;
  else if (a === 'confirm') confirmPlace();
  else if (a === 'resume' || a === 'cancelb' || a === 'unqueue') {
    const e = selected().find(e => e.b && e.owner === me);
    if (e) G.send({ t: a === 'cancelb' ? 'cancel' : a, b: e.id });
    if (a === 'resume') toast('Workers are on their way');
  }
  else if (a === 'train') { const e = selected().find(e => e.b && e.owner === me); if (e) G.send({ t: 'train', b: e.id, u: arg }); }
  else if (a === 'ability') { for (const e of myUnits()) if (DEF[e.type].hero) G.send({ t: 'ability', id: e.id }); }
  else if (a === 'stop') G.send({ t: 'stop', ids: myUnits().map(e => e.id) });
  hudT = 0;
});

// ---------------------------------------------------------------- frame loop
let lastT = performance.now();
function frame(now) {
  const dt = Math.min(.1, (now - lastT) / 1000);
  lastT = now;
  const v = G.view;
  if (v) {
    const c = R.cam, sp = 620 * dt / c.z;
    if (keys.has('arrowleft') || keys.has('a')) c.x -= sp;
    if (keys.has('arrowright') || keys.has('d')) c.x += sp;
    if (keys.has('arrowup') || keys.has('w')) c.y -= sp;
    if (keys.has('arrowdown') || keys.has('s')) c.y += sp;
    if (G.needCenter) {
      for (const e of v.ents.values()) if (e.owner === v.me && e.type === 'hq') { R.center(e.x, e.y); G.needCenter = false; break; }
    }
    for (const id of G.sel) { const e = v.ents.get(id); if (!e || !visible(e)) { G.sel.delete(id); hudT = 0; } }
    if (G.placing && !myUnits().some(e => e.type === 'worker')) { G.placing = null; hudT = 0; }
    let ghost = null;
    const p = G.placing;
    if (p) {
      if (!G.touch && G.mouse) { [p.tx, p.ty] = ghostTile(p.type, ...R.toWorld(G.mouse.x, G.mouse.y)); p.has = true; }
      if (p.has) ghost = { type: p.type, tx: p.tx, ty: p.ty, ok: canPlace(p.type, p.tx, p.ty) };
    }
    R.draw(dt, { sel: G.sel, box: G.box, ghost });
    if ((hudT -= dt) <= 0) { hudT = .2; updateHud(); }
  }
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);

// ---------------------------------------------------------------- PWA: install and offline
let installEvt = null;
addEventListener('beforeinstallprompt', e => { e.preventDefault(); installEvt = e; $('mInstall').hidden = false; });
$('mInstall').onclick = async () => { if (!installEvt) return; installEvt.prompt(); await installEvt.userChoice; installEvt = null; $('mInstall').hidden = true; };
addEventListener('appinstalled', () => { $('mInstall').hidden = true; });
if ('serviceWorker' in navigator && !LOCAL && (location.protocol === 'https:' || location.hostname === 'localhost' || location.hostname === '127.0.0.1')) {
  const had = !!navigator.serviceWorker.controller;
  addEventListener('load', () => navigator.serviceWorker.register('sw.js').then(reg => {
    document.addEventListener('visibilitychange', () => { if (!document.hidden && !G.view) reg.update().catch(() => {}); });
  }).catch(() => {}));
  // A new version has been downloaded: switch to it straight away, unless a game is on.
  navigator.serviceWorker.addEventListener('controllerchange', () => { if (had && !G.view) location.reload(); });
}
// Where multiplayer cannot work (an embedded preview with no peer connections), offer single player only.
if (window.WARCAMP_SOLO) { $('mHost').hidden = true; $('code').parentElement.hidden = true; }
if (iOS && !standalone && !window.WARCAMP_SOLO) $('mIOS').hidden = false;
show('menu');
