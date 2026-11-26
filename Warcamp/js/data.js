// Shared game data: every number that defines a unit, building, hero or spell lives here.
export const TILE = 32;
export const MAXCAP = 60;
export const MAP_SIZE = 112; // tiles per side

// The order is the wire format: add new types at the end only.
export const TYPES = ['worker', 'soldier', 'archer', 'knight', 'hero', 'hq', 'house', 'barracks', 'stable', 'tower', 'outpost', 'ranger', 'sage',
  'guard', 'mage', 'cleric', 'catapult', 'workshop', 'sanctum', 'wall', 'boss'];
export const TI = Object.fromEntries(TYPES.map((t, i) => [t, i]));

// range 0 = melee. Speeds and ranges are in pixels (32 px = 1 tile), times in seconds.
// cost is crystal, wood is wood. `info` is the one line shown when the unit is selected.
export const DEF = {
  worker:   { name: 'Worker',   hp: 40,  speed: 72,  dmg: 4,  range: 0,   cd: 1,   cost: 50,  time: 8,  sight: 6, r: 8,  info: 'Gathers and builds' },
  soldier:  { name: 'Soldier',  hp: 95,  speed: 66,  dmg: 10, range: 0,   cd: 1,   cost: 60,  time: 9,  sight: 6, r: 9,  mil: 1, info: 'Solid fighter up close' },
  archer:   { name: 'Archer',   hp: 55,  speed: 66,  dmg: 8,  range: 150, cd: 1.2, cost: 70,  time: 10, sight: 7, r: 8,  mil: 1, info: 'Shoots from range, fragile' },
  guard:    { name: 'Guard',    hp: 230, speed: 56,  dmg: 8,  range: 0,   cd: 1.1, cost: 90,  time: 12, sight: 6, r: 10, mil: 1, info: 'Slow wall of armour: soaks up damage' },
  knight:   { name: 'Rider',    hp: 160, speed: 108, dmg: 16, range: 0,   cd: 1.2, cost: 120, time: 14, sight: 7, r: 11, mil: 1, info: 'Fast and hits hard' },
  mage:     { name: 'Mage',     hp: 60,  speed: 62,  dmg: 14, range: 140, cd: 1.7, cost: 110, time: 14, sight: 7, r: 8,  mil: 1, splash: 42, info: 'Each blast hurts every enemy near the target' },
  cleric:   { name: 'Cleric',   hp: 70,  speed: 64,  dmg: 0,  range: 0,   cd: 1,   cost: 90,  time: 12, sight: 6, r: 8,  mil: 1, healer: 1, heal: 9, info: 'Cannot fight: heals wounded troops nearby' },
  catapult: { name: 'Catapult', hp: 130, speed: 40,  dmg: 70, range: 270, cd: 3.2, cost: 150, time: 18, sight: 8, r: 12, mil: 1, siege: 1, info: 'Smashes buildings from far away: cannot hit troops' },

  // The Horde's champion in Survival: one arrives with every fifth wave.
  boss:     { name: 'Warlord',  hp: 1700, speed: 54,  dmg: 44, range: 0,   cd: 1.4, cost: 0,   time: 0,  sight: 8, r: 16, mil: 1, splash: 48, boss: 1, info: 'Huge, and every swing hits a whole group' },

  // Heroes: each player picks one. It costs nothing, comes back at a Keep after falling, and levels up from kills.
  hero:     { name: 'Warden', hp: 420, speed: 82, dmg: 24, range: 0,   cd: 1, cost: 0, time: 0, sight: 8, r: 11, mil: 1, hero: 1, about: 'Tough fighter up close',
              abs: [{ name: 'Shockwave', lvl: 1, cd: 24, kind: 'shock', radius: 90, dmg: 32, about: 'hurts every enemy around' },
                    { name: 'Battle Cry', lvl: 2, cd: 35, kind: 'rage', radius: 150, secs: 8, about: 'nearby troops hit a little harder' },
                    { name: 'Earthshatter', lvl: 4, cd: 60, kind: 'shock', radius: 115, dmg: 65, about: 'a heavy blast' }] },
  ranger:   { name: 'Ranger', hp: 300, speed: 90, dmg: 20, range: 170, cd: 1, cost: 0, time: 0, sight: 9, r: 11, mil: 1, hero: 1, about: 'Fast, shoots from far away',
              abs: [{ name: 'Swift March', lvl: 1, cd: 30, kind: 'haste', radius: 150, secs: 6, about: 'nearby troops move faster' },
                    { name: 'Volley', lvl: 2, cd: 30, kind: 'shock', radius: 170, dmg: 22, about: 'arrows rain on every enemy near' },
                    { name: 'Deadeye', lvl: 4, cd: 45, kind: 'snipe', radius: 300, dmg: 150, about: 'one shot at the strongest enemy' }] },
  sage:     { name: 'Sage', hp: 340, speed: 80, dmg: 14, range: 110, cd: 1, cost: 0, time: 0, sight: 8, r: 11, mil: 1, hero: 1, about: 'Keeps the army alive',
              abs: [{ name: 'Mend', lvl: 1, cd: 22, kind: 'heal', radius: 130, heal: 45, about: 'heals nearby troops' },
                    { name: 'Ward', lvl: 2, cd: 35, kind: 'ward', radius: 150, secs: 6, about: 'nearby troops take less damage' },
                    { name: 'Renewal', lvl: 4, cd: 60, kind: 'heal', radius: 160, heal: 130, secs: 4, about: 'a great heal, and a burst of speed' }] },

  hq:       { name: 'Keep',       b: 1, size: 3, hp: 1400, cost: 450, wood: 550, time: 45, sight: 8, cap: 10, trains: ['worker'], drop: 1, anywhere: 1, info: 'A base: trains workers, takes crystal and wood, and lets you build around it' },
  house:    { name: 'Cottage',    b: 1, size: 2, hp: 320,  cost: 0,   wood: 80,  time: 12, sight: 4, cap: 5, info: 'Room for 5 more units' },
  outpost:  { name: 'Outpost',    b: 1, size: 2, hp: 450,  cost: 0,   wood: 100, time: 14, sight: 6, drop: 1, anywhere: 1, info: 'Workers drop crystal and wood here. Can go anywhere, like a Keep' },
  // Two buildings make every fighter: the Barracks the troops of the line, the Arsenal the specialists.
  barracks: { name: 'Barracks',   b: 1, size: 2, hp: 700,  cost: 0,   wood: 150, time: 20, sight: 5, trains: ['soldier', 'archer', 'guard', 'knight'], info: 'Trains Soldiers, Archers, Guards and Riders' },
  stable:   { name: 'Stable',     b: 1, size: 2, hp: 650,  cost: 80,  wood: 150, time: 22, sight: 5, trains: ['knight'], req: 'barracks' },
  workshop: { name: 'Arsenal',    b: 1, size: 2, hp: 650,  cost: 100, wood: 200, time: 24, sight: 5, trains: ['mage', 'cleric', 'catapult'], req: 'barracks', info: 'Trains Mages, Clerics and Catapults' },
  sanctum:  { name: 'Sanctum',    b: 1, size: 2, hp: 550,  cost: 100, wood: 160, time: 22, sight: 5, trains: ['mage', 'cleric'], req: 'barracks' },
  tower:    { name: 'Watchtower', b: 1, size: 1, hp: 420,  cost: 50,  wood: 80,  time: 15, sight: 8, dmg: 12, range: 190, cd: 1, info: 'Shoots enemies inside the dashed ring' },
  wall:     { name: 'Wall',       b: 1, size: 1, hp: 550,  cost: 0,   wood: 15,  time: 4,  sight: 2, wall: 1, info: 'Blocks the way. Walls alone do not keep you in the game' },
};

// Stable and Sanctum are no longer built (the Barracks and the Arsenal took over their troops); the types stay for old saves.
export const BUILDABLE = ['house', 'outpost', 'barracks', 'workshop', 'tower', 'wall', 'hq'];
export const COLORS = ['#e5484d', '#3b82f6', '#f5b301', '#a855f7', '#22a45d', '#f97316', '#14b8a6', '#ec4899'];
export const COLOR_NAMES = ['Red', 'Blue', 'Gold', 'Violet', 'Green', 'Orange', 'Teal', 'Pink'];
export const HEROES = ['hero', 'ranger', 'sage'];

export const HERO_RESPAWN = 30;
// Experience needed to reach level 2, 3, 4, 5. Each level adds 8% health and damage.
export const LEVELS = [20, 55, 110, 190];
export const LEVEL_BONUS = 0.08;
// Spell strengths that are not per-spell numbers.
export const RAGE_BONUS = 1.25, WARD_TAKEN = 0.7, SHOCK_VS_BUILDINGS = 0.4;
// Every building except a Keep must stand within this many tiles of one of the player's finished Keeps.
export const BUILD_RANGE = 16;
// How many Keeps a player may build in one game, on top of the one they start with.
export const KEEP_LIMIT = 2;
export const heroMult = lvl => 1 + LEVEL_BONUS * ((lvl || 1) - 1);

// Survival: everyone on one side against The Horde. Waves never stop; each is bigger than the last.
export const SURVIVAL = {
  first: 90,            // seconds before the first wave
  gap: n => Math.max(45, 75 - n),                                   // seconds between waves
  // Survival has its own difficulty. `hard` scales every wave; `grow` compounds wave after wave, so the harder
  // levels climb like a curve, not a line.
  levels: [{ name: 'Easy', hard: 0.75, grow: 1, about: 'waves grow steadily' },
           { name: 'Normal', hard: 1, grow: 1.03, about: 'each wave is 3% bigger again' },
           { name: 'Hard', hard: 1.3, grow: 1.06, about: 'each wave is 6% bigger again' },
           { name: 'Nightmare', hard: 1.6, grow: 1.1, about: 'each wave is 10% bigger again: it gets out of hand fast' }],
  // Every extra player brings 60% more Horde, and makes each of them 6% tougher.
  size: (n, players, L) => Math.round((3 + n * 1.9) * (0.4 + 0.6 * players) * L.hard * L.grow ** (n - 1)),
  strength: (n, players, L) => (1 + Math.max(0, n - 5) * 0.08) * (0.85 + 0.15 * L.hard) * (1 + 0.06 * (players - 1)) * L.grow ** ((n - 1) / 2), // health and damage multiplier
  boss: (n, players, L) => (1 + (n / 5 - 1) * 0.5) * (0.85 + 0.15 * L.hard) * (1 + 0.3 * (players - 1)) * L.grow ** ((n - 1) / 2),
  bossEvery: 5,
  limit: 90,            // most Horde units on the map at once
  unlock: [['soldier', 1], ['archer', 2], ['guard', 3], ['knight', 4], ['mage', 6], ['catapult', 8]],
};
