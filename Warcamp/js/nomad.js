// Nomad mode. Nobody has a base: each player leads a hero and a party away from the starting point, and the score is
// how far from it they get. Everything hostile belongs to The Horde:
//   camps    put on the map when the game starts. Most lie in wait (an ambush); every third one walks a beat (a patrol).
//            The camp at the far end of the land is led by a Warlord.
//   waves    sent after the party each time it pushes further out than ever before, and when it dawdles.
// The run ends when every hero has fallen (a hero has no Keep to return to), or when the camp at the far end is cleared.
// Like the rest of the simulation this has no DOM or network code; sim.js calls the three functions below.
import { TILE as T, DEF, NOMAD } from './data.js';
import { rng } from './maps.js';

const tiles = (e, x, y) => Math.hypot(e.x / T - (x + .5), e.y / T - (y + .5));
const seats = sim => sim.players.filter(p => !p.horde).length;

// Put one of the Horde on (or right beside) a tile.
function foe(sim, type, tx, ty, mul, tag, rnd) {
  let x = (tx + .5) * T + (rnd() - .5) * 44, y = (ty + .5) * T + (rnd() - .5) * 44;
  if (!sim.walkable(sim.tileOf(x), sim.tileOf(y))) { x = (tx + .5) * T; y = (ty + .5) * T; }
  const e = sim.spawnUnit(type, sim.hordeId, x, y);
  e.mul = mul; e.hp = sim.maxHp(e);
  return Object.assign(e, tag);
}
function march(sim, e, x, y) {
  e.order = { k: 'amove', x, y, tries: 0 };
  sim.pathPoint(e, x, y);
}

export function startNomad(sim, cfg) {
  const N = sim.N, [ox, oy] = sim.base, gx = N - 1 - ox, gy = N - 1 - oy, n = seats(sim), rnd = rng(cfg.seed ^ 0x4e6f6d);
  const ri = k => (rnd() * k) | 0;
  // ox, oy: where the journey starts. gx, gy: the far end of the land. far: the distance between them, in tiles.
  const nm = sim.nomad = { ox, oy, gx, gy, far: Math.floor(Math.hypot(gx - ox, gy - oy)), best: 0, wave: 0, waveT: 0, mark: 0, kills: 0, cleared: 0, won: 0, camps: [], ev: [] };

  // The parties, side by side around the starting point.
  let seat = 0;
  const stand = e => {
    if (sim.walkable(sim.tileOf(e.x), sim.tileOf(e.y))) return;
    const s = sim.nearFree(sim.tileOf(e.x), sim.tileOf(e.y));
    if (s) { e.x = (s[0] + .5) * T; e.y = (s[1] + .5) * T; }
  };
  sim.players.forEach((p, i) => {
    if (p.horde) return;
    const a = seat++ / n * Math.PI * 2, off = n > 1 ? 3.5 * T : 0;
    const cx = (ox + .5) * T + Math.cos(a) * off, cy = (oy + .5) * T + Math.sin(a) * off;
    stand(sim.spawnUnit(p.hero, i, cx, cy));
    NOMAD.party.forEach((type, j) => { const b = j / NOMAD.party.length * Math.PI * 2; stand(sim.spawnUnit(type, i, cx + Math.cos(b) * 44, cy + Math.sin(b) * 44)); });
  });

  // The camps: on open ground that can be walked to, spread out, and not on top of the start.
  const open = (x, y) => x >= 0 && y >= 0 && x < N && y < N && sim.reach[y * N + x] && sim.walkable(x, y);
  const roomy = (x, y) => { let k = 0; for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) if (open(x + dx, y + dy)) k++; return open(x, y) && k >= 7; };
  const camp = (x, y, k) => {
    const f = Math.min(1, Math.hypot(x - ox, y - oy) / nm.far), c = { x, y, k, s: 0, done: 0 };
    if (k === 1) { // a patrol walks between its camp and a second point
      for (let t = 0; t < 30 && c.px == null; t++) { const px = x + ri(25) - 12, py = y + ri(25) - 12; if (open(px, py) && Math.hypot(px - x, py - y) >= 6) { c.px = px; c.py = py; } }
      if (c.px == null) c.k = 0;
    }
    const id = nm.camps.push(c) - 1, kinds = NOMAD.campKinds.filter(u => f >= u[1]).map(u => u[0]), mul = NOMAD.campStrength(f, n, sim.lv);
    for (let i = NOMAD.camp(f, n, sim.lv); i > 0; i--) foe(sim, kinds[ri(kinds.length)], x, y, mul, { camp: id }, rnd);
    if (k === 2) foe(sim, 'boss', x, y, NOMAD.boss(NOMAD.bossEvery * 3, n, sim.lv), { camp: id }, rnd);
  };
  const want = Math.round(NOMAD.camps * (N / NOMAD.map) ** 2);
  for (let t = 0; t < want * 80 && nm.camps.length < want; t++) {
    const x = 2 + ri(N - 4), y = 2 + ri(N - 4);
    if (!roomy(x, y) || Math.hypot(x - ox, y - oy) < NOMAD.safe || Math.hypot(x - gx, y - gy) < NOMAD.spacing) continue;
    if (nm.camps.some(c => Math.hypot(c.x - x, c.y - y) < NOMAD.spacing)) continue;
    camp(x, y, nm.camps.length % 3 === 2 ? 1 : 0);
  }
  const end = open(gx, gy) ? [gx, gy] : sim.nearFree(gx, gy) || [gx, gy];
  camp(end[0], end[1], 2);
}

// Called by the simulation every tick.
export function stepNomad(sim) {
  const nm = sim.nomad, H = sim.hordeId, t = sim.tick;
  if (t % 5 !== 0) return;
  const heroes = [];
  for (const e of sim.ents.values()) if (e.owner !== H && DEF[e.type].hero) heroes.push(e);
  if (!heroes.length) return; // every hero has fallen: the win check ends the run

  // How far the leading hero is from the start.
  let lead = heroes[0];
  for (const h of heroes) if (tiles(h, nm.ox, nm.oy) > tiles(lead, nm.ox, nm.oy)) lead = h;
  nm.best = Math.max(nm.best, Math.floor(tiles(lead, nm.ox, nm.oy)));

  // Camps: one is sprung the moment any of its members picks a fight, and cleared when the last of them falls.
  const alive = nm.camps.map(() => 0), hot = [];
  for (const e of sim.ents.values()) {
    if (e.owner !== H || e.camp == null) continue;
    alive[e.camp]++;
    if (!nm.camps[e.camp].s && e.order && e.order.k === 'attack') hot[e.camp] = e;
  }
  nm.camps.forEach((c, id) => {
    if (c.done) return;
    if (!alive[id]) {
      c.done = 1; nm.cleared++; reward(sim, c, heroes);
      // The camp at the far end was the last thing in the way: the journey is complete.
      if (c.k === 2) { nm.won = 1; nm.best = Math.max(nm.best, nm.far); sim.winner = sim.players[lead.owner].team; }
      return;
    }
    const first = hot[id], tg = first && sim.ents.get(first.order.target);
    if (!tg) return;
    c.s = 1;
    nm.ev.push(['a', c.k]);
    // the whole camp joins in, wherever its members were standing
    for (const e of sim.ents.values()) if (e.owner === H && e.camp === id && !(e.order && e.order.k === 'attack')) march(sim, e, tg.x, tg.y);
  });

  // A new wave: the party has pushed further out than ever, or has been left alone for too long.
  if (t % 10 === 0) {
    const since = (t - nm.waveT) / 10, mark = Math.floor(nm.best / NOMAD.step);
    if (since >= NOMAD.minGap && (mark > nm.mark || since >= NOMAD.patience)) { nm.mark = Math.max(nm.mark, mark); nm.wave++; nm.waveT = t; sendWave(sim, lead); }
  }

  // Every few seconds, whoever is standing about gets moving again: hunters after the nearest hero, patrols along their beat.
  if (t % 30 !== 0) return;
  for (const e of sim.ents.values()) {
    if (e.owner !== H || e.order) continue;
    const c = e.camp != null ? nm.camps[e.camp] : null;
    if (e.hunt) {
      let near = heroes[0];
      for (const h of heroes) if (Math.hypot(h.x - e.x, h.y - e.y) < Math.hypot(near.x - e.x, near.y - e.y)) near = h;
      march(sim, e, near.x, near.y);
    } else if (c && c.k === 1) {
      e.leg = e.leg ? 0 : 1;
      march(sim, e, ((e.leg ? c.px : c.x) + .5) * T, ((e.leg ? c.py : c.y) + .5) * T);
    }
  }
}

// Two groups appear out of sight on opposite sides of the leading hero and come for the party.
function sendWave(sim, lead) {
  const nm = sim.nomad, n = nm.wave, N = sim.N, H = sim.hordeId, rnd = rng(sim.tick * 31 + n * 7919);
  const players = sim.players.filter(p => !p.horde && p.alive).length || 1;
  let have = 0;
  for (const e of sim.ents.values()) if (e.owner === H && e.hunt) have++;
  const count = Math.max(0, Math.min(NOMAD.wave(n, players, sim.lv), NOMAD.limit - have));
  const mul = NOMAD.strength(n, players, sim.lv), kinds = NOMAD.hunters.filter(u => n >= u[1]).map(u => u[0]);
  const hx = sim.tileOf(lead.x), hy = sim.tileOf(lead.y), a0 = rnd() * Math.PI * 2;
  const spot = a => { // open ground in that direction: as far out as the ring if possible, nearer if not
    for (let R = NOMAD.ring; R >= 6; R -= 3) for (let k = 0; k < 9; k++) {
      const b = a + (k % 2 ? -1 : 1) * Math.ceil(k / 2) * .35, x = Math.round(hx + Math.cos(b) * R), y = Math.round(hy + Math.sin(b) * R);
      if (x >= 0 && y >= 0 && x < N && y < N && sim.reach[y * N + x] && sim.walkable(x, y)) return [x, y];
    }
    return [hx, hy];
  };
  const at = [spot(a0), spot(a0 + Math.PI)];
  const put = (type, m, i) => march(sim, foe(sim, type, at[i % 2][0], at[i % 2][1], m, { hunt: 1 }, rnd), lead.x, lead.y);
  for (let i = 0; i < count; i++) put(kinds[(rnd() * kinds.length) | 0], mul, i);
  const boss = n % NOMAD.bossEvery === 0;
  if (boss) put('boss', NOMAD.boss(n, players, sim.lv), 0);
  nm.ev.push(['w', n, boss ? 1 : 0]);
}

// A cleared camp: its captives join the party of the nearest hero, and that party catches its breath.
function reward(sim, c, heroes) {
  const nm = sim.nomad, cx = (c.x + .5) * T, cy = (c.y + .5) * T;
  let hero = heroes[0];
  for (const h of heroes) if (Math.hypot(h.x - cx, h.y - cy) < Math.hypot(hero.x - cx, hero.y - cy)) hero = h;
  const pid = hero.owner, mine = [];
  for (const e of sim.ents.values()) if (e.owner === pid && !e.b) mine.push(e);
  for (const e of mine) {
    if (Math.hypot(e.x - cx, e.y - cy) > 14 * T) continue;
    const max = sim.maxHp(e), got = Math.min(max - e.hp, max * NOMAD.mend);
    if (got >= 1) { e.hp += got; sim.fx.push(['q', e.x | 0, e.y | 0], ['n', e.x | 0, e.y | 0, Math.round(got), 1]); }
  }
  const f = Math.min(1, Math.hypot(c.x - nm.ox, c.y - nm.oy) / nm.far), pool = NOMAD.recruits.slice(0, 3 + Math.round(f * (NOMAD.recruits.length - 3)));
  const give = Math.max(0, Math.min(c.k === 1 ? 1 : 2, NOMAD.cap - (mine.length - 1)));
  const s = sim.walkable(c.x, c.y) ? [c.x, c.y] : sim.nearFree(c.x, c.y) || [c.x, c.y];
  for (let j = 0; j < give; j++) sim.spawnUnit(pool[(nm.cleared * 3 + c.x + j * 5) % pool.length], pid, (s[0] + .5) * T + j * 14 - 7, (s[1] + .5) * T);
  nm.ev.push(['c', pid, give]);
}

// What every screen is told each tick. The events (a wave, an ambush sprung, a camp cleared) are sent once.
// [0] furthest distance so far, [1] waves sent, [2] the distance that sets off the next wave, [3] enemies defeated,
// [4] camps cleared, [5] camps on the map, [6] events, [7] 1 once the camp at the far end has been cleared
export function nomadSnap(sim) {
  const nm = sim.nomad, ev = nm.ev;
  nm.ev = [];
  return [nm.best, nm.wave, (nm.mark + 1) * NOMAD.step, nm.kills, nm.cleared, nm.camps.length, ev, nm.won];
}
