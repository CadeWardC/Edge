// What a screen knows (View, rebuilt from snapshots) and how it is drawn (Renderer).
// The host draws from snapshots too, so single player and multiplayer share every line here.
import { TILE as T, DEF, TYPES, COLORS, MAP_SIZE, heroMult } from './data.js';
import { genMap } from './sim.js';

export class View {
  constructor(cfg, me) {
    this.N = cfg.size || MAP_SIZE;
    this.seed = cfg.seed;
    this.terrain = genMap(cfg.seed, this.N).terrain;
    this.info = cfg.players.map((p, i) => ({ name: p.name, team: p.team, color: COLORS[p.color ?? i] || COLORS[i], hero: p.hero || 'hero' }));
    this.me = me; this.team = this.info[me].team;
    this.pl = this.info.map(() => ({ res: 0, pop: 0, cap: 0, alive: true, heroT: 0 }));
    this.ents = new Map(); this.fx = []; this.dirty = [];
    this.tick = 0; this.winner = -1; this.hurt = null;
    this.explored = new Uint8Array(this.N * this.N);
    this.visible = new Uint8Array(this.N * this.N);
  }
  apply(s) {
    this.tick = s.k; this.winner = s.w;
    s.p.forEach((a, i) => { this.pl[i] = { res: a[0], pop: a[1], cap: a[2], alive: !!a[3], heroT: a[4], wood: a[5] || 0, lvl: a[6] || 1, xp: a[7] || 0 }; });
    for (const a of s.e) {
      const type = TYPES[a[1]], d = DEF[type];
      let e = this.ents.get(a[0]);
      if (!e) {
        e = { id: a[0], type, owner: a[2], rx: a[3], ry: a[4], b: !!d.b, size: d.size || 0, face: 1, hp: a[5] };
        if (d.b) { e.tx = Math.round(a[3] / T - d.size / 2); e.ty = Math.round(a[4] / T - d.size / 2); }
        this.ents.set(e.id, e);
      }
      if (a[5] < e.hp && e.owner === this.me) this.hurt = { x: a[3], y: a[4], tick: s.k };
      e.x = a[3]; e.y = a[4]; e.hp = a[5]; e.stamp = s.k;
      if (d.b) { e.built = !!a[6]; e.prog = a[7]; e.queue = a[8]; e.paused = !!a[9]; }
      else { e.carry = a[6]; e.cds = a[7] || null; e.idle = a[8]; e.buff = a[9] || 0; }
      e.max = d.hero ? Math.round(d.hp * heroMult(this.pl[e.owner].lvl)) : d.hp;
    }
    for (const [id, e] of this.ents) if (e.stamp !== s.k) this.ents.delete(id);
    for (const i of s.rm) { this.terrain[i] = 0; this.dirty.push(i); }
    for (const f of s.fx) this.fx.push({ k: f[0], a: f, t: 0 });
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
  const t = e.type, isHero = !!DEF[t].hero, big = isHero || t === 'knight', s = big ? 1.2 : 1;
  g.save();
  g.translate(e.rx, e.ry);
  if (e.buff & 6) { // Battle Cry glows red, Ward glows blue
    g.strokeStyle = e.buff & 2 ? 'rgba(248,113,113,.9)' : 'rgba(147,197,253,.9)'; g.lineWidth = 1.6;
    g.beginPath(); g.ellipse(0, 6, 12 * s, 6.5 * s, 0, 0, 7); g.stroke();
  }
  if (t === 'catapult') { drawCatapult(g, e, col); g.restore(); return; }
  g.fillStyle = 'rgba(0,0,0,.28)';
  g.beginPath(); g.ellipse(0, 7 * s, 8 * s, 3.5 * s, 0, 0, 7); g.fill();
  g.scale(e.face < 0 ? -s : s, s);
  g.lineWidth = 1; g.strokeStyle = 'rgba(0,0,0,.55)'; g.lineCap = 'round';
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
  g.beginPath(); g.arc(0, by - 4, 4.2, 0, 7); g.fill(); g.stroke();
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

function drawBuilding(g, e, col) {
  const x = e.tx * T, y = e.ty * T, w = e.size * T, cx = x + w / 2, cy = y + w / 2, t = e.type;
  g.save();
  if (!e.built) g.globalAlpha = .6;
  g.lineWidth = 1.5; g.strokeStyle = '#5b5446';
  g.fillStyle = 'rgba(0,0,0,.25)'; rr(g, x + 4, y + 6, w - 5, w - 5, 5); g.fill();
  g.fillStyle = '#d3cab8'; rr(g, x + 2, y + 2, w - 4, w - 4, 5); g.fill(); g.stroke();
  if (t === 'wall') { // a stone block with a stripe of the owner's colour
    g.fillStyle = '#9aa3ad'; rr(g, x + 1, y + 1, w - 2, w - 2, 3); g.fill(); g.stroke();
    g.strokeStyle = 'rgba(0,0,0,.25)'; g.lineWidth = 1; line(g, x + 2, cy, x + w - 2, cy); line(g, cx, y + 2, cx, cy); line(g, x + 9, cy, x + 9, y + w - 2); line(g, x + 23, cy, x + 23, y + w - 2);
    g.fillStyle = col; g.fillRect(x + 4, y + 4, w - 8, 4);
  } else if (t === 'tower') {
    g.fillStyle = col; g.beginPath(); g.arc(cx, cy, 9, 0, 7); g.fill(); g.stroke();
    g.fillStyle = '#f8fafc';
    for (let i = 0; i < 4; i++) { const a = i * Math.PI / 2 + Math.PI / 4; g.fillRect(cx + Math.cos(a) * 8 - 2, cy + Math.sin(a) * 8 - 2, 4, 4); }
  } else {
    const p = t === 'hq' ? 9 : 6;
    g.fillStyle = col; rr(g, x + p, y + p, w - 2 * p, w - 2 * p, 3); g.fill(); g.stroke();
    g.strokeStyle = 'rgba(0,0,0,.28)'; g.lineWidth = 1.2;
    line(g, x + p, y + p, x + w - p, y + w - p); line(g, x + w - p, y + p, x + p, y + w - p);
    g.strokeStyle = '#5b5446';
    if (t === 'hq') {
      g.fillStyle = '#d3cab8';
      for (const [dx, dy] of [[0, 0], [1, 0], [0, 1], [1, 1]]) { rr(g, x + 3 + dx * (w - 20), y + 3 + dy * (w - 20), 14, 14, 3); g.fill(); g.stroke(); }
      g.fillStyle = '#fde68a'; g.beginPath();
      for (let i = 0; i < 10; i++) { const a = -Math.PI / 2 + i * Math.PI / 5, r = i % 2 ? 6 : 13; g.lineTo(cx + Math.cos(a) * r, cy + Math.sin(a) * r); }
      g.closePath(); g.fill(); g.stroke();
    } else if (t === 'house') {
      g.fillStyle = '#f8fafc'; rr(g, cx - 5, cy - 5, 10, 10, 2); g.fill(); g.stroke();
    } else if (t === 'barracks') {
      g.strokeStyle = '#f8fafc'; g.lineWidth = 3; g.lineCap = 'round';
      line(g, cx - 10, cy - 10, cx + 10, cy + 10); line(g, cx + 10, cy - 10, cx - 10, cy + 10);
    } else if (t === 'workshop') { // a cog
      g.fillStyle = '#f8fafc'; g.strokeStyle = '#5b5446'; g.lineWidth = 1.2;
      for (let i = 0; i < 8; i++) { const a = i * Math.PI / 4; g.fillRect(cx + Math.cos(a) * 9 - 2.5, cy + Math.sin(a) * 9 - 2.5, 5, 5); }
      g.beginPath(); g.arc(cx, cy, 8, 0, 7); g.fill(); g.stroke();
      g.fillStyle = col; g.beginPath(); g.arc(cx, cy, 3, 0, 7); g.fill();
    } else if (t === 'sanctum') { // a glowing orb
      g.fillStyle = 'rgba(196,181,253,.45)'; g.beginPath(); g.arc(cx, cy, 12, 0, 7); g.fill();
      g.fillStyle = '#7c3aed'; g.strokeStyle = '#f8fafc'; g.lineWidth = 1.5; g.beginPath(); g.arc(cx, cy, 7.5, 0, 7); g.fill(); g.stroke();
      g.fillStyle = '#ede9fe'; g.beginPath(); g.arc(cx - 2.5, cy - 2.5, 2.2, 0, 7); g.fill();
    } else if (t === 'outpost') {
      g.fillStyle = '#7dd3fc'; g.strokeStyle = '#0c4a6e'; g.lineWidth = 1.5;
      g.beginPath(); g.moveTo(cx, cy - 11); g.lineTo(cx + 8, cy - 2); g.lineTo(cx, cy + 11); g.lineTo(cx - 8, cy - 2); g.closePath(); g.fill(); g.stroke();
      g.strokeStyle = 'rgba(255,255,255,.8)'; line(g, cx - 8, cy - 2, cx + 8, cy - 2);
    } else if (t === 'stable') {
      g.strokeStyle = '#f8fafc'; g.lineWidth = 4; g.lineCap = 'round';
      g.beginPath(); g.arc(cx, cy - 1, 9, Math.PI * .85, Math.PI * .15); g.stroke();
    }
  }
  g.restore();
  if (!e.built) bar(g, cx, y + w - 7, w - 12, e.prog / 100, '#fbbf24');
}
function bar(g, cx, y, w, f, col) {
  g.fillStyle = 'rgba(0,0,0,.65)'; g.fillRect(cx - w / 2 - 1, y - 1, w + 2, 5);
  g.fillStyle = col; g.fillRect(cx - w / 2, y, Math.max(0, w * Math.min(1, f)), 3);
}

const MINI = ['#5f9e45', '#3d86c6', '#2f6b3a', '#7dd3fc'];

export class Renderer {
  constructor(canvas, mini) {
    this.cv = canvas; this.g = canvas.getContext('2d');
    this.mini = mini; this.mg = mini.getContext('2d');
    this.cam = { x: 0, y: 0, z: 1 };
    this.view = null; this.fogT = 0; this.miniT = 0;
    this.resize();
  }
  resize() {
    const d = this.dpr = Math.min(window.devicePixelRatio || 1, 2);
    this.w = this.cv.clientWidth; this.h = this.cv.clientHeight;
    this.cv.width = Math.round(this.w * d); this.cv.height = Math.round(this.h * d);
  }
  setView(v) {
    this.view = v;
    const N = v.N, c = this.atlas = document.createElement('canvas');
    c.width = 32 * T; c.height = T;
    const ag = c.getContext('2d');
    for (let t = 0; t < 4; t++) for (let chk = 0; chk < 2; chk++) for (let k = 0; k < 4; k++) this.paint(ag, (t * 8 + chk * 4 + k) * T, 0, t, chk, [96, 3, 14, 5][k]);
    this.mc = document.createElement('canvas'); this.mc.width = this.mc.height = N;
    this.mimg = this.mc.getContext('2d').createImageData(N, N);
    v.updateFog();
  }
  // One tile of ground. The map is drawn from a small sheet of these every frame, so its size costs no memory.
  paint(g, x, y, t, chk, h) {
    g.fillStyle = chk ? '#6aa84c' : '#65a247';
    g.fillRect(x, y, T, T);
    if (t === 0 && h % 7 === 0) { g.fillStyle = '#7dba5c'; g.fillRect(x + 6 + h % 13, y + 8 + (h >> 4) % 13, 3, 3); }
    if (t === 1) {
      g.fillStyle = '#3d86c6'; g.fillRect(x, y, T, T);
      g.strokeStyle = 'rgba(255,255,255,.35)'; g.lineWidth = 1.5; g.lineCap = 'round';
      line(g, x + 5 + h % 8, y + 10, x + 14 + h % 8, y + 10); line(g, x + 12, y + 22, x + 24, y + 22);
    } else if (t === 2) {
      g.fillStyle = 'rgba(0,0,0,.2)'; g.beginPath(); g.ellipse(x + 17, y + 26, 11, 4, 0, 0, 7); g.fill();
      g.fillStyle = '#6b4423'; g.fillRect(x + 14, y + 17, 5, 10);
      g.fillStyle = '#2f6b3a'; g.beginPath(); g.arc(x + 16, y + 13, 12, 0, 7); g.fill();
      g.fillStyle = '#3f8a4b'; g.beginPath(); g.arc(x + 13, y + 10, 7, 0, 7); g.fill();
    } else if (t === 3) {
      g.fillStyle = '#8a8f98'; g.beginPath(); g.ellipse(x + 16, y + 23, 13, 6, 0, 0, 7); g.fill();
      for (const [cx, hh, c] of [[9, 12, '#38bdf8'], [16, 19, '#7dd3fc'], [23, 13, '#0ea5e9']]) {
        g.fillStyle = c; g.beginPath();
        g.moveTo(x + cx, y + 24 - hh); g.lineTo(x + cx + 5, y + 24 - hh / 2); g.lineTo(x + cx + 3, y + 24);
        g.lineTo(x + cx - 3, y + 24); g.lineTo(x + cx - 5, y + 24 - hh / 2); g.closePath(); g.fill();
      }
      g.fillStyle = 'rgba(255,255,255,.7)'; g.fillRect(x + 15, y + 9, 2, 6);
    }
  }
  toWorld(sx, sy) { return [sx / this.cam.z + this.cam.x, sy / this.cam.z + this.cam.y]; }
  clamp() {
    const c = this.cam, W = this.view.N * T, vw = this.w / c.z, vh = this.h / c.z, m = 120;
    c.x = vw > W + 2 * m ? (W - vw) / 2 : Math.max(-m, Math.min(W + m - vw, c.x));
    c.y = vh > W + 2 * m ? (W - vh) / 2 : Math.max(-m, Math.min(W + m - vh, c.y));
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
        const h = (tx * 73856093 ^ ty * 19349663) >>> 0;
        g.drawImage(this.atlas, (v.terrain[i] * 8 + ((tx + ty) & 1) * 4 + (h & 3)) * T, 0, T, T, tx * T, ty * T, T + .6, T + .6);
      }
    }

    const k = Math.min(1, dt * 12), units = [], spect = v.spectating();
    for (const e of v.ents.values()) {
      if (e.b) continue;
      const dx = e.x - e.rx, dy = e.y - e.ry;
      if (Math.abs(dx) > 1.5) e.face = dx > 0 ? 1 : -1;
      if (Math.abs(dx) + Math.abs(dy) > 150) { e.rx = e.x; e.ry = e.y; } else { e.rx += dx * k; e.ry += dy * k; }
    }
    const onScreen = e => e.rx > c.x - 60 && e.ry > c.y - 60 && e.rx < c.x + vw + 60 && e.ry < c.y + vh + 60;
    for (const e of v.ents.values()) {
      if (!onScreen(e) || !(spect || v.canSee(e))) continue;
      if (!e.b) { units.push(e); continue; }
      if (ui.sel.has(e.id)) { g.strokeStyle = '#4ade80'; g.lineWidth = 2; rr(g, e.tx * T, e.ty * T, e.size * T, e.size * T, 6); g.stroke(); }
      drawBuilding(g, e, v.info[e.owner].color);
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
      const big = DEF[e.type].hero || e.type === 'knight' || e.type === 'catapult';
      if (ui.sel.has(e.id)) {
        g.strokeStyle = '#4ade80'; g.lineWidth = 1.6;
        g.beginPath(); g.ellipse(e.rx, e.ry + 6, big ? 13 : 10, big ? 7 : 5.5, 0, 0, 7); g.stroke();
      }
      drawUnit(g, e, v.info[e.owner].color);
      const max = e.max;
      if (e.hp < max || ui.sel.has(e.id) || DEF[e.type].hero) bar(g, e.rx, e.ry - (big ? 27 : 19), big ? 20 : 16, e.hp / max, v.friendly(e) ? '#4ade80' : '#f87171');
      if (DEF[e.type].hero) { // level badge
        const lv = v.pl[e.owner].lvl;
        g.fillStyle = '#fbbf24'; g.strokeStyle = '#1f2937'; g.lineWidth = 1;
        g.beginPath(); g.arc(e.rx - 16, e.ry - 26, 6, 0, 7); g.fill(); g.stroke();
        g.fillStyle = '#1f2937'; g.font = 'bold 9px system-ui, sans-serif'; g.textAlign = 'center'; g.textBaseline = 'middle';
        g.fillText(lv, e.rx - 16, e.ry - 25.5);
      }
    }

    // effects
    for (let i = v.fx.length - 1; i >= 0; i--) {
      const f = v.fx[i], a = f.a;
      f.t += dt;
      if (f.k === 'a') {
        const p = f.t / .16;
        if (p >= 1) { v.fx.splice(i, 1); continue; }
        g.strokeStyle = '#fff7d6'; g.lineWidth = 1.6;
        const x = a[1] + (a[3] - a[1]) * p, y = a[2] + (a[4] - a[2]) * p, l = Math.hypot(a[3] - a[1], a[4] - a[2]) || 1;
        line(g, x, y, x - (a[3] - a[1]) / l * 7, y - (a[4] - a[2]) / l * 7);
      } else if (f.k === 'h') {
        if (f.t > .15) { v.fx.splice(i, 1); continue; }
        g.strokeStyle = '#fff'; g.lineWidth = 1.5;
        const r = 3 + f.t * 40;
        line(g, a[1] - r, a[2] - r, a[1] + r, a[2] + r); line(g, a[1] + r, a[2] - r, a[1] - r, a[2] + r);
      } else if (f.k === 'd') {
        if (f.t > .45) { v.fx.splice(i, 1); continue; }
        const p = f.t / .45;
        g.fillStyle = `rgba(255,${200 - p * 120 | 0},90,${.7 * (1 - p)})`;
        g.beginPath(); g.arc(a[1], a[2], 8 + (a[3] ? a[3] * 22 : 10) * p, 0, 7); g.fill();
      } else if (f.k === 's') {
        if (f.t > .5) { v.fx.splice(i, 1); continue; }
        const p = f.t / .5;
        g.strokeStyle = `rgba(${['253,224,71', '125,211,252', '134,239,172', '248,113,113', '147,197,253'][a[4] || 0]},${1 - p})`; g.lineWidth = 5 * (1 - p) + 1;
        g.beginPath(); g.arc(a[1], a[2], (a[3] || 90) * p, 0, 7); g.stroke();
      } else if (f.k === 'l') { // level up
        if (f.t > 1.1) { v.fx.splice(i, 1); continue; }
        const p = f.t / 1.1;
        g.strokeStyle = `rgba(251,191,36,${1 - p})`; g.lineWidth = 3; g.beginPath(); g.arc(a[1], a[2], 12 + 40 * p, 0, 7); g.stroke();
        g.fillStyle = `rgba(253,230,138,${1 - p * p})`; g.font = 'bold 13px system-ui, sans-serif'; g.textAlign = 'center';
        g.fillText('LEVEL UP', a[1], a[2] - 30 - 22 * p);
      } else if (f.k === 'q') { // healed
        if (f.t > .5) { v.fx.splice(i, 1); continue; }
        const p = f.t / .5, y = a[2] - 18 - 12 * p;
        g.fillStyle = `rgba(74,222,128,${1 - p})`; g.fillRect(a[1] - 1.5, y - 5, 3, 10); g.fillRect(a[1] - 5, y - 1.5, 10, 3);
      } else if (f.k === 'm') {
        if (f.t > .4) { v.fx.splice(i, 1); continue; }
        const p = f.t / .4;
        g.strokeStyle = a[3]; g.lineWidth = 2;
        g.beginPath(); g.ellipse(a[1], a[2], 14 * (1 - p) + 3, 8 * (1 - p) + 2, 0, 0, 7); g.stroke();
      }
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
      g.fillStyle = gh.ok ? 'rgba(74,222,128,.4)' : 'rgba(248,113,113,.45)';
      g.strokeStyle = gh.ok ? '#4ade80' : '#f87171'; g.lineWidth = 2;
      rr(g, gh.tx * T, gh.ty * T, s, s, 5); g.fill(); g.stroke();
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
      const col = MINI[v.terrain[i]], f = !v.explored[i] ? 0 : v.visible[i] ? 1 : .55;
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
    if (v.hurt && v.tick - v.hurt.tick < 30 && (v.tick >> 1) & 1) {
      mg.strokeStyle = '#fff'; mg.lineWidth = 2; mg.strokeRect(v.hurt.x * k - 6, v.hurt.y * k - 6, 12, 12);
    }
    mg.strokeStyle = '#fff'; mg.lineWidth = 1.5;
    mg.strokeRect(c.x * k, c.y * k, this.w / c.z * k, this.h / c.z * k);
  }
}
