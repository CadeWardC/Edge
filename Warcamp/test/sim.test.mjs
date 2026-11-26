// Headless check: node Warcamp/test/sim.test.mjs
// Plays whole AI-vs-AI games with no browser and fails on any exception or a game that never ends.
import { Sim, genMap, basePos } from '../js/sim.js';
import { AI } from '../js/ai.js';

let failed = 0;
const check = (ok, msg) => { if (!ok) { failed++; console.error('FAIL', msg); } else console.log('ok  ', msg); };

// Every base must be able to walk to every other base on any seed.
for (const seed of [1, 2, 3, 99, 12345, 777777]) {
  const s = new Sim({ seed, players: [0, 1, 2, 3].map(i => ({ name: 'P' + i, team: i })) });
  const [ax, ay] = basePos(0, s.N);
  let ok = true;
  for (let i = 1; i < 4; i++) {
    const [bx, by] = basePos(i, s.N);
    const p = s.findPath(ax, ay + 3, bx, by + 3, bx, by + 3);
    const last = p[p.length - 1];
    if (last !== (by + 3) * s.N + bx) ok = false;
  }
  check(ok, `seed ${seed}: all bases connected`);
  const m = genMap(seed, 56);
  let sym = true;
  for (let y = 0; y < 56; y++) for (let x = 0; x < 56; x++) if (m.terrain[y * 56 + x] !== m.terrain[(55 - y) * 56 + (55 - x)]) sym = false;
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
  const r = play(n, seed, level, 36000, teams);
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
  const r0 = s.players[0].res;
  s.command(0, { t: 'cancel', b: b2.id });
  check(!s.ents.has(b2.id) && s.players[0].res === r0 + paid && s.canPlace('house', b2.tx, b2.ty), 'cancel removes it, frees the ground and refunds the cost');
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
    s.players[0].res = 1000;
    if (withOutpost) {
      const site = s.findSite('outpost', 4, 19);
      s.command(0, { t: 'build', ids: ws.map(w => w.id), b: 'outpost', tx: site[0], ty: site[1] });
      run(400);
    } else run(400);
    s.command(0, { t: 'harvest', ids: ws.map(w => w.id), tx: 4, ty: 19 });
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
    const site = s.findSite('outpost', 13, 5);
    s.command(0, { t: 'build', ids: ws, b: 'outpost', tx: site[0], ty: site[1] });
    for (let t = 0; t < 3000; t++) { s.step(); s.snapshot(); if (t > 300) for (const e of s.ents.values()) if (e.type === 'worker' && e.owner === 0 && !e.order) idle++; }
    if (![...s.ents.values()].some(e => e.type === 'outpost' && e.built)) unbuilt++;
  }
  check(idle === 0 && unbuilt === 0, `10 workers crowding an Outpost on 40 maps: ${idle} idle worker-ticks, ${unbuilt} Outposts left unbuilt`);
}

if (failed) { console.error(`${failed} check(s) failed`); process.exit(1); }
console.log('all checks passed');
