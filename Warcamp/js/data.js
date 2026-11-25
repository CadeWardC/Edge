// Shared game data: every number that defines a unit or building lives here.
export const TILE = 32;
export const MAXCAP = 40;

export const TYPES = ['worker', 'soldier', 'archer', 'knight', 'hero', 'hq', 'house', 'barracks', 'stable', 'tower'];
export const TI = Object.fromEntries(TYPES.map((t, i) => [t, i]));

// range 0 = melee. Speeds and ranges are in pixels (32 px = 1 tile), times in seconds.
export const DEF = {
  worker:   { name: 'Worker',     hp: 40,  speed: 72,  dmg: 4,  range: 0,   cd: 1,   cost: 50,  time: 8,  sight: 6, r: 8 },
  soldier:  { name: 'Soldier',    hp: 95,  speed: 66,  dmg: 10, range: 0,   cd: 1,   cost: 60,  time: 9,  sight: 6, r: 9,  mil: 1 },
  archer:   { name: 'Archer',     hp: 55,  speed: 66,  dmg: 8,  range: 150, cd: 1.2, cost: 70,  time: 10, sight: 7, r: 8,  mil: 1 },
  knight:   { name: 'Rider',      hp: 160, speed: 108, dmg: 16, range: 0,   cd: 1.2, cost: 120, time: 14, sight: 7, r: 11, mil: 1 },
  hero:     { name: 'Champion',   hp: 420, speed: 82,  dmg: 24, range: 0,   cd: 1,   cost: 0,   time: 0,  sight: 8, r: 11, mil: 1 },
  hq:       { name: 'Keep',       b: 1, size: 3, hp: 1400, cost: 0,   time: 1,  sight: 8, cap: 10, trains: ['worker'] },
  house:    { name: 'Cottage',    b: 1, size: 2, hp: 320,  cost: 80,  time: 12, sight: 4, cap: 5 },
  barracks: { name: 'Barracks',   b: 1, size: 2, hp: 650,  cost: 150, time: 20, sight: 5, trains: ['soldier', 'archer'] },
  stable:   { name: 'Stable',     b: 1, size: 2, hp: 650,  cost: 200, time: 22, sight: 5, trains: ['knight'], req: 'barracks' },
  tower:    { name: 'Watchtower', b: 1, size: 1, hp: 420,  cost: 120, time: 15, sight: 8, dmg: 12, range: 190, cd: 1 },
};

export const BUILDABLE = ['house', 'barracks', 'stable', 'tower'];
export const COLORS = ['#e5484d', '#3b82f6', '#f5b301', '#a855f7'];
export const COLOR_NAMES = ['Red', 'Blue', 'Gold', 'Violet'];

export const ABILITY = { name: 'Shockwave', cd: 20, radius: 90, dmg: 45 };
export const HERO_RESPAWN = 30;
