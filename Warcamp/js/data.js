// Shared game data: every number that defines a unit, building, hero or spell lives here.
export const TILE = 32;
export const MAXCAP = 40;
export const MAP_SIZE = 112; // tiles per side

// The order is the wire format: add new types at the end only.
export const TYPES = ['worker', 'soldier', 'archer', 'knight', 'hero', 'hq', 'house', 'barracks', 'stable', 'tower', 'outpost', 'ranger', 'sage',
  'guard', 'mage', 'cleric', 'catapult', 'workshop', 'sanctum', 'wall'];
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

  // Heroes: each player picks one. It costs nothing, comes back at a Keep after falling, and levels up from kills.
  hero:     { name: 'Warden', hp: 420, speed: 82, dmg: 24, range: 0,   cd: 1, cost: 0, time: 0, sight: 8, r: 11, mil: 1, hero: 1, about: 'Tough fighter up close',
              abs: [{ name: 'Shockwave', lvl: 1, cd: 20, kind: 'shock', radius: 90, dmg: 45, about: 'hurts every enemy around' },
                    { name: 'Battle Cry', lvl: 2, cd: 30, kind: 'rage', radius: 160, secs: 10, about: 'nearby troops hit harder' },
                    { name: 'Earthshatter', lvl: 4, cd: 45, kind: 'shock', radius: 150, dmg: 130, about: 'a huge blast' }] },
  ranger:   { name: 'Ranger', hp: 300, speed: 90, dmg: 20, range: 170, cd: 1, cost: 0, time: 0, sight: 9, r: 11, mil: 1, hero: 1, about: 'Fast, shoots from far away',
              abs: [{ name: 'Swift March', lvl: 1, cd: 25, kind: 'haste', radius: 160, secs: 8, about: 'nearby troops move faster' },
                    { name: 'Volley', lvl: 2, cd: 25, kind: 'shock', radius: 200, dmg: 38, about: 'arrows rain on every enemy in sight' },
                    { name: 'Deadeye', lvl: 4, cd: 40, kind: 'snipe', radius: 330, dmg: 280, about: 'one shot at the strongest enemy' }] },
  sage:     { name: 'Sage', hp: 340, speed: 80, dmg: 14, range: 110, cd: 1, cost: 0, time: 0, sight: 8, r: 11, mil: 1, hero: 1, about: 'Keeps the army alive',
              abs: [{ name: 'Mend', lvl: 1, cd: 18, kind: 'heal', radius: 130, heal: 70, about: 'heals nearby troops' },
                    { name: 'Ward', lvl: 2, cd: 30, kind: 'ward', radius: 160, secs: 8, about: 'nearby troops take half damage' },
                    { name: 'Renewal', lvl: 4, cd: 50, kind: 'heal', radius: 180, heal: 260, secs: 6, about: 'a great heal, and a burst of speed' }] },

  hq:       { name: 'Keep',       b: 1, size: 3, hp: 1400, cost: 200, wood: 300, time: 40, sight: 8, cap: 10, trains: ['worker'], drop: 1, info: 'A new base: trains workers, takes crystal and wood' },
  house:    { name: 'Cottage',    b: 1, size: 2, hp: 320,  cost: 0,   wood: 80,  time: 12, sight: 4, cap: 5, info: 'Room for 5 more units' },
  outpost:  { name: 'Outpost',    b: 1, size: 2, hp: 450,  cost: 0,   wood: 100, time: 14, sight: 6, drop: 1, info: 'Workers drop crystal and wood here' },
  barracks: { name: 'Barracks',   b: 1, size: 2, hp: 650,  cost: 0,   wood: 150, time: 20, sight: 5, trains: ['soldier', 'archer', 'guard'] },
  stable:   { name: 'Stable',     b: 1, size: 2, hp: 650,  cost: 80,  wood: 150, time: 22, sight: 5, trains: ['knight'], req: 'barracks' },
  workshop: { name: 'Workshop',   b: 1, size: 2, hp: 600,  cost: 60,  wood: 180, time: 22, sight: 5, trains: ['catapult'], req: 'barracks' },
  sanctum:  { name: 'Sanctum',    b: 1, size: 2, hp: 550,  cost: 100, wood: 160, time: 22, sight: 5, trains: ['mage', 'cleric'], req: 'barracks' },
  tower:    { name: 'Watchtower', b: 1, size: 1, hp: 420,  cost: 50,  wood: 80,  time: 15, sight: 8, dmg: 12, range: 190, cd: 1 },
  wall:     { name: 'Wall',       b: 1, size: 1, hp: 550,  cost: 0,   wood: 15,  time: 4,  sight: 2, wall: 1, info: 'Blocks the way. Walls alone do not keep you in the game' },
};

export const BUILDABLE = ['house', 'outpost', 'barracks', 'stable', 'workshop', 'sanctum', 'tower', 'wall', 'hq'];
export const COLORS = ['#e5484d', '#3b82f6', '#f5b301', '#a855f7', '#22a45d', '#f97316', '#14b8a6', '#ec4899'];
export const COLOR_NAMES = ['Red', 'Blue', 'Gold', 'Violet', 'Green', 'Orange', 'Teal', 'Pink'];
export const HEROES = ['hero', 'ranger', 'sage'];

export const HERO_RESPAWN = 30;
// Experience needed to reach level 2, 3, 4, 5. Each level adds 12% health and damage.
export const LEVELS = [20, 55, 110, 190];
export const LEVEL_BONUS = 0.12;
export const heroMult = lvl => 1 + LEVEL_BONUS * ((lvl || 1) - 1);
