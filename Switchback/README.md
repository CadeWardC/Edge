# Switchback: find trails, follow them, record your hikes

A separate iPhone app from Edge and Shuō. Like the big trail apps, but built on open data with no account, no
subscription and no API keys.

- **Explore:** trails around you or anywhere you search, drawn on the map (Apple Maps, satellite, OpenTopoMap topo, or
  USGS topo in the US). Tap a line to see the trail; switch to the list to sort (closest, shortest, longest, least or
  most climb) and filter (difficulty, length, elevation gain, loops only).
- **Trail page:** the route on a map, length, elevation gain, descent, highest point, estimated time (Naismith's rule),
  difficulty, an interactive elevation chart, OpenStreetMap details (SAC scale, surface, network, operator, website),
  driving directions to the trailhead, GPX export and a bookmark to save it.
- **Record & navigate:** GPS recording that keeps going with the phone locked (distance, time, moving time, pace,
  elevation gain). Follow a trail and it shows how far is left, and buzzes (plus a notification when the phone is
  locked) if you go more than 60 m off it. A hike in progress survives the app being closed.
- **Saved:** bookmarked trails, GPX import (from Files or "Open in Switchback"), and **offline maps**: download the topo
  tiles and the trails for an area, then use it without signal.
- **Activity:** every recorded hike with its map, stats and elevation chart; share as GPX, rename, or save it as a
  trail to follow again.

## Where the data comes from

| | Source | Licence |
| --- | --- | --- |
| Trails | [OpenStreetMap](https://www.openstreetmap.org) via the [Overpass API](https://overpass-api.de) (hiking route relations, plus named paths) | ODbL |
| Elevation | [Open-Meteo elevation API](https://open-meteo.com/en/docs/elevation-api) (Copernicus DEM GLO-90) | CC BY 4.0 |
| Topo map | [OpenTopoMap](https://opentopomap.org) | CC-BY-SA |
| US topo map | [USGS The National Map](https://basemap.nationalmap.gov) | Public domain |

Difficulty is worked out from length + climb (and the SAC scale when mapped); OSM has no star ratings or reviews.
Offline downloads are capped at 12,000 tiles per area and use three connections at a time, to stay polite to the free
tile servers.

Every push to `Switchback/` builds `Switchback-unsigned.ipa` into a `switchback-build-N` release
(`.github/workflows/build-switchback-ipa.yml`). Sign it while installing with AltStore / SideStore / Sideloadly, or use
TrollStore.

Build locally: `cd Switchback && xcodegen generate && open Switchback.xcodeproj`. The icon is drawn by
`scripts/make-icon.py`.
