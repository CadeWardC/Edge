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
