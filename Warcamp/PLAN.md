# Warcamp roadmap

The target is the kind of game LEGO Battles was on the DS: a friendly, readable, touch-first RTS with a few
themed worlds, a hero on every side, a story campaign, a free-play mode and things to collect and unlock.

One rule shapes everything below: **Warcamp borrows that game's structure, not its content.** The worlds,
factions, characters, names, art and levels here are our own. No LEGO name, minifigure, brick look or level
is copied, which also means the game can be shared and published freely.

## Where it stands (v0.1, built and tested)

| Area | In the game today |
| --- | --- |
| Core loop | Workers gather crystal from crystals and trees, carry it to the Keep, and build. Cottages raise the unit limit (up to 40). |
| Units | Worker, Soldier (melee), Archer (ranged), Rider (fast, heavy), and a Champion hero with a Shockwave power who returns 30 s after falling. |
| Buildings | Keep, Cottage, Barracks, Stable (needs a Barracks), Watchtower. |
| Map | 56×56 tiles, generated from a seed and mirrored four ways so every corner is equal. Fog of war and a minimap. |
| Players | 1 to 4, any mix of people and computers. Free for all, or everyone against the computers. Three computer levels. |
| Multiplayer | Host shares a 4-letter code. Peer to peer, no game server. A computer takes over a player who drops out. |
| Controls | Touch (tap, drag, pinch, hold-and-drag box) and mouse plus keyboard. |
| PWA | Installable, full screen, works offline after the first visit. |
| Tests | `node Warcamp/test/sim.test.mjs` plays whole games without a browser. |

## How the pieces of that style of game map onto Warcamp

| What made that game what it was | Warcamp's version | Status |
| --- | --- | --- |
| Three themed worlds, two rival sides in each | Three original worlds, six factions (Phase 2) | one neutral faction so far |
| A hero per side with special powers | Champion with Shockwave; three heroes per faction later | first hero done |
| Builders gather one resource and put up buildings | Workers and crystal | done |
| A building that raises the unit limit | Cottage | done |
| Land, sea and air units; transports | Ships, flyers, bridges (Phase 2) | not started |
| Story campaigns, one per side, short missions | Six campaigns of about eight missions (Phase 3) | not started |
| Free play with adjustable rules | Skirmish options (Phase 5) | players, teams and difficulty done |
| Hidden pickups, a currency, unlockable units and cheats | Relics, stars and a shop (Phase 4) | not started |
| Play with friends on separate devices | 4-player online with room codes | done |
| Stylus control with a map on the second screen | Touch control with a corner minimap | done |

## Phase 1: make it feel good (about a week)

Small things that decide whether the game is fun to hold.

- Sound: taps, attacks, building finished, "under attack", and one looping tune per world. Web Audio, a few kB.
- Attack-move button and a rally point for each production building.
- Control groups on desktop (Ctrl+1..9) and a "last selection" button on touch.
- Repair buildings with workers; cancel a queued unit or an unfinished building for a refund.
- A second drop-off building (Depot) so far-away crystals are worth mining.
- Walls and gates, as in the genre.
- A five-step interactive tutorial on first launch.
- Pause in single player. Game speed setting.
- Idle animation, walking bob, building going up in stages.

## Phase 2: three worlds, six factions (two to three weeks)

Each world has its own tile set, music and a pair of sides that share a tech tree shape but differ in units.
Working names, all original:

| World | Side A | Side B | Twist the world adds |
| --- | --- | --- | --- |
| The Old Marches (medieval) | The Kingdom: knights, crossbows, catapult | The Barrow Court: bone-walkers, hex casters, a wyrm | Magic: casters with area spells |
| The Salt Reaches (islands) | The Free Sails: boarders, gunners, sloops | The Crown Fleet: marines, mortars, frigates | Water: ships, transports, shore bombardment |
| The Far Belt (space) | The Prospectors: rovers, laser crews, dropships | The Hive: swarmers, spitters, a floating carrier | Air: flyers that ignore terrain |

Work items:

- Data-driven factions: `data.js` becomes one file per faction; the simulation already reads everything from data.
- Unit classes the engine does not have yet: siege (bonus against buildings), caster (area spell on a cooldown),
  transport (carries units over water), flyer (ignores terrain, only ranged units can hit it).
- Water as a second movement layer; shipyard building; bridges that workers can build.
- A special building per faction that unlocks the top unit.
- Three heroes per faction, each with one power (area damage, heal, speed aura, summon, and so on). The player
  picks one per match.
- Art: every unit drawn in code like today, or switch to sprite sheets. Decide before starting (see "Decisions").

## Phase 3: campaign (three to four weeks)

- A mission file format (JSON): map, starting units, objectives, triggers ("when the bridge is built, spawn a
  raid"), dialogue lines. The simulation gains a small trigger system; nothing else changes.
- Objective types: destroy the base, survive for N minutes, escort the hero, collect N crystal, hero-only
  missions with no base, rescue and hold.
- Six campaigns, one per faction, about eight missions each, with the story told in short cards between missions.
- A level-select map per world that shows progress and what is still to be found in each mission.
- Hand-made maps need an editor: an in-browser map editor that also ships as the player-facing editor in Phase 5.
- Progress saved on the device (IndexedDB), with export and import so a save can move between devices.

## Phase 4: things to find and unlock (one to two weeks)

- Three hidden relics on every campaign map and a star rating per mission (finished, fast, no hero lost).
- Stars are the currency. A shop unlocks extra heroes, bonus units for free play, map themes and "tricks"
  (fast build, double crystal, big heads) that can be switched on in single player.
- A collection screen: every unit and building with its numbers and a line of lore.

## Phase 5: free play and skirmish depth (one to two weeks)

- Options: map size, starting crystal, unit limit, fog on or off, revealed map, hero on or off.
- Win conditions: destroy every building (today), destroy the Keep, hold the centre, first to N crystal, timed.
- Teams of any shape (2v2, 3v1), shared vision (done), sending crystal to an ally, pings on the minimap.
- A map picker with hand-made maps, random maps by seed, and maps from the editor shared as a link.

## Phase 6: multiplayer that holds up (one to two weeks)

- Run our own matchmaking and relay (a PeerJS server plus a TURN relay). Today the game uses the free public
  PeerJS service, which is fine for friends but has no guarantee, and some mobile networks need a relay to connect.
- Reconnect to a running game; move the host role to another player when the host leaves.
- Smaller network traffic: send only what changed each tick (snapshots are about 3 kB ten times a second today).
- Lobby chat, quick messages in game, spectators, a rematch button.
- Later, if public matchmaking is wanted: a small server that runs the simulation, so no player's device is trusted.

## Decisions that are yours

1. **Hosting.** A PWA has to be served over HTTPS. GitHub Pages is free and a workflow for it is in the repo; it
   makes the game public. Alternatives: Cloudflare Pages, Netlify, or your own domain.
2. **Art direction.** Keep drawing everything in code (tiny, fast, consistent, limited) or move to sprite sheets
   (richer, needs an artist or a generator, bigger download).
3. **Which world first.** The Old Marches is closest to what exists. The Salt Reaches needs the water work, the
   Far Belt needs flyers.
4. **Campaign or skirmish first.** Campaign is the bigger half of the target game; skirmish depth is quicker to
   build and benefits multiplayer immediately.
5. **Multiplayer service.** Stay on the free public service, or pay a few dollars a month for a relay of our own.
