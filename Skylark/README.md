# Skylark: a flying game with aircraft you can add to

A separate iPhone and iPad game from Edge (landscape). Hold the screen to climb, let go to dive. Fly as far as you can
over hills that get taller and faster, round balloons and storm clouds, and collect stars to unlock more aircraft.

Six aircraft come with it: three planes (Sky Hopper, Bumble, Arrow Jet) and three that fly like helicopters
(Whirlybird, Big Lifter, Saucer). Each has its own speed, climb, agility and star magnet.

## Adding aircraft

Every aircraft is one `.json` file: its name, how it flies, its stats and the coloured shapes it is drawn from.
`Skylark/Resources/How to make aircraft.txt` explains every setting. Two ways to add one:

- **On the phone, no rebuild:** in the Files app open On My iPhone › Skylark, copy a file from `Examples` into
  `Aircraft`, change its `"id"` and anything else, then tap **Reload aircraft** in the Hangar. Mistakes in a file are
  listed there with what is wrong.
- **Built in:** add the file to `Skylark/Aircraft/` (named after its id) and push. `python3 scripts/aircraft.py check`
  validates the files, and `python3 scripts/aircraft.py sheet out.png` draws them all with their hit boxes (needs Pillow).

## Adding a new way of flying

`"type"` in an aircraft file picks a flight model. There are two, `plane` and `helicopter`, in `Game/FlightModel.swift`.
To add another (a glider, a rocket), write a struct that conforms to `FlightModel` and add one line to
`FlightModels.all`; aircraft files can then use the new name.

## Where things are

| | |
| --- | --- |
| `Aircraft/*.json` | the built-in aircraft |
| `Aircraft/AircraftSpec.swift`, `AircraftCatalog.swift` | reading and checking aircraft files, built in and from the Files folder |
| `Aircraft/AircraftArt.swift` | drawing an aircraft from its parts |
| `Game/FlightModel.swift` | how planes and helicopters answer a touch |
| `Game/Terrain.swift`, `Game/GameScene.swift` | the hills, the things in the sky, crashes (SpriteKit) |
| `Game/GameModel.swift` | stars, best distance, unlocked aircraft |
| `Views/` | menu, score, hangar (SwiftUI) |

Every push to `Skylark/` builds `Skylark-unsigned.ipa` into a `skylark-build-N` release. Sign it while installing with
AltStore / SideStore or Sideloadly, or install it with TrollStore.

Build locally: `cd Skylark && xcodegen generate && open Skylark.xcodeproj`.
