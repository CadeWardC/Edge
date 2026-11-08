# Vanguard: real-time strategy for iPhone and iPad

A separate app from Edge and Shuō: an original sci-fi RTS made for touch. Mine crystals, build a base, take the
beacons and destroy the enemy. Every sprite, building, terrain tile, effect and icon is drawn in code
(`Vanguard/Game/Art.swift`) in six team colors; there are no image files except the app icon, which
`scripts/make-icon.py` draws.

Every push to `Vanguard/` builds `Vanguard-unsigned.ipa` into a `vanguard-build-N` release (sign it with AltStore,
SideStore, Sideloadly or TrollStore, like Edge). CI first runs the headless simulation tests (`SimTests/main.swift`).

## What's in it

- **Economy:** Drones mine crystals and build. Supply from Command Centers (+10) and Power Depots (+8), up to 100.
  Expand by building more Command Centers at the other crystal fields.
- **Map control:** neutral **beacons** give +1.5 crystals/s and vision to the team holding them; capture by standing
  next to one with no enemies around (8 s). They pull armies into the middle and give a losing player something to win back.
- **Six units with clear counters:** Trooper (cheap, hits air), Lancer (anti-armor rockets), Mender (heals infantry),
  Skimmer (fast raider), Tank (splash; Siege Mode for range 330), Gunship (flies over terrain, hunts tanks).
  Light / Armored / Structure armor classes with bonus damage; units get Veteran (4 kills) and Elite (10 kills) ranks.
- **Tech:** Barracks → Factory and Tech Lab. Lab upgrades: Weapons I/II, Plating I/II, Siege Mode, Sprint.
  Turrets for defense.
- **Fog of war** with explored/seen/visible areas; enemy buildings are remembered where you last saw them.
- **Four maps:** Crossroads and Twin Rivers (1v1), Highlands (up to 4, free-for-all), Frontier (2v2).
  All are symmetric and checked for paths between every start.
- **Touch controls:** drag to scroll, pinch to zoom, tap to select or command, press-and-hold then drag for a box,
  double-tap a unit for all of its type on screen, Attack button for attack-move, Army / Idle drone buttons,
  three control groups, minimap, rally points, a ghost for placing buildings, hints on long press.
- **Bots** at four levels (Easy, Normal, Hard, Brutal) with four styles (Balanced, Rusher, Turtle, Mechanic).
  They see only what their team sees and act only through the same commands a player sends. Hard and Brutal scout,
  expand, counter your army composition, retreat from losing fights, siege tanks, sprint, and focus fire;
  Brutal reacts faster and mines 30% faster. Watch-only mode lets bots fight each other.
- **Multiplayer (ready to hook up):** deterministic lockstep. The simulation (`Sim/`) only uses exactly-rounded math
  and a seeded RNG, so devices that apply the same commands get the same game. Players send only their commands
  (`Net/Lockstep.swift`, 100 ms turns, 3-turn input delay) plus a state checksum every 10 turns to catch desyncs.
  `NetTransport` is the plug: there is a WebSocket transport for the relay in `Server/relay.py` (stdlib Python, no
  dependencies, rooms by code), and an in-process loopback used by the tests. Game Center or MultipeerConnectivity
  would be another `NetTransport`.

## Design notes (what makes an RTS fun, and what Vanguard does about it)

- **Macro and micro both matter, but neither should be a chore.** Micro is fun while it is manageable and tiring when it
  demands constant attention. So the boring parts are automatic: drones go back to mining after building, new drones
  mine on their own, idle units defend themselves, rally points, a one-tap Army button and control groups. Your
  attention goes to decisions: where to fight, when to expand, what to counter.
- **Units must feel different.** Distinct roles with readable counters (Light / Armored / Structure, air vs ground),
  two active abilities that reward timing (Siege Mode, Sprint), and veterancy so a surviving squad is worth saving.
- **Map control and comebacks.** Beacons in contested places pay out over time and give vision, so there is always
  something to fight over besides the main base, and a player who lost a fight can still win the map back.
  Turrets and the defender's shorter walk make holding your base easier than taking it.
- **Short, readable matches on a phone.** Matches run 5 to 15 minutes, and there's one resource plus supply.
  Silhouettes and team colors are clear at a glance, and health bars show only when they matter.
- **Designed for touch, not ported.** Ports of PC RTS games tend to carry over too many simultaneous controls. Vanguard
  uses tap to select or command, press-and-hold-drag for boxes, an armed Attack button instead of a modifier key,
  big command buttons with hints on long press, and an on-screen ghost for placing buildings.
- **Good bots are a feature.** Four difficulty levels and four styles give variety, and the bots play by your rules:
  they see only their fog of war and act only through commands. CI checks that each level beats the one below it.
- **Lockstep multiplayer from day one.** The simulation is deterministic and command-driven, as in classic RTS
  networking. Checksums catch desyncs, and the same code runs single player, bots and network games.

Sources consulted: [Game Developer: the three layers of control in strategy games](https://www.gamedeveloper.com/design/the-three-layers-of-control-in-strategy-games-),
[GameCloud: what makes RTS games fun (micro and unit differentiation)](https://gamecloud.net.au/features/opinion/what-makes-rts-games-fun-micro-unit-differentiation),
[Mobile Free to Play: touch control design, less is more](https://mobilefreetoplay.com/touch-control-design-less-is-more/),
[Spring RTS on its lockstep model](https://springrts.com/phpbb/viewtopic.php?p=587472),
[Ruoyu Sun: game networking, deterministic lockstep](https://hn.jakechampion.name/reader/https://ruoyusun.com/2019/03/29/game-networking-2.html).

## Play multiplayer now

1. On any computer on your network: `python3 Vanguard/Server/relay.py` (port 8765).
2. On each device: Multiplayer → enter `192.168.x.x:8765` (that computer's address) and the same room code.
3. One player taps **Host** and the others **Join**. The host picks the map, adds bots, sets teams and starts.

For internet play, run the relay on a small server (it doesn't read the game messages) and put it behind TLS for `wss://`.

## Code

| Folder | What |
| --- | --- |
| `Vanguard/Sim/` | Rules, maps, pathfinding (A* + string pulling), combat, fog, bots. Pure Swift, no UIKit, runs headless. |
| `Vanguard/Net/` | Lockstep session, wire messages, transports. |
| `Vanguard/Game/` | SpriteKit scene (rendering, effects, gestures), procedural art, the controller that turns taps into commands. |
| `Vanguard/Views/` | SwiftUI menus, skirmish setup, multiplayer lobby, HUD, how-to-play. |
| `SimTests/` | Determinism, lockstep-over-a-fake-network, bot ladder and performance checks (run on CI). |
| `Server/relay.py` | The multiplayer relay. |

Build locally: `cd Vanguard && xcodegen generate && open Vanguard.xcodeproj`.
Run the simulation tests on a Mac: `swiftc -O Vanguard/Vanguard/Sim/*.swift Vanguard/Vanguard/Net/*.swift Vanguard/SimTests/main.swift -o simtest && ./simtest`.
