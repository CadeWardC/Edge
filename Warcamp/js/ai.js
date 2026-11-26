// Computer opponent. It plays through the same sim.command() calls a human does.
import { DEF, MAXCAP, HEROES } from './data.js';

export class AI {
  // level: 0 easy, 1 normal, 2 hard
  constructor(sim, pid, level = 1) {
    this.s = sim; this.pid = pid;
    this.every = [30, 10, 10][level];   // ticks between decisions
    this.maxW = [6, 9, 11][level];      // workers it wants
    this.wave = [9, 6, 5][level];       // army size that triggers the first attack
    this.att = false;
  }
  update() {
    if ((this.s.tick + this.pid * 3) % this.every === 0) this.think();
  }
  think() {
    const s = this.s, pid = this.pid, me = s.players[pid];
    if (!me.alive || s.winner !== -1) return;
    const by = {};
    for (const e of s.ents.values()) if (e.owner === pid) (by[e.type] || (by[e.type] = [])).push(e);
    const g = t => by[t] || [];
    const cmd = c => s.command(pid, c);
    const hq = g('hq')[0], workers = g('worker');
    const near = (list, t) => list.reduce((b, w) => (!b || s.dist(w, t) < s.dist(b, t) ? w : b), null);

    for (const w of workers) if (!w.order) s.autoHarvest(w);
    // Keep some workers on wood (buildings cost it) and the rest on crystal (units cost it).
    const onWood = workers.filter(w => w.order && w.order.k === 'harvest' && w.order.kind === 2);
    const wantWood = me.wood < 200 ? Math.max(2, Math.ceil(workers.length * 0.4)) : me.wood > 500 ? 1 : Math.max(1, Math.round(workers.length * 0.25));
    if (onWood.length < wantWood) {
      const w = workers.find(w => w.order && w.order.k === 'harvest' && w.order.kind === 3);
      if (w && workers.length > 1) s.autoHarvest(w, 2);
    } else if (onWood.length > wantWood) s.autoHarvest(onWood[0], 3);

    // Never leave a building half finished.
    const unbuilt = ['hq', 'house', 'barracks', 'stable', 'tower', 'outpost'].flatMap(t => g(t).filter(b => !b.built));
    for (const b of unbuilt) {
      if (workers.some(w => w.order && w.order.k === 'build' && w.order.b === b.id)) continue;
      const w = near(workers.filter(w => !w.order || w.order.k !== 'build'), b);
      if (w) cmd({ t: 'assist', ids: [w.id], b: b.id });
    }

    if (hq && !hq.queue.length && workers.length < this.maxW) cmd({ t: 'train', b: hq.id, u: 'worker' });

    const army = [...g('soldier'), ...g('archer'), ...g('knight')];
    const racks = g('barracks');
    if (hq && !unbuilt.length && workers.length) {
      let want = null;
      if (me.cap - me.pop <= 2 && me.cap < MAXCAP) want = 'house';
      else if (!racks.length && workers.length >= 4) want = 'barracks';
      else if (!g('stable').length && racks.length && me.res >= 260) want = 'stable';
      else if (g('tower').length < 2 && army.length >= 4 && me.res >= 320) want = 'tower';
      else if (racks.length < 2 && me.res >= 500) want = 'barracks';
      let at = [hq.tx + 1, hq.ty + 1];
      if (!want && g('outpost').length < 2 && workers.length >= 6 && me.res >= 180) {
        // When the crystal being mined is a long walk from any drop-off, put an Outpost beside it.
        const w = workers.find(w => w.order && w.order.k === 'harvest');
        const far = w && !['hq', 'outpost'].some(t => g(t).some(b => b.built && Math.hypot(b.x / 32 - w.order.tx, b.y / 32 - w.order.ty) < 8));
        if (far) { want = 'outpost'; at = [w.order.tx, w.order.ty]; }
      }
      if (want && me.res >= DEF[want].cost && me.wood >= (DEF[want].wood || 0)) {
        const site = s.findSite(want, at[0], at[1]);
        const w = workers.find(w => !w.order || w.order.k === 'harvest');
        if (site && w) cmd({ t: 'build', ids: [w.id], b: want, tx: site[0], ty: site[1] });
      }
    }

    for (const b of racks) {
      if (b.built && b.queue.length < 2) cmd({ t: 'train', b: b.id, u: g('archer').length < g('soldier').length * 0.7 ? 'archer' : 'soldier' });
    }
    for (const b of g('stable')) if (b.built && b.queue.length < 1) cmd({ t: 'train', b: b.id, u: 'knight' });

    const hero = HEROES.flatMap(g)[0];
    const force = hero ? [...army, hero] : army;
    const idle = force.filter(u => !u.order).map(u => u.id);
    const home = hq || force[0];
    if (me.alert && s.tick - me.alert.tick < 40 && home && Math.hypot(me.alert.x - home.x, me.alert.y - home.y) < 520) {
      if (idle.length) cmd({ t: 'move', a: 1, ids: idle, x: me.alert.x, y: me.alert.y }); // defend the base
    } else if (!workers.length && me.res < DEF.worker.cost && idle.length) {
      const t = this.target(home); // nothing left to build with: throw everything at the enemy
      if (t) cmd({ t: 'move', a: 1, ids: idle, x: t.x, y: t.y });
    } else if (this.att) {
      if (army.length < 3) this.att = false;
      else if (idle.length) {
        const t = this.target(home);
        if (t) cmd({ t: 'move', a: 1, ids: idle, x: t.x, y: t.y });
      }
    } else if (army.length >= this.wave) {
      this.att = true;
      this.wave = Math.min(this.wave + 3, 22);
    }

    if (hero && hero.abT <= 0) {
      const ab = DEF[hero.type].ab;
      let foes = 0, friends = 0, hurt = 0;
      for (const t of s.ents.values()) {
        if (t.b || s.dist(hero, t) > ab.radius - 10) continue;
        if (s.enemy(hero, t)) foes++;
        else { friends++; if (t.hp < DEF[t.type].hp * 0.6) hurt++; }
      }
      if (ab.kind === 'shock' ? foes >= 2 : ab.kind === 'heal' ? hurt >= 2 : this.att && friends >= 4) cmd({ t: 'ability', id: hero.id });
    }
  }
  // The nearest enemy building, or any enemy at all if none is left standing.
  target(from) {
    const s = this.s;
    let best = null, bd = 1e9;
    for (const t of s.ents.values()) {
      if (!s.enemy(from, t)) continue;
      const d = s.dist(from, t) + (t.b ? 0 : 5000);
      if (d < bd) { bd = d; best = t; }
    }
    return best;
  }
}
