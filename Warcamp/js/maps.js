// Maps. Every battlefield is generated from the game's seed: one quarter is drawn, then mirrored four ways, so every
// player's corner is equal. Terrain: 0 grass, 1 water, 2 tree, 3 crystal. Only grass can be walked on: water is a
// wall (nothing sails yet), and trees and crystal are in the way until workers have gathered them.
// A map may also have a `deck` layer: grass tiles that are bridges. They are walked on like any ground, but nothing
// can be built on them.
import { MAP_SIZE } from './data.js';

export const TREE_AMT = 200, CRYSTAL_AMT = 1500;

// What the lobby offers. `classic` is the map every game used before there was a choice.
export const MAPS = [
  { id: 'classic', name: 'Open fields', about: 'Open ground with scattered woods and ponds.' },
  { id: 'island', name: 'Island', about: 'One big island. The sea cuts bays and coves into its shore, and narrow peninsulas hold extra crystal.' },
  { id: 'forest', name: 'Deep forest', about: 'Trees nearly everywhere: winding clearings, narrow paths, and plenty of wood.' },
  { id: 'rivers', name: 'Rivers and bridges', about: 'Four rivers cut the land into nine parts. The only ways across are the bridges.' },
];
export const mapOf = id => MAPS.find(m => m.id === id) || MAPS[0];

export function rng(a) {
  return () => {
    a |= 0; a = a + 0x6D2B79F5 | 0;
    let t = Math.imul(a ^ a >>> 15, 1 | a);
    t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
    return ((t ^ t >>> 14) >>> 0) / 4294967296;
  };
}

// The map a game is played on: { terrain, amt, base, base2, allies, deck }.
// base is the first base site of the top-left quarter, allies three more sites near it (used when cfg.cluster),
// base2 a site near the middle of the map (used when cfg.extra). All in tiles.
export function makeMap(cfg) {
  const N = cfg.size || MAP_SIZE, style = STYLES[cfg.map];
  return style ? build(style, cfg.seed, N, cfg.extra, cfg.cluster) : genMap(cfg.seed, N, cfg.extra, cfg.cluster);
}

// Copy a quarter into all four corners of the map.
function mirror(q, N, layer) {
  const Q = N >> 1, terrain = new Uint8Array(N * N), amt = new Uint16Array(N * N), deck = layer ? new Uint8Array(N * N) : null;
  for (let y = 0; y < Q; y++) for (let x = 0; x < Q; x++) {
    const v = q[y * Q + x];
    for (const [mx, my] of [[x, y], [N - 1 - x, y], [x, N - 1 - y], [N - 1 - x, N - 1 - y]]) {
      terrain[my * N + mx] = v;
      amt[my * N + mx] = v === 2 ? TREE_AMT : v === 3 ? CRYSTAL_AMT : 0;
      if (deck && layer[y * Q + x] && v === 0) deck[my * N + mx] = 1;
    }
  }
  return { terrain, amt, deck };
}

// ---------------------------------------------------------------- Open fields (the original map)
// The base sits at a different spot in its quarter each game.
export function genMap(seed, N, extra, cluster) {
  const r = rng(seed), Q = N >> 1, q = new Uint8Array(Q * Q), ri = n => (r() * n) | 0;
  const set = (x, y, t) => { if (x >= 0 && y >= 0 && x < Q && y < Q) q[y * Q + x] = t; };
  const blob = (t, x, y, n) => {
    for (let i = 0; i < n; i++) {
      set(x, y, t); set(x + 1, y, t);
      x = Math.max(0, Math.min(Q - 1, x + ri(3) - 1));
      y = Math.max(0, Math.min(Q - 1, y + ri(3) - 1));
    }
  };
  const k = (Q * Q) / 784; // how much bigger than the original 28-tile quarter
  const room = Math.floor(Q * 0.3) + 1;
  const bx = 9 + ri(room), by = 9 + ri(room);
  for (let i = 0; i < 8 * k; i++) blob(2, ri(Q), ri(Q), 10 + ri(14));
  for (let i = 0; i < 3 * k; i++) blob(1, ri(Q), ri(Q), 8 + ri(12));
  for (let i = 0; i < 2 * k; i++) blob(3, ri(Q), ri(Q), 3); // crystal out in the open, worth an Outpost or a new Keep
  // Clear the base, then carve roads so every base can always reach every other.
  for (let y = 0; y < Q; y++) for (let x = 0; x < Q; x++) if (Math.hypot(x - bx, y - by) < 6.5) q[y * Q + x] = 0;
  for (let x = bx; x < Q; x++) { set(x, by, 0); set(x, by + 1, 0); }
  for (let y = by; y < Q; y++) { set(bx, y, 0); set(bx + 1, y, 0); }
  for (let x = bx, y = by; x < Q - 1 || y < Q - 1;) { // a winding road to the middle of the map
    if (x < Q - 1 && (y >= Q - 1 || (Q - 1 - x) >= (Q - 1 - y))) x++; else y++;
    set(x, y, 0); set(x - 1, y, 0); set(x, y - 1, 0);
  }
  // Allies start near each other: three more base sites a short walk from the first, each with its own roads.
  const allies = [[bx + 15, by], [bx, by + 15], [bx + 15, by + 15]];
  if (cluster) for (const [ax, ay] of allies) {
    for (let y = 0; y < Q; y++) for (let x = 0; x < Q; x++) if (Math.hypot(x - ax, y - ay) < 6.5) q[y * Q + x] = 0;
    for (let x = ax; x < Q; x++) { set(x, ay, 0); set(x, ay + 1, 0); }
    for (let y = ay; y < Q; y++) { set(ax, y, 0); set(ax + 1, y, 0); }
    for (let x = bx; x <= ax; x++) { set(x, ay, 0); set(x, ay + 1, 0); } // and a road back to the first base
    for (let y = by; y <= ay; y++) { set(ax, y, 0); set(ax + 1, y, 0); }
  }
  // Guaranteed starting resources beside the base, and a contested deposit in the middle.
  for (let x = bx + 5; x <= bx + 7; x++) { set(x, by - 3, 3); set(x, by - 2, 3); }
  for (let x = bx - 4; x <= bx - 3; x++) { set(x, by + 11, 3); set(x, by + 12, 3); } // a second deposit a short walk away
  for (let x = bx - 5; x <= bx - 1; x++) { set(x, by + 6, 2); set(x, by + 7, 2); }
  if (cluster) for (const [ax, ay] of allies) { // the same start for every ally: crystal and trees by the base
    for (let x = ax + 5; x <= ax + 7; x++) { set(x, ay - 3, 3); set(x, ay - 2, 3); }
    for (let x = ax - 5; x <= ax - 1; x++) { set(x, ay + 6, 2); set(x, ay + 7, 2); }
  }
  for (const [x, y] of [[Q - 3, Q - 6], [Q - 2, Q - 6], [Q - 1, Q - 6], [Q - 6, Q - 3], [Q - 6, Q - 2], [Q - 6, Q - 1]]) set(x, y, 3);

  // With more than four players, each quarter gets a second base site nearer the middle of the map.
  const sx = Q - 13, sy = Q - 13;
  if (extra) {
    for (let y = 0; y < Q; y++) for (let x = 0; x < Q; x++) if (Math.hypot(x - sx, y - sy) < 6.5) q[y * Q + x] = 0;
    for (let x = sx; x < Q; x++) { set(x, sy, 0); set(x, sy + 1, 0); }
    for (let y = sy; y < Q; y++) { set(sx, y, 0); set(sx + 1, y, 0); }
    for (let x = sx - 8; x <= sx - 7; x++) for (let y = sy - 1; y <= sy + 1; y++) set(x, y, 3);
    for (let x = sx - 2; x <= sx + 2; x++) { set(x, sy - 8, 2); set(x, sy - 9, 2); }
  }
  return { ...mirror(q, N), base: [bx, by], base2: [sx, sy], allies };
}

// ---------------------------------------------------------------- the other maps
// They share one builder. A style says where bases may sit and paints the land (`paint`) and its roads (`roads`);
// the builder clears the base sites, lays the same starting resources as the original map, and makes sure every
// piece of open ground can be walked to.
function build(style, seed, N, extra, cluster) {
  const r = rng(seed), Q = N >> 1, q = new Uint8Array(Q * Q), ri = n => (r() * n) | 0;
  const keep = new Uint8Array(Q * Q); // rivers: clearings and resources leave these tiles alone, and a road over one is a bridge
  const inside = (x, y) => x >= 0 && y >= 0 && x < Q && y < Q;
  const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
  const c = {
    Q, q, keep, r, ri, clamp, k: (Q * Q) / 784,
    get: (x, y) => inside(x, y) ? q[y * Q + x] : -1,
    set(x, y, t) { if (inside(x, y)) q[y * Q + x] = t; },
    put(x, y, t) { if (inside(x, y) && !keep[y * Q + x]) q[y * Q + x] = t; },
    blob(t, x, y, n) {
      for (let i = 0; i < n; i++) {
        c.set(x, y, t); c.set(x + 1, y, t);
        x = clamp(x + ri(3) - 1, 0, Q - 1); y = clamp(y + ri(3) - 1, 0, Q - 1);
      }
    },
    disc(cx, cy, rad, t) {
      for (let y = Math.floor(cy - rad); y <= cy + rad; y++) for (let x = Math.floor(cx - rad); x <= cx + rad; x++) if (Math.hypot(x - cx, y - cy) < rad) c.put(x, y, t);
    },
    // A straight road two tiles wide between two points on one row or one column.
    road(x0, y0, x1, y1) {
      for (let x = Math.min(x0, x1); x <= Math.max(x0, x1); x++) for (let y = Math.min(y0, y1); y <= Math.max(y0, y1); y++) { c.set(x, y, 0); c.set(x0 === x1 ? x + 1 : x, x0 === x1 ? y : y + 1, 0); }
    },
    // A winding path two tiles wide: it drifts sideways now and then, but always arrives.
    trail(x0, y0, x1, y1) {
      let x = x0, y = y0;
      for (let n = 0; n < Q * 40; n++) {
        c.set(x, y, 0); c.set(x + 1, y, 0); c.set(x, y + 1, 0); c.set(x + 1, y + 1, 0);
        if (x === x1 && y === y1) break;
        const dx = Math.abs(x1 - x), dy = Math.abs(y1 - y);
        if (r() < .3) { if (ri(2)) x = clamp(x + ri(3) - 1, 1, Q - 1); else y = clamp(y + ri(3) - 1, 1, Q - 1); }
        else if (r() * (dx + dy) < dx) x += Math.sign(x1 - x); else y += Math.sign(y1 - y);
      }
    },
  };

  const [lo, room] = style.base(Q), gap = style.gap, bx = lo + ri(room), by = lo + ri(room);
  const allies = [[bx + gap, by], [bx, by + gap], [bx + gap, by + gap]];
  const sx = Q - style.mid, sy = sx;
  const info = { bx, by, sx, sy, allies: cluster ? allies : [], extra: !!extra };
  style.paint(c, info);
  for (const [x, y] of [[bx, by], ...info.allies, ...(extra ? [[sx, sy]] : [])]) c.disc(x, y, style.clear, 0);
  style.roads(c, info);

  // The same start as on the original map: crystal and trees by every base, a second deposit a short walk from
  // the first base, and a contested deposit in the middle.
  for (const [x, y] of [[bx, by], ...info.allies]) {
    for (let i = 5; i <= 7; i++) { c.put(x + i, y - 3, 3); c.put(x + i, y - 2, 3); }
    for (let i = -5; i <= -1; i++) { c.put(x + i, y + 6, 2); c.put(x + i, y + 7, 2); }
  }
  for (let x = bx - 4; x <= bx - 3; x++) { c.put(x, by + 11, 3); c.put(x, by + 12, 3); }
  for (const [x, y] of [[Q - 3, Q - 6], [Q - 2, Q - 6], [Q - 1, Q - 6], [Q - 6, Q - 3], [Q - 6, Q - 2], [Q - 6, Q - 1]]) c.put(x, y, 3);
  if (extra) {
    for (let x = sx - 8; x <= sx - 7; x++) for (let y = sy - 1; y <= sy + 1; y++) c.put(x, y, 3);
    for (let x = sx - 2; x <= sx + 2; x++) { c.put(x, sy - 8, 2); c.put(x, sy - 9, 2); }
  }

  // Open ground nobody could ever walk to is closed up, so nothing is placed or sent there.
  const seen = new Uint8Array(Q * Q), todo = [by * Q + bx];
  seen[todo[0]] = 1;
  while (todo.length) {
    const i = todo.pop(), x = i % Q, y = (i / Q) | 0;
    for (const [nx, ny] of [[x + 1, y], [x - 1, y], [x, y + 1], [x, y - 1]]) {
      const j = ny * Q + nx;
      if (inside(nx, ny) && !seen[j] && q[j] === 0) { seen[j] = 1; todo.push(j); }
    }
  }
  for (let i = 0; i < Q * Q; i++) if (q[i] === 0 && !seen[i]) q[i] = style.fill;

  return { ...mirror(q, N, keep.some(v => v) ? keep : null), base: [bx, by], base2: [sx, sy], allies };
}

// The roads of the original map: from each base straight to the two middle lines of the map (where they meet the
// roads of the neighbouring quarters), and one that winds to the very middle.
function plainRoads(c, { bx, by, sx, sy, allies, extra }) {
  const Q = c.Q;
  c.road(bx, by, Q - 1, by); c.road(bx, by, bx, Q - 1);
  for (let x = bx, y = by; x < Q - 1 || y < Q - 1;) {
    if (x < Q - 1 && (y >= Q - 1 || (Q - 1 - x) >= (Q - 1 - y))) x++; else y++;
    c.set(x, y, 0); c.set(x - 1, y, 0); c.set(x, y - 1, 0);
  }
  for (const [ax, ay] of allies) { c.road(bx, ay, Q - 1, ay); c.road(ax, by, ax, Q - 1); }
  if (extra) { c.road(sx, sy, Q - 1, sy); c.road(sx, sy, sx, Q - 1); }
}

const STYLES = {
  // One big island. In a quarter the sea lies along the two outer edges (x = 0 and y = 0).
  island: {
    base: Q => [20, Math.max(1, Math.floor(Q * 0.3) - 8)], gap: 15, mid: 13, clear: 6.5, fill: 1,
    paint(c, { bx, by }) {
      const { Q, ri, k } = c;
      for (let i = 0; i < 7 * k; i++) c.blob(2, ri(Q), ri(Q), 10 + ri(14));
      for (let i = 0; i < k; i++) c.blob(1, ri(Q), ri(Q), 5 + ri(6)); // a few ponds inland
      for (let i = 0; i < 2 * k; i++) c.blob(3, ri(Q), ri(Q), 3);
      // A ragged shore: how far the sea reaches in, tile by tile along each edge.
      const shore = () => { const d = []; for (let i = 0, v = 8; i < Q; i++) { if (i % 3 === 0) v = c.clamp(v + ri(3) - 1, 6, 11); d.push(v); } return d; };
      const west = shore(), north = shore(), R = 12; // R rounds off the corner of the island
      for (let y = 0; y < Q; y++) for (let x = 0; x < Q; x++) {
        const ex = x - west[y], ey = y - north[x];
        if (ex < 0 || ey < 0 || (ex < R && ey < R && Math.hypot(R - ex, R - ey) > R)) c.set(x, y, 1);
      }
      // A bay on each coast, towards the middle of that side of the map, never reaching the base...
      const bay = (along, reach, wide, west_) => {
        for (let a = -wide; a <= wide; a++) for (let b = 0; b <= reach; b++) {
          if ((a / wide) ** 2 + (b / reach) ** 2 < 1) west_ ? c.set(b, along + a, 1) : c.set(along + a, b, 1);
        }
      };
      const span = lo => lo + ri(Math.max(1, Q - 5 - lo));
      const wy = span(by + 20), nx = span(bx + 20);
      bay(wy, Math.min(west[c.clamp(wy, 0, Q - 1)] + 10 + ri(5), bx - 4), 4 + ri(3), true);
      bay(nx, Math.min(north[c.clamp(nx, 0, Q - 1)] + 10 + ri(5), by - 4), 4 + ri(3), false);
      // ...a few small coves...
      for (let i = 0; i < 3 * k; i++) { const a = 14 + ri(Q - 14), rad = 2.5 + ri(2); if (ri(2)) c.disc(west[a], a, rad, 1); else c.disc(north[a], a, rad, 1); }
      // ...and two peninsulas: a neck of land two tiles wide running out to sea, with crystal at its head.
      const py = by - 2, px = bx + 12;
      const sea = (x, y) => c.get(x, y) === 1; // each neck runs inland until it is on dry ground
      for (let x = 4; x < bx && (x <= west[py] + 1 || sea(x, py) || sea(x, py + 1)); x++) { c.set(x, py, 0); c.set(x, py + 1, 0); }
      c.disc(5, py + .5, 3.2, 0); c.set(3, py, 3); c.set(3, py + 1, 3); c.set(4, py - 2, 3);
      for (let y = 4; y < by && (y <= north[px] + 1 || sea(px, y) || sea(px + 1, y)); y++) { c.set(px, y, 0); c.set(px + 1, y, 0); }
      c.disc(px + .5, 5, 3.2, 0); c.set(px, 3, 3); c.set(px + 1, 3, 3); c.set(px - 2, 4, 3);
    },
    roads: plainRoads,
  },

  // Trees nearly everywhere. The clearings grow the way caves are drawn: scatter trees at random, then let every
  // tile follow its neighbours a few times, which leaves winding open pockets between solid woods.
  forest: {
    base: Q => [10, Math.floor(Q * 0.3)], gap: 16, mid: 13, clear: 7.5, fill: 2,
    paint(c) {
      const { Q, q, r, ri, k } = c;
      for (let i = 0; i < Q * Q; i++) q[i] = r() < .56 ? 2 : 0;
      for (let pass = 0; pass < 4; pass++) {
        const old = q.slice();
        for (let y = 0; y < Q; y++) for (let x = 0; x < Q; x++) {
          let n = 0;
          for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
            const nx = x + dx, ny = y + dy;
            // past the outer edges is solid forest; past the inner ones is this quarter's own mirror image
            if (nx < 0 || ny < 0 || old[Math.min(ny, Q - 1) * Q + Math.min(nx, Q - 1)] === 2) n++;
          }
          q[y * Q + x] = n >= 5 ? 2 : 0;
        }
      }
      for (let i = 0; i < 1.2 * k; i++) c.blob(1, ri(Q), ri(Q), 6 + ri(8)); // forest pools
      for (let i = 0; i < 3 * k; i++) { // crystal in the clearings
        let x = ri(Q), y = ri(Q);
        for (let t = 0; t < 40 && q[y * Q + x] !== 0; t++) { x = ri(Q); y = ri(Q); }
        c.blob(3, x, y, 3);
      }
    },
    // Narrow winding paths instead of straight roads: to the middle lines, to the middle (by way of the second
    // base site), and to a glade in the far corner, where the Horde can walk in.
    roads(c, { bx, by, sx, sy, allies, extra }) {
      const Q = c.Q;
      c.trail(bx, by, Q - 1, by); c.trail(bx, by, bx, Q - 1);
      c.trail(bx, by, sx, sy); c.trail(sx, sy, Q - 1, Q - 1);
      c.disc(4, 4, 2.6, 0); c.trail(4, 4, bx, by);
      for (const [ax, ay] of allies) { c.trail(bx, by, ax, ay); c.trail(ax, ay, Q - 1, ay); c.trail(ax, ay, ax, Q - 1); }
      if (extra) { c.trail(sx, sy, Q - 1, sy); c.trail(sx, sy, sx, Q - 1); }
    },
  },

  // Rivers. Each quarter has one running down and one running across; mirrored, that is two of each: nine pieces
  // of land. A road that crosses a river becomes a bridge, and there are no other ways over.
  rivers: {
    base: Q => [10, Math.max(1, Math.round(Q * 0.6) - 31)], gap: 12, mid: 10, clear: 6.5, fill: 2,
    paint(c) {
      const { Q, keep, ri, k } = c, mid = Math.round(Q * 0.6);
      for (let i = 0; i < 8 * k; i++) c.blob(2, ri(Q), ri(Q), 10 + ri(14));
      for (let i = 0; i < 2 * k; i++) c.blob(3, ri(Q), ri(Q), 3);
      const course = () => { const d = []; for (let i = 0, v = mid; i < Q; i++) { if (i % 4 === 0) v = c.clamp(v + ri(3) - 1, mid - 2, mid + 2); d.push(v); } return d; };
      const down = course(), across = course();
      const wet = (x, y) => { c.set(x, y, 1); if (x >= 0 && y >= 0 && x < Q && y < Q) keep[y * Q + x] = 1; };
      for (let i = 0; i < Q; i++) for (let w = -1; w <= 1; w++) { wet(down[i] + w, i); wet(i, across[i] + w); }
    },
    // Four crossings in each quarter: the base's two roads each cross one river into the land beside it, and two
    // more roads lead on from there over the other river into the middle of the map.
    roads(c, { bx, by, allies }) {
      const Q = c.Q, in_ = Q - 8;
      c.road(bx, by, Q - 1, by); c.road(bx, by, bx, Q - 1);
      c.road(bx, in_, Q - 1, in_); c.road(in_, by, in_, Q - 1);
      for (const [ax, ay] of allies) { c.road(bx, ay, ax, ay); c.road(ax, by, ax, ay); } // allies share the first base's bridges
    },
  },
};
