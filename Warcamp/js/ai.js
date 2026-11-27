// Computer opponent. It plays through the same sim.command() calls a human does.
//
// How it thinks, every second or so (every three seconds on Easy):
//   economy   workers on crystal and wood, housing, Barracks, Arsenal, towers on the side the enemy is on
//   army      what to train is weighed against what the enemy has (Guards against Riders, Riders against archers
//             and Mages, Catapults against towers), with Clerics to keep it alive
//   staging   troops gather at a point in front of the base instead of standing where they were trained
//   attack    it picks the nearest, weakest enemy and marches as one group; reinforcements follow in batches, not
//             one at a time
//   retreat   an attack that is being lost is called off, and the survivors come home to rebuild
//   defence   everyone at home turns on raiders; a big raid calls the army back from the front
// Easy does the simple version of each (small economy, fixed army mix, never retreats until almost wiped out);
// Normal does all of it; Hard also sizes up the enemy before attacking, pulls a hurt hero out, and expands.
import { DEF, MAXCAP, HEROES, KEEP_LIMIT, TILE as T } from './data.js';

const FIGHTERS = ['soldier', 'archer', 'knight', 'guard', 'mage', 'catapult'];

export class AI {
  // level: 0 easy, 1 normal, 2 hard
  constructor(sim, pid, level = 1) {
    this.s = sim; this.pid = pid; this.level = level;
    this.every = [30, 10, 10][level];   // ticks between decisions
    this.maxW = [6, 11, 14][level];     // workers it wants
    this.wave = [10, 6, 6][level];       // army size that triggers the first attack
    this.batch = [3, 4, 5][level];      // reinforcements leave home in groups of at least this many
    this.att = false;                   // is an attack under way?
    this.launch = 0;                    // how big the army was when it set out
    this.foe = -1;                      // which player it is attacking
    this.rest = false;                  // is the hero pulled back to recover?
    this.grit = 0;                      // attacks called off so far: each one makes it harder to scare off again
  }
  // What a saved game must keep to carry on mid-attack; put back with Object.assign(ai, state).
  state() { return { att: this.att, wave: this.wave, launch: this.launch, foe: this.foe, rest: this.rest, grit: this.grit }; }
  update() {
    if ((this.s.tick + this.pid * 3) % this.every === 0) this.think();
  }
  think() {
    const s = this.s, pid = this.pid, me = s.players[pid], L = this.level;
    if (!me.alive || s.winner !== -1) return;
    const by = {}, foes = [], self = { owner: pid };
    for (const e of s.ents.values()) {
      if (e.owner === pid) (by[e.type] || (by[e.type] = [])).push(e);
      else if (s.enemy(self, e)) foes.push(e);
    }
    const g = t => by[t] || [];
    const cmd = c => s.command(pid, c);
    const hq = g('hq')[0], workers = g('worker');
    const near = (list, t) => list.reduce((b, w) => (!b || s.dist(w, t) < s.dist(b, t) ? w : b), null);
    const far = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);

    // ---------------------------------------------------------------- economy
    // With no Keep or Outpost there is nowhere to bring anything. If a new Keep cannot be paid for either, the base
    // is lost for good: the workers stop gathering and join the last stand further down.
    const depot = hq || g('outpost').some(b => b.built);
    const canKeep = me.keeps < KEEP_LIMIT && me.res >= DEF.hq.cost && me.wood >= DEF.hq.wood;
    const lost = !depot && !canKeep;
    for (const w of workers) if (!w.order && !lost) s.autoHarvest(w);
    // Keep some workers on wood (buildings cost it) and the rest on crystal (units cost it).
    const onWood = workers.filter(w => w.order && w.order.k === 'harvest' && w.order.kind === 2);
    const wantWood = me.wood < 200 ? Math.max(2, Math.ceil(workers.length * 0.4)) : me.wood > 500 ? 1 : Math.max(1, Math.round(workers.length * 0.25));
    if (onWood.length < wantWood) {
      const w = workers.find(w => w.order && w.order.k === 'harvest' && w.order.kind === 3);
      if (w && workers.length > 1) s.autoHarvest(w, 2);
    } else if (onWood.length > wantWood) s.autoHarvest(onWood[0], 3);

    // Never leave a building half finished.
    const unbuilt = ['hq', 'house', 'barracks', 'stable', 'tower', 'outpost', 'workshop', 'sanctum', 'wall'].flatMap(t => g(t).filter(b => !b.built));
    for (const b of unbuilt) {
      if (workers.some(w => w.order && w.order.k === 'build' && w.order.b === b.id)) continue;
      const w = near(workers.filter(w => !w.order || w.order.k !== 'build'), b);
      if (w) cmd({ t: 'assist', ids: [w.id], b: b.id });
    }

    // Mend buildings once the fighting near them has stopped.
    if (!me.alert || s.tick - me.alert.tick > 80) {
      for (const t of Object.keys(by)) for (const b of by[t]) {
        if (!b.b || !b.built || b.hp > DEF[b.type].hp * 0.75 || DEF[b.type].wall) continue;
        if (!workers.some(w => w.order && w.order.k === 'repair' && w.order.b === b.id)) cmd({ t: 'repair', b: b.id });
        break;
      }
    }

    for (const k of g('hq')) if (k.built && !k.queue.length && workers.length < this.maxW) { cmd({ t: 'train', b: k.id, u: 'worker' }); break; }
    // The last Keep has fallen, but there are workers and enough in store: build a new one beside them.
    if (!hq && workers.length && canKeep) {
      const w = workers[0], site = s.findSite('hq', s.tileOf(w.x), s.tileOf(w.y));
      if (site) cmd({ t: 'build', ids: workers.slice(0, 3).map(w => w.id), b: 'hq', tx: site[0], ty: site[1] });
    }

    // ---------------------------------------------------------------- the enemy, and where to face them
    const fighters = FIGHTERS.flatMap(g), army = [...fighters, ...g('cleric')];
    const hero = HEROES.flatMap(g)[0];
    const home = hq || army[0] || hero;
    // Who to go for: the enemy whose nearest building is closest, counting each of their fighters as two more tiles.
    // (The Horde has no buildings: against it the computer only defends.)
    const sides = new Map();
    for (const f of foes) {
      let o = sides.get(f.owner);
      if (!o) sides.set(f.owner, o = { id: f.owner, mil: 0, near: 1e9, b: 0 });
      if (f.b) { o.b++; if (home) o.near = Math.min(o.near, far(home, f)); } else if (DEF[f.type].mil) o.mil++;
    }
    let foe = sides.get(this.foe);
    if (!foe || !foe.b || !this.att) {
      foe = null;
      for (const o of sides.values()) if (o.b && (!foe || o.near / T + o.mil * 2 < foe.near / T + foe.mil * 2)) foe = o;
      this.foe = foe ? foe.id : -1;
    }
    // The staging point: a few tiles out from the Keep, towards that enemy (or towards whoever is nearest).
    let stage = null;
    if (hq) {
      const to = near(foes.filter(f => foe ? f.owner === foe.id && f.b : true), hq);
      const d = to ? far(hq, to) || 1 : 1, ux = to ? (to.x - hq.x) / d : 0, uy = to ? (to.y - hq.y) / d : 1;
      const tx = s.tileOf(hq.x + ux * 7 * T), ty = s.tileOf(hq.y + uy * 7 * T), spot = s.walkable(tx, ty) ? [tx, ty] : s.nearFree(tx, ty) || [tx, ty];
      stage = { x: (spot[0] + .5) * T, y: (spot[1] + .5) * T };
    }

    // ---------------------------------------------------------------- building
    const racks = g('barracks');
    if (hq && !unbuilt.length && workers.length) {
      let want = null, at = [hq.tx + 1, hq.ty + 1], gift;
      if (me.cap - me.pop <= 2 && me.cap < MAXCAP) want = 'house';
      else if (!racks.length && workers.length >= 4) want = 'barracks';
      else if (fighters.length >= 4 && me.res >= DEF.hq.cost && me.wood >= DEF.hq.wood && s.players.some((q, i) => s.canRevive(pid, i))) {
        want = 'hq'; gift = s.players.findIndex((q, i) => s.canRevive(pid, i)); // Survival: bring a fallen ally back
        at = [hq.tx + 1 + (pid % 2 ? 9 : -9), hq.ty + 1];
      }
      else if (g('tower').length < [1, 2, 3][L] && fighters.length >= 4 && me.res >= 320) {
        want = 'tower';
        if (stage && L > 0) at = [s.tileOf((hq.x + stage.x) / 2), s.tileOf((hq.y + stage.y) / 2)]; // on the side the enemy will come from
      }
      else if (!g('workshop').length && racks.some(b => b.built) && fighters.length >= 5 && me.res >= 300) want = 'workshop';
      else if (racks.length < 2 && me.res >= 500) want = 'barracks';
      else if (L > 0 && racks.length < 3 && me.res >= [0, 800, 500][L]) want = 'barracks'; // a third one once crystal is piling up
      else if (L === 2 && g('hq').length === 1 && me.keeps < KEEP_LIMIT && fighters.length >= 8 && me.res >= DEF.hq.cost + 400 && me.wood >= DEF.hq.wood + 150) {
        // Hard: a second base by the nearest crystal that is a real walk from the first.
        const N = s.N, cx = s.tileOf(hq.x), cy = s.tileOf(hq.y);
        let best = null, bd = 1e9;
        for (let y = Math.max(0, cy - 34); y <= Math.min(N - 1, cy + 34); y += 2) for (let x = Math.max(0, cx - 34); x <= Math.min(N - 1, cx + 34); x += 2) {
          const d = Math.hypot(x - cx, y - cy);
          if (s.terrain[y * N + x] === 3 && d >= 14 && d < bd && !foes.some(f => f.b && Math.hypot(f.x / T - x, f.y / T - y) < 18)) { bd = d; best = [x, y]; }
        }
        if (best) { want = 'hq'; at = best; }
      }
      if (!want && g('outpost').length < 2 && workers.length >= 6 && me.res >= 180) {
        // When the crystal being mined is a long walk from any drop-off, put an Outpost beside it.
        const w = workers.find(w => w.order && w.order.k === 'harvest');
        const walk = w && !['hq', 'outpost'].some(t => g(t).some(b => b.built && Math.hypot(b.x / 32 - w.order.tx, b.y / 32 - w.order.ty) < 8));
        if (walk) { want = 'outpost'; at = [w.order.tx, w.order.ty]; }
      }
      if (want && me.res >= DEF[want].cost && me.wood >= (DEF[want].wood || 0)) {
        const site = s.findSite(want, at[0], at[1]);
        const w = workers.find(w => !w.order || w.order.k === 'harvest');
        if (site && w && (DEF[want].anywhere || s.nearKeep(pid, want, site[0], site[1]))) cmd(gift === undefined ? { t: 'build', ids: [w.id], b: want, tx: site[0], ty: site[1] } : { t: 'build', ids: [w.id], b: want, tx: site[0], ty: site[1], for: gift });
      }
    }

    // ---------------------------------------------------------------- training
    // A share of the army for each kind, shifted by what the enemy has brought (not on Easy).
    const share = { soldier: 1, archer: .7, knight: .5, guard: .4 };
    const theirs = foes.filter(f => !f.b && DEF[f.type].mil && (!foe || f.owner === foe.id));
    if (L > 0 && theirs.length >= 4) {
      const part = ts => theirs.filter(f => ts.includes(f.type)).length / theirs.length;
      if (part(['knight']) > .25) { share.guard = 1.1; share.knight = .3; }   // Guards stop Riders
      if (part(['archer', 'mage']) > .4) share.knight = Math.max(share.knight, 1); // Riders run down the ones at the back
    }
    const total = Object.values(share).reduce((a, b) => a + b, 0), n = t => g(t).length, line = n('soldier') + n('archer') + n('knight') + n('guard');
    for (const b of racks) {
      if (!b.built || b.queue.length >= 2) continue;
      let pick = 'soldier', gap = -1e9;
      for (const t of Object.keys(share)) {
        const d = share[t] / total - n(t) / (line + 1);
        if (d > gap && (t !== 'knight' || me.res >= 200)) { gap = d; pick = t; }
      }
      cmd({ t: 'train', b: b.id, u: pick });
    }
    const towers = foes.filter(f => f.type === 'tower' && (!foe || f.owner === foe.id)).length;
    for (const b of g('workshop')) {
      if (!b.built || b.queue.length) continue;
      const clerics = L === 0 ? 1 : Math.min(3, Math.floor(fighters.length / 6)), cats = L > 0 && towers >= 3 ? 4 : 2;
      cmd({ t: 'train', b: b.id, u: n('cleric') < clerics ? 'cleric' : n('mage') < 4 ? 'mage' : n('catapult') < cats ? 'catapult' : 'mage' });
    }

    // ---------------------------------------------------------------- the army
    // A badly hurt hero comes home until it has recovered (not on Easy).
    const force = army.slice();
    if (hero) {
      const hp = hero.hp / s.maxHp(hero);
      if (hp < .35) this.rest = true; else if (hp > .75) this.rest = false;
      if (this.rest && L > 0 && hq && far(hero, hq) > 6 * T) { if (!(hero.order && hero.order.k === 'move')) cmd({ t: 'move', ids: [hero.id], x: hq.x, y: hq.y + 2.5 * T }); }
      else if (!this.rest || L === 0) force.push(hero);
    }
    if (lost) force.push(...workers);
    const idle = force.filter(u => !u.order).map(u => u.id);
    // Is a unit already on its way to (about) this spot? Then it is left alone, so it is not re-routed every second.
    const going = (u, p) => u.order && (u.order.k === 'attack' || ((u.order.k === 'amove' || u.order.k === 'move') && Math.hypot(u.order.x - p.x, u.order.y - p.y) < 4 * T));
    const send = (list, p, march) => { const ids = list.filter(u => !going(u, p)).map(u => u.id); if (ids.length) cmd({ t: 'move', a: march ? 0 : 1, ids, x: p.x, y: p.y }); };
    const away = home ? force.filter(u => far(u, home) > 14 * T) : [], here = force.filter(u => !away.includes(u));
    // Raiders: enemy troops close to the Keep, or right on top of any building.
    const mine = Object.keys(by).flatMap(t => by[t]).filter(e => e.b);
    const raid = foes.filter(f => !f.b && DEF[f.type].dmg && ((hq && far(f, hq) < 15 * T) || mine.some(b => far(f, b) < 7 * T)));

    if (lost || (!workers.length && me.res < DEF.worker.cost)) {
      // nothing left to build with: throw everything at the enemy
      const t = home && this.target(home);
      if (t && idle.length) cmd({ t: 'move', a: 1, ids: idle, x: t.x, y: t.y });
    } else if (raid.length && home) {
      const t = near(raid, home);
      send(here, t);
      // a raid this size is more than the troops at home can handle: the army comes back (not on Easy)
      if (L > 0 && this.att && away.length && raid.length >= here.length + 4) { this.att = false; send(away, t); }
    } else if (this.att) {
      const front = away.length ? away : here, cx = front.reduce((a, u) => a + u.x, 0) / (front.length || 1), cy = front.reduce((a, u) => a + u.y, 0) / (front.length || 1);
      const t = front.length && this.target({ owner: pid, x: cx, y: cy }, foe ? foe.id : -1);
      // Call it off when most of the army is gone, or (not on Easy) when the front is badly outnumbered where it stands.
      const facing = L > 0 && away.length ? foes.filter(f => (f.b ? DEF[f.type].dmg : DEF[f.type].mil && DEF[f.type].dmg) && Math.hypot(f.x - cx, f.y - cy) < 9 * T).length : 0;
      const beaten = fighters.length < Math.max(3, this.launch * [.25, .35, .45][L]) || (facing && fighters.length < 20 && facing > away.length * ([0, 2.2, 1.6][L] + .5 * this.grit) + 2);
      if (!t || beaten) {
        this.att = false;
        if (beaten) this.grit++;
        if (stage && away.length) send(away, stage, true); // walk home without stopping to fight
      } else {
        send(away.filter(u => !u.order), t);
        // those at home set out together: all of them at the start, later only once a batch has gathered
        const ready = here.filter(u => !(u.order && u.order.k === 'attack'));
        if (!away.length || ready.length >= this.batch) send(ready, t);
        else if (stage) send(ready.filter(u => !u.order && far(u, stage) > 5 * T), stage);
      }
    } else {
      // Building up. Troops wait together at the staging point.
      if (stage) send(here.filter(u => !u.order && far(u, stage) > 5 * T), stage);
      if (away.length && stage) send(away.filter(u => !u.order), stage, true);
      const full = me.pop >= Math.min(me.cap, MAXCAP) - 1 && me.cap >= MAXCAP;
      // Hard looks before it leaps: no attack on an enemy with a clearly bigger army, unless there is no room left to grow.
      const outgunned = L === 2 && foe && foe.mil > fighters.length * 1.25 && fighters.length < 20 && !full;
      // ...and they set out only once most of them have arrived there.
      const gathered = !stage || fighters.filter(u => far(u, stage) < 7 * T).length >= fighters.length * .75;
      if (foe && !outgunned && gathered && (fighters.length >= this.wave || (full && fighters.length >= 5))) {
        this.att = true;
        this.launch = fighters.length;
        this.wave = Math.min(this.wave + 3, 22);
      } else if (!foe && foes.length && home) {
        // Only the Horde is out there: meet whatever comes within reach of the base, and no further.
        const t = near(foes.filter(f => far(f, home) < 30 * T), home);
        if (t) send(here.filter(u => !u.order), t);
      }
    }

    if (hero) DEF[hero.type].abs.forEach((ab, k) => {
      if (me.lvl < ab.lvl || hero.cds[k] > 0) return;
      let close = 0, friends = 0, hurt = 0, big = 0;
      for (const t of s.ents.values()) {
        if (t.b || s.dist(hero, t) > ab.radius - 10) continue;
        if (s.enemy(hero, t)) { close++; if (t.hp > 80) big++; }
        else { friends++; if (t.hp < s.maxHp(t) * 0.6) hurt++; }
      }
      const go = { shock: close >= 2, snipe: big >= 1, heal: hurt >= 2, haste: this.att && friends >= 4, rage: close >= 2 && friends >= 3, ward: close >= 2 && friends >= 3 }[ab.kind];
      if (go) cmd({ t: 'ability', id: hero.id, n: k });
    });
  }
  // The nearest enemy building (of one player, if given: what fights back first, walls last), or any enemy at all
  // if none is left standing.
  target(from, owner = -1) {
    const s = this.s;
    let best = null, bd = 1e9;
    for (const t of s.ents.values()) {
      if (!s.enemy(from, t)) continue;
      const d = s.dist(from, t) + (t.b ? (DEF[t.type].wall ? 2500 : 0) : 5000) + (owner >= 0 && t.owner !== owner ? 20000 : 0);
      if (d < bd) { bd = d; best = t; }
    }
    return best;
  }
}
