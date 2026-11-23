# Skylark: a flight simulator with aircraft you can add to

A separate iPhone and iPad app from Edge (landscape). Fly planes and helicopters in 3D around an island: take off,
climb over the mountains, fly a circuit of rings, and come back and land.

- **Controls:** a stick on the right (pitch and roll), a throttle on the left (the collective, on a helicopter) and a
  rudder slider beside it. Outside and cockpit views.
- **Instruments:** speed, altitude, climb rate, heading, height above the ground on the way down, and a stall warning.
- **Flight:** planes fly on their wings: lift from speed and angle to the air, drag, thrust, a stall, a ground roll.
  A plane's stall speed, top speed and power come from its file and hold true in flight. Helicopters hover, lean to
  move and level themselves.
- **Landing:** touch down gently and level and you get your sink rate and a verdict; too hard, banked, nose first,
  into a hillside or the sea and it is a crash. Helicopters can land anywhere flat.
- **The world:** one island about 12 km across with beaches, forest, rock and snow, two airports (North Field, South
  Strip), clouds, and nine rings to fly through from North Field.

Six aircraft come with it: three planes (Sky Hopper, Bumble, Arrow Jet) and three that fly as helicopters
(Whirlybird, Big Lifter, Saucer).

## Adding aircraft

Every aircraft is one `.json` file: its name, how it flies, and the solid shapes it is built from.
`Skylark/Resources/How to make aircraft.txt` explains every setting. Two ways to add one:

- **On the phone, no rebuild:** in the Files app open On My iPhone › Skylark, copy a file from `Examples` into
  `Aircraft`, change its `"id"` and anything else, then tap **Reload aircraft** in the Hangar. Mistakes in a file are
  listed there with what is wrong.
- **Built in:** add the file to `Skylark/Aircraft/` (named after its id) and push. `python3 scripts/aircraft.py check`
  validates the files, and `python3 scripts/aircraft.py sheet out.png` draws side, top and front views of them all.

## Adding a new way of flying

`"type"` in an aircraft file picks a flight model. There are two, `plane` (`Sim/PlaneFlight.swift`) and `helicopter`
(`Sim/HelicopterFlight.swift`). To add another (a glider, an airship), write a struct that conforms to `FlightModel`
and add one line to `FlightModels.all` in `Sim/FlightModel.swift`; aircraft files can then use the new name.

## Where things are

| | |
| --- | --- |
| `Aircraft/*.json` | the built-in aircraft |
| `Aircraft/AircraftSpec.swift`, `AircraftCatalog.swift` | reading and checking aircraft files, built in and from the Files folder |
| `Aircraft/AircraftBuilder.swift` | building the 3D model from the parts |
| `Sim/FlightModel.swift`, `PlaneFlight.swift`, `HelicopterFlight.swift` | the physics |
| `Sim/FlightSimulator.swift` | the frame loop: landings, crashes, rings, cameras (SceneKit) |
| `World/Terrain.swift`, `WorldBuilder.swift` | the island, airports, sea, sky, trees, clouds |
| `Views/` | menu, instruments and controls, hangar (SwiftUI) |
| `scripts/` | `aircraft.py` (check and draw aircraft), `terrain.py` (map of the island), `plane.py` (the plane physics, to try numbers) |

Every push to `Skylark/` builds `Skylark-unsigned.ipa` into a `skylark-build-N` release. Sign it while installing with
AltStore / SideStore or Sideloadly, or install it with TrollStore.

Build locally: `cd Skylark && xcodegen generate && open Skylark.xcodeproj`.
