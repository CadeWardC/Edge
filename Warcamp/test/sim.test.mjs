// Headless check: node Warcamp/test/sim.test.mjs
// Plays whole AI-vs-AI games with no browser and fails on any exception or a game that never ends.
import { Sim, genMap } from '../js/sim.js';
import { AI } from '../js/ai.js';

let failed = 0;
const check = (ok, msg) => { if (!ok) { failed++; console.error('FAIL', msg); } else console.log('ok  ', msg); };

// Every base must be able to walk to every other base on any seed.
for (const seed of [1, 2, 3, 99, 12345, 777777]) {
  const s = new Sim({ seed, players: [0, 1, 2, 3].map(i => ({ name: 'P' + i, team: i })) });
  const [ax, ay] = s.basePos(0);
  let ok = true;
  for (let i = 1; i < 4; i++) {
    const [bx, by] = s.basePos(i);
    const p = s.findPath(ax, ay + 3, bx, by + 3, bx, by + 3);
    const last = p[p.length - 1];
    if (last !== (by + 3) * s.N + bx) ok = false;
  }
  check(ok, `seed ${seed}: all bases connected`);
  const m = genMap(seed, s.N), n = s.N;
  let sym = true;
  for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) if (m.terrain[y * n + x] !== m.terrain[(n - 1 - y) * n + (n - 1 - x)]) sym = false;
  check(sym, `seed ${seed}: map is symmetric`);
}

function play(n, seed, level, maxTicks, teams) {
  const sim = new Sim({ seed, players: Array.from({ length: n }, (_, i) => ({ name: 'AI' + i, team: teams ? teams[i] : i })) });
  const ais = sim.players.map((_, i) => new AI(sim, i, level));
  let peak = 0, bytes = 0;
  const t0 = Date.now();
  while (sim.winner === -1 && sim.tick < maxTicks) {
    for (const a of ais) a.update();
    sim.step();
    const snap = sim.snapshot();
    if (sim.tick % 50 === 0) { peak = Math.max(peak, sim.ents.size); bytes = Math.max(bytes, JSON.stringify(snap).length); }
  }
  const ms = Date.now() - t0;
  return { sim, peak, bytes, ms, perTick: ms / sim.tick };
}

for (const [n, seed, level, teams] of [[2, 5, 1], [4, 42, 1], [4, 7, 2], [3, 11, 0], [4, 8, 1, [0, 0, 1, 1]], [4, 1, 1], [4, 2, 0], [4, 3, 2], [2, 4, 2], [3, 6, 1], [4, 9, 1], [4, 10, 1], [4, 13, 1]]) {
  const r = play(n, seed, level, 60000, teams);
  const mins = (r.sim.tick / 600).toFixed(1);
  check(r.sim.winner >= 0, `${n} AIs (level ${level}${teams ? ', teams' : ''}) finish: winner team ${r.sim.winner} after ${mins} game-min; ` +
    `peak ${r.peak} entities, biggest snapshot ${r.bytes} B, ${r.perTick.toFixed(3)} ms/tick`);
}

// Commands from the network must never throw, whatever they contain.
{
  const sim = new Sim({ seed: 3, players: [{ name: 'a', team: 0 }, { name: 'b', team: 1 }] });
  const junk = [null, 5, 'x', {}, { t: 'move' }, { t: 'move', ids: 'no', x: 1, y: 1 }, { t: 'move', ids: [1, 2, 99], x: NaN, y: 1 },
    { t: 'move', ids: [2, 3], x: -1e9, y: 1e9 }, { t: 'build', ids: [2], b: 'hq', tx: 1, ty: 1 }, { t: 'build', ids: [2], b: 'nope', tx: 1, ty: 1 },
    { t: 'build', ids: [2], b: 'house', tx: -5, ty: 9999 }, { t: 'train', b: 1, u: 'hero' }, { t: 'train', b: 999, u: 'worker' },
    { t: 'attack', ids: [2], target: 1 }, { t: 'harvest', ids: [2], tx: 1e9, ty: 0 }, { t: 'ability', id: 1 }, { t: 'assist', ids: [2], b: 2 }];
  let threw = false;
  try { for (const j of junk) { sim.command(0, j); sim.command(7, j); sim.step(); } } catch (e) { threw = true; console.error(e); }
  check(!threw, 'malformed commands are ignored');
  sim.command(0, { t: 'stop', ids: [...sim.ents.keys()] });
  const enemyWorker = [...sim.ents.values()].find(e => e.owner === 1 && e.type === 'worker');
  check(enemyWorker.order !== null, "a player can't command another player's units");
}

// Left alone, workers keep working: none may stand idle while there is still something to gather.
for (const seed of [1, 2, 3, 4, 5, 6]) {
  const s = new Sim({ seed, players: [{ name: 'a', team: 0 }] });
  const hq = [...s.ents.values()].find(e => e.type === 'hq');
  let idle = 0;
  for (let t = 0; t < 6000; t++) {
    if (t % 100 === 0 && s.players[0].pop < 10) s.command(0, { t: 'train', b: hq.id, u: 'worker' });
    s.step(); s.snapshot();
    for (const e of s.ents.values()) if (e.type === 'worker' && !e.order) idle++;
  }
  check(idle === 0 && s.players[0].res > 3000, `seed ${seed}: 10 workers never idle in 10 game-min (gathered ${Math.floor(s.players[0].res)})`);
}

// A half-built building can be left, resumed by the nearest workers, or cancelled for a full refund.
{
  const s = new Sim({ seed: 9, players: [{ name: 'a', team: 0 }, { name: 'b', team: 1 }] });
  const run = n => { for (let i = 0; i < n; i++) { s.step(); s.snapshot(); } };
  const hq = [...s.ents.values()].find(e => e.type === 'hq' && e.owner === 0);
  const w = [...s.ents.values()].find(e => e.type === 'worker' && e.owner === 0);
  const site = s.findSite('house', hq.tx + 1, hq.ty + 1);
  s.command(0, { t: 'build', ids: [w.id], b: 'house', tx: site[0], ty: site[1] });
  const b = [...s.ents.values()].find(e => e.type === 'house');
  run(60);
  const mid = b.prog;
  s.command(0, { t: 'stop', ids: [w.id] });
  run(30);
  const snap = s.snapshot().e.find(a => a[0] === b.id);
  check(mid > 0 && mid < 1 && b.prog === mid && snap[9] === 1, 'a building with no worker stays where it is and reports paused');
  s.command(1, { t: 'cancel', b: b.id }); s.command(1, { t: 'resume', b: b.id });
  check(s.ents.has(b.id) && b.prog === mid, "another player can't cancel or resume it");
  s.command(0, { t: 'resume', b: b.id });
  run(200);
  check(b.built, 'resume sends workers and the building is finished');
  const before = s.players[0].res;
  s.command(0, { t: 'build', ids: [w.id], b: 'house', tx: s.findSite('house', hq.tx + 1, hq.ty + 1)[0], ty: s.findSite('house', hq.tx + 1, hq.ty + 1)[1] });
  const b2 = [...s.ents.values()].find(e => e.type === 'house' && !e.built);
  run(20);
  const paid = before - s.players[0].res < 0 ? 80 : 80; // income keeps arriving, so compare around the cancel itself
  const r0 = s.players[0].wood;
  s.command(0, { t: 'cancel', b: b2.id });
  check(!s.ents.has(b2.id) && s.players[0].wood === r0 + paid && s.canPlace('house', b2.tx, b2.ty), 'cancel removes it, frees the ground and refunds the cost');
  s.command(0, { t: 'train', b: hq.id, u: 'worker' });
  const r1 = s.players[0].res;
  s.command(0, { t: 'unqueue', b: hq.id });
  check(hq.queue.length === 0 && s.players[0].res === r1 + 50, 'a queued unit can be cancelled for a refund');
}

// An Outpost beside a far deposit is a drop-off: the same workers bring in more than when they walk home.
{
  const income = withOutpost => {
    const s = new Sim({ seed: 9, players: [{ name: 'a', team: 0 }, { name: 'b', team: 1 }] });
    const run = n => { for (let i = 0; i < n; i++) { s.step(); s.snapshot(); } };
    const ws = [...s.ents.values()].filter(e => e.type === 'worker' && e.owner === 0);
    const fx = s.basePos(0)[0] - 3, fy = s.basePos(0)[1] + 11; // the second deposit
    s.players[0].res = 1000;
    if (withOutpost) {
      const site = s.findSite('outpost', fx, fy + 1);
      s.command(0, { t: 'build', ids: ws.map(w => w.id), b: 'outpost', tx: site[0], ty: site[1] });
      run(400);
    } else run(400);
    s.command(0, { t: 'harvest', ids: ws.map(w => w.id), tx: fx, ty: fy });
    run(100);
    const r0 = s.players[0].res; run(1200);
    return { gain: s.players[0].res - r0, built: !withOutpost || [...s.ents.values()].some(e => e.type === 'outpost' && e.built) };
  };
  const a = income(false), b = income(true);
  check(b.built && b.gain > a.gain * 1.5, `an Outpost by the far deposit raises income (${a.gain} -> ${b.gain} in 2 game-min)`);
}

// A crowd of workers shuttling between a deposit and an Outpost right beside it must never give up.
{
  let idle = 0, unbuilt = 0;
  for (let seed = 1; seed <= 40; seed++) {
    const s = new Sim({ seed, players: [{ name: 'a', team: 0 }, { name: 'b', team: 1 }] });
    const hq = [...s.ents.values()].find(e => e.type === 'hq' && e.owner === 0);
    s.players[0].res = 2000;
    for (let i = 0; i < 7; i++) { s.players[0].cap = 30; s.command(0, { t: 'train', b: hq.id, u: 'worker' }); for (let k = 0; k < 85; k++) s.step(); }
    const ws = [...s.ents.values()].filter(e => e.type === 'worker' && e.owner === 0).map(w => w.id);
    const site = s.findSite('outpost', s.basePos(0)[0] + 6, s.basePos(0)[1] - 2);
    s.command(0, { t: 'build', ids: ws, b: 'outpost', tx: site[0], ty: site[1] });
    for (let t = 0; t < 3000; t++) { s.step(); s.snapshot(); if (t > 300) for (const e of s.ents.values()) if (e.type === 'worker' && e.owner === 0 && !e.order) idle++; }
    if (![...s.ents.values()].some(e => e.type === 'outpost' && e.built)) unbuilt++;
  }
  check(idle === 0 && unbuilt === 0, `10 workers crowding an Outpost on 40 maps: ${idle} idle worker-ticks, ${unbuilt} Outposts left unbuilt`);
}

// Wood comes from trees, crystal from crystals, and buildings need wood.
{
  const s = new Sim({ seed: 4, players: [{ name: 'a', team: 0 }, { name: 'b', team: 1 }] });
  const run = n => { for (let i = 0; i < n; i++) { s.step(); s.snapshot(); } };
  const ws = [...s.ents.values()].filter(e => e.type === 'worker' && e.owner === 0);
  const P = s.players[0];
  const tree = s.nearestRes(...s.basePos(0), 2), w0 = P.wood;
  s.command(0, { t: 'harvest', ids: [ws[0].id], tx: tree[0], ty: tree[1] });
  run(600);
  check(P.wood > w0 + 50 && P.res > 300, `one worker on trees brings wood (${w0} -> ${P.wood}), the others crystal (${Math.floor(P.res)})`);
  P.wood = 10;
  const hq = [...s.ents.values()].find(e => e.type === 'hq' && e.owner === 0), site = s.findSite('house', hq.tx + 1, hq.ty + 1);
  s.command(0, { t: 'build', ids: [ws[1].id], b: 'house', tx: site[0], ty: site[1] });
  check(![...s.ents.values()].some(e => e.type === 'house'), 'no wood, no building');
}

// A building placed on top of units moves them out, and they carry on with what they were doing.
{
  let stuck = 0, lostOrder = 0;
  for (let seed = 1; seed <= 30; seed++) {
    const s = new Sim({ seed, players: [{ name: 'a', team: 0 }, { name: 'b', team: 1 }] });
    const run = n => { for (let i = 0; i < n; i++) { s.step(); s.snapshot(); } };
    const mine = [...s.ents.values()].filter(e => !e.b && e.owner === 0);
    s.players[0].wood = 1000;
    const [bx, by] = s.basePos(0);
    s.command(0, { t: 'move', ids: mine.map(e => e.id), x: (bx + 3.5) * 32, y: (by + 3.5) * 32 });
    run(80);
    // a Barracks right on the group, built by one of the workers standing there
    const w = mine.find(e => e.type === 'worker');
    s.command(0, { t: 'build', ids: [w.id], b: 'barracks', tx: bx + 3, ty: by + 3 });
    const b = [...s.ents.values()].find(e => e.type === 'barracks');
    for (const e of mine) if (!s.walkable(s.tileOf(e.x), s.tileOf(e.y))) stuck++;
    run(400);
    if (!b || !b.built) lostOrder++;
    s.command(0, { t: 'move', ids: mine.map(e => e.id), x: (bx + 9.5) * 32, y: (by + 1.5) * 32 });
    run(150);
    for (const e of mine) if (Math.hypot(e.x - (bx + 9.5) * 32, e.y - (by + 1.5) * 32) > 90 || !s.walkable(s.tileOf(e.x), s.tileOf(e.y))) stuck++;
  }
  check(stuck === 0 && lostOrder === 0, `buildings dropped on units on 30 maps: ${stuck} stuck, ${lostOrder} left unbuilt`);
}

// Each hero's power does what it says.
{
  const mk = hero => new Sim({ seed: 2, players: [{ name: 'a', team: 0, hero }, { name: 'b', team: 1 }] });
  let s = mk('ranger');
  let h = [...s.ents.values()].find(e => e.owner === 0 && e.type === 'ranger');
  const w = [...s.ents.values()].find(e => e.owner === 0 && e.type === 'worker');
  s.command(0, { t: 'ability', id: h.id });
  check(!!h && w.hasteT > s.tick && h.cds[0] > 0, 'the Ranger is the hero that was picked, and Swift March speeds up nearby units');
  s = mk('sage');
  h = [...s.ents.values()].find(e => e.owner === 0 && e.type === 'sage');
  const w2 = [...s.ents.values()].find(e => e.owner === 0 && e.type === 'worker');
  w2.hp = 5; s.command(0, { t: 'ability', id: h.id });
  check(w2.hp === 40, 'the Sage heals nearby units');
  h.hp = 0; s.kill(h);
  for (let i = 0; i < 320; i++) s.step();
  check([...s.ents.values()].some(e => e.owner === 0 && e.type === 'sage') && s.players[0].pop === 3, 'a fallen hero comes back as the same hero and takes no housing');
  s = mk('nonsense');
  check([...s.ents.values()].some(e => e.owner === 0 && e.type === 'hero'), 'an unknown hero name falls back to the Warden');
}

// New troops, walls, new Keeps, and hero levels.
{
  const mk = () => new Sim({ seed: 6, players: [{ name: 'a', team: 0 }, { name: 'b', team: 1 }] });
  const run = (s, n) => { for (let i = 0; i < n; i++) { s.step(); s.snapshot(); } };
  // catapult: buildings only
  let s = mk();
  const [ex, ey] = s.basePos(1);
  const eh = [...s.ents.values()].find(e => e.type === 'hq' && e.owner === 1), ew = [...s.ents.values()].find(e => e.type === 'worker' && e.owner === 1);
  const cat = s.spawnUnit('catapult', 0, (ex - 6.5) * 32, (ey + .5) * 32);
  s.command(0, { t: 'attack', ids: [cat.id], target: ew.id });
  check(cat.order === null, 'a Catapult refuses to attack troops');
  const hp0 = eh.hp, whp = [...s.ents.values()].filter(e => e.owner === 1 && !e.b).map(e => e.hp).join();
  run(s, 100);
  check(eh.hp < hp0 - 100 && [...s.ents.values()].filter(e => e.owner === 1 && !e.b && e.type === 'worker').every(e => e.hp === 40), `left alone it shells the Keep (${hp0} -> ${eh.hp}) and never a worker`);
  // mage splash
  s = mk();
  const m = s.spawnUnit('mage', 0, 600, 600), t1 = s.spawnUnit('soldier', 1, 700, 600), t2 = s.spawnUnit('soldier', 1, 720, 610), far = s.spawnUnit('soldier', 1, 700, 760);
  for (const u of [t1, t2, far]) u.order = { k: 'move', x: u.x, y: u.y, tries: 0 }; // hold still
  s.command(0, { t: 'attack', ids: [m.id], target: t1.id }); s.step();
  check(t1.hp < 95 && t2.hp < 95 && t2.hp > t1.hp && far.hp === 95, 'a Mage blast also hurts enemies beside the target, not those far away');
  // cleric
  s = mk();
  const c = s.spawnUnit('cleric', 0, 600, 600), hurt = s.spawnUnit('worker', 0, 640, 600), foe = s.spawnUnit('worker', 1, 600, 660);
  hurt.hp = 2; foe.order = { k: 'move', x: foe.x, y: foe.y, tries: 0 };
  run(s, 40);
  check(hurt.hp > 30 && foe.hp === 40 && !c.order, 'a Cleric heals a wounded friend and attacks nobody');
  // walls block, and do not keep a player alive
  s = mk();
  const [bx, by] = s.basePos(0);
  s.players[0].wood = 500;
  const w = [...s.ents.values()].find(e => e.type === 'worker' && e.owner === 0);
  s.command(0, { t: 'build', ids: [w.id], b: 'wall', tx: bx + 4, ty: by });
  check(!s.walkable(bx + 4, by) && s.players[0].wood === 485, 'a Wall costs 15 wood and blocks its tile');
  run(s, 80);
  const hq = [...s.ents.values()].find(e => e.type === 'hq' && e.owner === 0);
  s.kill(hq); run(s, 12);
  check(!s.players[0].alive && s.winner === 1, 'with only a Wall left standing, the player is out');
  // a second Keep
  s = mk();
  s.players[0].wood = 500; s.players[0].res = 500;
  const ws = [...s.ents.values()].filter(e => e.type === 'worker' && e.owner === 0);
  const site = s.findSite('hq', s.basePos(0)[0] + 8, s.basePos(0)[1] + 8);
  s.command(0, { t: 'build', ids: ws.map(x => x.id), b: 'hq', tx: site[0], ty: site[1] });
  run(s, 200);
  const keeps = [...s.ents.values()].filter(e => e.type === 'hq' && e.owner === 0);
  check(keeps.length === 2 && keeps.every(k => k.built) && s.players[0].cap === 20, 'workers can build a second Keep, which adds housing');
  s.command(0, { t: 'train', b: keeps[1].id, u: 'worker' }); run(s, 90);
  check([...s.ents.values()].filter(e => e.type === 'worker' && e.owner === 0).length === 4, 'the new Keep trains workers');
  s.kill(keeps[0]); run(s, 12);
  check(s.players[0].alive, 'losing the first Keep does not end the game while the second stands');
  // hero levels
  s = mk();
  const h = [...s.ents.values()].find(e => e.owner === 0 && e.type === 'hero'), P = s.players[0];
  s.command(0, { t: 'ability', id: h.id, n: 1 });
  check(h.cds[1] <= 0, 'a level 1 hero cannot cast its level 2 spell');
  for (let i = 0; i < 6; i++) { const v = s.spawnUnit('soldier', 1, h.x + 10, h.y); s.hit(v, 999, h); }
  check(P.lvl === 2 && h.hp === Math.round(420 * 1.12), `six kills take the hero to level ${P.lvl} with more health (${h.hp})`);
  const friend = s.spawnUnit('soldier', 0, h.x + 30, h.y);
  s.command(0, { t: 'ability', id: h.id, n: 1 });
  check(h.cds[1] > 0 && friend.rageT > s.tick, 'now Battle Cry works and fires up nearby troops');
  for (let i = 0; i < 60; i++) { const v = s.spawnUnit('soldier', 1, h.x + 10, h.y); s.hit(v, 999, h); }
  check(P.lvl === 5, 'levels stop at 5');
  s.kill(h); run(s, 320);
  const h2 = [...s.ents.values()].find(e => e.owner === 0 && e.type === 'hero');
  check(h2 && h2.hp === s.maxHp(h2) && s.snapshot().p[0][6] === 5, 'a fallen hero returns at the same level');
}

// A saved game, written out as text and read back, plays on exactly as the original does.
{
  const cfg = { seed: 77, players: [0, 1, 2, 3].map(i => ({ name: 'AI' + i, team: i, hero: ['hero', 'ranger', 'sage', 'hero'][i] })) };
  const a = new Sim(cfg), aisA = a.players.map((_, i) => new AI(a, i, 1));
  const stepAll = (s, ais, n) => { let last; for (let i = 0; i < n; i++) { for (const x of ais) x.update(); s.step(); last = s.snapshot(); } return JSON.stringify(last); };
  stepAll(a, aisA, 2500);
  const text = JSON.stringify({ sim: a.save(), ais: aisA.map(x => ({ att: x.att, wave: x.wave })) });
  const back = JSON.parse(text), b = Sim.restore(cfg, back.sim), aisB = b.players.map((_, i) => Object.assign(new AI(b, i, 1), back.ais[i]));
  const sa = stepAll(a, aisA, 1500), sb = stepAll(b, aisB, 1500);
  check(sa === sb && a.ents.size > 30, `a game saved at tick 2500 and restored matches the original 1500 ticks later (${a.ents.size} entities, ${(text.length / 1024).toFixed(0)} kB saved)`);
}

if (failed) { console.error(`${failed} check(s) failed`); process.exit(1); }
console.log('all checks passed');
