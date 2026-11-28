// What a screen knows (View, rebuilt from snapshots) and how it is drawn (Renderer).
// The host draws from snapshots too, so single player and multiplayer share every line here.
import { TILE as T, DEF, TYPES, COLORS, MAP_SIZE, heroMult, BUILD_RANGE } from './data.js';
import { makeMap } from './maps.js';

export class View {
  constructor(cfg, me) {
    this.N = cfg.size || MAP_SIZE;
    this.seed = cfg.seed;
    const m = makeMap(cfg), N = this.N;
    this.terrain = m.terrain; this.deck = m.deck || null; // deck: the tiles that are bridges
    this.wave = null; // Survival: [wave number, seconds to the next one]
    // Nomad: where the journey starts (ox, oy) and where the land ends (gx, gy), in tiles; the rest comes with each snapshot.
    this.nomad = cfg.mode !== 'nomad' ? null : { ox: m.base[0], oy: m.base[1], gx: N - 1 - m.base[0], gy: N - 1 - m.base[1],
      far: Math.floor(Math.hypot(N - 1 - 2 * m.base[0], N - 1 - 2 * m.base[1])), best: 0, wave: 0, next: 0, kills: 0, cleared: 0, camps: 0, won: 0, news: [] };
    this.info = cfg.players.map((p, i) => ({ name: p.name, team: p.team, color: p.tint || COLORS[p.color ?? i] || COLORS[i % COLORS.length], hero: p.hero || 'hero', horde: !!p.horde }));
    this.me = me; this.team = this.info[me].team;
    this.pl = this.info.map(() => ({ res: 0, pop: 0, cap: 0, alive: true, heroT: 0 }));
    this.ents = new Map(); this.fx = []; this.dirty = []; this.news = []; this.back = []; this.got = false; // news: who has just been knocked out; back: who has just been brought back
    this.tick = 0; this.winner = -1; this.hurt = null;
    this.explored = new Uint8Array(this.N * this.N);
    this.visible = new Uint8Array(this.N * this.N);
  }
  apply(s) {
    this.tick = s.k; this.winner = s.w;
    if (s.wv) { if (this.wave && s.wv[0] > this.wave[0]) this.waveNews = s.wv[0]; this.wave = s.wv; }
    if (s.nm && this.nomad) { const n = this.nomad; [n.best, n.wave, n.next, n.kills, n.cleared, n.camps] = s.nm; n.won = s.nm[7]; n.news.push(...s.nm[6]); }
    // who has just been knocked out (not on the first snapshot, which only says how things already stand)
    if (this.got) s.p.forEach((a, i) => { if (this.pl[i].alive && !a[3]) this.news.push(i); else if (!this.pl[i].alive && a[3]) this.back.push(i); });
    this.got = true;
    s.p.forEach((a, i) => { this.pl[i] = { res: a[0], pop: a[1], cap: a[2], alive: !!a[3], heroT: a[4], wood: a[5] || 0, lvl: a[6] || 1, xp: a[7] || 0, keeps: a[8] ?? 0 }; });
    for (const a of s.e) {
      const type = TYPES[a[1]], d = DEF[type];
      let e = this.ents.get(a[0]);
      if (!e) {
        e = { id: a[0], type, owner: a[2], rx: a[3], ry: a[4], b: !!d.b, size: d.size || 0, face: 1, hp: a[5] };
        if (d.b) { e.tx = Math.round(a[3] / T - d.size / 2); e.ty = Math.round(a[4] / T - d.size / 2); }
        this.ents.set(e.id, e);
      }
      if (a[5] < e.hp && e.owner === this.me) this.hurt = { x: a[3], y: a[4], tick: s.k };
      if (a[5] < e.hp) e.hurtT = performance.now();
      e.x = a[3]; e.y = a[4]; e.hp = a[5]; e.stamp = s.k;
      if (d.b) { e.built = !!a[6]; e.prog = a[7]; e.queue = a[8]; e.paused = !!a[9]; e.rally = a[10] || null; e.fast = !!a[11]; }
      else { e.carry = a[6]; e.cds = a[7] || null; e.idle = a[8]; e.buff = a[9] || 0; }
      e.max = Math.round(d.hp * (d.hero ? heroMult(this.pl[e.owner].lvl) : 1) * (!d.b && a[10] ? a[10] / 100 : 1));
    }
    for (const [id, e] of this.ents) if (e.stamp !== s.k) this.ents.delete(id);
    for (const i of s.rm) { this.terrain[i] = 0; this.dirty.push(i); }
    for (const f of s.fx) { if (f[0] === 'n' && this.fx.length > 140) continue; this.fx.push({ k: f[0], a: f, t: 0, ox: f[0] === 'n' ? ((this.fx.length * 7) % 15) - 7 : 0 }); }
  }
  friendly(e) { return this.info[e.owner].team === this.team; }
  spectating() { return this.winner !== -1 || !this.pl[this.me].alive; }
  // Fog of war: what my team can see right now, and everything it has ever seen.
  updateFog() {
    const N = this.N, vis = this.visible;
    if (this.spectating()) { vis.fill(1); this.explored.fill(1); return; }
    vis.fill(0);
    for (const e of this.ents.values()) {
      if (!this.friendly(e)) continue;
      const r = DEF[e.type].sight + (e.size || 0) / 2, cx = e.x / T, cy = e.y / T;
      const x0 = Math.max(0, Math.floor(cx - r)), x1 = Math.min(N - 1, Math.ceil(cx + r));
      const y0 = Math.max(0, Math.floor(cy - r)), y1 = Math.min(N - 1, Math.ceil(cy + r));
      for (let y = y0; y <= y1; y++) for (let x = x0; x <= x1; x++) {
        if ((x + .5 - cx) ** 2 + (y + .5 - cy) ** 2 <= r * r) { vis[y * N + x] = 1; this.explored[y * N + x] = 1; }
      }
    }
  }
  canSee(e) {
    if (this.friendly(e)) return true;
    const N = this.N;
    return !!this.visible[Math.min(N - 1, (e.y / T) | 0) * N + Math.min(N - 1, (e.x / T) | 0)];
  }
}

function rr(g, x, y, w, h, r) {
  g.beginPath();
  g.moveTo(x + r, y); g.arcTo(x + w, y, x + w, y + h, r); g.arcTo(x + w, y + h, x, y + h, r);
  g.arcTo(x, y + h, x, y, r); g.arcTo(x, y, x + w, y, r); g.closePath();
}
const line = (g, x1, y1, x2, y2) => { g.beginPath(); g.moveTo(x1, y1); g.lineTo(x2, y2); g.stroke(); };

function drawUnit(g, e, col) {
  const t = e.type, isHero = !!DEF[t].hero, boss = t === 'boss', big = isHero || t === 'knight', s = boss ? 1.9 : big ? 1.2 : 1;
  if (boss) col = '#3f3a45';
  g.save();
  g.translate(e.rx, e.ry);
  if (e.buff & 6) { // Battle Cry glows red, Ward glows blue
    g.strokeStyle = e.buff & 2 ? 'rgba(248,113,113,.9)' : 'rgba(147,197,253,.9)'; g.lineWidth = 1.6;
    g.beginPath(); g.ellipse(0, 6, 12 * s, 6.5 * s, 0, 0, 7); g.stroke();
  }
  if (t === 'catapult') { drawCatapult(g, e, col); g.restore(); return; }
  g.fillStyle = 'rgba(0,0,0,.28)';
  g.beginPath(); g.ellipse(0, 7 * s, 8 * s, 3.5 * s, 0, 0, 7); g.fill();
  g.translate(0, -(e.bob || 0)); // a little hop with each step
  g.scale(e.face < 0 ? -s : s, s);
  g.lineWidth = 1.1; g.strokeStyle = 'rgba(20,16,12,.8)'; g.lineCap = 'round'; g.lineJoin = 'round';
  let by = -4;
  if (t === 'knight') {
    by = -10;
    g.fillStyle = '#7a5230';
    rr(g, -9, -3, 18, 9, 3); g.fill(); g.stroke();
    g.fillRect(-7, 5, 3, 4); g.fillRect(4, 5, 3, 4);
    rr(g, 7, -8, 5, 8, 2); g.fill(); g.stroke();
  } else {
    g.fillStyle = '#33343c';
    g.fillRect(-4, by + 8, 3, 4); g.fillRect(1, by + 8, 3, 4);
  }
  if (isHero) { g.fillStyle = t === 'ranger' ? '#14532d' : t === 'sage' ? '#e2e8f0' : '#7c2d12'; rr(g, -7, by + 1, 6, 11, 2); g.fill(); }
  g.fillStyle = col;
  rr(g, -5, by, 10, 9, 2); g.fill(); g.stroke();
  g.fillStyle = t === 'soldier' || t === 'knight' ? '#b4bac4' : '#f1cf9d';
  g.beginPath(); g.arc(0, by - 4, 4.4, 0, 7); g.fill(); g.stroke();
  g.fillStyle = 'rgba(255,255,255,.22)'; g.fillRect(-4, by + 1, 3, 6); // light on the tunic
  g.fillStyle = '#1f1a14'; g.fillRect(1, by - 5, 1.3, 1.6); g.fillRect(3.2, by - 5, 1.1, 1.6); // eyes, looking the way it walks
  g.lineWidth = 1.6;
  if (t === 'worker') {
    g.fillStyle = '#8b5a2b'; g.beginPath(); g.arc(0, by - 5, 4.4, Math.PI, 0); g.fill();
    g.strokeStyle = '#5b3a1c'; line(g, 5, by + 7, 9, by - 3);
    g.strokeStyle = '#cfd3da'; line(g, 6, by - 4, 12, by - 2);
    if (e.carry) { g.fillStyle = e.carry === 2 ? '#a16207' : '#7dd3fc'; g.strokeStyle = 'rgba(0,0,0,.55)'; g.lineWidth = 1; rr(g, -10, by + 1, 6, 6, 1.5); g.fill(); g.stroke(); }
  } else if (t === 'soldier') {
    g.strokeStyle = '#eef0f4'; line(g, 6, by + 6, 10, by - 6);
    g.fillStyle = '#f8fafc'; g.strokeStyle = 'rgba(0,0,0,.55)'; g.lineWidth = 1;
    g.beginPath(); g.arc(-6, by + 5, 3.6, 0, 7); g.fill(); g.stroke();
  } else if (t === 'archer') {
    g.fillStyle = '#2f6b3a'; g.beginPath(); g.arc(0, by - 5, 4.6, Math.PI * .9, Math.PI * .1); g.fill();
    g.strokeStyle = '#6b4423'; g.beginPath(); g.arc(4, by + 3, 7, -1.1, 1.1); g.stroke();
    g.strokeStyle = '#e5e7eb'; g.lineWidth = .8; line(g, 7.2, by - 3.2, 7.2, by + 9.2);
  } else if (t === 'knight') {
    g.strokeStyle = '#e5e7eb'; line(g, 3, by + 6, 15, by - 8);
  } else if (boss) { // horns, burning eyes and a great axe
    g.fillStyle = '#e7e5e4'; g.strokeStyle = 'rgba(20,16,12,.8)'; g.lineWidth = .8;
    for (const sx of [-1, 1]) { g.beginPath(); g.moveTo(sx * 3, by - 7); g.quadraticCurveTo(sx * 8, by - 9, sx * 7, by - 13); g.quadraticCurveTo(sx * 5, by - 9, sx * 2, by - 8.5); g.closePath(); g.fill(); g.stroke(); }
    g.fillStyle = '#ef4444'; g.fillRect(.6, by - 5.2, 1.8, 1.6); g.fillRect(3, by - 5.2, 1.5, 1.6);
    g.strokeStyle = '#57534e'; g.lineWidth = 1.6; line(g, 7, by + 9, 9, by - 9);
    g.fillStyle = '#d6d3d1'; g.strokeStyle = 'rgba(20,16,12,.8)'; g.lineWidth = .8; g.beginPath(); g.moveTo(9, by - 9); g.quadraticCurveTo(16, by - 10, 14, by - 2); g.lineTo(8.6, by - 4); g.closePath(); g.fill(); g.stroke();
    g.fillStyle = '#7f1d1d'; g.fillRect(-5, by + 4, 10, 1.6);
  } else if (t === 'guard') { // tall shield, short blade
    g.fillStyle = '#cbd5e1'; g.strokeStyle = 'rgba(0,0,0,.55)'; g.lineWidth = 1;
    rr(g, -11, by - 2, 8, 13, 2.5); g.fill(); g.stroke();
    g.fillStyle = col; g.fillRect(-8.5, by + 2, 3, 5);
    g.strokeStyle = '#eef0f4'; g.lineWidth = 1.8; line(g, 6, by + 6, 8, by - 2);
  } else if (t === 'mage') { // pointed hat and a staff
    g.fillStyle = '#6d28d9'; g.beginPath(); g.moveTo(-5.5, by - 5); g.lineTo(0, by - 15); g.lineTo(5.5, by - 5); g.closePath(); g.fill();
    g.strokeStyle = '#854d0e'; g.lineWidth = 1.6; line(g, 8, by + 9, 8, by - 8);
    g.fillStyle = '#c4b5fd'; g.beginPath(); g.arc(8, by - 9.5, 2.8, 0, 7); g.fill();
  } else if (t === 'cleric') { // white hood and a green cross
    g.fillStyle = '#f1f5f9'; g.beginPath(); g.arc(0, by - 5, 4.8, Math.PI * .95, Math.PI * .05); g.fill();
    g.fillStyle = '#16a34a'; g.fillRect(-1.2, by + 1.5, 2.4, 6.5); g.fillRect(-3.2, by + 3.5, 6.4, 2.4);
  } else if (isHero) {
    g.fillStyle = '#fbbf24';
    g.beginPath(); g.moveTo(-4.5, by - 6); g.lineTo(-4.5, by - 11); g.lineTo(-2, by - 8); g.lineTo(0, by - 12); g.lineTo(2, by - 8);
    g.lineTo(4.5, by - 11); g.lineTo(4.5, by - 6); g.closePath(); g.fill();
    if (t === 'ranger') { // long bow
      g.strokeStyle = '#854d0e'; g.lineWidth = 1.8; g.beginPath(); g.arc(5, by + 2, 9, -1.15, 1.15); g.stroke();
      g.strokeStyle = '#fde68a'; g.lineWidth = .9; line(g, 8.7, by - 6.2, 8.7, by + 10.2);
    } else if (t === 'sage') { // staff with a glowing tip
      g.strokeStyle = '#854d0e'; g.lineWidth = 1.8; line(g, 8, by + 9, 8, by - 9);
      g.fillStyle = '#86efac'; g.beginPath(); g.arc(8, by - 10, 3, 0, 7); g.fill();
    } else { g.strokeStyle = '#fde68a'; g.lineWidth = 2.2; line(g, 6, by + 7, 11, by - 8); }
  }
  if (e.buff & 1) { // speed lines
    g.strokeStyle = 'rgba(253,224,71,.9)'; g.lineWidth = 1.2;
    line(g, -13, by + 2, -8, by + 2); line(g, -14, by + 6, -9, by + 6);
  }
  g.restore();
}

function drawCatapult(g, e, col) {
  g.scale(e.face < 0 ? -1 : 1, 1);
  g.fillStyle = 'rgba(0,0,0,.28)'; g.beginPath(); g.ellipse(0, 9, 14, 4.5, 0, 0, 7); g.fill();
  g.strokeStyle = 'rgba(0,0,0,.55)'; g.lineWidth = 1; g.lineCap = 'round';
  g.fillStyle = '#8b5a2b'; rr(g, -12, 0, 24, 7, 2); g.fill(); g.stroke();
  g.fillStyle = col; g.fillRect(-9, 2, 18, 3);
  g.fillStyle = '#3f3f46'; for (const x of [-8, 8]) { g.beginPath(); g.arc(x, 8, 3.6, 0, 7); g.fill(); g.stroke(); }
  g.strokeStyle = '#6b4423'; g.lineWidth = 3; line(g, -6, 2, 9, -13);
  g.fillStyle = '#9ca3af'; g.strokeStyle = 'rgba(0,0,0,.55)'; g.lineWidth = 1; g.beginPath(); g.arc(10, -14, 3.6, 0, 7); g.fill(); g.stroke();
}

// Shade a #rrggbb colour: f < 1 darker, f > 1 lighter.
const shadeCache = new Map();
function shade(col, f) {
  const key = col + f;
  let v = shadeCache.get(key);
  if (!v) {
    const n = parseInt(col.slice(1), 16), ch = s => Math.max(0, Math.min(255, Math.round(((n >> s) & 255) * f)));
    v = `rgb(${ch(16)},${ch(8)},${ch(0)})`;
    shadeCache.set(key, v);
  }
  return v;
}
// A box seen from above and slightly in front: a top face, and a darker front face below it.
function block(g, x, y, w, h, d, top, front, r = 3) {
  g.fillStyle = front; rr(g, x, y + d, w, h, r); g.fill(); g.stroke();
  g.fillStyle = top; rr(g, x, y, w, h, r); g.fill(); g.stroke();
}
const STONE = '#d8cfbc', STONE_D = '#978d7b', INK = '#4a4336';

function drawBuilding(g, e, col) {
  const x = e.tx * T, y = e.ty * T, w = e.size * T, cx = x + w / 2, cy = y + w / 2, t = e.type;
  const dark = shade(col, .68), light = shade(col, 1.22);
  g.save();
  if (!e.built) g.globalAlpha = .6;
  g.lineWidth = 1.4; g.strokeStyle = INK; g.lineJoin = 'round'; g.lineCap = 'round';
  g.fillStyle = 'rgba(0,0,0,.16)'; g.beginPath(); g.ellipse(cx + 2, y + w - 8, w / 2 - 4, w / 5, 0, 0, 7); g.fill(); // shadow on the ground
  if (t === 'hq') { // a walled keep: four round towers, a hall with a pitched roof, a gate and a flag
    block(g, x + 8, y + 10, w - 16, w - 26, 9, STONE, STONE_D);
    g.fillStyle = '#b3a892'; rr(g, x + 15, y + 17, w - 30, w - 40, 2); g.fill();
    g.fillStyle = '#3b2f22'; rr(g, cx - 7, y + w - 17, 14, 11, 3); g.fill(); g.stroke(); // gate
    block(g, cx - 19, cy - 22, 38, 26, 6, col, dark);
    g.fillStyle = light; g.beginPath(); g.moveTo(cx - 19, cy - 22); g.lineTo(cx + 19, cy - 22); g.lineTo(cx + 12, cy - 9); g.lineTo(cx - 12, cy - 9); g.closePath(); g.fill();
    g.strokeStyle = 'rgba(0,0,0,.35)'; line(g, cx - 12, cy - 9, cx + 12, cy - 9); g.strokeStyle = INK;
    for (const [tx, ty] of [[x + 12, y + 13], [x + w - 12, y + 13], [x + 12, y + w - 20], [x + w - 12, y + w - 20]]) {
      g.fillStyle = STONE_D; g.beginPath(); g.ellipse(tx, ty + 6, 10, 8, 0, 0, 7); g.fill(); g.stroke();
      g.fillStyle = STONE; g.beginPath(); g.arc(tx, ty, 10, 0, 7); g.fill(); g.stroke();
      g.fillStyle = col; g.beginPath(); g.arc(tx, ty, 5.5, 0, 7); g.fill(); g.stroke();
    }
    g.strokeStyle = INK; g.lineWidth = 1.6; line(g, cx, cy - 12, cx, cy - 36);
    g.fillStyle = '#fde68a'; g.beginPath(); g.moveTo(cx, cy - 36); g.lineTo(cx + 13, cy - 32); g.lineTo(cx, cy - 27); g.closePath(); g.fill(); g.stroke();
  } else if (t === 'house') { // a cottage: cream walls, a two-sided roof, a chimney and a door
    block(g, x + 9, y + 20, w - 18, w - 36, 8, '#f1e6cf', '#c9b994');
    g.fillStyle = '#6b4423'; rr(g, cx - 4, y + w - 17, 8, 9, 2); g.fill(); g.stroke();
    g.fillStyle = dark; g.beginPath(); g.moveTo(x + 5, y + 30); g.lineTo(cx, y + 8); g.lineTo(x + w - 5, y + 30); g.lineTo(x + w - 5, y + 36); g.lineTo(x + 5, y + 36); g.closePath(); g.fill(); g.stroke();
    g.fillStyle = col; g.beginPath(); g.moveTo(x + 5, y + 30); g.lineTo(cx, y + 8); g.lineTo(cx, y + 36); g.lineTo(x + 5, y + 36); g.closePath(); g.fill(); g.stroke();
    g.fillStyle = '#8a8f98'; rr(g, x + w - 22, y + 9, 8, 12, 1.5); g.fill(); g.stroke();
  } else if (t === 'barracks') { // a long hall with a planked roof, shields on the front and banners
    block(g, x + 6, y + 22, w - 12, w - 38, 9, STONE, STONE_D);
    g.fillStyle = col; rr(g, x + 4, y + 8, w - 8, 26, 4); g.fill(); g.stroke();
    g.fillStyle = light; rr(g, x + 4, y + 8, w - 8, 9, 4); g.fill();
    g.strokeStyle = 'rgba(0,0,0,.28)'; g.lineWidth = 1; for (let i = 1; i < 5; i++) line(g, x + 4 + i * (w - 8) / 5, y + 9, x + 4 + i * (w - 8) / 5, y + 33);
    g.strokeStyle = INK; g.lineWidth = 1.4; rr(g, x + 4, y + 8, w - 8, 26, 4); g.stroke();
    for (const sx of [cx - 13, cx + 13]) { g.fillStyle = '#f8fafc'; g.beginPath(); g.arc(sx, y + w - 18, 6, 0, 7); g.fill(); g.stroke(); g.fillStyle = col; g.fillRect(sx - 1.5, y + w - 23, 3, 10); g.fillRect(sx - 5, y + w - 19.5, 10, 3); }
    g.fillStyle = '#3b2f22'; rr(g, cx - 5, y + w - 20, 10, 12, 2); g.fill(); g.stroke();
  } else if (t === 'workshop') { // the Arsenal: a round slate forge with a cog, a chimney and a glowing crystal
    g.fillStyle = STONE_D; g.beginPath(); g.ellipse(cx, cy + 9, 25, 21, 0, 0, 7); g.fill(); g.stroke();
    g.fillStyle = '#64748b'; g.beginPath(); g.arc(cx, cy, 25, 0, 7); g.fill(); g.stroke();
    g.fillStyle = '#475569'; g.beginPath(); g.arc(cx, cy, 18, 0, 7); g.fill();
    g.strokeStyle = col; g.lineWidth = 3.5; g.beginPath(); g.arc(cx, cy, 21.5, 0, 7); g.stroke();
    g.strokeStyle = INK; g.lineWidth = 1.2; g.fillStyle = '#e2e8f0';
    for (let i = 0; i < 8; i++) { const a = i * Math.PI / 4; g.fillRect(cx + Math.cos(a) * 10 - 2.5, cy + Math.sin(a) * 10 - 2.5, 5, 5); }
    g.beginPath(); g.arc(cx, cy, 9, 0, 7); g.fill(); g.stroke();
    g.fillStyle = '#a78bfa'; g.beginPath(); g.arc(cx, cy, 4, 0, 7); g.fill(); g.stroke();
    g.fillStyle = '#334155'; rr(g, x + w - 18, y + 4, 10, 15, 2); g.fill(); g.stroke();
    g.fillStyle = '#fb923c'; rr(g, x + w - 16, y + 6, 6, 4, 1); g.fill();
  } else if (t === 'outpost') { // an open depot: a plank floor, a striped awning, crates, logs and crystal
    block(g, x + 6, y + 14, w - 12, w - 26, 6, '#b88a55', '#8a6238');
    g.strokeStyle = 'rgba(0,0,0,.22)'; g.lineWidth = 1; for (let i = 1; i < 4; i++) line(g, x + 7, y + 14 + i * (w - 26) / 4, x + w - 7, y + 14 + i * (w - 26) / 4);
    g.strokeStyle = INK; g.lineWidth = 1.4;
    for (let i = 0; i < 6; i++) { g.fillStyle = i % 2 ? '#f8fafc' : col; g.fillRect(x + 6 + i * (w - 12) / 6, y + 7, (w - 12) / 6 + .5, 13); }
    rr(g, x + 6, y + 7, w - 12, 13, 2); g.stroke();
    g.fillStyle = '#d6a45f'; rr(g, x + 11, y + 27, 12, 12, 1.5); g.fill(); g.stroke(); line(g, x + 11, y + 27, x + 23, y + 39); line(g, x + 23, y + 27, x + 11, y + 39);
    g.fillStyle = '#7dd3fc'; g.beginPath(); g.moveTo(cx + 6, y + 40); g.lineTo(cx + 11, y + 25); g.lineTo(cx + 16, y + 33); g.lineTo(cx + 20, y + 27); g.lineTo(cx + 23, y + 40); g.closePath(); g.fill(); g.stroke();
    g.fillStyle = '#a16207'; for (const lx of [x + 13, x + 20]) { g.beginPath(); g.arc(lx, y + 46, 3.4, 0, 7); g.fill(); g.stroke(); }
  } else if (t === 'tower') { // a round stone tower with battlements and a pointed roof
    g.fillStyle = STONE_D; g.beginPath(); g.ellipse(cx, cy + 6, 12, 10, 0, 0, 7); g.fill(); g.stroke();
    g.fillStyle = STONE; g.beginPath(); g.arc(cx, cy - 1, 12, 0, 7); g.fill(); g.stroke();
    g.fillStyle = '#f8fafc'; for (let i = 0; i < 6; i++) { const a = i * Math.PI / 3; g.fillRect(cx + Math.cos(a) * 10.5 - 2, cy - 1 + Math.sin(a) * 10.5 - 2, 4, 4); }
    g.fillStyle = dark; g.beginPath(); g.arc(cx, cy - 1, 7.5, 0, 7); g.fill(); g.stroke();
    g.fillStyle = col; g.beginPath(); g.moveTo(cx - 7.5, cy - 1); g.lineTo(cx, cy - 13); g.lineTo(cx + 7.5, cy - 1); g.closePath(); g.fill(); g.stroke();
  } else if (t === 'wall') { // a stone block with a stripe of the owner's colour
    block(g, x + 1, y + 2, w - 2, w - 9, 6, '#a8b0ba', '#767e88');
    g.strokeStyle = 'rgba(0,0,0,.25)'; g.lineWidth = 1; line(g, x + 2, y + 12, x + w - 2, y + 12); line(g, cx, y + 3, cx, y + 12); line(g, x + 9, y + 12, x + 9, y + w - 8); line(g, x + 23, y + 12, x + 23, y + w - 8);
    g.fillStyle = col; g.fillRect(x + 4, y + 4, w - 8, 3.5);
  } else { // buildings from older saves: a plain hall
    block(g, x + 6, y + 10, w - 12, w - 24, 8, col, dark);
    g.strokeStyle = 'rgba(255,255,255,.8)'; g.lineWidth = 3; line(g, cx - 9, cy - 12, cx + 9, cy + 4); line(g, cx + 9, cy - 12, cx - 9, cy + 4);
  }
  g.restore();
  if (!e.built) bar(g, cx, y + w - 7, w - 12, e.prog / 100, '#fbbf24');
}
// Smoke from a damaged building, fire from a badly damaged one.
function wounds(g, e, now) {
  const f = e.hp / e.max;
  if (f >= .6 || !e.built) return;
  const w = e.size * T, x = e.tx * T, y = e.ty * T, n = e.size + (f < .3 ? 1 : 0);
  for (let i = 0; i < n; i++) {
    const seed = e.id * 7 + i * 13, px = x + 8 + (seed * 17 % (w - 16)), py = y + 8 + (seed * 29 % (w - 22));
    const ph = (now * .9 + seed * .37) % 1;
    g.fillStyle = `rgba(70,70,78,${.5 * (1 - ph)})`;
    g.beginPath(); g.arc(px + Math.sin(ph * 4 + seed) * 3, py - ph * 22, 3 + ph * 6, 0, 7); g.fill();
    if (f < .3) {
      const fl = 5 + Math.sin(now * 14 + seed) * 1.6;
      g.fillStyle = '#f97316'; g.beginPath(); g.moveTo(px - 4, py + 3); g.quadraticCurveTo(px - 5, py - fl, px, py - fl - 5); g.quadraticCurveTo(px + 5, py - fl, px + 4, py + 3); g.closePath(); g.fill();
      g.fillStyle = '#fde047'; g.beginPath(); g.moveTo(px - 2, py + 3); g.quadraticCurveTo(px - 2.5, py - fl * .5, px, py - fl * .7); g.quadraticCurveTo(px + 2.5, py - fl * .5, px + 2, py + 3); g.closePath(); g.fill();
    }
  }
}
// How far something can shoot: a dashed ring.
function reach(g, x, y, radius, z) {
  g.save();
  g.fillStyle = 'rgba(248,113,113,.07)'; g.strokeStyle = 'rgba(252,165,165,.9)'; g.lineWidth = 2 / z; g.setLineDash([9 / z, 6 / z]);
  g.beginPath(); g.arc(x, y, radius, 0, 7); g.fill(); g.stroke();
  g.restore();
}
function bar(g, cx, y, w, f, col) {
  g.fillStyle = 'rgba(0,0,0,.65)'; g.fillRect(cx - w / 2 - 1, y - 1, w + 2, 5);
  g.fillStyle = col; g.fillRect(cx - w / 2, y, Math.max(0, w * Math.min(1, f)), 3);
}

// A small picture of a unit or building in a player's colour, for buttons and chips.
const icons = new Map();
export function icon(type, color) {
  const key = type + color;
  if (icons.has(key)) return icons.get(key);
  const c = document.createElement('canvas'), d = DEF[type];
  c.width = c.height = 72;
  const g = c.getContext('2d');
  if (d.b) {
    const k = 60 / (d.size * T);
    g.translate(6, 6); g.scale(k, k);
    drawBuilding(g, { type, tx: 0, ty: 0, size: d.size, built: true, prog: 100 }, color);
  } else {
    g.translate(36, type === 'knight' || type === 'catapult' ? 46 : 42); g.scale(2.3, 2.3);
    drawUnit(g, { type, rx: 0, ry: 0, face: 1, buff: 0, carry: 0 }, color);
  }
  const url = c.toDataURL();
  icons.set(key, url);
  return url;
}

const MINI = ['#5f9e45', '#3d86c6', '#2f6b3a', '#7dd3fc'];

const AT = 3; // how much larger than a tile the ground pictures are painted
export class Renderer {
  constructor(canvas, mini) {
    this.cv = canvas; this.g = canvas.getContext('2d');
    this.mini = mini; this.mg = mini.getContext('2d');
    this.cam = { x: 0, y: 0, z: 1 };
    this.view = null; this.fogT = 0; this.miniT = 0;
    this.resize();
  }
  resize() {
    const d = this.dpr = Math.min(window.devicePixelRatio || 1, 3);
    this.w = this.cv.clientWidth; this.h = this.cv.clientHeight;
    this.cv.width = Math.round(this.w * d); this.cv.height = Math.round(this.h * d);
  }
  setView(v) {
    this.view = v;
    const N = v.N, c = this.atlas = document.createElement('canvas');
    // Painted at three times its size so the ground stays sharp on a phone screen; 64 variants in an 8 by 8 sheet.
    c.width = c.height = 8 * T * AT;
    const ag = c.getContext('2d');
    for (let n = 0; n < 64; n++) { ag.setTransform(AT, 0, 0, AT, (n & 7) * T * AT, (n >> 3) * T * AT); this.paint(ag, 0, 0, n >> 4, (n >> 3) & 1, n & 7); }
    this.mc = document.createElement('canvas'); this.mc.width = this.mc.height = N;
    this.mimg = this.mc.getContext('2d').createImageData(N, N);
    v.updateFog();
  }
  // One tile of ground. The map is drawn from a small sheet of these every frame, so its size costs no memory.
  paint(g, x, y, t, chk, h) {
    // h is the variant, 0 to 7. Most grass is plain; a few variants carry a tuft, flowers or a stone.
    const k = h & 7, v = k & 3, circle = (cx, cy, rad) => { g.beginPath(); g.arc(x + cx, y + cy, rad, 0, 7); g.fill(); };
    // grass, with a soft light and dark patch so the ground is not flat
    g.fillStyle = chk ? '#6bab4d' : '#67a549'; g.fillRect(x, y, T, T);
    if (k === 1) { g.fillStyle = 'rgba(255,255,255,.05)'; g.beginPath(); g.ellipse(x + 12, y + 12, 10, 7, .4, 0, 7); g.fill(); }
    if (k === 6) { g.fillStyle = 'rgba(0,0,0,.045)'; g.beginPath(); g.ellipse(x + 19, y + 20, 10, 7, -.3, 0, 7); g.fill(); }
    if (t === 0) {
      g.strokeStyle = '#4f8a3a'; g.lineWidth = 1.2; g.lineCap = 'round';
      const tuft = (cx, cy) => { line(g, x + cx, y + cy, x + cx - 2, y + cy - 4); line(g, x + cx, y + cy, x + cx, y + cy - 5); line(g, x + cx, y + cy, x + cx + 2, y + cy - 4); };
      if (k === 3) tuft(9, 22);
      else if (k === 5) { tuft(22, 12); tuft(8, 27); }
      else if (k === 4) { g.fillStyle = '#fef9c3'; circle(21, 21, 1.6); circle(24, 19, 1.3); g.fillStyle = '#fbbf24'; circle(22.5, 20, .8); tuft(8, 12); }
      else if (k === 7) { g.fillStyle = '#a8a29e'; circle(10, 23, 2); g.fillStyle = '#d6d3d1'; circle(9.4, 22.4, .9); }
    } else if (t === 1) { // water: deep blue, a lighter band, a few ripples
      g.fillStyle = '#3a82c4'; g.fillRect(x, y, T, T);
      g.fillStyle = 'rgba(125,190,240,.22)'; g.fillRect(x, y + (v * 7) % 22, T, 7);
      g.strokeStyle = 'rgba(255,255,255,.45)'; g.lineWidth = 1.4; g.lineCap = 'round';
      g.beginPath(); g.arc(x + 9 + v * 3, y + 11, 5, Math.PI * 1.15, Math.PI * 1.85); g.stroke();
      g.beginPath(); g.arc(x + 21 - v * 2, y + 24, 5, Math.PI * 1.15, Math.PI * 1.85); g.stroke();
    } else if (t === 2) { // a tree: trunk, and a canopy of three leafy rounds
      const ox = [0, 1.5, -1.5, 0][v], sc = [1, .92, 1.06, .98][v];
      g.fillStyle = 'rgba(0,0,0,.22)'; g.beginPath(); g.ellipse(x + 17 + ox, y + 27, 11 * sc, 4, 0, 0, 7); g.fill();
      g.fillStyle = '#6b4423'; g.fillRect(x + 14 + ox, y + 18, 4.5, 9);
      g.fillStyle = '#285f33'; circle(16 + ox, 14, 12 * sc);
      g.fillStyle = '#348043'; circle(12 + ox, 11, 8 * sc); circle(20 + ox, 13, 7 * sc);
      g.fillStyle = '#4c9b56'; circle(13 + ox, 8.5, 4.5 * sc);
      if (v === 2) { g.fillStyle = '#ef4444'; circle(19, 16, 1.4); circle(11, 15, 1.4); } // apples on some
    } else if (t === 3) { // crystal: three cut shards on a bed of rock
      g.fillStyle = '#7c8088'; g.beginPath(); g.ellipse(x + 16, y + 24, 13, 6, 0, 0, 7); g.fill();
      g.fillStyle = '#9ca3af'; g.beginPath(); g.ellipse(x + 15, y + 23, 9, 3.5, 0, 0, 7); g.fill();
      const shard = (cx, hh, c1, c2) => {
        g.fillStyle = c1; g.beginPath(); g.moveTo(x + cx, y + 25 - hh); g.lineTo(x + cx + 5, y + 25 - hh / 2); g.lineTo(x + cx + 3, y + 25); g.lineTo(x + cx - 3, y + 25); g.lineTo(x + cx - 5, y + 25 - hh / 2); g.closePath(); g.fill();
        g.fillStyle = c2; g.beginPath(); g.moveTo(x + cx, y + 25 - hh); g.lineTo(x + cx + 5, y + 25 - hh / 2); g.lineTo(x + cx + 3, y + 25); g.lineTo(x + cx, y + 25); g.closePath(); g.fill();
      };
      shard(9, 12 + v, '#7dd3fc', '#38bdf8'); shard(23, 13 - v, '#7dd3fc', '#0ea5e9'); shard(16, 19 + v, '#bae6fd', '#38bdf8');
      g.fillStyle = 'rgba(255,255,255,.85)'; g.fillRect(x + 14.5, y + 9, 1.6, 6);
    }
  }
  // One tile of a bridge: planks laid across the way people walk, and a rail wherever the water is.
  plank(g, tx, ty, i) {
    const v = this.view, N = v.N, x = tx * T, y = ty * T, wet = j => j >= 0 && j < N * N && v.terrain[j] === 1;
    const n = wet(i - N), s = wet(i + N), w = tx > 0 && wet(i - 1), e = tx < N - 1 && wet(i + 1);
    g.fillStyle = '#b08a56'; g.fillRect(x, y, T + .6, T + .6);
    g.strokeStyle = 'rgba(74,52,28,.55)'; g.lineWidth = 1;
    for (let k = 8; k < T; k += 8) { if (n || s) line(g, x + k, y, x + k, y + T); else line(g, x, y + k, x + T, y + k); }
    g.fillStyle = '#6b4a2b';
    if (n) g.fillRect(x, y, T + .6, 4);
    if (s) g.fillRect(x, y + T - 4, T + .6, 4);
    if (w) g.fillRect(x, y, 4, T + .6);
    if (e) g.fillRect(x + T - 4, y, 4, T + .6);
  }
  toWorld(sx, sy) { return [sx / this.cam.z + this.cam.x, sy / this.cam.z + this.cam.y]; }
  clamp() {
    // The camera may travel past each edge of the map: a little everywhere, and further where controls float over
    // the map (this.pad, in screen pixels), so that nothing on the map is ever stuck behind them.
    const c = this.cam, W = this.view.N * T, vw = this.w / c.z, vh = this.h / c.z, p = this.pad || { l: 0, t: 0, r: 0, b: 0 };
    // Past each edge: a third of what is left of the screen once the controls are taken off, so a base in a
    // corner or along the bottom can be brought well into the open.
    const mx = Math.max(60, (vw - (p.l + p.r) / c.z) * .33), my = Math.max(60, (vh - (p.t + p.b) / c.z) * .33);
    const x0 = -mx - p.l / c.z, x1 = W + mx + p.r / c.z - vw, y0 = -my - p.t / c.z, y1 = W + my + p.b / c.z - vh;
    c.x = x1 < x0 ? (x0 + x1) / 2 : Math.max(x0, Math.min(x1, c.x));
    c.y = y1 < y0 ? (y0 + y1) / 2 : Math.max(y0, Math.min(y1, c.y));
  }
  center(x, y) { this.cam.x = x - this.w / this.cam.z / 2; this.cam.y = y - this.h / this.cam.z / 2; this.clamp(); }
  zoomAt(sx, sy, f) {
    const c = this.cam, [wx, wy] = this.toWorld(sx, sy);
    c.z = Math.max(.45, Math.min(2.5, c.z * f));
    c.x = wx - sx / c.z; c.y = wy - sy / c.z;
    this.clamp();
  }

  // ui: { sel:Set, box:{x0,y0,x1,y1}|null (screen px), ghost:{type,tx,ty,ok}|null }
  draw(dt, ui) {
    const v = this.view, g = this.g, c = this.cam, d = this.dpr, N = v.N;
    if (!v) return;
    v.dirty.length = 0;
    if ((this.fogT -= dt) <= 0) { this.fogT = .2; v.updateFog(); }
    this.clamp();
    g.setTransform(1, 0, 0, 1, 0, 0);
    g.fillStyle = '#0b1220'; g.fillRect(0, 0, this.cv.width, this.cv.height);
    g.setTransform(d * c.z, 0, 0, d * c.z, -c.x * d * c.z, -c.y * d * c.z);
    const vw = this.w / c.z, vh = this.h / c.z, W = N * T;
    {
      const x0 = Math.max(0, (c.x / T) | 0), x1 = Math.min(N - 1, ((c.x + vw) / T) | 0), y0 = Math.max(0, (c.y / T) | 0), y1 = Math.min(N - 1, ((c.y + vh) / T) | 0);
      for (let ty = y0; ty <= y1; ty++) for (let tx = x0; tx <= x1; tx++) {
        const i = ty * N + tx;
        if (!v.explored[i]) continue;
        let h = Math.imul(tx * 374761393 + ty * 668265263, 1274126177); h ^= h >>> 15; // well mixed, so variants do not line up
        const tt = v.terrain[i];
        g.drawImage(this.atlas, ((h >>> 8) & 7) * T * AT, (tt * 2 + ((tx + ty) & 1)) * T * AT, T * AT, T * AT, tx * T, ty * T, T + .6, T + .6);
        if (v.deck && v.deck[i]) this.plank(g, tx, ty, i);
        if (tt === 1) { // a sandy shore wherever water meets land
          g.fillStyle = 'rgba(233,224,180,.7)';
          if (ty > 0 && v.terrain[i - N] !== 1) g.fillRect(tx * T, ty * T, T, 3.5);
          if (ty < N - 1 && v.terrain[i + N] !== 1) g.fillRect(tx * T, ty * T + T - 3.5, T, 3.5);
          if (tx > 0 && v.terrain[i - 1] !== 1) g.fillRect(tx * T, ty * T, 3.5, T);
          if (tx < N - 1 && v.terrain[i + 1] !== 1) g.fillRect(tx * T + T - 3.5, ty * T, 3.5, T);
        }
      }
    }

    const k = Math.min(1, dt * 12), units = [], spect = v.spectating();
    const now = this.time = (this.time || 0) + dt, clock = performance.now();
    for (const e of v.ents.values()) {
      if (e.b) continue;
      const dx = e.x - e.rx, dy = e.y - e.ry;
      if (Math.abs(dx) > 1.5) e.face = dx > 0 ? 1 : -1;
      if (Math.abs(dx) + Math.abs(dy) > 150) { e.rx = e.x; e.ry = e.y; } else { e.rx += dx * k; e.ry += dy * k; }
      e.bob = Math.abs(dx) + Math.abs(dy) > 1.2 ? Math.abs(Math.sin(now * 11 + e.id)) * 1.8 : 0;
    }
    const onScreen = e => e.rx > c.x - 60 && e.ry > c.y - 60 && e.rx < c.x + vw + 60 && e.ry < c.y + vh + 60;
    for (const e of v.ents.values()) {
      if (!onScreen(e) || !(spect || v.canSee(e))) continue;
      if (!e.b) { units.push(e); continue; }
      if (ui.sel.has(e.id)) { g.strokeStyle = '#4ade80'; g.lineWidth = 2; rr(g, e.tx * T, e.ty * T, e.size * T, e.size * T, 6); g.stroke(); }
      drawBuilding(g, e, v.info[e.owner].color);
      wounds(g, e, now);
      if (clock - e.hurtT < 110) { g.fillStyle = 'rgba(255,255,255,.35)'; rr(g, e.tx * T + 3, e.ty * T + 3, e.size * T - 6, e.size * T - 6, 5); g.fill(); }
      if (e.fast) { // Swift March: training faster, shown as a pulsing gold outline
        g.strokeStyle = `rgba(253,224,71,${.55 + .35 * Math.sin(now * 9)})`; g.lineWidth = 2.5; rr(g, e.tx * T + 2, e.ty * T + 2, e.size * T - 4, e.size * T - 4, 6); g.stroke();
      }
      if (ui.sel.has(e.id) && DEF[e.type].range) reach(g, e.rx, e.ry, DEF[e.type].range, c.z);
      if (ui.sel.has(e.id) && e.rally && e.owner === v.me) { // where its new units go: a dashed line to a small flag
        const [fx, fy] = e.rally;
        g.strokeStyle = 'rgba(253,230,138,.9)'; g.lineWidth = 2 / c.z; g.setLineDash([8 / c.z, 6 / c.z]); line(g, e.rx, e.ry, fx, fy); g.setLineDash([]);
        g.strokeStyle = '#1f2937'; g.lineWidth = 2; line(g, fx, fy + 4, fx, fy - 20);
        g.fillStyle = '#fde68a'; g.lineWidth = 1; g.beginPath(); g.moveTo(fx, fy - 20); g.lineTo(fx + 14, fy - 15); g.lineTo(fx, fy - 10); g.closePath(); g.fill(); g.stroke();
      }
      const max = e.max;
      if (e.built && (e.hp < max || ui.sel.has(e.id))) bar(g, e.rx, e.ty * T - 4, e.size * T - 10, e.hp / max, '#4ade80');
      if (!e.built && e.paused && v.friendly(e)) { // nobody is building this: a pause badge
        const bx = e.rx, by = e.ry - 4;
        g.fillStyle = '#f59e0b'; g.strokeStyle = '#1f2937'; g.lineWidth = 1.5;
        g.beginPath(); g.arc(bx, by, 9, 0, 7); g.fill(); g.stroke();
        g.fillStyle = '#1f2937'; g.fillRect(bx - 4, by - 4.5, 3, 9); g.fillRect(bx + 1, by - 4.5, 3, 9);
      }
    }
    units.sort((a, b) => a.ry - b.ry);
    for (const e of units) {
      const big = DEF[e.type].hero || e.type === 'knight' || e.type === 'catapult' || e.type === 'boss';
      if (ui.sel.has(e.id)) {
        g.strokeStyle = '#4ade80'; g.lineWidth = 1.6;
        g.beginPath(); g.ellipse(e.rx, e.ry + 6, big ? 13 : 10, big ? 7 : 5.5, 0, 0, 7); g.stroke();
      }
      drawUnit(g, e, v.info[e.owner].color);
      if (clock - e.hurtT < 110) { g.fillStyle = 'rgba(255,255,255,.6)'; g.beginPath(); g.ellipse(e.rx, e.ry - 3 - (e.bob || 0), big ? 10 : 7.5, big ? 13 : 10, 0, 0, 7); g.fill(); } // a white flash when hit
      const max = e.max;
      const boss = e.type === 'boss';
      if (e.hp < max || ui.sel.has(e.id) || DEF[e.type].hero || boss) bar(g, e.rx, e.ry - (boss ? 42 : big ? 27 : 19), boss ? 34 : big ? 20 : 16, e.hp / max, v.friendly(e) ? '#4ade80' : '#f87171');
      if (DEF[e.type].hero) { // level badge
        const lv = v.pl[e.owner].lvl;
        g.fillStyle = '#fbbf24'; g.strokeStyle = '#1f2937'; g.lineWidth = 1;
        g.beginPath(); g.arc(e.rx - 16, e.ry - 26, 6, 0, 7); g.fill(); g.stroke();
        g.fillStyle = '#1f2937'; g.font = 'bold 9px system-ui, sans-serif'; g.textAlign = 'center'; g.textBaseline = 'middle';
        g.fillText(lv, e.rx - 16, e.ry - 25.5);
      }
    }

    if (v.nomad) { // Nomad: a white flag where the journey began, a gold one where the land ends
      const flag = (tx, ty, col) => {
        if (!v.explored[ty * N + tx]) return;
        const x = (tx + .5) * T, y = (ty + .5) * T;
        g.strokeStyle = '#1f2937'; g.lineWidth = 2.4; line(g, x, y + 8, x, y - 26);
        g.fillStyle = col; g.strokeStyle = '#1f2937'; g.lineWidth = 1.2;
        g.beginPath(); g.moveTo(x, y - 26); g.lineTo(x + 18, y - 20); g.lineTo(x, y - 13); g.closePath(); g.fill(); g.stroke();
      };
      flag(v.nomad.ox, v.nomad.oy, '#f8fafc'); flag(v.nomad.gx, v.nomad.gy, '#fbbf24');
    }

    // effects: shots in flight, blows landing, numbers for damage and healing
    const seen = (x, y) => spect || v.visible[Math.max(0, Math.min(N - 1, (y / T) | 0)) * N + Math.max(0, Math.min(N - 1, (x / T) | 0))];
    for (let i = v.fx.length - 1; i >= 0; i--) {
      const f = v.fx[i], a = f.a, drop = () => v.fx.splice(i, 1);
      if (f.t === 0 && f.k !== 'm' && !seen(a[1], a[2]) && !((f.k === 'a' || f.k === 'p') && seen(a[3], a[4]))) { drop(); continue; } // nothing shows through the fog
      f.t += dt;
      if (f.k === 'a') { // 0 arrow, 1 magic bolt, 2 boulder, 3 tower shot
        const kind = a[5] || 0, len = Math.hypot(a[3] - a[1], a[4] - a[2]) || 1, dur = kind === 2 ? Math.max(.4, len / 420) : kind === 1 ? Math.max(.16, len / 520) : Math.max(.1, len / 900);
        const p = f.t / dur;
        if (p >= 1) { drop(); if (kind === 1 || kind === 2) v.fx.push({ k: 'i', a: ['i', a[3], a[4], kind], t: 0 }); continue; }
        const x = a[1] + (a[3] - a[1]) * p, y = a[2] + (a[4] - a[2]) * p, ux = (a[3] - a[1]) / len, uy = (a[4] - a[2]) / len;
        if (kind === 2) {
          const lift = Math.sin(p * Math.PI) * Math.min(70, len * .3);
          g.fillStyle = 'rgba(0,0,0,.25)'; g.beginPath(); g.ellipse(x, y + 4, 5, 2.5, 0, 0, 7); g.fill();
          g.fillStyle = '#6b7280'; g.strokeStyle = '#1f2937'; g.lineWidth = 1; g.beginPath(); g.arc(x, y - lift, 4.5, 0, 7); g.fill(); g.stroke();
        } else if (kind === 1) {
          g.fillStyle = 'rgba(196,181,253,.35)'; g.beginPath(); g.arc(x - ux * 6, y - uy * 6, 4, 0, 7); g.fill();
          g.fillStyle = '#c4b5fd'; g.beginPath(); g.arc(x, y, 4, 0, 7); g.fill();
          g.fillStyle = '#fff'; g.beginPath(); g.arc(x, y, 1.8, 0, 7); g.fill();
        } else {
          g.strokeStyle = kind === 3 ? '#fde047' : '#f5f0dc'; g.lineWidth = kind === 3 ? 2.2 : 1.6; line(g, x, y, x - ux * 9, y - uy * 9);
          if (kind === 0) { g.strokeStyle = '#7c4a1e'; g.lineWidth = 1.6; line(g, x - ux * 9, y - uy * 9, x - ux * 12, y - uy * 12); }
        }
      } else if (f.k === 'i') { // a bolt bursting or a boulder landing
        if (f.t > .32) { drop(); continue; }
        const p = f.t / .32, big = a[3] === 2;
        g.strokeStyle = big ? `rgba(120,113,108,${1 - p})` : `rgba(196,181,253,${1 - p})`; g.lineWidth = 3 * (1 - p) + 1;
        g.beginPath(); g.arc(a[1], a[2], (big ? 8 : 6) + (big ? 26 : 36) * p, 0, 7); g.stroke();
        if (big) { g.fillStyle = `rgba(214,211,209,${.6 * (1 - p)})`; for (let n = 0; n < 5; n++) { const an = n * 1.257 + a[1]; g.beginPath(); g.arc(a[1] + Math.cos(an) * 22 * p, a[2] + Math.sin(an) * 14 * p - 6 * p, 3.5 * (1 - p) + 1, 0, 7); g.fill(); } }
      } else if (f.k === 'h') { // a blade landing: a quick white slash
        if (f.t > .16) { drop(); continue; }
        const p = f.t / .16;
        g.strokeStyle = `rgba(255,255,255,${1 - p * .6})`; g.lineWidth = 2.4 * (1 - p) + .8;
        g.beginPath(); g.arc(a[1] - 6, a[2] - 2, 12, -1.1 + p * .9, .2 + p * .9); g.stroke();
      } else if (f.k === 'n') { // how much damage (or healing) that was
        if (f.t > .75) { drop(); continue; }
        const p = f.t / .75, heal = a[4] === 1, big = a[3] >= 40;
        g.font = `bold ${big ? 13 : 10.5}px system-ui, sans-serif`; g.textAlign = 'center'; g.textBaseline = 'middle';
        const tx = a[1] + f.ox, ty = a[2] - 16 - 20 * p;
        g.globalAlpha = p < .6 ? 1 : 1 - (p - .6) / .4;
        g.lineWidth = 2.6; g.strokeStyle = 'rgba(15,23,42,.85)'; g.strokeText((heal ? '+' : '') + a[3], tx, ty);
        g.fillStyle = heal ? '#86efac' : big ? '#fde047' : '#fecaca'; g.fillText((heal ? '+' : '') + a[3], tx, ty);
        g.globalAlpha = 1;
      } else if (f.k === 'd') {
        if (f.t > .5) { drop(); continue; }
        const p = f.t / .5;
        g.fillStyle = `rgba(255,${200 - p * 120 | 0},90,${.7 * (1 - p)})`;
        g.beginPath(); g.arc(a[1], a[2], 8 + (a[3] ? a[3] * 22 : 10) * p, 0, 7); g.fill();
        g.fillStyle = `rgba(87,83,78,${.8 * (1 - p)})`;
        for (let n = 0; n < (a[3] ? 8 : 4); n++) { const an = n * 2.4 + a[2]; const d = (a[3] ? a[3] * 24 : 14) * p; g.fillRect(a[1] + Math.cos(an) * d - 1.5, a[2] + Math.sin(an) * d * .7 - 10 * p * (1 - p) * 4 - 1.5, 3, 3); }
      } else if (f.k === 's') {
        if (f.t > .5) { drop(); continue; }
        const p = f.t / .5;
        g.fillStyle = `rgba(${['253,224,71', '125,211,252', '134,239,172', '248,113,113', '147,197,253'][a[4] || 0]},${.14 * (1 - p)})`;
        g.beginPath(); g.arc(a[1], a[2], (a[3] || 90) * p, 0, 7); g.fill();
        g.strokeStyle = `rgba(${['253,224,71', '125,211,252', '134,239,172', '248,113,113', '147,197,253'][a[4] || 0]},${1 - p})`; g.lineWidth = 5 * (1 - p) + 1;
        g.beginPath(); g.arc(a[1], a[2], (a[3] || 90) * p, 0, 7); g.stroke();
      } else if (f.k === 'l') { // level up
        if (f.t > 1.1) { drop(); continue; }
        const p = f.t / 1.1;
        g.strokeStyle = `rgba(251,191,36,${1 - p})`; g.lineWidth = 3; g.beginPath(); g.arc(a[1], a[2], 12 + 40 * p, 0, 7); g.stroke();
        g.fillStyle = `rgba(253,230,138,${1 - p * p})`; g.font = 'bold 13px system-ui, sans-serif'; g.textAlign = 'center';
        g.fillText('LEVEL UP', a[1], a[2] - 30 - 22 * p);
      } else if (f.k === 'q') { // healed: a green ring closing on the unit
        if (f.t > .45) { drop(); continue; }
        const p = f.t / .45;
        g.strokeStyle = `rgba(74,222,128,${1 - p})`; g.lineWidth = 2;
        g.beginPath(); g.ellipse(a[1], a[2] + 5, 16 - 8 * p, 9 - 4.5 * p, 0, 0, 7); g.stroke();
      } else if (f.k === 'p') { // a shot that goes straight through: a bright line that fades
        if (f.t > .35) { drop(); continue; }
        const p = f.t / .35;
        g.lineCap = 'round';
        g.strokeStyle = `rgba(253,224,71,${.5 * (1 - p)})`; g.lineWidth = 9 * (1 - p) + 2; line(g, a[1], a[2], a[3], a[4]);
        g.strokeStyle = `rgba(255,255,255,${1 - p})`; g.lineWidth = 2.5; line(g, a[1], a[2], a[3], a[4]);
      } else if (f.k === 'm') {
        if (f.t > .4) { drop(); continue; }
        const p = f.t / .4;
        g.strokeStyle = a[3]; g.lineWidth = 2;
        g.beginPath(); g.ellipse(a[1], a[2], 14 * (1 - p) + 3, 8 * (1 - p) + 2, 0, 0, 7); g.stroke();
      } else drop();
    }

    // fog, one run of tiles at a time
    const tx0 = Math.max(0, (c.x / T) | 0), tx1 = Math.min(N - 1, ((c.x + vw) / T) | 0);
    const ty0 = Math.max(0, (c.y / T) | 0), ty1 = Math.min(N - 1, ((c.y + vh) / T) | 0);
    for (let ty = ty0; ty <= ty1; ty++) {
      let run = -1, kind = 0;
      for (let tx = tx0; tx <= tx1 + 1; tx++) {
        const i = ty * N + tx, kd = tx > tx1 ? 0 : !v.explored[i] ? 2 : !v.visible[i] ? 1 : 0;
        if (kd !== kind) {
          if (kind) { g.fillStyle = kind === 2 ? '#0b1220' : 'rgba(11,18,32,.5)'; g.fillRect(run * T, ty * T, (tx - run) * T + .5, T + .5); }
          run = tx; kind = kd;
        }
      }
    }

    if (ui.ghost) {
      const gh = ui.ghost, s = DEF[gh.type].size * T;
      if (!DEF[gh.type].anywhere) { // where building is allowed: around each of my finished Keeps
        g.strokeStyle = 'rgba(253,230,138,.95)'; g.lineWidth = 2.5 / c.z; g.setLineDash([10 / c.z, 7 / c.z]);
        for (const k of v.ents.values()) if (k.type === 'hq' && k.owner === v.me && k.built) g.strokeRect(k.x - BUILD_RANGE * T, k.y - BUILD_RANGE * T, BUILD_RANGE * 2 * T, BUILD_RANGE * 2 * T);
        g.setLineDash([]);
      }
      g.fillStyle = gh.ok ? 'rgba(74,222,128,.4)' : 'rgba(248,113,113,.45)';
      g.strokeStyle = gh.ok ? '#4ade80' : '#f87171'; g.lineWidth = 2;
      rr(g, gh.tx * T, gh.ty * T, s, s, 5); g.fill(); g.stroke();
      if (DEF[gh.type].range) reach(g, gh.tx * T + s / 2, gh.ty * T + s / 2, DEF[gh.type].range, c.z); // a tower shows what it would cover
    }
    if (ui.box) {
      g.setTransform(d, 0, 0, d, 0, 0);
      const b = ui.box;
      g.fillStyle = 'rgba(74,222,128,.15)'; g.strokeStyle = '#4ade80'; g.lineWidth = 1.5;
      g.fillRect(b.x0, b.y0, b.x1 - b.x0, b.y1 - b.y0); g.strokeRect(b.x0, b.y0, b.x1 - b.x0, b.y1 - b.y0);
    }
    if ((this.miniT -= dt) <= 0) { this.miniT = .25; this.drawMini(); }
  }

  drawMini() {
    const v = this.view, N = v.N, mg = this.mg, S = this.mini.width, px = this.mimg.data, c = this.cam, spect = v.spectating();
    for (let i = 0; i < N * N; i++) {
      const col = v.deck && v.deck[i] ? '#b08a56' : MINI[v.terrain[i]], f = !v.explored[i] ? 0 : v.visible[i] ? 1 : .55;
      px[i * 4] = parseInt(col.slice(1, 3), 16) * f; px[i * 4 + 1] = parseInt(col.slice(3, 5), 16) * f;
      px[i * 4 + 2] = parseInt(col.slice(5, 7), 16) * f; px[i * 4 + 3] = 255;
      if (!f) { px[i * 4] = 11; px[i * 4 + 1] = 18; px[i * 4 + 2] = 32; }
    }
    this.mc.getContext('2d').putImageData(this.mimg, 0, 0);
    mg.imageSmoothingEnabled = false;
    mg.drawImage(this.mc, 0, 0, S, S);
    const k = S / (N * T);
    for (const e of v.ents.values()) {
      if (!(spect || v.canSee(e))) continue;
      mg.fillStyle = v.info[e.owner].color;
      const s = e.b ? e.size * T * k + 1 : 3;
      mg.fillRect(e.x * k - s / 2, e.y * k - s / 2, s, s);
    }
    if (v.nomad) { // the start and the far end are always marked, so there is always somewhere to head for
      const dot = (tx, ty, col) => { mg.fillStyle = '#0b1220'; mg.fillRect(tx * T * k - 4, ty * T * k - 4, 8, 8); mg.fillStyle = col; mg.fillRect(tx * T * k - 3, ty * T * k - 3, 6, 6); };
      dot(v.nomad.ox, v.nomad.oy, '#f8fafc'); dot(v.nomad.gx, v.nomad.gy, '#fbbf24');
    }
    if (v.hurt && v.tick - v.hurt.tick < 30 && (v.tick >> 1) & 1) {
      mg.strokeStyle = '#fff'; mg.lineWidth = 2; mg.strokeRect(v.hurt.x * k - 6, v.hurt.y * k - 6, 12, 12);
    }
    mg.strokeStyle = '#fff'; mg.lineWidth = 1.5;
    mg.strokeRect(c.x * k, c.y * k, this.w / c.z * k, this.h / c.z * k);
  }
}
