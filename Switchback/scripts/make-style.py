#!/usr/bin/env python3
"""Writes Switchback's own map style (MapLibre style JSON) to Switchback/Resources/switchback-style.json.

Map data: OpenFreeMap (OpenMapTiles schema, from OpenStreetMap). Hillshading: AWS Terrain Tiles (terrarium).
Edit the colours here and run it again.
"""
import json, os

C = dict(
    bg="#f3f1ea", wood="#cfe2bf", grass="#e2ecd1", farm="#eeeddc", wetland="#d5e6dc", sand="#f2e8c9",
    ice="#f6f9fb", rock="#e4e1da", park="#c6e0b4", park_line="#86b06f", residential="#ebe6dc",
    water="#a9d0ea", waterway="#86bde2", building="#e0d9cf",
    road_casing="#d8cdbb", minor="#ffffff", secondary="#fbe8ab", primary="#f6cf88", motorway="#f0b36a",
    track="#b08655", path="#9a6236", boundary="#b8a6c8",
    label="#3b3b3b", water_label="#3b78a8", peak="#5a3d1f", park_label="#3b6a2d", path_label="#7a4a22",
)
NAME = ["coalesce", ["get", "name:en"], ["get", "name"]]
REG, BOLD, ITAL = ["Noto Sans Regular"], ["Noto Sans Bold"], ["Noto Sans Italic"]
HALO = {"text-halo-color": "rgba(255,255,255,0.92)", "text-halo-width": 1.4}

def zoom(*stops):
    return ["interpolate", ["linear"], ["zoom"], *[v for s in stops for v in s]]

def cls(*names):
    return ["match", ["get", "class"], list(names), True, False]

L = []
def add(**kw):
    L.append(kw)

add(id="background", type="background", paint={"background-color": C["bg"]})
for c, col in [("farmland", "farm"), ("grass", "grass"), ("wood", "wood"), ("wetland", "wetland"),
               ("sand", "sand"), ("ice", "ice"), ("rock", "rock")]:
    add(id=f"landcover-{c}", type="fill", source="openmaptiles", **{"source-layer": "landcover"},
        filter=cls(c), paint={"fill-color": C[col], "fill-opacity": 0.9})
add(id="landuse-residential", type="fill", source="openmaptiles", **{"source-layer": "landuse"},
    filter=cls("residential", "suburb", "neighbourhood"), paint={"fill-color": C["residential"], "fill-opacity": 0.7})
add(id="park", type="fill", source="openmaptiles", **{"source-layer": "park"},
    paint={"fill-color": C["park"], "fill-opacity": 0.45})
add(id="park-outline", type="line", source="openmaptiles", **{"source-layer": "park"},
    paint={"line-color": C["park_line"], "line-width": zoom((8, 0.6), (14, 1.6)), "line-dasharray": [3, 2], "line-opacity": 0.7})
add(id="hillshade", type="hillshade", source="terrain",
    paint={"hillshade-exaggeration": 0.45, "hillshade-shadow-color": "#4f4636",
           "hillshade-highlight-color": "#ffffff", "hillshade-accent-color": "#9e9483"})
add(id="water", type="fill", source="openmaptiles", **{"source-layer": "water"},
    paint={"fill-color": C["water"]})
add(id="waterway", type="line", source="openmaptiles", **{"source-layer": "waterway"},
    paint={"line-color": C["waterway"], "line-width": zoom((8, 0.5), (12, 1), (16, 3))})
add(id="building", type="fill", source="openmaptiles", **{"source-layer": "building"}, minzoom=14,
    paint={"fill-color": C["building"], "fill-outline-color": "#d0c7ba"})
add(id="boundary", type="line", source="openmaptiles", **{"source-layer": "boundary"},
    filter=["<=", ["get", "admin_level"], 4],
    paint={"line-color": C["boundary"], "line-width": 1.2, "line-dasharray": [4, 2]})

# roads: quiet, so trails stand out
major = ("motorway", "trunk", "primary", "secondary", "tertiary")
add(id="road-casing", type="line", source="openmaptiles", **{"source-layer": "transportation"},
    filter=cls(*major), layout={"line-cap": "round", "line-join": "round"},
    paint={"line-color": C["road_casing"], "line-width": zoom((6, 0.8), (10, 2.5), (14, 8), (18, 22))})
add(id="road-minor", type="line", source="openmaptiles", **{"source-layer": "transportation"}, minzoom=11,
    filter=cls("minor", "service"), layout={"line-cap": "round", "line-join": "round"},
    paint={"line-color": C["minor"], "line-width": zoom((11, 0.8), (14, 3), (18, 12))})
add(id="road-track", type="line", source="openmaptiles", **{"source-layer": "transportation"}, minzoom=11,
    filter=cls("track"), paint={"line-color": C["track"], "line-width": zoom((11, 0.8), (16, 2.2)), "line-dasharray": [3, 1.5]})
add(id="path", type="line", source="openmaptiles", **{"source-layer": "transportation"}, minzoom=12,
    filter=cls("path"), paint={"line-color": C["path"], "line-width": zoom((12, 0.9), (16, 2)), "line-dasharray": [1.5, 1.2]})
for name, classes, col, w in [("road-secondary", ("secondary", "tertiary"), "secondary", 6),
                              ("road-primary", ("primary", "trunk"), "primary", 7),
                              ("road-motorway", ("motorway",), "motorway", 8)]:
    add(id=name, type="line", source="openmaptiles", **{"source-layer": "transportation"},
        filter=cls(*classes), layout={"line-cap": "round", "line-join": "round"},
        paint={"line-color": C[col], "line-width": zoom((6, 0.5), (10, 1.6), (14, w), (18, w * 2.6))})

# labels
add(id="waterway-label", type="symbol", source="openmaptiles", **{"source-layer": "waterway"}, minzoom=12,
    layout={"text-field": NAME, "text-font": ITAL, "text-size": 11, "symbol-placement": "line"},
    paint={"text-color": C["water_label"], **HALO})
add(id="water-label", type="symbol", source="openmaptiles", **{"source-layer": "water_name"},
    layout={"text-field": NAME, "text-font": ITAL, "text-size": 12},
    paint={"text-color": C["water_label"], **HALO})
add(id="road-label", type="symbol", source="openmaptiles", **{"source-layer": "transportation_name"}, minzoom=13,
    filter=["!", cls("path", "track")],
    layout={"text-field": NAME, "text-font": REG, "text-size": 10.5, "symbol-placement": "line"},
    paint={"text-color": "#6a6a6a", **HALO})
add(id="path-label", type="symbol", source="openmaptiles", **{"source-layer": "transportation_name"}, minzoom=14,
    filter=cls("path", "track"),
    layout={"text-field": NAME, "text-font": ITAL, "text-size": 11, "symbol-placement": "line"},
    paint={"text-color": C["path_label"], **HALO})
add(id="park-label", type="symbol", source="openmaptiles", **{"source-layer": "park"}, minzoom=9,
    filter=["has", "name"],
    layout={"text-field": NAME, "text-font": ITAL, "text-size": zoom((9, 11), (14, 13)), "text-max-width": 8},
    paint={"text-color": C["park_label"], **HALO})
for units, field, suffix in [("imperial", "ele_ft", " ft"), ("metric", "ele", " m")]:
    add(id=f"peak-label-{units}", type="symbol", source="openmaptiles", **{"source-layer": "mountain_peak"}, minzoom=10,
        layout={"text-field": ["concat", "▲ ", NAME, ["case", ["has", field], ["concat", "\n", ["to-string", ["get", field]], suffix], ""]],
                "text-font": REG, "text-size": 11, "text-anchor": "top", "text-offset": [0, -0.6],
                "visibility": "visible" if units == "imperial" else "none"},
        paint={"text-color": C["peak"], **HALO})
for c, size, font, minz in [("village", 11.5, REG, 10), ("town", 13, REG, 7), ("city", 15, BOLD, 4)]:
    add(id=f"place-{c}", type="symbol", source="openmaptiles", **{"source-layer": "place"}, minzoom=minz,
        filter=cls(c, "hamlet") if c == "village" else cls(c),
        layout={"text-field": NAME, "text-font": font, "text-size": size, "text-max-width": 8},
        paint={"text-color": C["label"], **HALO})

style = {
    "version": 8,
    "name": "Switchback Outdoors",
    "glyphs": "https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf",
    "sources": {
        "openmaptiles": {"type": "vector", "url": "https://tiles.openfreemap.org/planet"},
        "terrain": {
            "type": "raster-dem", "encoding": "terrarium", "tileSize": 256, "maxzoom": 15,
            "tiles": ["https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"],
            "attribution": "Terrain: Mapzen / AWS Terrain Tiles",
        },
    },
    "layers": L,
}
out = os.path.join(os.path.dirname(__file__), "..", "Switchback", "Resources", "switchback-style.json")
with open(out, "w") as f:
    json.dump(style, f, ensure_ascii=False, indent=1)
print("wrote", os.path.normpath(out), len(L), "layers")
