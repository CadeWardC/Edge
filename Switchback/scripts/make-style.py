#!/usr/bin/env python3
"""Writes Switchback's own map styles (MapLibre style JSON), light and dark:
Switchback/Resources/switchback-style.json and switchback-style-dark.json.

Map data: OpenFreeMap (OpenMapTiles schema, from OpenStreetMap). Hillshading: AWS Terrain Tiles (terrarium).
Point-of-interest icons ("sb-<class>") are drawn by the app at runtime from SF Symbols.
Edit the palettes here and run it again.
"""
import json, os

LIGHT = dict(
    bg="#f4f1ea", wood="#c9dfb8", scrub="#d8e6c4", grass="#dfeacb", farm="#efeddf", wetland="#cfe3d9",
    sand="#f3e9cb", ice="#ffffff", rock="#e2ded6",
    residential="#ebe6dc", commercial="#f2e4e1", industrial="#ebe3ee", cemetery="#d5e5cd", hospital="#f6dfdf",
    school="#f2ebd4", pitch="#cde7c0", military="#f1dede",
    park="#cbe5b8", reserve="#c2deac", park_line="#78a862",
    water="#9ecae8", water_line="#8bbde0",
    hill_shadow="#46392a", hill_high="#ffffff", hill_accent="#8a7f6f", hill_ex=0.5,
    building="#e5ded3", building_line="#d4cbbe", building_3d="#e8e1d6",
    runway="#dedad2",
    motorway="#f5b462", motorway_case="#d4934a", trunk="#f9c47b", trunk_case="#d9a25e",
    primary="#fde39b", primary_case="#d9bd72", secondary="#ffffff", secondary_case="#d3c9b9",
    minor="#ffffff", minor_case="#dcd4c7", tunnel="#f4f1ea", track="#a8825a", path="#8a572e", cycle="#5e94c2",
    rail="#b4ada3", ferry="#5c9bd0", boundary2="#8f7ea9", boundary4="#a99bbd",
    text="#3a3a3a", text_soft="#6b6b6b", halo="rgba(255,255,255,0.92)", water_text="#2f6f9f",
    park_text="#3a6a2c", path_text="#7a4a22", peak_text="#5a3d1f", place_text="#2b2b2b", state_text="#8a7f96",
)
DARK = dict(
    bg="#1d2022", wood="#22302a", scrub="#25302a", grass="#252f29", farm="#23272a", wetland="#203030",
    sand="#2c2a24", ice="#2e3338", rock="#2a2b2c",
    residential="#24272a", commercial="#2a2628", industrial="#27252c", cemetery="#22302a", hospital="#2d2526",
    school="#2a2925", pitch="#22302a", military="#2c2526",
    park="#213428", reserve="#1f3a29", park_line="#4f7f5a",
    water="#1d3a52", water_line="#25486a",
    hill_shadow="#000000", hill_high="#3c4248", hill_accent="#16191b", hill_ex=0.45,
    building="#2c3034", building_line="#363b40", building_3d="#30353a",
    runway="#33363a",
    motorway="#a26a32", motorway_case="#5a3c20", trunk="#8c6436", trunk_case="#4e3820",
    primary="#6f6340", primary_case="#3c3626", secondary="#4a4e53", secondary_case="#2c2f33",
    minor="#3d4146", minor_case="#2a2d31", tunnel="#2a2d31", track="#8a6c4c", path="#c08a5a", cycle="#5e94c2",
    rail="#4b4f54", ferry="#4a85b8", boundary2="#8a7aa3", boundary4="#6d6380",
    text="#d9dcdf", text_soft="#a2a8ae", halo="rgba(20,22,24,0.9)", water_text="#8cc3ec",
    park_text="#8fc497", path_text="#e0b088", peak_text="#e2c9a8", place_text="#eceef0", state_text="#a49bb3",
)

NAME = ["coalesce", ["get", "name:en"], ["get", "name"]]
REG, BOLD, ITAL = ["Noto Sans Regular"], ["Noto Sans Bold"], ["Noto Sans Italic"]

def z(*stops, kind="linear"):
    curve = ["exponential", 1.4] if kind == "exp" else ["linear"]
    return ["interpolate", curve, ["zoom"], *[v for s in stops for v in s]]

def cls(*names, key="class"):
    return ["match", ["get", key], list(names), True, False]

def build(C):
    HALO = {"text-halo-color": C["halo"], "text-halo-width": 1.4, "text-halo-blur": 0.3}
    L = []
    def add(**kw):
        src = kw.pop("src", None)
        if src:
            kw["source"] = "openmaptiles"
            kw["source-layer"] = src
        L.append(kw)

    # ---- ground
    add(id="background", type="background", paint={"background-color": C["bg"]})
    for c, col, op in [("farmland", "farm", 0.8), ("grass", "grass", 0.9), ("wood", "wood", 1), ("wetland", "wetland", 0.9),
                       ("sand", "sand", 0.9), ("ice", "ice", 0.95), ("rock", "rock", 0.9)]:
        add(id=f"landcover-{c}", type="fill", src="landcover", filter=cls(c),
            paint={"fill-color": C[col], "fill-opacity": z((4, op * 0.5), (10, op)), "fill-antialias": False})
    add(id="landcover-scrub", type="fill", src="landcover", filter=cls("scrub", "heath", key="subclass"),
        paint={"fill-color": C["scrub"], "fill-opacity": 0.8, "fill-antialias": False})
    for name, classes, col, minz in [
        ("residential", ("residential", "suburb", "quarter", "neighbourhood"), "residential", 6),
        ("commercial", ("commercial", "retail"), "commercial", 11),
        ("industrial", ("industrial", "garages", "railway", "dam"), "industrial", 11),
        ("cemetery", ("cemetery",), "cemetery", 11),
        ("hospital", ("hospital",), "hospital", 11),
        ("school", ("school", "university", "college", "kindergarten"), "school", 11),
        ("pitch", ("pitch", "stadium", "playground", "track", "zoo", "theme_park"), "pitch", 12),
        ("military", ("military",), "military", 10),
    ]:
        add(id=f"landuse-{name}", type="fill", src="landuse", minzoom=minz, filter=cls(*classes),
            paint={"fill-color": C[col], "fill-opacity": z((minz, 0.4), (minz + 2, 0.85))})
    add(id="park", type="fill", src="park",
        paint={"fill-color": ["match", ["get", "class"], ["national_park", "nature_reserve", "protected_area"], C["reserve"], C["park"]],
               "fill-opacity": z((4, 0.35), (10, 0.55), (14, 0.65))})
    add(id="park-outline", type="line", src="park", minzoom=8,
        paint={"line-color": C["park_line"], "line-width": z((8, 0.6), (14, 1.8)), "line-dasharray": [3, 2], "line-opacity": 0.75})
    add(id="hillshade", type="hillshade", source="terrain",
        paint={"hillshade-exaggeration": C["hill_ex"], "hillshade-shadow-color": C["hill_shadow"],
               "hillshade-highlight-color": C["hill_high"], "hillshade-accent-color": C["hill_accent"],
               "hillshade-illumination-anchor": "viewport"})

    # ---- water
    add(id="water", type="fill", src="water", filter=["!=", ["get", "brunnel"], "tunnel"],
        paint={"fill-color": C["water"]})
    add(id="waterway-river", type="line", src="waterway", filter=cls("river", "canal"),
        layout={"line-cap": "round", "line-join": "round"},
        paint={"line-color": C["water_line"], "line-width": z((8, 0.8), (12, 2), (16, 6), (18, 12), kind="exp")})
    add(id="waterway-stream", type="line", src="waterway", minzoom=11,
        filter=["all", cls("stream", "drain", "ditch"), ["!=", ["get", "intermittent"], 1]],
        layout={"line-cap": "round", "line-join": "round"},
        paint={"line-color": C["water_line"], "line-width": z((11, 0.5), (15, 1.4), (18, 3))})
    add(id="waterway-stream-intermittent", type="line", src="waterway", minzoom=11,
        filter=["all", cls("stream", "drain", "ditch"), ["==", ["get", "intermittent"], 1]],
        paint={"line-color": C["water_line"], "line-width": z((11, 0.5), (15, 1.4), (18, 3)), "line-dasharray": [3, 2]})

    # ---- airports
    add(id="aeroway-area", type="fill", src="aeroway", minzoom=10, filter=["==", ["geometry-type"], "Polygon"],
        paint={"fill-color": C["runway"], "fill-opacity": 0.6})
    add(id="aeroway-runway", type="line", src="aeroway", minzoom=10, filter=cls("runway"),
        paint={"line-color": C["runway"], "line-width": z((10, 2), (14, 18), (18, 80), kind="exp")})

    # ---- buildings: flat, then 3D when close
    add(id="building", type="fill", src="building", minzoom=13, maxzoom=15.5,
        paint={"fill-color": C["building"], "fill-outline-color": C["building_line"], "fill-opacity": z((13, 0.4), (14.5, 1))})
    add(id="building-3d", type="fill-extrusion", src="building", minzoom=15,
        paint={"fill-extrusion-color": C["building_3d"],
               "fill-extrusion-height": ["coalesce", ["get", "render_height"], 6],
               "fill-extrusion-base": ["coalesce", ["get", "render_min_height"], 0],
               "fill-extrusion-opacity": z((15, 0), (16, 0.82))})

    # ---- roads (tunnels, then surface, then bridges)
    ROADS = [  # class, fill, casing, widths at z (6, 10, 14, 18), min zoom
        ("motorway", "motorway", "motorway_case", (0.8, 2.5, 8, 26), 5),
        ("trunk", "trunk", "trunk_case", (0.6, 2.2, 7, 22), 5),
        ("primary", "primary", "primary_case", (0.4, 1.8, 6.5, 20), 7),
        ("secondary", "secondary", "secondary_case", (0.3, 1.4, 6, 18), 8),
        ("tertiary", "secondary", "secondary_case", (0.2, 1.2, 5, 16), 9),
        ("minor", "minor", "minor_case", (0, 0.6, 4, 14), 12),
        ("service", "minor", "minor_case", (0, 0.3, 2, 8), 14),
    ]
    def road_layers(brunnel):
        bf = ["==", ["get", "brunnel"], brunnel] if brunnel else ["!", ["match", ["get", "brunnel"], ["bridge", "tunnel"], True, False]]
        tag = brunnel or "road"
        # paths and tracks
        add(id=f"{tag}-track", type="line", src="transportation", minzoom=11, filter=["all", bf, cls("track")],
            paint={"line-color": C["track"], "line-width": z((11, 0.8), (16, 2.4), (18, 4)), "line-dasharray": [3, 1.6]})
        add(id=f"{tag}-path", type="line", src="transportation", minzoom=12,
            filter=["all", bf, cls("path"), ["!", cls("cycleway", key="subclass")]],
            paint={"line-color": C["path"], "line-width": z((12, 0.9), (16, 2), (18, 3.4)), "line-dasharray": [1.6, 1.1]})
        add(id=f"{tag}-cycleway", type="line", src="transportation", minzoom=13,
            filter=["all", bf, cls("path"), cls("cycleway", key="subclass")],
            paint={"line-color": C["cycle"], "line-width": z((13, 0.9), (18, 3)), "line-dasharray": [2, 1.2]})
        for c, fill, case, w, minz in reversed(ROADS):
            wz = z((6, w[0]), (10, w[1]), (14, w[2]), (18, w[3]), kind="exp")
            cz = z((6, w[0] + 0.4), (10, w[1] + 1), (14, w[2] + 2), (18, w[3] + 4), kind="exp")
            add(id=f"{tag}-{c}-casing", type="line", src="transportation", minzoom=max(minz, 10 if c in ("secondary", "tertiary") else minz),
                filter=["all", bf, cls(c)],
                layout={"line-cap": "butt" if brunnel else "round", "line-join": "round"},
                paint={"line-color": C[case], "line-width": cz,
                       **({"line-dasharray": [0.6, 0.4]} if brunnel == "tunnel" else {})})
        for c, fill, case, w, minz in reversed(ROADS):
            wz = z((6, w[0]), (10, w[1]), (14, w[2]), (18, w[3]), kind="exp")
            add(id=f"{tag}-{c}", type="line", src="transportation", minzoom=minz, filter=["all", bf, cls(c)],
                layout={"line-cap": "round", "line-join": "round"},
                paint={"line-color": C["tunnel"] if brunnel == "tunnel" else C[fill], "line-width": wz})
    road_layers("tunnel")
    road_layers(None)
    add(id="rail", type="line", src="transportation", minzoom=10, filter=cls("rail", "transit"),
        paint={"line-color": C["rail"], "line-width": z((10, 0.6), (16, 2))})
    add(id="rail-hatch", type="line", src="transportation", minzoom=14, filter=cls("rail"),
        paint={"line-color": C["rail"], "line-width": z((14, 4), (18, 8)), "line-dasharray": [0.15, 2.5]})
    add(id="ferry", type="line", src="transportation", minzoom=9, filter=cls("ferry"),
        paint={"line-color": C["ferry"], "line-width": 1.2, "line-dasharray": [3, 2]})
    road_layers("bridge")

    # ---- boundaries
    add(id="boundary-state", type="line", src="boundary", filter=["all", ["==", ["get", "admin_level"], 4], ["!=", ["get", "maritime"], 1]],
        paint={"line-color": C["boundary4"], "line-width": z((3, 0.6), (10, 1.6)), "line-dasharray": [4, 2, 1, 2]})
    add(id="boundary-country", type="line", src="boundary", filter=["all", ["==", ["get", "admin_level"], 2], ["!=", ["get", "maritime"], 1]],
        paint={"line-color": C["boundary2"], "line-width": z((2, 0.8), (10, 2.4))})

    # ---- labels (lowest priority first)
    add(id="housenumber", type="symbol", src="housenumber", minzoom=17,
        layout={"text-field": ["get", "housenumber"], "text-font": REG, "text-size": 10},
        paint={"text-color": C["text_soft"], **HALO})
    add(id="waterway-label", type="symbol", src="waterway", minzoom=12, filter=["has", "name"],
        layout={"text-field": NAME, "text-font": ITAL, "text-size": z((12, 10), (16, 13)), "symbol-placement": "line",
                "text-letter-spacing": 0.08, "symbol-spacing": 400},
        paint={"text-color": C["water_text"], **HALO})
    add(id="path-label", type="symbol", src="transportation_name", minzoom=14, filter=cls("path", "track"),
        layout={"text-field": NAME, "text-font": ITAL, "text-size": z((14, 10.5), (18, 13)), "symbol-placement": "line"},
        paint={"text-color": C["path_text"], **HALO})
    add(id="road-label-minor", type="symbol", src="transportation_name", minzoom=14, filter=cls("minor", "service"),
        layout={"text-field": NAME, "text-font": REG, "text-size": z((14, 10), (18, 13)), "symbol-placement": "line"},
        paint={"text-color": C["text_soft"], **HALO})
    add(id="road-label-major", type="symbol", src="transportation_name", minzoom=11,
        filter=cls("motorway", "trunk", "primary", "secondary", "tertiary"),
        layout={"text-field": ["coalesce", NAME, ["get", "ref"]], "text-font": REG,
                "text-size": z((11, 10), (16, 13), (18, 15)), "symbol-placement": "line"},
        paint={"text-color": C["text"], **HALO})
    POI = [  # (classes, colour) — icon images "sb-<class>" are made by the app
        (("restaurant", "fast_food", "cafe", "bar", "pub", "ice_cream", "bakery"), "#e8833a"),
        (("shop", "grocery", "supermarket", "convenience", "clothing_store", "outdoor"), "#3f7fd8"),
        (("lodging", "hotel", "hostel", "motel"), "#8a62c9"),
        (("campsite", "picnic_site", "shelter", "viewpoint", "attraction", "park", "information", "drinking_water", "toilets"), "#3d8b45"),
        (("hospital", "doctors", "pharmacy"), "#d24b4b"),
        (("fuel", "parking", "bus", "railway", "car"), "#6b7280"),
        (("school", "college", "library", "museum", "town_hall", "place_of_worship"), "#8b6b45"),
    ]
    color_expr = ["match", ["get", "class"]]
    for classes, col in POI:
        color_expr += [list(classes), col]
    color_expr.append("#6b7280")
    add(id="poi", type="symbol", src="poi", minzoom=13,
        filter=["any", ["<=", ["get", "rank"], ["step", ["zoom"], 4, 15, 12, 16, 22, 17, 40]],
                cls("campsite", "picnic_site", "shelter", "viewpoint", "drinking_water", "toilets", "parking", "information")],
        layout={"icon-image": ["concat", "sb-", ["get", "class"]], "icon-size": 0.5, "icon-anchor": "bottom",
                "text-field": NAME, "text-font": REG, "text-size": 11, "text-anchor": "top", "text-offset": [0, 0.2],
                "text-max-width": 8, "text-optional": True, "symbol-sort-key": ["get", "rank"]},
        paint={"text-color": color_expr, **HALO})
    add(id="water-label", type="symbol", src="water_name", filter=["has", "name"],
        layout={"text-field": NAME, "text-font": ITAL, "text-size": z((8, 11), (14, 14)), "text-letter-spacing": 0.08,
                "text-max-width": 7},
        paint={"text-color": C["water_text"], **HALO})
    add(id="park-label", type="symbol", src="park", minzoom=8, filter=["has", "name"],
        layout={"text-field": NAME, "text-font": ITAL,
                "text-size": z((8, 11), (14, 13.5)), "text-max-width": 8, "symbol-sort-key": ["coalesce", ["get", "rank"], 10]},
        paint={"text-color": C["park_text"], **HALO})
    for units, field, suffix in [("imperial", "ele_ft", " ft"), ("metric", "ele", " m")]:
        add(id=f"peak-label-{units}", type="symbol", src="mountain_peak", minzoom=9, filter=cls("peak", "volcano"),
            layout={"icon-image": "sb-peak", "icon-size": 0.45, "icon-anchor": "bottom",
                    "text-field": ["concat", NAME, ["case", ["has", field], ["concat", "\n", ["to-string", ["get", field]], suffix], ""]],
                    "text-font": REG, "text-size": 11, "text-anchor": "top", "text-offset": [0, 0.15], "text-optional": True,
                    "symbol-sort-key": ["get", "rank"],
                    "visibility": "visible" if units == "imperial" else "none"},
            paint={"text-color": C["peak_text"], **HALO})
    add(id="airport-label", type="symbol", src="aerodrome_label", minzoom=9,
        layout={"icon-image": "sb-airport", "icon-size": 0.5, "text-field": NAME, "text-font": REG, "text-size": 11,
                "text-anchor": "top", "text-offset": [0, 0.8], "text-optional": True, "text-max-width": 8},
        paint={"text-color": C["text_soft"], **HALO})
    add(id="place-neighbourhood", type="symbol", src="place", minzoom=13, filter=cls("neighbourhood", "quarter", "suburb"),
        layout={"text-field": NAME, "text-font": REG, "text-size": z((13, 10), (16, 12)), "text-transform": "uppercase",
                "text-letter-spacing": 0.12, "text-max-width": 7},
        paint={"text-color": C["text_soft"], **HALO})
    add(id="place-village", type="symbol", src="place", minzoom=10, filter=cls("village", "hamlet", "isolated_dwelling"),
        layout={"text-field": NAME, "text-font": REG, "text-size": z((10, 11), (15, 14)), "text-max-width": 8},
        paint={"text-color": C["place_text"], **HALO})
    add(id="place-town", type="symbol", src="place", minzoom=7, filter=cls("town"),
        layout={"text-field": NAME, "text-font": REG, "text-size": z((7, 11), (12, 14), (15, 17)), "text-max-width": 8},
        paint={"text-color": C["place_text"], **HALO})
    add(id="place-city", type="symbol", src="place", minzoom=3, filter=cls("city"),
        layout={"text-field": NAME, "text-font": BOLD,
                "text-size": ["interpolate", ["linear"], ["zoom"], 4, ["case", ["<=", ["get", "rank"], 3], 13, 11],
                              10, ["case", ["<=", ["get", "rank"], 3], 19, 15], 14, 21],
                "text-max-width": 8, "symbol-sort-key": ["get", "rank"]},
        paint={"text-color": C["place_text"], **HALO})
    add(id="place-state", type="symbol", src="place", minzoom=3, maxzoom=9, filter=cls("state", "province"),
        layout={"text-field": NAME, "text-font": REG, "text-size": z((3, 10), (7, 14)), "text-transform": "uppercase",
                "text-letter-spacing": 0.18, "text-max-width": 8},
        paint={"text-color": C["state_text"], **HALO})
    add(id="place-country", type="symbol", src="place", maxzoom=7, filter=cls("country"),
        layout={"text-field": NAME, "text-font": BOLD, "text-size": z((1, 11), (6, 16)), "text-max-width": 7},
        paint={"text-color": C["place_text"], **HALO})

    return {
        "version": 8,
        "name": "Switchback Outdoors",
        "glyphs": "https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf",
        "sources": {
            "openmaptiles": {"type": "vector", "url": "https://tiles.openfreemap.org/planet"},
            "terrain": {
                "type": "raster-dem", "encoding": "terrarium", "tileSize": 256, "maxzoom": 13,
                "tiles": ["https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"],
                "attribution": "Terrain: Mapzen / AWS Terrain Tiles",
            },
        },
        "layers": L,
    }

here = os.path.join(os.path.dirname(__file__), "..", "Switchback", "Resources")
for name, pal in [("switchback-style.json", LIGHT), ("switchback-style-dark.json", DARK)]:
    style = build(pal)
    with open(os.path.join(here, name), "w") as f:
        json.dump(style, f, ensure_ascii=False, separators=(",", ":"))
    print("wrote", name, len(style["layers"]), "layers")
