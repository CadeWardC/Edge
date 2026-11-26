// Menus, lobby, controls and the game loop.
import { TILE as T, DEF, TYPES, BUILDABLE, COLORS, COLOR_NAMES, HEROES, MAP_SIZE, BUILD_RANGE, MAXCAP, SURVIVAL, NOMAD } from './data.js';
import { MAPS, mapOf } from './maps.js';
import { Sim } from './sim.js';
import { AI } from './ai.js';
import { View, Renderer, icon } from './render.js';
import { hostRoom, joinRoom, makeCode } from './net.js';

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
  $('game').classList.toggle('on', !!G.view); // the dock takes its place beside the map
  applyLayout();
  if (id === 'menu') {
    const s = session(); $('mRejoin').hidden = !s; if (s) $('mRejoin').textContent = 'Rejoin game ' + s.code;
    const g = saved(); $('mContinue').hidden = !g;
    if (g) $('mContinue').textContent = 'Continue your game' + (g.code ? ' (room ' + g.code + ')' : '');
  }
  if (id && !G.view) startDemo(); else stopDemo(); // a game plays behind the menus until a real one is on
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
  L = { online, host: true, code, mode: 'ffa', map: 'classic', level: 1, you: 0, slots: [{ kind: 'human', name: myName(), token: TOKEN, hero: p.hero, color: p.color }] };
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
    L = { online: true, host: false, code, mode: 'ffa', map: 'classic', level: 1, you: -1, slots: [] };
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
// A game this device is running (single player, or as host) is saved every few seconds, so it survives the app
// being closed or the page being reloaded.
const SAVE = 'warcamp-save' + (params.get('id') || '');
const NKEY = 'warcamp-nomad-best'; // the furthest any Nomad run on this device has got, in tiles
function saved() {
  try { const s = JSON.parse(store.get(SAVE) || 'null'); return s && s.sim && Date.now() - s.at < 12 * 3600e3 ? s : null; } catch { return null; }
}
$('mContinue').onclick = async () => {
  const s = saved();
  if (!s) return;
  L = { online: !!s.code, host: true, code: s.code || '', mode: s.cfg.mode || 'ffa', map: s.cfg.map || 'classic', level: s.cfg.level, you: 0, slots: [] };
  if (s.code) { // reopen the same room, so the other players' devices find their way back in
    $('mMsg').textContent = 'Reopening room ' + s.code + '…';
    try { G.room = await hostRoom(s.code); G.room.onconn = onJoin; $('mMsg').textContent = ''; }
    catch { $('mMsg').textContent = ''; setTimeout(() => toast('Could not reopen the room: the others cannot rejoin'), 500); }
  }
  G.tokens = s.tokens || [];
  startGame(s.cfg, s.me, s.cfg.players.map(() => null), s);
};
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
      if (pid < 0 || pid === G.view.me || !G.attach) return full();
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
  L.slots.forEach((s, i) => s.conn && s.conn.send({ t: 'lobby', slots, mode: L.mode, map: L.map, level: L.level, wave: L.wave ?? 1, extra: L.extra || 0, code: L.code, you: i }));
}
function renderLobby() {
  $('lTitle').textContent = L.online ? 'Multiplayer game' : 'Single player';
  $('lCode').hidden = !L.online;
  $('lCode').innerHTML = `Room code<b>${esc(L.code)}</b><button id="lCopy">${copied === L.code ? 'Copied' : 'Copy code'}</button>${L.host ? '<span>Friends type this code and tap Join.</span>' : ''}`;
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
      `<button data-hero="${h}" class="${me.hero === h ? 'on' : ''}"><b>${DEF[h].name}</b><small>${DEF[h].about}</small><small><i>${DEF[h].abs[0].name}</i>: ${DEF[h].abs[0].about}</small><small>More spells at levels 2 and 4</small></button>`).join('') +
    '</div><div class="pl">Your colour</div><div class="colors">' + COLORS.map((c, i) =>
      `<button data-color="${i}" style="background:${c}" class="${me.color === i ? 'on' : ''}" aria-label="${COLOR_NAMES[i]}"${L.slots.some(o => o !== me && seated(o) && o.color === i) ? ' disabled' : ''}></button>`).join('') + '</div>';
  const horde = L.mode === 'survival' || L.mode === 'nomad', lv = SURVIVAL.levels[L.wave ?? 1];
  $('lMode').value = L.mode; $('lMap').value = L.map; $('lLevel').value = L.level; $('lWave').value = L.wave ?? 1; $('lWave').disabled = !L.host;
  $('lWaveL').hidden = !horde; $('lExtra').value = L.extra || 0;
  // The computers' own difficulty matters wherever a computer plays: not in Nomad, and in Survival only with one seated.
  $('lLevel').parentElement.hidden = L.mode === 'nomad' || (L.mode === 'survival' && !L.slots.some(s => s.kind === 'ai'));
  $('lMode').disabled = $('lMap').disabled = $('lLevel').disabled = $('lExtra').disabled = !L.host;
  $('lExtraL').hidden = L.mode !== 'coop';
  $('lAbout').textContent = { ffa: 'Everyone for themselves.', coop: 'All the players on one side against the computers. Computers can sit in empty seats, and up to four more can be added.',
    survival: 'Everyone on one side, their Keeps together in the middle of the map, against endless waves from its edges. Each wave is bigger than the last, with a Warlord every fifth. More players bring a bigger, tougher Horde. ' + lv.name + ': ' + lv.about + '.',
    nomad: 'No base: lead your hero and a small party as far from the start as you can. Camps lie in wait or patrol on the way, and the further you push, the more waves hunt you. It ends when your hero falls, or the Warlord at the far end does. Computers sit this one out. ' + lv.name + ': ' + lv.about + '.' }[L.mode]
    + ' Map: ' + mapOf(L.map).about;
  $('lStart').hidden = !L.host;
  $('lMsg').textContent = L.host ? '' : 'Waiting for the host to start…';
}
// Tap the room code, or the button under it, to copy it.
let copied = '';
$('lCode').onclick = async e => {
  if (!L || !L.code || !e.target.closest('b, button')) return;
  const code = L.code;
  try { await navigator.clipboard.writeText(code); }
  catch { // no clipboard access here (an old browser, or a page not served over HTTPS): the old way
    const t = document.createElement('textarea');
    t.value = code; t.setAttribute('readonly', ''); t.style.cssText = 'position:fixed;top:0;left:0;opacity:0';
    document.body.appendChild(t); t.select();
    let ok = false; try { ok = document.execCommand('copy'); } catch { /* not allowed either */ }
    t.remove();
    if (!ok) { $('lMsg').textContent = 'Could not copy: the code is ' + code + '.'; return; }
  }
  copied = code; buzz(8);
  if ($('lCopy')) $('lCopy').textContent = 'Copied';
  setTimeout(() => { copied = ''; if ($('lCopy')) $('lCopy').textContent = 'Copy code'; }, 2000);
};
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
$('lMode').onchange = () => { L.mode = $('lMode').value; if (L.mode === 'coop' && !L.extra && !L.slots.some(s => s.kind === 'ai')) L.extra = 1; syncLobby(); };
$('lMap').innerHTML = MAPS.map(m => `<option value="${m.id}">${m.name}</option>`).join('');
$('lMap').onchange = () => { L.map = mapOf($('lMap').value).id; syncLobby(); };
$('lExtra').onchange = () => { L.extra = +$('lExtra').value; syncLobby(); };
$('lLevel').onchange = () => { L.level = +$('lLevel').value; syncLobby(); };
$('lWave').onchange = () => { L.wave = +$('lWave').value; syncLobby(); };
$('lBack').onclick = () => { closeNet(); show('menu'); };
$('lStart').onclick = () => {
  const ps = [], conns = [], tokens = [];
  let n = 1;
  const survival = L.mode === 'survival', nomad = L.mode === 'nomad';
  for (const s of L.slots) {
    if (!seated(s) || (nomad && s.kind === 'ai')) continue; // Nomad is for people: a computer has no idea how to wander
    const ai = s.kind === 'ai';
    ps.push({ name: ai ? 'Computer ' + n++ : s.name, ai, team: 0, bonus: ai ? [.85, 1, 1.25][L.level] : 1, hero: s.hero || 'hero', color: s.color });
    conns.push(s.conn || null);
    tokens.push(ai ? null : s.token || null);
  }
  if (ps.length < 2 && L.mode === 'ffa') { $('lMsg').textContent = 'Add a computer or wait for a player.'; return; }
  if (L.mode === 'coop') { // up to four more computers, on top of the four seats
    const used = new Set(ps.map(p => p.color));
    for (let k = 0; k < (L.extra || 0) && ps.length < 8; k++) {
      let c = 0; while (used.has(c)) c++; used.add(c);
      ps.push({ name: 'Computer ' + n++, ai: true, team: 1, bonus: [.85, 1, 1.25][L.level], hero: HEROES[(Math.random() * HEROES.length) | 0], color: c });
      conns.push(null); tokens.push(null);
    }
  }
  const coop = L.mode === 'coop' && ps.some(p => p.ai) && ps.some(p => !p.ai);
  if (L.mode === 'coop' && !coop) { $('lMsg').textContent = 'Players vs computers needs at least one computer.'; return; }
  ps.forEach((p, i) => { p.team = survival || nomad ? 0 : coop ? (p.ai ? 1 : 0) : i; });
  if (survival || nomad) { ps.push({ name: 'The Horde', horde: true, team: 1, tint: '#57534e' }); conns.push(null); tokens.push(null); }
  // Where everyone starts: allies against computers share a corner (cluster); in Survival the players hold the middle
  // of the map together (center, on the sites that `extra` lays out there) and the Horde walks in from the edges.
  const cfg = { seed: (Math.random() * 2 ** 31) | 0, size: nomad ? NOMAD.map : MAP_SIZE, level: L.level, wave: L.wave ?? 1, mode: L.mode, map: mapOf(L.map).id,
    cluster: L.mode === 'coop', center: survival, extra: survival || (L.mode === 'ffa' && ps.length > 4), players: ps };
  G.tokens = tokens;
  conns.forEach((c, i) => c && c.send({ t: 'start', cfg, you: i }));
  startGame(cfg, 0, conns);
};

// Client side: messages from the host.
function net(msg) { const n = $('net'); n.textContent = msg; n.hidden = !msg; }
function clientMsg(m) {
  if (!m) return;
  if (m.t === 'lobby' && !G.view) { L = { online: true, host: false, code: m.code, mode: m.mode, map: mapOf(m.map).id, level: m.level, wave: m.wave ?? 1, extra: m.extra || 0, you: m.you, slots: m.slots }; renderLobby(); }
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
  else if (m.t === 'takeover') takeover(m.state);
  else if (m.t === 'moved' && typeof m.code === 'string') { // the game has a new host: go and knock there
    L.code = m.code;
    store.set(SKEY, JSON.stringify({ code: L.code, token: TOKEN, at: Date.now() }));
    if (G.rc) { clearTimeout(G.rc.wait); G.rc = null; }
    reconnect('The host changed. Joining the new one…');
  }
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
function reconnect(why) {
  if (G.rc || !G.view || G.ended || G.conns) return;
  const rc = G.rc = { since: performance.now(), wait: 0 };
  const drop = () => { const x = G.conn; G.conn = null; if (x) { x.onclose = null; x.ondata = null; try { x.close(); } catch { /* already gone */ } } };
  drop();
  net(why || 'Connection lost. Getting you back in…');
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

// ---------------------------------------------------------------- screen layouts
// Three ways to arrange the screen, chosen in the game menu and remembered on this device:
//   dock  the map and the controls each have their own area (nothing covers the map)
//   over  the map fills the screen and the controls float over it
//   lite  like "over", with the panel only there when something is selected and no mini-map
// Any of them can be folded (the arrow at the edge of the map) to put the panel and mini-map away.
// Floating controls are the default. (The key is new, so devices that only ever had the old default follow it.)
const LAYKEY = 'warcamp-layout2';
const LAY = (() => { try { return { lay: 'over', left: false, nomap: false, ...JSON.parse(store.get(LAYKEY) || '{}') }; } catch { return { lay: 'over', left: false, nomap: false }; } })();
let folded = false;
function applyLayout() {
  const g = $('game');
  for (const k of ['dock', 'over', 'lite']) g.classList.toggle('lay-' + k, LAY.lay === k);
  g.classList.toggle('left', !!LAY.left);
  g.classList.toggle('nomap', LAY.lay !== 'lite' && !!LAY.nomap);
  g.classList.toggle('showmap', LAY.lay === 'lite' && !!LAY.liteMap); // Light starts without the mini-map
  g.classList.toggle('folded', folded);
  for (const b of document.querySelectorAll('#layouts button')) b.classList.toggle('on', b.dataset.lay === LAY.lay);
  $('layLeft').classList.toggle('on', !!LAY.left);
  const mapOn = LAY.lay === 'lite' ? !!LAY.liteMap : !LAY.nomap;
  $('layMap').classList.toggle('on', mapOn);
  $('layMap').textContent = mapOn ? 'Mini-map: shown' : 'Mini-map: hidden';
  g.classList.toggle('mapoff', !mapOn);
  $('mapTog').textContent = mapOn ? 'Hide map' : 'Map';
  store.set(LAYKEY, JSON.stringify(LAY));
  R.resize();
  pads();
}
// Where controls float over the map, let the camera travel that much further past the map's edge,
// and keep the floating messages clear of them.
function pads() {
  const S = $('stage').getBoundingClientRect(), p = { l: 0, t: 0, r: 0, b: 0 };
  if (G.view) for (const id of ['top', 'side', 'panel', 'mini']) {
    const E = $(id).getBoundingClientRect();
    if (!E.width || !E.height || E.right <= S.left + 1 || E.left >= S.right - 1 || E.bottom <= S.top + 1 || E.top >= S.bottom - 1) continue; // not over the map
    // A wide, flat control lies along the top or the bottom; anything else sits against the left or the right.
    if (E.width >= E.height * 1.3) { if (E.top + E.height / 2 < S.top + S.height / 2) p.t = Math.max(p.t, E.bottom - S.top); else p.b = Math.max(p.b, S.bottom - E.top); }
    else if (E.left + E.width / 2 > S.left + S.width / 2) p.r = Math.max(p.r, S.right - E.left);
    else p.l = Math.max(p.l, E.right - S.left);
  }
  R.pad = p;
  const st = $('stage').style;
  // The floating messages only need to clear the bar across the top, not the mini-map in the corner.
  const T0 = $('top').getBoundingClientRect(), barTop = G.view && S.height >= S.width && T0.width && T0.top < S.top + S.height / 2 && T0.bottom > S.top + 1 ? T0.bottom - S.top : 0;
  st.setProperty('--pt', barTop + 'px'); st.setProperty('--pb', p.b + 'px');
  st.setProperty('--pr', (p.r > 150 ? p.r : 0) + 'px'); st.setProperty('--pl', (p.l > 150 ? p.l : 0) + 'px');
}
$('layouts').onclick = e => { const b = e.target.closest('button[data-lay]'); if (!b) return; LAY.lay = b.dataset.lay; folded = false; applyLayout(); };
$('layLeft').onclick = () => { LAY.left = !LAY.left; applyLayout(); };
$('layMap').onclick = () => { if (LAY.lay === 'lite') LAY.liteMap = !LAY.liteMap; else LAY.nomap = !LAY.nomap; applyLayout(); };
$('fold').onclick = () => { folded = !folded; applyLayout(); };
$('mapTog').onclick = () => $('layMap').click();

// ---------------------------------------------------------------- handing the game to another host
// The host's device runs the game. When the host is knocked out or leaves, the whole game is passed to another
// player's device, which opens a new room; everyone else is told the new code and rejoins there by themselves.
async function handover() {
  if (!G.conns || G.moving || !G.sim || G.sim.winner !== -1) return null;
  const sim = G.sim, cfg = G.cfg, conns = G.conns;
  // the players still in the game first
  const order = cfg.players.map((_, i) => i).filter(i => conns[i]).sort((a, b) => sim.players[b].alive - sim.players[a].alive);
  if (!order.length) return null;
  G.moving = true;
  clearInterval(G.timer); G.timer = 0; // freeze, so the copy that is sent is the final word
  const state = { cfg, tokens: G.tokens, ais: G.ais.map((a, i) => a && cfg.players[i].ai ? { att: a.att, wave: a.wave } : null), sim: sim.save() };
  for (const i of order) {
    const c = conns[i];
    if (!c) continue;
    const code = await new Promise(res => {
      const t = setTimeout(() => res(null), 9000);
      G.onReady = (from, m) => { if (from === i && typeof m.code === 'string') { clearTimeout(t); res(m.code); } };
      c.send({ t: 'takeover', state });
    });
    G.onReady = null;
    if (!code) continue; // that device did not manage: try the next player
    conns.forEach((o, j) => { if (o && j !== i) o.send({ t: 'moved', code }); });
    store.set(SAVE, '');
    return { code, name: cfg.players[i].name };
  }
  G.moving = false;
  if (!G.timer && G.tick) G.timer = setInterval(G.tick, 50); // nobody could take it: carry on hosting
  return null;
}
// Stop hosting and follow the game on its new host, as a player like any other.
function follow(to) {
  const conns = G.conns, room = G.room;
  G.conns = G.room = G.attach = G.sim = G.ais = G.tick = null;
  setTimeout(() => { if (conns) for (const c of conns) c && c.close(); if (room) room.close(); }, 1500); // let "moved" go out first
  L = { online: true, host: false, code: to.code, mode: 'ffa', level: G.cfg.level, you: -1, slots: [] };
  G.send = c => G.conn && G.conn.send({ t: 'cmd', c });
  G.lastSnap = performance.now();
  reconnect(to.name + ' is now the host. Joining…');
}
// This device has been asked to become the host.
async function takeover(st) {
  const me = st && Array.isArray(st.tokens) ? st.tokens.indexOf(TOKEN) : -1;
  if (me < 0 || !st.cfg || !st.sim || G.conns) return;
  let room = null, code = '';
  for (let n = 0; n < 3 && !room; n++) { code = makeCode(); try { room = await hostRoom(code); } catch { room = null; } }
  const old = G.conn;
  if (!room || !old) return; // the old host will ask someone else
  old.send({ t: 'ready', code });
  setTimeout(() => { old.onclose = null; old.ondata = null; old.close(); }, 1500);
  G.conn = null;
  if (G.rc) { clearTimeout(G.rc.wait); G.rc = null; }
  net('');
  const seen = G.view && G.view.seed === st.cfg.seed ? G.view.explored : null, cam = { ...R.cam }, sel = [...G.sel];
  G.room = room; room.onconn = onJoin; G.tokens = st.tokens;
  L = { online: true, host: true, code, mode: 'ffa', level: st.cfg.level, you: 0, slots: [] };
  store.set(SKEY, '');
  startGame(st.cfg, me, st.cfg.players.map(() => null), st);
  if (seen) { G.view.explored.set(seen); Object.assign(R.cam, cam); G.needCenter = false; for (const id of sel) G.sel.add(id); }
  toast('You are now the host: keep the game open');
}

// ---------------------------------------------------------------- the game behind the menus
// Four computers play each other on a random map, drawn with no fog; the camera drifts to wherever there is a fight.
// It is its own little game (its own Sim and View), so nothing about a real game depends on it.
let demo = null;
const calm = matchMedia('(prefers-reduced-motion: reduce)').matches;
function startDemo() {
  if (demo || G.view) return;
  try {
    const cfg = { seed: (Math.random() * 2 ** 31) | 0, size: MAP_SIZE, mode: 'ffa', map: MAPS[(Math.random() * MAPS.length) | 0].id,
      players: [0, 1, 2, 3].map(i => ({ name: 'Computer ' + (i + 1), ai: true, team: i, hero: HEROES[i % HEROES.length], color: [0, 1, 2, 4][i] })) };
    const sim = new Sim(cfg), view = new View(cfg, 0);
    view.spectating = () => true;
    demo = { sim, view, ais: cfg.players.map((_, i) => new AI(sim, i, 2)), acc: 0, hold: 0, focus: 0, x: 0, y: 0, placed: false };
    R.setView(view);
  } catch { demo = null; } // the menus work without it
}
function stopDemo() { demo = null; }
function demoFrame(dt) {
  const d = demo, s = d.sim;
  // The first game-minute and a half is skipped through quickly, so there are bases to look at straight away.
  let n = s.tick < 900 ? 24 : 0;
  if (!calm || s.tick < 900) { d.acc += dt * 15; while (d.acc >= 1) { d.acc--; n++; } }
  for (n = Math.min(n, 30); n > 0 && s.winner === -1; n--) { for (const a of d.ais) a.update(); s.step(); d.view.apply(s.snapshot()); }
  if (s.winner !== -1 || s.tick > 12000) { demo = null; startDemo(); return; }
  // Look at a fight if there is one, else at each base in turn; stay a while, then move on.
  let at = s.ents.get(d.focus);
  if (!at || (d.hold -= dt) <= 0) {
    const all = [...s.ents.values()], fights = all.filter(e => !e.b && e.order && e.order.k === 'attack' && !e.order.auto), keeps = all.filter(e => e.type === 'hq');
    const pool = fights.length ? fights : keeps.length ? keeps : all;
    at = pool[(Math.random() * pool.length) | 0];
    d.focus = at ? at.id : 0; d.hold = 12;
  }
  if (!at) return;
  const k = d.placed ? Math.min(1, dt * .7) : 1;
  d.x += (at.x - d.x) * k; d.y += (at.y - d.y) * k; d.placed = true;
  R.cam.z = Math.min(innerWidth, innerHeight) < 500 ? .7 : .95;
  R.center(d.x, d.y);
  R.draw(dt, { sel: NONE, box: null, ghost: null });
}
const NONE = new Set();

// ---------------------------------------------------------------- starting and ending a game
function startGame(cfg, me, conns, save) {
  G.view = new View(cfg, me);
  R.setView(G.view);
  R.cam.z = Math.min(innerWidth, innerHeight) < 500 ? .8 : 1;
  G.sel.clear(); G.placing = null; G.box = null; G.boxMode = false; G.amove = false; G.disband = 0; G.moving = false; G.cfg = cfg; G.ended = false; G.elim = false; G.lost = false; G.needCenter = true;
  G.record = G.record0 = +store.get(NKEY) || 0;
  G.lastSnap = performance.now();
  $('news').textContent = '';
  $('bBox').classList.remove('on');
  if (conns) {
    // This device is the host: it runs the simulation and sends everyone a snapshot each tick.
    const sim = G.sim = save ? Sim.restore(cfg, save.sim) : new Sim(cfg);
    // In a restored game a computer holds every other player's base until that player rejoins.
    const ais = G.ais = cfg.players.map((p, i) => p.ai ? new AI(sim, i, cfg.level) : save && i !== me && !p.horde && sim.players[i].alive ? new AI(sim, i, 1) : null);
    if (save) {
      (save.ais || []).forEach((a, i) => { if (a && ais[i]) Object.assign(ais[i], a); });
      for (const i of sim.gone) G.view.terrain[i] = 0;
    }
    const keep = () => {
      if (sim.winner !== -1 || G.lost) return store.set(SAVE, ''); // over, or over for the only person playing
      try {
        store.set(SAVE, JSON.stringify({ at: Date.now(), cfg, me, code: L && L.online ? L.code : '', tokens: G.tokens || [],
          ais: ais.map((a, i) => a && cfg.players[i].ai ? { att: a.att, wave: a.wave } : null), sim: sim.save() }));
      } catch { /* storage full or blocked: play on without saving */ }
    };
    G.conns = conns;
    const hook = (c, i) => {
      c.ondata = m => {
        if (m && m.t === 'cmd') { try { sim.command(i, m.c); } catch { /* ignore bad input */ } }
        else if (m && m.t === 'ready' && G.onReady) G.onReady(i, m);
      };
      c.onclose = () => {
        if (conns[i] !== c || G.moving) return; // while the game is being handed over, players leaving this host is expected
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
    G.tick = () => {
      const now = performance.now();
      acc += Math.min(500, now - last) * SPEED; last = now;
      for (let n = 0; acc >= 100 && !done; n++) {
        if (n >= 60) { acc = 0; break; }
        acc -= 100;
        for (const a of ais) a && a.update();
        sim.step();
        emit();
        done = sim.winner !== -1;
        if (done || sim.tick % 50 === 0) keep();
      }
    };
    G.timer = setInterval(G.tick, 50);
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
// stats: the lines of a run summary, as [label, value] pairs.
function endScreen(title, msg, stats) {
  G.ended = true;
  $('eTitle').textContent = title; $('eMsg').textContent = msg;
  $('eStats').hidden = !stats;
  $('eStats').innerHTML = (stats || []).map(([k, v]) => `<li><span>${esc(k)}</span><b>${esc(v)}</b></li>`).join('');
  show('end');
}
function quit() {
  store.set(SKEY, '');
  if (G.conns) store.set(SAVE, ''); // leaving on purpose ends the saved game
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
  const out = !G.view.pl[G.view.me].alive, others = G.conns && G.conns.some(c => c);
  $('askGive').hidden = out;
  $('askMsg').textContent = others ? 'Another player takes over as host.' : G.conn ? (out ? 'The others play on.' : 'A computer takes over your base.') : 'This game will be lost.';
  show('ask');
};
$('askNo').onclick = () => show(null);
$('askGive').onclick = () => { G.send({ t: 'giveup' }); show(null); };
$('askYes').onclick = async () => {
  if (G.conns && G.conns.some(c => c) && !G.ended) { // hosting for others: pass the game on before going
    show(null); net('Handing the game to another player…');
    const to = await handover();
    net('');
    if (to) { // let the news of the new host go out before hanging up
      const conns = G.conns, room = G.room;
      G.conns = G.room = null;
      setTimeout(() => { for (const c of conns) c && c.close(); if (room) room.close(); }, 1500);
    }
  }
  quit();
};

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
    if (x < 0 || y < 0 || x >= N || y >= N || v.terrain[y * N + x] !== 0 || !v.explored[y * N + x] || (v.deck && v.deck[y * N + x])) return false;
  }
  for (const e of ents().values()) if (e.b && tx < e.tx + e.size && tx + s > e.tx && ty < e.ty + e.size && ty + s > e.ty) return false;
  return !!DEF[type].anywhere || inRange(type, tx, ty);
}
// Everything but a Keep has to go up near one of my finished Keeps.
function inRange(type, tx, ty) {
  const s = DEF[type].size, cx = tx + s / 2, cy = ty + s / 2, me = G.view.me;
  for (const k of ents().values()) if (k.type === 'hq' && k.owner === me && k.built && Math.max(Math.abs(cx - k.x / T), Math.abs(cy - k.y / T)) <= BUILD_RANGE) return true;
  return false;
}
const ghostTile = (type, wx, wy) => { const s = DEF[type].size; return [Math.floor(wx / T - s / 2 + .5), Math.floor(wy / T - s / 2 + .5)]; };
function confirmPlace() {
  const p = G.placing;
  if (!p || !p.has) return;
  if (!canPlace(p.type, p.tx, p.ty)) { toast(!DEF[p.type].anywhere && !inRange(p.type, p.tx, p.ty) ? 'Too far from your Keep: build inside the dashed line' : "Can't build there"); return; }
  const ids = myUnits().filter(e => e.type === 'worker').map(e => e.id);
  if (ids.length) G.send({ t: 'build', ids, b: p.type, tx: p.tx, ty: p.ty });
  // Walls go down in runs: stay in placing mode until the player stops.
  if (DEF[p.type].wall) { p.has = false; if (G.touch) buzz(8); } else G.placing = null;
  hudT = 0;
}
function mark(x, y, col) { if (G.touch) buzz(8); G.view.fx.push({ k: 'm', a: ['m', x, y, col], t: 0 }); }

// What a tap (or right-click) on the world means for the units that are selected.
function order(wx, wy, ent) {
  const v = G.view, us = myUnits();
  if (!us.length) return;
  const ids = us.map(e => e.id), workers = us.filter(e => e.type === 'worker').map(e => e.id), rest = us.filter(e => e.type !== 'worker').map(e => e.id);
  if (ent && !v.friendly(ent)) { G.send({ t: 'attack', ids, target: ent.id }); mark(ent.rx, ent.ry, '#f87171'); return; }
  if (ent && ent.b && ent.built && ent.owner === v.me && ent.hp < ent.max && workers.length) { // mend it
    G.send({ t: 'repair', ids: workers, b: ent.id });
    if (rest.length) G.send({ t: 'move', ids: rest, x: wx, y: wy });
    mark(ent.rx, ent.ry, '#4ade80'); return;
  }
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
  G.send({ t: 'move', ids, x: wx, y: wy, a: G.amove ? 1 : 0 });
  mark(wx, wy, G.amove ? '#f87171' : '#4ade80');
  if (G.amove) { G.amove = false; hudT = 0; }
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
  // With workers selected, a tap on one of my buildings that needs them (unfinished or damaged) sends them to it.
  if (e && e.b && e.owner === G.view.me && (!e.built || e.hp < e.max) && myUnits().some(u => u.type === 'worker')) return order(wx, wy, e);
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
  if (k === 'b') $('bBuild').click();
  if (k === '.') $('bIdle').click();
});
addEventListener('keyup', e => keys.delete(e.key.toLowerCase()));
addEventListener('blur', () => keys.clear());
// An installed iPhone app whose page runs under the clock is laid out shorter than the screen, by the height of the
// clock bar, and the phone draws nothing in the band that leaves along the bottom: stretching the page into it only
// got the bottom of the controls cut off. So the page keeps the size it is given. An app added to the Home Screen
// from this version on starts below the clock and has no band; one added earlier keeps its old setting until it
// is added again, and the menu says so.
function fit() {
  if (!navigator.standalone) return;
  const pr = document.createElement('div');
  pr.style.cssText = 'position:fixed;top:0;bottom:0;left:0;width:0;visibility:hidden;padding-top:env(safe-area-inset-top)';
  document.body.appendChild(pr);
  const have = pr.getBoundingClientRect().height, wide = pr.parentElement.clientWidth || innerWidth, bar = parseFloat(getComputedStyle(pr).paddingTop) || 0;
  pr.remove();
  const full = have >= wide ? Math.max(screen.width, screen.height) : Math.min(screen.width, screen.height);
  if (bar > 0 && Math.abs(full - have - bar) < 12) {
    $('mIOS').textContent = 'There is an empty strip along the bottom. To get rid of it, remove Warcamp from your Home Screen and add it again from Safari.';
    $('mIOS').hidden = false;
  }
}
fit(); setTimeout(fit, 300); setTimeout(fit, 1500);
{ const ver = new URL(import.meta.url).searchParams.get('v'); $('mVer').textContent = 'Version ' + (ver ? ver.slice(0, 7) : 'dev'); $('mVer').hidden = false; }
// Tap the version on the menu to see how this device lays the page out: the numbers needed to chase a screen that
// sits too high, too low or too short in the installed app.
$('mVer').onclick = () => {
  const box = css => { const d = document.createElement('div'); d.style.cssText = 'position:fixed;visibility:hidden;' + css; document.body.appendChild(d); const r = d.getBoundingClientRect(), c = getComputedStyle(d); const o = { top: r.top, h: r.height, pt: c.paddingTop, pb: c.paddingBottom }; d.remove(); return o; };
  const fixed = box('top:0;bottom:0;left:0;width:0'), vh = box('top:0;left:0;width:0;height:100vh'), dvh = box('top:0;left:0;width:0;height:100dvh');
  const safe = box('top:0;left:0;padding-top:env(safe-area-inset-top);padding-bottom:env(safe-area-inset-bottom)'), vv = window.visualViewport, g = $('menu').getBoundingClientRect();
  const mode = ['fullscreen', 'standalone', 'browser'].find(m => matchMedia(`(display-mode: ${m})`).matches);
  $('mDiag').textContent = [
    `screen ${screen.width}x${screen.height}  window ${innerWidth}x${innerHeight}  page ${document.documentElement.clientWidth}x${document.documentElement.clientHeight}`,
    `fixed box top ${fixed.top} height ${fixed.h}  100vh ${vh.h}  100dvh ${dvh.h}`,
    `menu top ${g.top} height ${g.height}`,
    `view ${vv ? `${vv.width}x${vv.height} top ${vv.offsetTop} page ${vv.pageTop} zoom ${vv.scale}` : 'n/a'}  scroll ${scrollX},${scrollY}`,
    `safe top ${safe.pt} bottom ${safe.pb}  mode ${mode}  installed ${!!navigator.standalone}  ${innerHeight >= innerWidth ? 'portrait' : 'landscape'}`,
    navigator.userAgent.replace(/^.*?\((.*?)\).*$/, '$1'),
  ].join('\n');
  $('mDiag').hidden = false;
};
addEventListener('resize', () => { fit(); R.resize(); });
if (window.ResizeObserver) new ResizeObserver(() => { R.resize(); pads(); }).observe(cv); // the map area changes size with the dock
addEventListener('orientationchange', () => setTimeout(() => { fit(); R.resize(); }, 250));
if (window.visualViewport) visualViewport.addEventListener('resize', () => R.resize());
// iPhone: stop the page itself from zooming or bouncing under the game.
for (const t of ['gesturestart', 'gesturechange']) document.addEventListener(t, e => e.preventDefault());
document.addEventListener('touchmove', e => { if (G.view && !e.target.closest('#panel, .screen')) e.preventDefault(); }, { passive: false });
const buzz = ms => { if (navigator.vibrate) navigator.vibrate(ms); };

// ---------------------------------------------------------------- HUD buttons and the selection panel
$('bArmy').onclick = () => {
  G.sel.clear(); G.placing = null;
  for (const e of ents().values()) if (e.owner === G.view.me && DEF[e.type].mil) G.sel.add(e.id);
  if (!G.sel.size) toast(G.view.nomad ? 'Nobody is left in your party' : 'No army yet: train soldiers at a Barracks');
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
// Build: pick the workers nearest the middle of the screen (idle ones first) and show what they can build.
$('bBuild').onclick = () => {
  const v = G.view, c = R.cam, cx = c.x + R.w / c.z / 2, cy = c.y + R.h / c.z / 2;
  const ws = [...ents().values()].filter(e => e.owner === v.me && e.type === 'worker');
  if (!ws.length) { toast('No workers: train one at your Keep'); return; }
  const far = e => Math.hypot(e.x - cx, e.y - cy) - (e.idle ? 400 : 0);
  ws.sort((a, b) => far(a) - far(b));
  G.sel.clear(); G.placing = null;
  for (const w of ws.slice(0, 2)) G.sel.add(w.id);
  hudT = 0;
  toast('Pick a building, then tap where it goes');
};
$('bBox').onclick = () => { G.boxMode = !G.boxMode; $('bBox').classList.toggle('on', G.boxMode); if (G.boxMode) toast('Drag a box around your units'); };
$('bDesel').onclick = () => { G.sel.clear(); G.placing = null; hudT = 0; };

const price = d => (d.wood ? `<small class="w">▮ ${d.wood}</small>` : '') + (d.cost ? `<small>◆ ${d.cost}</small>` : '');
const pic = t => `<img src="${icon(t, G.view.info[G.view.me].color)}" alt="">`;
const btn = (act, d, off, t) => `<button data-act="${act}" class="ib"${off ? ' disabled' : ''}>${pic(t)}<span class="l">${d.name}<span>${price(d)}</span></span></button>`;
function panelHTML() {
  const v = G.view, me = v.me, P = v.pl[me];
  if (G.placing) {
    const p = G.placing;
    return `<div class="t">Place ${DEF[p.type].name}${DEF[p.type].wall ? ': keep tapping to build a run, then Done' : ''}</div><div class="d">${G.touch ? (p.has ? 'Tap the same spot again, or Build here.' : 'Tap where it should go.') : 'Click where it should go.'}</div>` +
      `<div class="acts">${p.has && G.touch ? '<button data-act="confirm">Build here</button>' : ''}<button data-act="cancel">${DEF[p.type].wall ? 'Done' : 'Cancel'}</button></div>`;
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
    if (b.hp < b.max) h += '<div class="acts"><button data-act="repair" class="go">Repair<small>send workers</small></button></div>';
    if (d.trains) {
      h += '<div class="acts">' + d.trains.map(u => btn('train:' + u, DEF[u], P.res < DEF[u].cost || P.pop >= P.cap || b.queue.length >= 5, u)).join('') + '</div>';
      if (b.queue.length) h += `<div class="d q">Training ${b.queue.map(i => pic(TYPES[i])).join('')}</div><div class="pb"><i id="pbar"></i></div>`;
      if (b.queue.length) h = h.replace('</div><div class="d q">Training', '<button data-act="unqueue" class="warn">Cancel last<small>refund</small></button></div><div class="d q">Training');
    }
    return h;
  }
  const count = {};
  for (const e of mine) count[e.type] = (count[e.type] || 0) + 1;
  const kinds = Object.keys(count), hero = mine.find(e => DEF[e.type].hero), fighters = mine.some(e => DEF[e.type].mil);
  let h;
  if (mine.length > 1 && kinds.length === 1) { // several of one kind: a single line is enough
    h = `<div class="t">${pic(kinds[0])}${mine.length} ${DEF[kinds[0]].name}s</div>`;
  } else if (mine.length === 1) {
    const e = mine[0], d = DEF[e.type];
    h = `<div class="t">${pic(e.type)}${d.name}${d.hero ? ` · Level ${P.lvl}` : ''}</div><div class="d">${d.info || d.about || ''}</div>`;
  } else {
    // One chip per kind of unit: tap a chip to keep only that kind selected.
    h = `<div class="chips"><span class="n">${mine.length} units</span>` +
      kinds.map(t => `<button data-act="only:${t}" class="chip${DEF[t].hero ? ' hero' : ''}">${pic(t)}${DEF[t].name}${count[t] > 1 ? `<b>${count[t]}</b>` : ''}</button>`).join('') + '</div>';
  }
  h += '<div class="bars"><div class="hpl"><span id="pd"></span><div class="pb hp"><i id="phb"></i></div></div>' +
    (hero ? `<div class="hpl"><span>${P.lvl >= 5 ? 'Top level' : 'Lv ' + P.lvl}</span><div class="pb xp"><i id="pxp"></i></div></div>` : '') + '</div>';
  h += '<div class="acts">';
  if (hero) h += DEF[hero.type].abs.map((ab, n) => P.lvl >= ab.lvl
    ? `<button data-act="ability:${n}" id="pab${n}" class="go spell" title="${ab.about}">${ab.name}<small>${ab.about}</small></button>`
    : `<button disabled class="spell">${ab.name}<small>unlocks at level ${ab.lvl}</small></button>`).join('');
  if (count.worker) {
    const has = t => [...ents().values()].some(e => e.owner === me && e.type === t && e.built);
    h += BUILDABLE.map(t => btn('build:' + t, t === 'hq' ? { ...DEF.hq, name: `Keep ×${P.keeps}` } : t === 'tower' ? { ...DEF.tower, name: 'Tower' } : DEF[t], P.res < DEF[t].cost || P.wood < (DEF[t].wood || 0) || (DEF[t].req && !has(DEF[t].req)) || (t === 'hq' && P.keeps < 1), t)).join('');
  }
  if (fighters) h += `<button data-act="amove" class="${G.amove ? 'on' : ''}">Attack-move<small>${G.amove ? 'now tap where to go' : 'fight on the way'}</small></button>`;
  h += '<button data-act="stop">Stop</button>';
  const n = mine.filter(e => !DEF[e.type].hero).length, armed = G.disband && performance.now() - G.disband < 4000;
  if (n) h += `<button data-act="disband" class="warn${armed ? ' on' : ''}">${armed ? 'Tap again' : 'Disband'}<small>${armed ? `to remove ${n} unit${n > 1 ? 's' : ''} for good` : 'remove for good'}</small></button>`;
  return h + '</div>';
}
// A line across the top of the screen for news that everyone should see.
function announce(text, color, note) {
  const row = document.createElement('div');
  row.innerHTML = `<i style="background:${color}"></i><b>${esc(text)}</b>${note ? `<span>${esc(note)}</span>` : ''}`;
  $('news').appendChild(row);
  buzz(30);
  setTimeout(() => row.classList.add('out'), 6000);
  setTimeout(() => row.remove(), 6600);
}
// Is this device's player the only person in the game (single player, however many computers)?
const solo = () => !!G.conns && !G.cfg.players.some((p, i) => i !== G.view.me && !p.ai && !p.horde);

// ---------------------------------------------------------------- Nomad: distance, alerts and the run summary
const TIPS = { res: $('res').title, wood: $('wood').title, pop: $('pop').title };
const NOMAD_TIPS = { res: 'How far your hero is from the start now, in tiles', wood: 'The furthest this run has got', pop: 'The furthest any run on this device has got' };
function nomadHud(v, nm) {
  const hero = [...ents().values()].find(e => e.owner === v.me && DEF[e.type].hero);
  const now = hero ? Math.floor(Math.hypot(hero.x / T - (nm.ox + .5), hero.y / T - (nm.oy + .5))) : 0;
  if (nm.best > G.record) { G.record = nm.best; store.set(NKEY, G.record); }
  $('res').textContent = '➤ Now ' + now;
  $('wood').textContent = 'Run ' + nm.best;
  $('pop').textContent = '★ Best ' + G.record;
  $('waveInfo').textContent = v.winner !== -1 ? '' : `Wave ${nm.wave} · ${nm.best >= nm.next ? 'the next is on its way' : `next at ${nm.next} tiles`} · camps ${nm.cleared}/${nm.camps}`;
  while (nm.news.length) {
    const [k, a, b] = nm.news.shift();
    if (k === 'w') announce('Wave ' + a, '#57534e', b ? 'A Warlord leads the hunt' : 'The Horde is on your trail');
    else if (k === 'a') announce(a === 2 ? "The Warlord's camp" : a === 1 ? 'A patrol has found you' : 'Ambush!', '#b91c1c', a === 2 ? 'Defeat it to complete the journey' : a === 1 ? '' : 'They were lying in wait');
    else if (k === 'c') announce('Camp cleared', v.info[a].color, (b ? `${b} recruit${b > 1 ? 's' : ''} join${b > 1 ? '' : 's'} ${a === v.me ? 'you' : v.info[a].name}` : 'No room for recruits') + ': tap Army to gather everyone');
  }
}
function nomadEnd(v, nm) {
  const secs = Math.floor(v.tick / 10), record = nm.best > G.record0;
  endScreen(nm.won ? 'Journey complete' : 'Party lost',
    nm.won ? `You crossed the whole land, ${nm.best} tiles from where you set out, and the Warlord at its end is beaten.` : `You got ${nm.best} tiles from where you set out. The far end of the land is ${nm.far} tiles away.`,
    [['Furthest this run', nm.best + ' tiles' + (record ? ' (a new best)' : '')], [record ? 'Best before' : 'Best on this device', Math.max(G.record0, record ? 0 : nm.best) + ' tiles'],
      ['Waves faced', nm.wave], ['Camps cleared', `${nm.cleared} of ${nm.camps}`], ['Enemies defeated', nm.kills], ['Time', `${Math.floor(secs / 60)}:${String(secs % 60).padStart(2, '0')}`]]);
}

let hudT = 0, lastPanel = null, lastAlert = 0;
function updateHud() {
  const v = G.view, P = v.pl[v.me], nm = v.nomad;
  if (nm) nomadHud(v, nm);
  else {
    $('res').textContent = '◆ ' + P.res;
    $('pop').textContent = `☗ ${P.pop}/${P.cap}`;
    $('wood').textContent = '▮ ' + P.wood;
  }
  for (const id of ['res', 'wood', 'pop']) $(id).title = (nm ? NOMAD_TIPS : TIPS)[id];
  $('bBuild').disabled = $('bIdle').disabled = !!nm; // a party has no workers
  $('heroInfo').textContent = P.heroT > 0 ? `${DEF[v.info[v.me].hero].name} returns in ${P.heroT}s` : P.alive ? `${DEF[v.info[v.me].hero].name} Lv ${P.lvl}` : '';
  $('heroInfo').classList.toggle('down', P.heroT > 0);
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
  pads();
  const sel = selected(), pd = $('pd'), pbar = $('pbar'), phb = $('phb'), pxp = $('pxp');
  if (pd && sel.length) {
    const e = sel[0];
    if (phb) { // one or many of my units: total health
      let hp = 0, max = 0;
      for (const u of sel) { hp += u.hp; max += u.max; }
      pd.textContent = `♥ ${hp}/${max}`;
      phb.style.width = Math.round(hp / max * 100) + '%';
      phb.style.background = hp / max > .5 ? '#4ade80' : hp / max > .25 ? '#fbbf24' : '#f87171';
    }
    else if (e.b && !e.built) pd.textContent = e.owner !== v.me ? `Under construction ${e.prog}%` : e.paused ? `Paused at ${e.prog}%: no worker is building it` : `Under construction ${e.prog}%`;
    else if (e.b && e.owner === v.me && DEF[e.type].trains && P.pop >= P.cap) pd.textContent = P.cap >= MAXCAP ? 'Unit limit reached.' : 'Unit limit reached: build a Cottage.';
    else pd.textContent = (e.b && e.owner === v.me && DEF[e.type].info ? DEF[e.type].info + '. ' : '') + `Health ${e.hp}/${e.max}`;
    if (pbar) pbar.style.width = (e.prog || 0) + '%';
  }
  if (pxp) pxp.style.width = P.xp + '%';
  const hero = sel.find(e => DEF[e.type].hero && e.owner === v.me);
  if (hero && hero.cds) DEF[hero.type].abs.forEach((ab, n) => {
    const b = $('pab' + n);
    if (!b) return;
    const cd = hero.cds[n];
    b.disabled = cd > 0;
    b.firstChild.textContent = cd > 0 ? `${ab.name} ${cd}s` : ab.name;
  });
  // Survival: the wave counter, and a call when a new wave walks in
  if (v.wave) {
    const [n, secs] = v.wave;
    $('waveInfo').textContent = `Wave ${n} · next in ${Math.floor(secs / 60)}:${String(secs % 60).padStart(2, '0')}`;
    if (v.waveNews) { announce('Wave ' + v.waveNews, '#57534e', v.waveNews % SURVIVAL.bossEvery === 0 ? 'A Warlord leads it' : 'The Horde is coming'); v.waveNews = 0; }
  } else if (!nm) $('waveInfo').textContent = '';
  // tell everyone when a player has been knocked out
  while (v.news.length) {
    const i = v.news.shift(), left = v.pl.filter(p => p.alive).length;
    if (i !== v.me) announce(`${v.info[i].name} has been wiped out`, v.info[i].color, v.winner === -1 && left > 1 ? `${left - (v.wave || nm ? 1 : 0)} players left` : '');
  }
  // alerts and the end of the game
  if (v.hurt && v.tick - v.hurt.tick < 5 && performance.now() - lastAlert > 12000) {
    const c = R.cam, h = v.hurt;
    if (h.x < c.x || h.y < c.y || h.x > c.x + R.w / c.z || h.y > c.y + R.h / c.z) { lastAlert = performance.now(); toast('You are under attack!'); }
  }
  if (v.winner !== -1 && !G.ended) {
    store.set(SKEY, '');
    const won = v.winner === v.team;
    if (nm) nomadEnd(v, nm);
    else if (v.wave) { // Survival has no victory: the score is how far you got
      const held = Math.max(0, v.wave[0] - 1), best = Math.max(held, +store.get('warcamp-best') || 0);
      store.set('warcamp-best', best);
      endScreen('Overrun', `You held out for ${held} wave${held === 1 ? '' : 's'}. Your best: ${best}.`);
    } else endScreen(won ? 'Victory' : 'Defeat', won ? 'Every enemy Keep, worker and hero is gone.' : v.winner === -2 ? 'Nobody is left standing.' : 'Your Keeps, workers and hero are all gone.');
  } else if (!P.alive && !G.elim && !G.ended) {
    G.elim = true;
    if (solo() && !v.pl.some((p, i) => p.alive && v.info[i].team === v.team)) {
      // Single player, and nobody is left on my side: the game is decided for the only person playing, so say so
      // now (not when the computers have finished with each other), and do not offer this game again from the menu.
      G.lost = true; store.set(SAVE, '');
      endScreen('Defeat', 'Your Keeps, workers and hero are all gone. The computers fight on: look around to watch.');
      return;
    }
    announce('You have been wiped out', v.info[v.me].color, 'You can keep watching');
    // A knocked-out host passes the game on straight away, so it no longer depends on their device.
    if (G.conns && G.conns.some(c => c)) handover().then(to => { if (to) follow(to); });
  }
}
$('panel').addEventListener('click', ev => {
  const b = ev.target.closest('button[data-act]');
  if (!b || b.disabled || !G.view) return;
  const [a, arg] = b.dataset.act.split(':'), me = G.view.me;
  if (a === 'build') G.placing = { type: arg, tx: 0, ty: 0, has: false };
  else if (a === 'cancel') G.placing = null;
  else if (a === 'confirm') confirmPlace();
  else if (a === 'repair') { const e = selected().find(e => e.b && e.owner === me); if (e) { G.send({ t: 'repair', b: e.id }); toast('Workers are on their way'); } }
  else if (a === 'resume' || a === 'cancelb' || a === 'unqueue') {
    const e = selected().find(e => e.b && e.owner === me);
    if (e) G.send({ t: a === 'cancelb' ? 'cancel' : a, b: e.id });
    if (a === 'resume') toast('Workers are on their way');
  }
  else if (a === 'train') { const e = selected().find(e => e.b && e.owner === me); if (e) G.send({ t: 'train', b: e.id, u: arg }); }
  else if (a === 'ability') { for (const e of myUnits()) if (DEF[e.type].hero) G.send({ t: 'ability', id: e.id, n: +arg }); }
  else if (a === 'stop') { G.send({ t: 'stop', ids: myUnits().map(e => e.id) }); G.amove = false; }
  else if (a === 'amove') G.amove = !G.amove;
  else if (a === 'disband') {
    if (G.disband && performance.now() - G.disband < 4000) { G.send({ t: 'disband', ids: myUnits().filter(e => !DEF[e.type].hero).map(e => e.id) }); G.disband = 0; }
    else { G.disband = performance.now(); setTimeout(() => { hudT = 0; }, 4100); }
  }
  else if (a === 'only') { for (const e of selected()) if (e.type !== arg) G.sel.delete(e.id); }
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
      // start on my Keep, or on my hero when there is none (Nomad)
      const mine = [...v.ents.values()].filter(e => e.owner === v.me), at = mine.find(e => e.type === 'hq') || mine.find(e => DEF[e.type].hero);
      if (at) { R.center(at.x, at.y); G.needCenter = false; }
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
  } else if (demo) {
    try { demoFrame(dt); } catch { demo = null; }
  }
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);

// ---------------------------------------------------------------- PWA: install and offline
let installEvt = null;
addEventListener('beforeinstallprompt', e => { e.preventDefault(); installEvt = e; $('mInstall').hidden = false; });
$('mInstall').onclick = async () => { if (!installEvt) return; installEvt.prompt(); await installEvt.userChoice; installEvt = null; $('mInstall').hidden = true; };
addEventListener('appinstalled', () => { $('mInstall').hidden = true; });
// Where multiplayer cannot work (an embedded preview with no peer connections), offer single player only.
if (window.WARCAMP_SOLO) { $('mHost').hidden = true; $('code').parentElement.hidden = true; }
if (iOS && !standalone && !window.WARCAMP_SOLO) $('mIOS').hidden = false;
show('menu');
