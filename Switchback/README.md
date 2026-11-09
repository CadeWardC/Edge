# Switchback: find trails, follow them, record your hikes

A separate iPhone app from Edge and Shuō. Like the big trail apps, but built on open data with no account, no
subscription and no API keys.

- **Explore:** trails load by themselves as you move the map, drawn in their difficulty colour with a white outline and
  a hiker pin at each trailhead (pins group into numbered bubbles when they crowd). Base maps: Apple Maps, satellite,
  OpenTopoMap topo, and USGS topo or USGS satellite in the US. Tap a line or pin to see the trail; switch to the list to
  sort (closest, shortest, longest, least or most climb) and filter (difficulty, length, elevation gain, loops only).
- **More trails:** in the US, U.S. Forest Service National Forest System trails are added too (Settings toggle, on by
  default). A Forest Service trail that's already in OpenStreetMap is merged into it (adding its trail number, class,
  surface and grade) instead of being drawn twice. The **hiking routes layer** (map style menu) draws Waymarked Trails'
  worldwide map of signposted hiking routes on top of any base map. **Unnamed trails** (paths mapped in OpenStreetMap
  without a name, joined into continuous lines of at least 800 m, skipping paved paths) are drawn dashed with no pin, and
  named tracks (dirt and fire roads) are included too; both can be turned off in Settings.
- **Our own map:** the "Switchback" map style (the default, on every screen) is drawn by
  [MapLibre](https://maplibre.org) from OpenStreetMap vector tiles served free by [OpenFreeMap](https://openfreemap.org),
  in our own outdoor style, light and dark (`scripts/make-style.py` writes `Resources/switchback-style*.json`, checked
  with MapLibre's style validator): hillshading from AWS Terrain Tiles; land cover and land use; a full road hierarchy
  with casings, bridges and tunnels; rail, ferries and airports; 3D buildings when close; paths and tracks; places,
  parks, water and peaks (with heights in the app's units) labelled at the right sizes; point-of-interest icons drawn
  from SF Symbols. The app's trails sit on top in their difficulty colours with their names along the lines, plus
  trailhead dots, your recorded track, trail highlights and your photos. Apple Maps, satellite and the topo maps are
  still in the map style menu.
- **Small, sharp offline maps:** downloading an area of the Switchback map saves a MapLibre offline pack (vector tiles
  to zoom 14, terrain and fonts). Vector data is redrawn on the phone, so it stays sharp at every zoom with labels, and
  it's a fraction of the size of map pictures.
- **Compact storage:** trail lines are saved as encoded polylines (about 6 characters a point instead of ~40) and every
  file the app writes is compressed with LZFSE; files from earlier versions still load.
- **Trail packs (fastest, lightest), US states and Canadian provinces:** `.github/workflows/trail-packs.yml` turns each state's
  OpenStreetMap extract (Geofabrik) into one compact file per state (`<state>.trails`: a table of contents, then one
  compressed block per 0.25° cell), all published weekly in the single release `trails-us` with `regions.json`. The app
  downloads a state's file once, the first time the map shows it, then has every trail there instantly and offline,
  unpacking only the cells around the map. As soon as the map knows where you are, your area's file downloads (Missouri is about
  0.4 MB, about a second), then the rest of your country quietly on Wi-Fi (the US is about 38 MB), so trails work
  offline wherever you go in it; travelling to another country does the same there. Only the list of areas is built
  into the app (`BUNDLED_STATES: "none"`; `"all"` builds every US state in instead). Each file also holds the trail
  highlights (viewpoints, peaks, waterfalls, water, shelters, campsites, toilets, parking within ~200 m of a trail),
  so trail pages need no live search; paths closed to people on foot are left out; and the build log has a quality
  report per area (routes, named paths, connectors, spurs, how many sit in a named area, suspiciously long trails,
  duplicate names). Each trail also carries detailed elevation (`scripts/elevation.py`): sampled every 10 m from AWS
  Terrain Tiles (zoom 13, ~15 m), with gain, descent, lowest and highest worked out from those samples, and the chart
  reduced to the points it can't redraw within 1.5 m (typically a tenth to a third), stored as small deltas — about
  40–80 bytes a trail, so charts, gain and difficulty are instant and offline. Settings › Check for trail updates checks right away, and a downloaded
  offline map area can be updated with a swipe (only changed pieces are fetched for our own map).
  `scripts/build_trail_pack.py` uses the same rules (and trail ids) as the live search, and also: puts every trail in
  its area (the smallest named park, nature reserve or protected area it lies in); names unnamed paths from the map
  where it's certain ("Connector: A – B", "A spur"); and drops unnamed paths outside parks that join no trail and
  aren't tagged for hiking. No live search is needed inside covered states. The list groups trails by area, and search matches area names.
- **Regions:** the pack job's matrix in `trail-packs.yml` lists the areas (any Geofabrik extract); each becomes one
  `.trails` file with its country, display name and the 1° squares it has trails in (`coverage`), so the app knows
  exactly which file covers a place. US states are built in; others download in the background as soon as the map
  knows your location (or the map shows them), and Settings › Trail regions lists them all to download ahead of a
  trip or remove.
- **Fast:** trails found are cached on the phone in 0.05° cells for two weeks, so places you've seen load instantly and a
  search only fetches the cells it doesn't have. If the main Overpass server is slow, a second one is asked after 3 s
  and the first answer wins. Trail shapes are simplified (Douglas–Peucker, 3 m) to draw quickly.
- **Photos:** each trail page opens with photos from Wikimedia Commons (ones OpenStreetMap or Wikidata link to the
  trail and its sights first, then ones taken nearby, with their author and licence), and a satellite picture of the
  route drawn by MapKit. List rows show small satellite pictures of each trail. Recorded hikes can show the photos you
  took during them (from your library, placed on the map where you took them; they never leave the phone).
- **Highlights:** viewpoints, peaks, waterfalls, lakes, caves, water, shelters, campsites, picnic areas, toilets and
  trailhead parking along each trail (from OpenStreetMap), on the map and listed with their distance along the trail.
- **Trail page:** the route on a map, length, elevation gain, descent, highest point, estimated time (Naismith's rule),
  difficulty, an interactive elevation chart, OpenStreetMap details (SAC scale, surface, network, operator, website),
  driving directions to the trailhead, GPX export and a bookmark to save it.
- **Navigate:** while following a trail, a you-are-here dot on its elevation chart, the climbing left, your
  arrival time (from your own pace) against today's sunset (worked out on the phone), and the distance to the next
  water. Optional spoken updates every mile or km, when you leave the trail and when you reach its end. A Live Activity
  shows time, distance, climb and what's left on the lock screen and in the Dynamic Island.
- **One-tap offline:** "Download for offline" on a trail page saves it and downloads the map around it (about a km of
  margin), as detailed as the size limit allows.
- **Record & navigate:** GPS recording that keeps going with the phone locked (distance, time, moving time, pace,
  elevation gain). Follow a trail and it shows how far is left, and buzzes (plus a notification when the phone is
  locked) if you go more than 60 m off it. A hike in progress survives the app being closed.
- **Saved:** bookmarked trails, GPX import (from Files or "Open in Switchback"), and **offline maps**: download the topo
  or USGS satellite tiles and the trails for an area, then use it without signal. Zooming in past a map's last level (or
  past what you downloaded) enlarges the closest tiles instead of going blank.
- **Activity:** every recorded hike with its map, stats and elevation chart; share as GPX, rename, or save it as a
  trail to follow again.

## Where the data comes from

| | Source | Licence |
| --- | --- | --- |
| Trails | [OpenStreetMap](https://www.openstreetmap.org) via the [Overpass API](https://overpass-api.de) (hiking route relations, plus named paths) | ODbL |
| Photos | [Wikimedia Commons](https://commons.wikimedia.org) and [Wikidata](https://www.wikidata.org) | Each photo's own licence (shown) |
| Elevation | [Open-Meteo elevation API](https://open-meteo.com/en/docs/elevation-api) (Copernicus DEM GLO-90) | CC BY 4.0 |
| Topo map | [OpenTopoMap](https://opentopomap.org) | CC-BY-SA |
| US topo map | [USGS The National Map](https://basemap.nationalmap.gov) (USGSTopo) | Public domain |
| US trails | [USDA Forest Service EDW](https://data.fs.usda.gov/geodata/edw/datasets.php) (National Forest System Trails) | Public domain |
| Hiking routes layer | [Waymarked Trails](https://hiking.waymarkedtrails.org) | CC-BY-SA |
| US satellite | [USGS The National Map](https://basemap.nationalmap.gov) (USGSImageryOnly, NAIP aerial photos) | Public domain |

Difficulty is worked out from length + climb (and the SAC scale when mapped); OSM has no star ratings or reviews.
Offline downloads are capped at 12,000 tiles per area and use three connections at a time, to stay polite to the free
tile servers.

Every push to `Switchback/` builds `Switchback-unsigned.ipa` into a `switchback-build-N` release
(`.github/workflows/build-switchback-ipa.yml`). Sign it while installing with AltStore / SideStore / Sideloadly, or use
TrollStore.

Build locally: `cd Switchback && xcodegen generate && open Switchback.xcodeproj`. The icon is drawn by
`scripts/make-icon.py`.
