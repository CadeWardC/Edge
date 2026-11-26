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
      const site = s.findSite('outpost', fx, fy - 2);
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
  const mineOf = t => [...s.ents.values()].filter(e => e.owner === 0 && (t === 'hero' ? e.type === 'hero' : e.type === t));
  s.players[0].wood = 500; s.command(0, { t: 'build', ids: [w.id], b: 'barracks', tx: bx + 4, ty: by + 3 });
  s.kill(hq); run(s, 12);
  check(s.players[0].alive && s.winner === -1, 'losing the only Keep does not knock a player out while workers and the hero live');
  for (const u of mineOf('worker')) s.kill(u); run(s, 12);
  check(s.players[0].alive, 'nor does losing every worker as well, while the hero lives');
  for (const u of mineOf('hero')) s.kill(u); run(s, 12);
  check(!s.players[0].alive && s.winner === 1 && ![...s.ents.values()].some(e => e.owner === 0), 'Keeps gone, workers gone, hero dead: the player is out, whatever other buildings stood');
  run(s, 400);
  check(!mineOf('hero').length, 'a hero with no Keep to return to stays dead');
  // a second Keep
  s = mk();
  s.players[0].wood = 3000; s.players[0].res = 3000;
  const ws = [...s.ents.values()].filter(e => e.type === 'worker' && e.owner === 0);
  const site = s.findSite('hq', s.basePos(0)[0] + 8, s.basePos(0)[1] + 8);
  s.command(0, { t: 'build', ids: ws.map(x => x.id), b: 'hq', tx: site[0], ty: site[1] });
  run(s, 250);
  const keeps = [...s.ents.values()].filter(e => e.type === 'hq' && e.owner === 0);
  check(keeps.length === 2 && keeps.every(k => k.built) && s.players[0].cap === 20, 'workers can build a second Keep, which adds housing');
  s.command(0, { t: 'train', b: keeps[1].id, u: 'worker' }); run(s, 90);
  check([...s.ents.values()].filter(e => e.type === 'worker' && e.owner === 0).length === 4, 'the new Keep trains workers');
  s.kill(keeps[0]); run(s, 12);
  check(s.players[0].alive, 'losing the first Keep does not end the game while the second stands');
  // range: near a Keep or not at all; Keeps go anywhere; two per game
  const away = s.findSite('house', s.basePos(0)[0] + 30, s.basePos(0)[1] + 30), w0 = s.players[0].wood;
  s.command(0, { t: 'build', ids: ws.map(x => x.id), b: 'house', tx: away[0], ty: away[1] });
  check(s.players[0].wood === w0 && ![...s.ents.values()].some(e => e.type === 'house'), 'a Cottage far from any Keep is refused');
  s.command(0, { t: 'build', ids: ws.map(x => x.id), b: 'hq', tx: away[0], ty: away[1] });
  const k2 = [...s.ents.values()].find(e => e.type === 'hq' && e.owner === 0 && !e.built);
  check(!!k2 && s.snapshot().p[0][8] === 0, 'a Keep can go there, and that is the second and last one allowed');
  s.command(0, { t: 'build', ids: ws.map(x => x.id), b: 'house', tx: away[0] + 4, ty: away[1] });
  check(![...s.ents.values()].some(e => e.type === 'house'), 'an unfinished Keep does not yet let you build around it');
  run(s, 1500);
  s.command(0, { t: 'build', ids: ws.map(x => x.id), b: 'house', tx: away[0] + 4, ty: away[1] });
  check(k2.built && [...s.ents.values()].some(e => e.type === 'house'), 'once it is finished, building around it works');
  const site3 = s.findSite('hq', s.basePos(0)[0] + 12, s.basePos(0)[1] + 2), n3 = [...s.ents.values()].filter(e => e.type === 'hq' && e.owner === 0).length;
  s.command(0, { t: 'build', ids: ws.map(x => x.id), b: 'hq', tx: site3[0], ty: site3[1] });
  check([...s.ents.values()].filter(e => e.type === 'hq' && e.owner === 0).length === n3, 'a third Keep is refused');
  // hero levels
  s = mk();
  const h = [...s.ents.values()].find(e => e.owner === 0 && e.type === 'hero'), P = s.players[0];
  s.command(0, { t: 'ability', id: h.id, n: 1 });
  check(h.cds[1] <= 0, 'a level 1 hero cannot cast its level 2 spell');
  for (let i = 0; i < 6; i++) { const v = s.spawnUnit('soldier', 1, h.x + 10, h.y); s.hit(v, 999, h); }
  check(P.lvl === 2 && h.hp === Math.round(420 * 1.08), `six kills take the hero to level ${P.lvl} with more health (${h.hp})`);
  const friend = s.spawnUnit('soldier', 0, h.x + 30, h.y);
  s.command(0, { t: 'ability', id: h.id, n: 1 });
  check(h.cds[1] > 0 && friend.rageT > s.tick, 'now Battle Cry works and fires up nearby troops');
  for (let i = 0; i < 60; i++) { const v = s.spawnUnit('soldier', 1, h.x + 10, h.y); s.hit(v, 999, h); }
  check(P.lvl === 5, 'levels stop at 5');
  {
    const squad = [0, 1, 2].map(i => s.spawnUnit('soldier', 1, h.x + 20 + i * 12, h.y + 20)), tower = s.addBuilding('tower', 1, s.tileOf(h.x) + 2, s.tileOf(h.y) - 2, true);
    for (const u of squad) u.order = { k: 'move', x: u.x, y: u.y, tries: 0 };
    h.cds[2] = 0; s.command(0, { t: 'ability', id: h.id, n: 2 });
    check(squad.every(u => u.hp === 30) && tower.hp === 420 - 26, `Earthshatter hurts a squad of Soldiers (95 -> ${squad[0].hp}) without wiping it out, and barely dents a tower (420 -> ${tower.hp})`);
    for (const u of squad) s.kill(u); s.kill(tower);
  }
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

// 60 units, disbanding, giving up, and the two troop buildings.
{
  const s = new Sim({ seed: 12, players: [{ name: 'a', team: 0 }, { name: 'b', team: 1 }, { name: 'c', team: 2 }] });
  const run = n => { for (let i = 0; i < n; i++) { s.step(); s.snapshot(); } };
  const P = s.players[0], hq = [...s.ents.values()].find(e => e.type === 'hq' && e.owner === 0);
  P.cap = 200; P.res = 1e5;
  for (let i = 0; i < 75; i++) { s.command(0, { t: 'train', b: hq.id, u: 'worker' }); run(82); }
  check(P.pop === 60 && s.snapshot().p[0][2] === 60, `the unit limit is 60 (trained to ${P.pop})`);
  const ws = [...s.ents.values()].filter(e => e.type === 'worker' && e.owner === 0), hero = [...s.ents.values()].find(e => e.owner === 0 && e.type === 'hero');
  s.command(0, { t: 'disband', ids: [...ws.slice(0, 20).map(w => w.id), hero.id, hq.id] }); run(2);
  check(P.pop === 40 && s.ents.has(hero.id) && s.ents.has(hq.id), 'disbanding removes the chosen troops and frees their housing; the hero and buildings stay');
  const foe = [...s.ents.values()].find(e => e.type === 'worker' && e.owner === 1);
  s.command(0, { t: 'disband', ids: [foe.id] });
  check(s.ents.has(foe.id), "a player cannot disband someone else's units");
  P.wood = 5000;
  const b = t => { const site = s.findSite(t, hq.tx + 1, hq.ty + 1); s.command(0, { t: 'build', ids: ws.slice(20, 30).map(w => w.id), b: t, tx: site[0], ty: site[1] }); return [...s.ents.values()].find(e => e.type === t && e.owner === 0); };
  check(!b('stable') && !b('sanctum'), 'the Stable and the Sanctum can no longer be built');
  const rax = b('barracks'); run(300);
  const ars = b('workshop'); run(300);
  for (const u of ['soldier', 'archer', 'guard', 'knight']) s.command(0, { t: 'train', b: rax.id, u });
  for (const u of ['mage', 'cleric', 'catapult']) s.command(0, { t: 'train', b: ars.id, u });
  check(rax.built && ars.built && rax.queue.length === 4 && ars.queue.length === 3, 'the Barracks trains Soldiers, Archers, Guards and Riders; the Arsenal trains Mages, Clerics and Catapults');
  s.command(1, { t: 'giveup' }); run(2);
  check(!s.players[1].alive && ![...s.ents.values()].some(e => e.owner === 1) && s.winner === -1, 'giving up knocks that player out and the game goes on for the others');
  s.command(2, { t: 'giveup' }); run(2);
  check(s.winner === 0, 'when the last opponent gives up, the remaining player wins');
}

// Survival: endless waves that grow, a boss every fifth wave, and no way to win.
{
  const cfg = { seed: 21, level: 1, mode: 'survival', players: [{ name: 'A', team: 0, ai: true }, { name: 'B', team: 0, ai: true, hero: 'sage' }, { name: 'The Horde', team: 1, horde: true }] };
  const s = new Sim(cfg), ais = [new AI(s, 0, 2), new AI(s, 1, 2)], H = 2;
  check(![...s.ents.values()].some(e => e.owner === H) && s.snapshot().wv[0] === 0 && s.snapshot().wv[1] === 90, 'the Horde has no base, and the first wave is 90 seconds away');
  const sizes = [], seenBoss = [], bossIds = new Set();
  let lastWave = 0, strongest = 1;
  while (s.winner === -1 && s.tick < 30000) {
    for (const a of ais) a.update();
    s.step(); s.snapshot();
    if (s.wave !== lastWave) {
      lastWave = s.wave;
      const mine = [...s.ents.values()].filter(e => e.owner === H);
      sizes.push(mine.length);
      for (const e of mine) if (e.type === 'boss' && !bossIds.has(e.id)) { bossIds.add(e.id); if (!seenBoss.includes(s.wave)) seenBoss.push(s.wave); } // a Warlord that walked in with this wave
      for (const e of mine) strongest = Math.max(strongest, e.mul || 1);
    }
  }
  check(lastWave >= 5 && sizes[0] > 0 && sizes[0] <= 8, `waves keep coming (${lastWave} in ${(s.tick / 600).toFixed(0)} game-min); the first is small (${sizes[0]} units)`);
  check(seenBoss.length > 0 && seenBoss.every(w => w % 5 === 0), `a Warlord arrives with every fifth wave (waves ${seenBoss.join(', ')})`);
  check(strongest > 1.2, `later waves are stronger, not just bigger (up to x${strongest.toFixed(2)} health and damage)`);
  check(s.winner === 1 || s.winner === -1, s.winner === 1 ? `two hard computers were overrun at wave ${s.wave}: it is hard` : `two hard computers were still standing at wave ${s.wave}`);
  check(s.winner !== 0 && s.players[H].alive, 'the players can never "win" Survival: the Horde is never knocked out');
  {
    const { SURVIVAL: SV } = await import('../js/data.js'), [E, , Hd, Nm] = SV.levels;
    check(SV.size(5, 4, Hd) > SV.size(5, 2, Hd) * 1.6 && SV.strength(5, 4, Hd) > SV.strength(5, 1, Hd) && SV.boss(5, 4, Hd) > SV.boss(5, 1, Hd) * 1.8,
      `more players, harder waves: wave 5 on Hard is ${SV.size(5, 1, Hd)} / ${SV.size(5, 2, Hd)} / ${SV.size(5, 4, Hd)} strong for 1 / 2 / 4 players, and tougher each`);
    const ratio = L => SV.size(20, 1, L) / SV.size(10, 1, L);
    check(ratio(Nm) > ratio(Hd) && ratio(Hd) > ratio(E) * 1.5, `harder levels curve upward: wave 10 to 20 grows x${ratio(E).toFixed(1)} on Easy, x${ratio(Hd).toFixed(1)} on Hard, x${ratio(Nm).toFixed(1)} on Nightmare`);
    const nm = new Sim({ seed: 5, wave: 3, mode: 'survival', players: [{ name: 'A', team: 0 }, { name: 'The Horde', team: 1, horde: true }] });
    check(nm.lv.name === 'Nightmare', 'Survival takes its own difficulty setting');
  }
  // one player alone against the Horde, doing nothing: overrun
  const lone = new Sim({ seed: 5, level: 2, mode: 'survival', players: [{ name: 'A', team: 0 }, { name: 'The Horde', team: 1, horde: true }] });
  while (lone.winner === -1 && lone.tick < 20000) { lone.step(); lone.snapshot(); }
  check(lone.winner === 1, `a player who does nothing is overrun (at wave ${lone.wave}, ${(lone.tick / 600).toFixed(1)} game-min)`);
  // saved and restored mid-wave
  const text = JSON.stringify(s.save()), back = Sim.restore(cfg, JSON.parse(text));
  check(back.wave === s.wave && back.waveAt === s.waveAt && back.hordeId === H, 'a saved Survival game comes back at the same wave');
}

// Eight players: four seats and four more computers, each on its own base site.
{
  const players = [0, 1, 2, 3, 4, 5, 6, 7].map(i => ({ name: 'P' + i, team: i < 4 ? 0 : 1, ai: true }));
  const s = new Sim({ seed: 31, extra: true, players });
  const hqs = [...s.ents.values()].filter(e => e.type === 'hq');
  const spots = new Set(hqs.map(h => h.tx + ',' + h.ty));
  let linked = true;
  const [ax, ay] = s.basePos(0);
  for (let i = 1; i < 8; i++) { const [bx, by] = s.basePos(i), p = s.findPath(ax, ay + 3, bx, by + 3, bx, by + 3); if (p[p.length - 1] !== (by + 3) * s.N + bx) linked = false; }
  check(hqs.length === 8 && spots.size === 8 && linked, 'eight players get eight separate bases, all connected');
  const plain = genMap(31, s.N), withExtra = genMap(31, s.N, true);
  check(plain.terrain.some((v, i) => v !== withExtra.terrain[i]) && genMap(31, s.N).terrain.every((v, i) => v === plain.terrain[i]), 'the extra base sites only appear when asked for');
  const ais = players.map((_, i) => new AI(s, i, 1));
  while (s.winner === -1 && s.tick < 60000) { for (const a of ais) a.update(); s.step(); s.snapshot(); }
  check(s.winner === 0 || s.winner === 1, `a 4 v 4 game finishes (team ${s.winner} won after ${(s.tick / 600).toFixed(1)} game-min, ${s.ents.size} entities at the end)`);
}

// Workers repair damaged buildings.
{
  const s = new Sim({ seed: 3, players: [{ name: 'a', team: 0 }, { name: 'b', team: 1 }] });
  const run = n => { for (let i = 0; i < n; i++) { s.step(); s.snapshot(); } };
  const hq = [...s.ents.values()].find(e => e.type === 'hq' && e.owner === 0), ws = [...s.ents.values()].filter(e => e.type === 'worker' && e.owner === 0);
  run(50); hq.hp = 700;
  const w0 = s.players[0].wood;
  s.command(1, { t: 'repair', b: hq.id }); s.command(0, { t: 'repair', ids: [ws[0].id], b: hq.id });
  check(ws[0].order.k === 'repair' && ws[1].order.k === 'harvest', 'the worker that was sent goes to repair; the others keep gathering');
  run(300);
  const mid = hq.hp;
  run(1200);
  check(mid > 700 && mid < 1400 && hq.hp === 1400 && ws[0].order && ws[0].order.k === 'harvest', `repair takes time (700 -> ${Math.round(mid)} after 30 s -> ${hq.hp}), then the worker goes back to gathering`);
  hq.hp = 900; s.command(0, { t: 'repair', b: hq.id });
  check([...s.ents.values()].filter(e => e.owner === 0 && e.order && e.order.k === 'repair').length === 2, 'with no workers named, the two nearest free ones go');
  s.command(0, { t: 'repair', ids: [ws[2].id], b: ws[0].id });
  check(ws[2].order.k !== 'repair' || ws[2].order.b === hq.id, 'a unit cannot be "repaired"');
}

// Allies start close together; the other side starts far away. Outposts may go anywhere.
{
  const dist = (s, a, b) => { const p = s.basePos(a), q = s.basePos(b); return Math.hypot(p[0] - q[0], p[1] - q[1]); };
  let near = 0, far = 1e9, linked = true, sep = 1e9;
  for (const seed of [1, 2, 3, 4, 5, 6, 7, 8]) {
    const players = [0, 1, 2, 3].map(i => ({ name: 'P' + i, team: 0 })).concat([4, 5, 6, 7, 8].map(i => ({ name: 'C' + i, team: 1, ai: true })));
    const s = new Sim({ seed, cluster: true, players });
    for (let a = 0; a < 4; a++) for (let b = a + 1; b < 4; b++) { near = Math.max(near, dist(s, a, b)); sep = Math.min(sep, dist(s, a, b)); }
    for (let a = 0; a < 4; a++) for (let b = 4; b < 9; b++) far = Math.min(far, dist(s, a, b));
    for (let a = 0; a < 9; a++) for (let b = a + 1; b < 9; b++) sep = Math.min(sep, dist(s, a, b));
    const [ax, ay] = s.basePos(0);
    for (let i = 1; i < 9; i++) { const [bx, by] = s.basePos(i), p = s.findPath(ax, ay + 3, bx, by + 3, bx, by + 3); if (p[p.length - 1] !== (by + 3) * s.N + bx) linked = false; }
    // every ally has the same start: a Keep, crystal within 9 tiles, trees within 10
    for (let i = 0; i < 4; i++) { const [x, y] = s.basePos(i); if (!s.nearestRes(x, y, 3, 9) || !s.nearestRes(x, y, 2, 10) || s.terrain[s.nearestRes(x, y, 3, 9)[1] * s.N + s.nearestRes(x, y, 3, 9)[0]] !== 3) linked = false; }
  }
  check(near <= 23 && sep >= 12, `four allies start within ${near.toFixed(0)} tiles of each other (never closer than ${sep.toFixed(0)})`);
  check(far >= 30, `the other side starts at least ${far.toFixed(0)} tiles away`);
  check(linked, 'on 8 maps every base is connected and every ally has crystal and trees beside it');
  const surv = new Sim({ seed: 9, mode: 'survival', cluster: true, players: [{ name: 'A', team: 0 }, { name: 'B', team: 0 }, { name: 'C', team: 0 }, { name: 'The Horde', team: 1, horde: true }] });
  check(dist(surv, 0, 1) <= 23 && dist(surv, 0, 2) <= 23 && [...surv.ents.values()].filter(e => e.type === 'hq').length === 3, 'in Survival the players start together too');
  const ffa = new Sim({ seed: 9, players: [0, 1, 2, 3].map(i => ({ name: 'P' + i, team: i })) });
  check(dist(ffa, 0, 1) > 60, `in a free-for-all they still start far apart (${dist(ffa, 0, 1).toFixed(0)} tiles)`);
  // an Outpost far from any Keep
  const s = new Sim({ seed: 3, players: [{ name: 'a', team: 0 }, { name: 'b', team: 1 }] });
  const ws = [...s.ents.values()].filter(e => e.type === 'worker' && e.owner === 0).map(w => w.id), [bx, by] = s.basePos(0);
  const site = s.findSite('outpost', bx + 32, by + 30);
  s.command(0, { t: 'build', ids: ws, b: 'outpost', tx: site[0], ty: site[1] });
  s.command(0, { t: 'build', ids: ws, b: 'house', tx: site[0] + 4, ty: site[1] });
  check([...s.ents.values()].some(e => e.type === 'outpost') && ![...s.ents.values()].some(e => e.type === 'house'), 'an Outpost can be built far from any Keep; other buildings still cannot');
}

if (failed) { console.error(`${failed} check(s) failed`); process.exit(1); }
console.log('all checks passed');
