// The authoritative simulation. It has no DOM or network code: the host (or a single-player
// game) steps it 10 times a second, feeds it commands, and ships snapshot() to every screen.
import { TILE as T, DEF, TI, MAXCAP, ABILITY, HERO_RESPAWN } from './data.js';

export const DT = 0.1;
const TREE_AMT = 200, CRYSTAL_AMT = 1500, CARRY = 10;

export function rng(a) {
  return () => {
    a |= 0; a = a + 0x6D2B79F5 | 0;
    let t = Math.imul(a ^ a >>> 15, 1 | a);
    t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
    return ((t ^ t >>> 14) >>> 0) / 4294967296;
  };
}

// One quadrant is generated from the seed and mirrored four ways, so every corner is equal.
// Terrain: 0 grass, 1 water, 2 tree, 3 crystal.
export function genMap(seed, N) {
  const r = rng(seed), Q = N >> 1, q = new Uint8Array(Q * Q), ri = n => (r() * n) | 0;
  const set = (x, y, t) => { if (x >= 0 && y >= 0 && x < Q && y < Q) q[y * Q + x] = t; };
  const blob = (t, x, y, n) => {
    for (let i = 0; i < n; i++) {
      set(x, y, t); set(x + 1, y, t);
      x = Math.max(0, Math.min(Q - 1, x + ri(3) - 1));
      y = Math.max(0, Math.min(Q - 1, y + ri(3) - 1));
    }
  };
  for (let i = 0; i < 8; i++) blob(2, ri(Q), ri(Q), 10 + ri(12));
  for (let i = 0; i < 3; i++) blob(1, 5 + ri(Q - 8), 5 + ri(Q - 8), 8 + ri(10));
  for (let i = 0; i < 2; i++) blob(3, 13 + ri(Q - 15), 13 + ri(Q - 15), 3);
  // Clear the base, then carve roads so every base can always reach every other.
  for (let y = 0; y < Q; y++) for (let x = 0; x < Q; x++) if (Math.hypot(x - 7, y - 7) < 6) q[y * Q + x] = 0;
  for (let i = 7; i < Q; i++) { set(i, 7, 0); set(i, 8, 0); set(7, i, 0); set(8, i, 0); set(i, i, 0); set(i - 1, i, 0); }
  // Guaranteed starting resources, and a contested deposit near the middle.
  for (const [x, y] of [[12, 4], [13, 4], [14, 4], [12, 5], [13, 5], [14, 5]]) set(x, y, 3);
  for (const [x, y] of [[3, 19], [4, 19], [3, 20], [4, 20]]) set(x, y, 3); // a second deposit a short walk away
  for (let x = 2; x <= 6; x++) { set(x, 13, 2); set(x, 14, 2); }
  for (const [x, y] of [[Q - 3, Q - 6], [Q - 2, Q - 6], [Q - 1, Q - 6], [Q - 6, Q - 3], [Q - 6, Q - 2], [Q - 6, Q - 1]]) set(x, y, 3);

  const terrain = new Uint8Array(N * N), amt = new Uint16Array(N * N);
  for (let y = 0; y < Q; y++) for (let x = 0; x < Q; x++) {
    const v = q[y * Q + x];
    for (const [mx, my] of [[x, y], [N - 1 - x, y], [x, N - 1 - y], [N - 1 - x, N - 1 - y]]) {
      terrain[my * N + mx] = v;
      amt[my * N + mx] = v === 2 ? TREE_AMT : v === 3 ? CRYSTAL_AMT : 0;
    }
  }
  return { terrain, amt };
}

// Slots 0 and 1 are opposite corners, so a two-player game is always a fair diagonal.
export function basePos(slot, N) {
  const a = 7, b = N - 8;
  return [[a, a], [b, b], [b, a], [a, b]][slot];
}

const FORMATION = [];
for (let y = -3; y <= 3; y++) for (let x = -3; x <= 3; x++) FORMATION.push([x * 20, y * 20]);
FORMATION.sort((a, b) => Math.hypot(a[0], a[1]) - Math.hypot(b[0], b[1]));

const num = v => typeof v === 'number' && isFinite(v);

export class Sim {
  constructor(cfg) {
    const N = this.N = cfg.size || 56;
    const m = genMap(cfg.seed, N);
    this.terrain = m.terrain; this.amt = m.amt;
    this.occ = new Int32Array(N * N);
    this.ents = new Map();
    this.nextId = 1; this.tick = 0; this.winner = -1;
    this.changed = []; this.fx = [];
    this.bad = new Set(); // resource tiles found unreachable; cleared whenever the terrain changes
    this._g = new Float32Array(N * N); this._st = new Uint32Array(N * N);
    this._cl = new Uint32Array(N * N); this._par = new Int32Array(N * N); this._stamp = 0;
    this.players = cfg.players.map(p => ({
      name: p.name, team: p.team, res: 250, pop: 0, cap: 0, alive: true, heroT: 0, bonus: p.bonus || 1, alert: null,
    }));
    this.players.forEach((p, i) => {
      const [bx, by] = basePos(i, N);
      this.addBuilding('hq', i, bx - 1, by - 1, true);
      for (let j = 0; j < 3; j++) this.autoHarvest(this.spawnUnit('worker', i, (bx - 1 + j + .5) * T, (by + 2.5) * T));
      this.spawnUnit('hero', i, (bx + 2.5) * T, (by + 2.5) * T);
    });
  }

  // ---------- helpers ----------
  walkable(x, y) {
    const N = this.N;
    if (x < 0 || y < 0 || x >= N || y >= N) return false;
    const i = y * N + x;
    return this.terrain[i] === 0 && this.occ[i] === 0;
  }
  enemy(a, b) { return this.players[a.owner].team !== this.players[b.owner].team; }
  dist(a, t) {
    if (t.b) {
      const h = t.size * T / 2;
      // Square distance to the wall, so a unit standing at a corner is as close as one at a side.
      return Math.max(Math.abs(a.x - t.x) - h, Math.abs(a.y - t.y) - h, 0);
    }
    return Math.hypot(a.x - t.x, a.y - t.y);
  }
  tileOf(v) { return Math.max(0, Math.min(this.N - 1, (v / T) | 0)); }

  addBuilding(type, owner, tx, ty, built) {
    const d = DEF[type], s = d.size;
    const e = {
      id: this.nextId++, type, owner, b: true, tx, ty, size: s, x: (tx + s / 2) * T, y: (ty + s / 2) * T,
      hp: built ? d.hp : d.hp * 0.1, built, prog: built ? 1 : 0, queue: [], trainT: 0, cdT: 0,
    };
    for (let y = ty; y < ty + s; y++) for (let x = tx; x < tx + s; x++) this.occ[y * this.N + x] = e.id;
    if (built && d.cap) this.players[owner].cap += d.cap;
    this.ents.set(e.id, e);
    if (this.bad) this.bad.clear();
    return e;
  }
  spawnUnit(type, owner, x, y) {
    const e = { id: this.nextId++, type, owner, x, y, hp: DEF[type].hp, order: null, path: null, pi: 0, cdT: 0, carry: 0, abT: 0 };
    this.ents.set(e.id, e);
    return e;
  }
  canPlace(type, tx, ty) {
    const s = DEF[type].size;
    for (let y = ty; y < ty + s; y++) for (let x = tx; x < tx + s; x++) if (!this.walkable(x, y)) return false;
    return true;
  }
  hasBuilt(owner, type) {
    for (const e of this.ents.values()) if (e.owner === owner && e.type === type && e.built) return true;
    return false;
  }
  openNeighbor(x, y) {
    for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) if ((dx || dy) && this.walkable(x + dx, y + dy)) return true;
    return false;
  }
  nearestRes(tx, ty, kind, R = 24) {
    const N = this.N;
    let best = null, bd = 1e9;
    for (let y = Math.max(0, ty - R); y <= Math.min(N - 1, ty + R); y++) {
      for (let x = Math.max(0, tx - R); x <= Math.min(N - 1, tx + R); x++) {
        const t = this.terrain[y * N + x];
        if (t < 2 || (kind && t !== kind) || this.bad.has(y * N + x)) continue;
        const d = (x - tx) * (x - tx) + (y - ty) * (y - ty);
        if (d < bd && this.openNeighbor(x, y)) { bd = d; best = [x, y]; }
      }
    }
    return best || (kind ? this.nearestRes(tx, ty, 0, R) : null);
  }
  autoHarvest(e) {
    const r = this.nearestRes(this.tileOf(e.x), this.tileOf(e.y), 3);
    if (r) this.orderHarvest(e, r[0], r[1]);
  }
  orderHarvest(e, tx, ty) {
    e.order = { k: 'harvest', tx, ty, kind: this.terrain[ty * this.N + tx], ph: 0, tries: 0 };
    this.pathTo(e, tx, ty, tx, ty);
  }
  dropoff(e) {
    let best = null, bd = 1e9;
    for (const h of this.ents.values()) {
      if (h.type !== 'hq' || h.owner !== e.owner || !h.built) continue;
      const d = this.dist(e, h);
      if (d < bd) { bd = d; best = h; }
    }
    return best;
  }
  freeSpot(b) {
    const spots = [];
    for (let r = 1; r <= 3 && !spots.length; r++) {
      for (let y = b.ty - r; y < b.ty + b.size + r; y++) for (let x = b.tx - r; x < b.tx + b.size + r; x++) {
        if (this.walkable(x, y)) spots.push([x, y]);
      }
    }
    return spots.length ? spots[this.nextId % spots.length] : null;
  }
  // A free building site near (cx, cy) with a one-tile walkway kept clear all round it.
  findSite(type, cx, cy) {
    const s = DEF[type].size;
    for (let r = 3; r <= 14; r++) {
      const c = [];
      for (let ty = cy - r; ty <= cy + r; ty++) for (let tx = cx - r; tx <= cx + r; tx++) {
        if (Math.max(Math.abs(tx - cx), Math.abs(ty - cy)) !== r) continue;
        let ok = true;
        for (let y = ty - 1; y <= ty + s && ok; y++) for (let x = tx - 1; x <= tx + s; x++) if (!this.walkable(x, y)) { ok = false; break; }
        if (ok) c.push([tx, ty]);
      }
      if (c.length) return c[(this.tick + this.nextId) % c.length];
    }
    return null;
  }

  // ---------- pathfinding ----------
  // A* to the nearest tile of a goal rectangle. The goal may be blocked (a building, a tree):
  // the path then stops beside it. If nothing is reachable it leads to the closest point.
  findPath(sx, sy, gx0, gy0, gx1, gy1) {
    const N = this.N, g = this._g, st = this._st, cl = this._cl, par = this._par, stamp = ++this._stamp;
    const h = (x, y) => {
      const dx = Math.max(gx0 - x, 0, x - gx1), dy = Math.max(gy0 - y, 0, y - gy1);
      return Math.max(dx, dy) + 0.414 * Math.min(dx, dy);
    };
    const hf = [], hi = [];
    const push = (f, i) => {
      let c = hf.length; hf.push(f); hi.push(i);
      while (c > 0) {
        const p = (c - 1) >> 1;
        if (hf[p] <= f) break;
        hf[c] = hf[p]; hi[c] = hi[p]; c = p;
      }
      hf[c] = f; hi[c] = i;
    };
    const pop = () => {
      const top = hi[0], f = hf.pop(), i = hi.pop(), n = hf.length;
      if (n) {
        let c = 0;
        for (;;) {
          let k = 2 * c + 1;
          if (k >= n) break;
          if (k + 1 < n && hf[k + 1] < hf[k]) k++;
          if (hf[k] >= f) break;
          hf[c] = hf[k]; hi[c] = hi[k]; c = k;
        }
        hf[c] = f; hi[c] = i;
      }
      return top;
    };
    const s = sy * N + sx;
    g[s] = 0; st[s] = stamp; par[s] = -1; push(h(sx, sy), s);
    let best = s, bestH = h(sx, sy), end = -1;
    while (hi.length) {
      const i = pop();
      if (cl[i] === stamp) continue;
      cl[i] = stamp;
      const x = i % N, y = (i / N) | 0, hh = h(x, y);
      if (hh === 0) { end = i; break; }
      if (hh < bestH) { bestH = hh; best = i; }
      for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
        if (!dx && !dy) continue;
        const nx = x + dx, ny = y + dy;
        if (nx < 0 || ny < 0 || nx >= N || ny >= N) continue;
        const inG = nx >= gx0 && nx <= gx1 && ny >= gy0 && ny <= gy1;
        if (!inG && !this.walkable(nx, ny)) continue;
        if (dx && dy && !inG && (!this.walkable(nx, y) || !this.walkable(x, ny))) continue; // no cutting corners
        const ni = ny * N + nx;
        if (cl[ni] === stamp) continue;
        const ng = g[i] + (dx && dy ? 1.414 : 1);
        if (st[ni] !== stamp || ng < g[ni]) { g[ni] = ng; st[ni] = stamp; par[ni] = i; push(ng + h(nx, ny), ni); }
      }
    }
    if (end < 0) end = best;
    const out = [];
    for (let i = end; i !== s && i >= 0; i = par[i]) out.push(i);
    out.reverse();
    if (out.length) { const l = out[out.length - 1]; if (!this.walkable(l % N, (l / N) | 0)) out.pop(); }
    return out;
  }
  // Give a unit a path to a goal rectangle; (px, py) is an exact end point inside a 1-tile goal.
  pathTo(e, gx0, gy0, gx1, gy1, px, py) {
    const N = this.N, sx = this.tileOf(e.x), sy = this.tileOf(e.y);
    const t = this.findPath(sx, sy, gx0, gy0, gx1, gy1), p = [];
    for (const i of t) p.push((i % N + .5) * T, (((i / N) | 0) + .5) * T);
    if (px !== undefined && this.walkable(gx0, gy0)) {
      const last = t.length ? t[t.length - 1] : sy * N + sx;
      if (last === gy0 * N + gx0) {
        if (t.length) { p[p.length - 2] = px; p[p.length - 1] = py; } else p.push(px, py);
      }
    }
    e.path = p; e.pi = 0;
  }
  // 0 = still moving, 1 = arrived, 2 = the way is now blocked.
  follow(e) {
    const p = e.path;
    if (!p || e.pi >= p.length) return 1;
    let step = DEF[e.type].speed * DT;
    while (step > 0 && e.pi < p.length) {
      const wx = p[e.pi], wy = p[e.pi + 1];
      if (!this.walkable((wx / T) | 0, (wy / T) | 0)) { e.path = null; return 2; }
      const dx = wx - e.x, dy = wy - e.y, d = Math.hypot(dx, dy);
      if (d <= step) { e.x = wx; e.y = wy; step -= d; e.pi += 2; }
      else { e.x += dx / d * step; e.y += dy / d * step; step = 0; }
    }
    return e.pi >= p.length ? 1 : 0;
  }
  pathPoint(e, x, y) { const tx = this.tileOf(x), ty = this.tileOf(y); this.pathTo(e, tx, ty, tx, ty, x, y); }

  // ---------- combat ----------
  acquire(e, range) {
    let best = null, bd = range;
    for (const t of this.ents.values()) {
      if (!this.enemy(e, t)) continue;
      let d = this.dist(e, t);
      if (d > range) continue;
      if (t.b && !DEF[t.type].dmg) d += 60; // fight what fights back first
      if (d < bd || !best) { bd = d; best = t; }
    }
    return best;
  }
  hit(t, dmg) {
    if (t.hp <= 0) return;
    t.hp -= dmg;
    this.players[t.owner].alert = { x: t.x, y: t.y, tick: this.tick };
    if (t.hp <= 0) this.kill(t);
  }
  kill(e) {
    e.hp = 0;
    this.ents.delete(e.id);
    this.fx.push(['d', e.x | 0, e.y | 0, e.b ? e.size : 0]);
    const P = this.players[e.owner];
    if (e.b) {
      for (let y = e.ty; y < e.ty + e.size; y++) for (let x = e.tx; x < e.tx + e.size; x++) this.occ[y * this.N + x] = 0;
      this.bad.clear();
      if (e.built && DEF[e.type].cap) P.cap -= DEF[e.type].cap;
    } else if (e.type === 'hero') P.heroT = HERO_RESPAWN;
  }
  resume(e, o) {
    e.path = null;
    if (o.resume) { e.order = o.resume; this.pathPoint(e, o.resume.x, o.resume.y); }
    else e.order = null;
  }

  // ---------- per-tick updates ----------
  updateUnit(e) {
    const d = DEF[e.type], o = e.order, P = this.players[e.owner], N = this.N;
    e.cdT -= DT;
    if (e.type === 'hero') { e.abT -= DT; if (e.hp < d.hp) e.hp = Math.min(d.hp, e.hp + 2 * DT); }
    const scan = (this.tick + e.id) % 5 === 0;
    if (!o) {
      if (d.mil && scan) { const t = this.acquire(e, 200); if (t) e.order = { k: 'attack', target: t.id, auto: 1 }; }
      return;
    }
    switch (o.k) {
      case 'move': case 'amove': {
        if (o.k === 'amove' && scan) {
          const t = this.acquire(e, 200);
          if (t) { e.order = { k: 'attack', target: t.id, auto: 1, resume: o }; break; }
        }
        const r = this.follow(e);
        if (r === 1) e.order = null;
        else if (r === 2) { if (++o.tries > 4) e.order = null; else this.pathPoint(e, o.x, o.y); }
        break;
      }
      case 'attack': {
        const t = this.ents.get(o.target);
        if (!t) { this.resume(e, o); break; }
        const dd = this.dist(e, t), reach = d.range || 26;
        if (dd <= reach) {
          if (e.cdT <= 0) {
            e.cdT = d.cd;
            this.fx.push(d.range ? ['a', e.x | 0, e.y | 0, t.x | 0, t.y | 0] : ['h', t.x | 0, t.y | 0]);
            this.hit(t, d.dmg);
          }
        } else if (o.auto && dd > 320) this.resume(e, o);
        else if (!t.b && dd < 70) {
          const s = Math.min(d.speed * DT, dd), nx = e.x + (t.x - e.x) / dd * s, ny = e.y + (t.y - e.y) / dd * s;
          if (this.walkable((nx / T) | 0, (ny / T) | 0)) { e.x = nx; e.y = ny; e.path = null; }
        } else {
          if (!e.path || e.pi >= e.path.length || (this.tick + e.id) % 10 === 0) {
            if (t.b) this.pathTo(e, t.tx, t.ty, t.tx + t.size - 1, t.ty + t.size - 1);
            else this.pathPoint(e, t.x, t.y);
          }
          this.follow(e);
        }
        break;
      }
      case 'harvest': {
        if (o.ph === 0) { // walk to the resource
          const i = o.ty * N + o.tx;
          if (this.terrain[i] < 2) {
            const r = this.nearestRes(o.tx, o.ty, o.kind);
            if (!r) { e.order = null; break; }
            o.tx = r[0]; o.ty = r[1]; o.tries = 0;
            this.pathTo(e, o.tx, o.ty, o.tx, o.ty);
            break;
          }
          const cx = (o.tx + .5) * T, cy = (o.ty + .5) * T;
          if (Math.max(Math.abs(e.x - cx), Math.abs(e.y - cy)) <= T * 1.3) { o.ph = 1; o.t = o.kind === 3 ? 1.2 : 2; break; }
          const r = this.follow(e);
          if (r === 1) { // the path ended and the resource is still out of reach: try another one
            this.bad.add(i);
            const n = this.nearestRes(this.tileOf(e.x), this.tileOf(e.y), o.kind);
            if (!n) { e.order = null; break; }
            o.tx = n[0]; o.ty = n[1]; o.kind = this.terrain[n[1] * N + n[0]]; o.tries = 0;
            this.pathTo(e, o.tx, o.ty, o.tx, o.ty);
          } else if (r === 2) { if (++o.tries > 4) e.order = null; else this.pathTo(e, o.tx, o.ty, o.tx, o.ty); }
        } else if (o.ph === 1) { // gather
          o.t -= DT;
          if (o.t > 0) break;
          const i = o.ty * N + o.tx;
          if (this.terrain[i] < 2) { o.ph = 0; break; }
          const take = Math.min(CARRY, this.amt[i]);
          this.amt[i] -= take; e.carry = take;
          if (this.amt[i] <= 0) { this.terrain[i] = 0; this.changed.push(i); this.bad.clear(); }
          o.ph = 2; o.d = 0; o.tries = 0;
        } else { // carry it home
          let hq = this.ents.get(o.d);
          if (!hq) {
            hq = this.dropoff(e);
            if (!hq) { e.order = null; break; }
            o.d = hq.id;
            this.pathTo(e, hq.tx, hq.ty, hq.tx + 2, hq.ty + 2);
          }
          if (this.dist(e, hq) <= 26) {
            P.res += e.carry * P.bonus; e.carry = 0; o.ph = 0; o.tries = 0;
            this.pathTo(e, o.tx, o.ty, o.tx, o.ty);
          } else if (this.follow(e)) {
            if (++o.tries > 4) e.order = null; else this.pathTo(e, hq.tx, hq.ty, hq.tx + 2, hq.ty + 2);
          }
        }
        break;
      }
      case 'build': {
        const b = this.ents.get(o.b);
        if (!b || b.built) { e.order = null; this.autoHarvest(e); break; }
        const bd = DEF[b.type];
        if (this.dist(e, b) <= 26) {
          b.prog += DT / bd.time; b.wk = this.tick;
          b.hp = Math.min(bd.hp, b.hp + bd.hp * 0.9 * DT / bd.time);
          if (b.prog >= 1) { b.prog = 1; b.built = true; if (bd.cap) this.players[b.owner].cap += bd.cap; }
        } else if (this.follow(e)) {
          if (++o.tries > 6) e.order = null; else this.pathTo(e, b.tx, b.ty, b.tx + b.size - 1, b.ty + b.size - 1);
        }
        break;
      }
    }
  }
  updateBuilding(e) {
    if (!e.built) return;
    const d = DEF[e.type];
    if (d.dmg) {
      e.cdT -= DT;
      if (e.cdT <= 0 && (this.tick + e.id) % 3 === 0) {
        const t = this.acquire(e, d.range);
        if (t) { e.cdT = d.cd; this.fx.push(['a', e.x | 0, e.y | 0, t.x | 0, t.y | 0]); this.hit(t, d.dmg); }
      }
    }
    if (e.queue.length) {
      const u = e.queue[0], need = DEF[u].time;
      e.trainT += DT;
      if (e.trainT >= need) {
        const s = this.freeSpot(e);
        if (s) {
          const n = this.spawnUnit(u, e.owner, (s[0] + .5) * T, (s[1] + .5) * T);
          e.queue.shift(); e.trainT = 0;
          if (u === 'worker') this.autoHarvest(n);
        } else e.trainT = need;
      }
    }
  }
  step() {
    if (this.winner !== -1) return;
    const units = [];
    for (const p of this.players) p.pop = 0;
    for (const e of this.ents.values()) {
      if (e.b) this.players[e.owner].pop += e.queue.length;
      else if (e.type !== 'hero') this.players[e.owner].pop++;
    }
    for (const e of this.ents.values()) {
      if (e.hp <= 0) continue;
      if (e.b) this.updateBuilding(e); else { this.updateUnit(e); units.push(e); }
    }
    // Soft separation: units push each other apart instead of stacking.
    for (let i = 0; i < units.length; i++) {
      const a = units[i];
      if (a.hp <= 0) continue;
      for (let j = i + 1; j < units.length; j++) {
        const b = units[j];
        let dx = b.x - a.x, dy = b.y - a.y;
        if (dx > 16 || dx < -16 || dy > 16 || dy < -16 || b.hp <= 0) continue;
        let dd = Math.hypot(dx, dy);
        if (dd >= 16) continue;
        if (dd < .01) { dx = ((a.id * 7 + b.id) % 5) - 2 || 1; dy = ((a.id + b.id * 3) % 5) - 2; dd = Math.hypot(dx, dy); }
        const p = (16 - dd) * .25, ux = dx / dd * p, uy = dy / dd * p;
        this.nudge(a, -ux, -uy); this.nudge(b, ux, uy);
      }
    }
    // A standing Keep earns a trickle on its own, so nobody is ever stuck with no workers and no way back.
    if (this.tick % 20 === 0) for (const e of this.ents.values()) if (e.type === 'hq' && e.built) this.players[e.owner].res += 1;
    this.players.forEach((p, i) => {
      if (p.heroT <= 0) return;
      p.heroT -= DT;
      if (p.heroT > 0) return;
      p.heroT = 0;
      let hq = null;
      for (const e of this.ents.values()) if (e.type === 'hq' && e.owner === i && e.built) { hq = e; break; }
      const s = hq && this.freeSpot(hq);
      if (s) this.spawnUnit('hero', i, (s[0] + .5) * T, (s[1] + .5) * T);
      else if (p.alive) p.heroT = 5;
    });
    if (this.tick % 10 === 0) this.checkWin();
    this.tick++;
  }
  nudge(e, dx, dy) {
    const nx = e.x + dx, ny = e.y + dy;
    if (this.walkable((nx / T) | 0, (ny / T) | 0)) { e.x = nx; e.y = ny; }
  }
  // A player is out when their last building falls; the last team standing wins.
  checkWin() {
    const has = this.players.map(() => false);
    for (const e of this.ents.values()) if (e.b) has[e.owner] = true;
    this.players.forEach((p, i) => {
      if (p.alive && !has[i]) {
        p.alive = false; p.heroT = 0;
        for (const e of [...this.ents.values()]) if (e.owner === i) this.kill(e);
      }
    });
    if (this.players.length < 2) return;
    const teams = new Set(this.players.filter(p => p.alive).map(p => p.team));
    if (teams.size <= 1) this.winner = teams.size ? [...teams][0] : -2;
  }

  // ---------- commands (from the local player, a remote player or an AI) ----------
  command(pid, c) {
    const P = this.players[pid];
    if (!P || !P.alive || !c || this.winner !== -1) return;
    const own = ids => (Array.isArray(ids) ? ids.slice(0, 200) : []).map(id => this.ents.get(id)).filter(e => e && e.owner === pid);
    const lim = this.N * T - 1;
    switch (c.t) {
      case 'move': {
        if (!num(c.x) || !num(c.y)) return;
        const x = Math.max(0, Math.min(lim, c.x)), y = Math.max(0, Math.min(lim, c.y));
        own(c.ids).filter(e => !e.b).forEach((e, i) => {
          const f = FORMATION[i % FORMATION.length];
          let dx = x + f[0], dy = y + f[1];
          if (!this.walkable((dx / T) | 0, (dy / T) | 0)) { dx = x; dy = y; }
          e.order = { k: c.a ? 'amove' : 'move', x: dx, y: dy, tries: 0 };
          this.pathPoint(e, dx, dy);
        });
        break;
      }
      case 'attack': {
        const t = this.ents.get(c.target);
        if (!t || !this.enemy({ owner: pid }, t)) return;
        for (const e of own(c.ids)) if (!e.b) { e.order = { k: 'attack', target: t.id }; e.path = null; }
        break;
      }
      case 'harvest': {
        if (!num(c.tx) || !num(c.ty)) return;
        let tx = c.tx | 0, ty = c.ty | 0;
        if (tx < 0 || ty < 0 || tx >= this.N || ty >= this.N || this.terrain[ty * this.N + tx] < 2) return;
        if (!this.openNeighbor(tx, ty)) {
          const r = this.nearestRes(tx, ty, this.terrain[ty * this.N + tx]);
          if (!r) return;
          [tx, ty] = r;
        }
        for (const e of own(c.ids)) if (e.type === 'worker') this.orderHarvest(e, tx, ty);
        break;
      }
      case 'build': {
        const d = DEF[c.b];
        if (!d || !d.b || c.b === 'hq' || !num(c.tx) || !num(c.ty)) return;
        const tx = c.tx | 0, ty = c.ty | 0;
        if (P.res < d.cost || (d.req && !this.hasBuilt(pid, d.req)) || !this.canPlace(c.b, tx, ty)) return;
        const ws = own(c.ids).filter(e => e.type === 'worker');
        if (!ws.length) return;
        P.res -= d.cost;
        const b = this.addBuilding(c.b, pid, tx, ty, false);
        for (const e of ws) { e.order = { k: 'build', b: b.id, tries: 0 }; this.pathTo(e, tx, ty, tx + d.size - 1, ty + d.size - 1); }
        break;
      }
      case 'assist': {
        const b = this.ents.get(c.b);
        if (!b || !b.b || b.built || b.owner !== pid) return;
        for (const e of own(c.ids)) if (e.type === 'worker') {
          e.order = { k: 'build', b: b.id, tries: 0 };
          this.pathTo(e, b.tx, b.ty, b.tx + b.size - 1, b.ty + b.size - 1);
        }
        break;
      }
      case 'resume': { // send the nearest free workers to an unfinished building
        const b = this.ents.get(c.b);
        if (!b || !b.b || b.built || b.owner !== pid) return;
        const ws = [];
        for (const e of this.ents.values()) if (e.owner === pid && e.type === 'worker' && !(e.order && e.order.k === 'build')) ws.push(e);
        ws.sort((p, q) => (p.order ? 1e6 : 0) + this.dist(p, b) - (q.order ? 1e6 : 0) - this.dist(q, b)); // idle workers first
        for (const e of ws.slice(0, 2)) {
          e.order = { k: 'build', b: b.id, tries: 0 };
          this.pathTo(e, b.tx, b.ty, b.tx + b.size - 1, b.ty + b.size - 1);
        }
        break;
      }
      case 'cancel': { // tear down an unfinished building and get the crystal back
        const b = this.ents.get(c.b);
        if (!b || !b.b || b.built || b.owner !== pid) return;
        P.res += DEF[b.type].cost;
        this.kill(b);
        break;
      }
      case 'unqueue': { // drop the last unit waiting in a building's queue
        const b = this.ents.get(c.b);
        if (!b || !b.b || b.owner !== pid || !b.queue.length) return;
        const u = b.queue.pop();
        P.res += DEF[u].cost;
        if (!b.queue.length) b.trainT = 0;
        break;
      }
      case 'train': {
        const b = this.ents.get(c.b), d = DEF[c.u];
        if (!b || b.owner !== pid || !b.built || !d || !(DEF[b.type].trains || []).includes(c.u)) return;
        if (b.queue.length >= 5 || P.res < d.cost || P.pop >= P.cap) return;
        P.res -= d.cost; P.pop++;
        b.queue.push(c.u);
        break;
      }
      case 'ability': {
        const e = this.ents.get(c.id);
        if (!e || e.owner !== pid || e.type !== 'hero' || e.abT > 0) return;
        e.abT = ABILITY.cd;
        this.fx.push(['s', e.x | 0, e.y | 0]);
        for (const t of [...this.ents.values()]) if (this.enemy(e, t) && this.dist(e, t) <= ABILITY.radius) this.hit(t, ABILITY.dmg);
        break;
      }
      case 'stop':
        for (const e of own(c.ids)) if (!e.b) { e.order = null; e.path = null; }
        break;
    }
  }

  // Everything a screen needs to draw this tick. Tile changes and effects are sent once.
  snapshot() {
    const s = {
      k: this.tick, w: this.winner,
      p: this.players.map(p => [Math.floor(p.res), p.pop, Math.min(p.cap, MAXCAP), p.alive ? 1 : 0, Math.ceil(p.heroT)]),
      e: [], rm: this.changed, fx: this.fx,
    };
    this.changed = []; this.fx = [];
    for (const e of this.ents.values()) {
      const a = [e.id, TI[e.type], e.owner, Math.round(e.x), Math.round(e.y), Math.ceil(e.hp)];
      if (e.b) a.push(e.built ? 1 : 0, Math.floor((e.built ? (e.queue.length ? e.trainT / DEF[e.queue[0]].time : 0) : e.prog) * 100), e.queue.map(u => TI[u]), !e.built && this.tick - (e.wk ?? -99) > 8 ? 1 : 0);
      else a.push(e.carry ? 1 : 0, Math.max(0, Math.ceil(e.abT)), e.order ? 0 : 1);
      s.e.push(a);
    }
    return s;
  }
}
