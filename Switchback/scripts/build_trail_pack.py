#!/usr/bin/env python3
"""Builds Switchback's lightweight trail packs from an OpenStreetMap extract.

    build_trail_pack.py <region.osm.pbf> <region-name> <out-dir>

Writes, into <out-dir>:
  c_<row>_<col>.z   one file per 0.25° cell that has trails: a raw-DEFLATE-compressed JSON list of trails in exactly
                    the format the app saves them (encoded polylines), each trail in the cell where it starts
  index.json        {version, region, cell, bbox, cells: {"row_col": bytes}}

The trail rules mirror the app's live search (Overpass.swift), so ids match and the two can be mixed:
hiking/foot/walking route relations, named paths/footways/bridleways and named tracks, and unnamed paths (joined,
800 m or more). Lines are simplified to 4 m and stored at 1e-5° (about a metre).

Each trail also gets its area: the smallest named park, nature reserve or protected area (conservation areas,
national forests, wildernesses…) its middle lies in, as the tag "switchback:area". Unnamed paths are named from the
map where it says something true ("Connector: A – B" between two named trails, "A spur" off one), and dropped when
they're neither in an area nor joined to a trail nor tagged for hiking (city shortcuts, yard paths).
"""
import json, math, os, sys, zlib
from collections import defaultdict

import osmium
from shapely.geometry import Point, Polygon, MultiPolygon
from shapely.strtree import STRtree

CELL = 0.25
SIMPLIFY_M = 4.0
KEEP_TAGS = {"sac_scale", "surface", "trail_visibility", "operator", "network", "ref", "from", "to", "website",
             "wikidata", "wikimedia_commons", "dog", "symbol", "description", "description:en", "note", "name:en"}
SKIP_ROLES = {"alternative", "excursion", "approach", "connection", "link"}
PAVED = {"paved", "asphalt", "concrete", "paving_stones", "sett", "compacted"}
NO_ACCESS = {"private", "no"}

# ---------------------------------------------------------------- geometry

def dist(a, b):
    la1, la2 = math.radians(a[0]), math.radians(b[0])
    dla, dlo = la2 - la1, math.radians(b[1] - a[1])
    h = math.sin(dla / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin(dlo / 2) ** 2
    return 2 * 6371000 * math.asin(min(1, math.sqrt(h)))

def length(pts):
    return sum(dist(pts[i - 1], pts[i]) for i in range(1, len(pts)))

def seg_dist(p, a, b):
    k = math.cos(math.radians(p[0])) * 111320
    ax, ay = (a[1] - p[1]) * k, (a[0] - p[0]) * 111320
    bx, by = (b[1] - p[1]) * k, (b[0] - p[0]) * 111320
    dx, dy = bx - ax, by - ay
    l2 = dx * dx + dy * dy
    t = 0 if l2 == 0 else max(0, min(1, -(ax * dx + ay * dy) / l2))
    x, y = ax + t * dx, ay + t * dy
    return math.hypot(x, y)

def simplify(pts, tol=SIMPLIFY_M):
    if len(pts) < 3:
        return pts
    keep = [False] * len(pts)
    keep[0] = keep[-1] = True
    stack = [(0, len(pts) - 1)]
    while stack:
        a, b = stack.pop()
        if b <= a + 1:
            continue
        best, idx = 0, a
        for i in range(a + 1, b):
            d = seg_dist(pts[i], pts[a], pts[b])
            if d > best:
                best, idx = d, i
        if best > tol:
            keep[idx] = True
            stack += [(a, idx), (idx, b)]
    return [p for p, k in zip(pts, keep) if k]

def encode(pts):
    out, plat, plon = [], 0, 0
    def put(v):
        v = ~(v << 1) if v < 0 else (v << 1)
        while v >= 0x20:
            out.append(chr((0x20 | (v & 0x1f)) + 63))
            v >>= 5
        out.append(chr(v + 63))
    for la, lo in pts:
        a, b = int(round(la * 1e5)), int(round(lo * 1e5))
        put(a - plat)
        put(b - plon)
        plat, plon = a, b
    return "".join(out)

def decode(s):
    out, i, lat, lon = [], 0, 0, 0
    def nxt():
        nonlocal i
        r = sh = 0
        while True:
            b = ord(s[i]) - 63
            i += 1
            r |= (b & 0x1f) << sh
            sh += 5
            if b < 0x20:
                return ~(r >> 1) if r & 1 else r >> 1
    while i < len(s):
        lat += nxt()
        lon += nxt()
        out.append((lat / 1e5, lon / 1e5))
    return out

def chains(pieces, with_nodes=False):
    """Joins pieces (lists of (node_id, (lat, lon))) that share end nodes into the longest continuous lines."""
    remaining = [p for p in pieces if len(p) >= 2]
    ends = defaultdict(set)
    for i, p in enumerate(remaining):
        ends[p[0][0]].add(i)
        ends[p[-1][0]].add(i)
    used, out = set(), []
    for i in range(len(remaining)):
        if i in used:
            continue
        used.add(i)
        chain = list(remaining[i])
        grown = True
        while grown:
            grown = False
            for at_end in (True, False):
                node = chain[-1][0] if at_end else chain[0][0]
                for j in list(ends[node]):
                    if j in used:
                        continue
                    p = remaining[j]
                    if not at_end:
                        p = list(reversed(p)) if p[0][0] == node else p
                        chain = p[:-1] + chain
                    else:
                        p = p if p[0][0] == node else list(reversed(p))
                        chain = chain + p[1:]
                    used.add(j)
                    grown = True
                    break
        out.append(chain if with_nodes else [c for _, c in chain])
    return out

# ---------------------------------------------------------------- reading OSM

class Relations(osmium.SimpleHandler):
    def __init__(self):
        super().__init__()
        self.routes = {}          # id -> (tags, [(way_id, role)])
        self.member_ways = set()

    def relation(self, r):
        t = r.tags
        if t.get("type") == "route" and t.get("route") in ("hiking", "foot", "walking"):
            members = [(m.ref, m.role) for m in r.members if m.type == "w"]
            self.routes[r.id] = ({k: v for k, v in t}, members)
            self.member_ways.update(w for w, _ in members)

AREA_TAGS = {("boundary", "protected_area"), ("boundary", "national_park"), ("leisure", "park"),
             ("leisure", "nature_reserve")}

class Areas(osmium.SimpleHandler):
    """Named parks, reserves and protected areas, as polygons (assembled from ways and multipolygon relations)."""
    def __init__(self):
        super().__init__()
        self.names, self.polys = [], []

    def area(self, a):
        t = a.tags
        name = t.get("name")
        if not name or not any(t.get(k) == v for k, v in AREA_TAGS):
            return
        try:
            parts = []
            for outer in a.outer_rings():
                shell = [(n.lon, n.lat) for n in outer]
                holes = [[(n.lon, n.lat) for n in inner] for inner in a.inner_rings(outer)]
                if len(shell) >= 4:
                    parts.append(Polygon(shell, [h for h in holes if len(h) >= 4]))
            if not parts:
                return
            geom = parts[0] if len(parts) == 1 else MultiPolygon(parts)
            if not geom.is_valid:
                geom = geom.buffer(0)
            if geom.is_empty:
                return
        except Exception:
            return
        self.names.append(name)
        self.polys.append(geom)

class AreaFinder:
    def __init__(self, areas):
        self.names = areas.names
        self.polys = areas.polys
        self.tree = STRtree(self.polys) if self.polys else None

    def find(self, lat, lon):
        """The smallest named area containing the point."""
        if self.tree is None:
            return None
        p = Point(lon, lat)
        best = None
        for i in self.tree.query(p):
            poly = self.polys[int(i)]
            if poly.contains(p) and (best is None or poly.area < self.polys[best].area):
                best = int(i)
        return self.names[best] if best is not None else None

class Ways(osmium.SimpleHandler):
    def __init__(self, member_ways):
        super().__init__()
        self.member_ways = member_ways
        self.geom = {}            # way id -> [(node_id, (lat, lon))] for route members
        self.named = []           # (way id, name, tags, nodes)
        self.unnamed = []         # (way id, tags, nodes)

    def way(self, w):
        try:
            nodes = [(n.ref, (n.location.lat, n.location.lon)) for n in w.nodes if n.location.valid()]
        except osmium.InvalidLocationError:
            return
        if len(nodes) < 2:
            return
        if w.id in self.member_ways:
            self.geom[w.id] = nodes
        t = w.tags
        hw = t.get("highway")
        if t.get("access") in NO_ACCESS:
            return
        name = t.get("name")
        if name and hw in ("path", "footway", "bridleway") and t.get("footway") not in ("sidewalk", "crossing"):
            self.named.append((w.id, name, {k: v for k, v in t}, nodes))
        elif name and hw == "track" and t.get("tracktype") != "grade1":
            self.named.append((w.id, name, {k: v for k, v in t}, nodes))
        elif not name and hw == "path" and t.get("surface") not in PAVED and "segregated" not in t:
            self.unnamed.append((w.id, {k: v for k, v in t}, nodes))

# ---------------------------------------------------------------- trails

def make_trail(tid, osm_id, source, name, lines, tags, min_len):
    measured = [(l, length(l)) for l in lines if len(l) >= 2]
    if not measured:
        return None
    main, main_len = max(measured, key=lambda m: m[1])
    if main_len < min_len:
        return None
    segs = [simplify(l) for l, ln in measured if ln >= 30]
    path = simplify(main)
    kept = {k: v[:400] for k, v in tags.items() if k in KEEP_TAGS}
    t = {"id": tid, "name": name, "source": source, "osmId": osm_id,
         "segments": [encode(s) for s in segs], "length": round(main_len, 1)}
    if path in segs:
        t["pathIndex"] = segs.index(path)
    else:
        t["path"] = encode(path)
    if kept:
        t["tags"] = kept
    return t, path[0]

HIKING_HINTS = {"sac_scale", "trail_visibility", "mtb:scale"}
NATURAL_SURFACE = {"ground", "dirt", "earth", "grass", "gravel", "fine_gravel", "rock", "pebblestone", "mud", "sand",
                   "unpaved", "wood", "woodchips"}

def middle(pts):
    """The point halfway along a line."""
    total, half = length(pts), length(pts) / 2
    run = 0
    for i in range(1, len(pts)):
        d = dist(pts[i - 1], pts[i])
        if run + d >= half and d > 0:
            t = (half - run) / d
            return (pts[i - 1][0] + (pts[i][0] - pts[i - 1][0]) * t, pts[i - 1][1] + (pts[i][1] - pts[i - 1][1]) * t)
        run += d
    return pts[len(pts) // 2]

def build(pbf):
    areas = Areas()
    areas.apply_file(pbf, locations=True, idx="flex_mem")
    finder = AreaFinder(areas)
    print(f"  {len(areas.names)} named parks and protected areas")
    rel = Relations()
    rel.apply_file(pbf)
    ways = Ways(rel.member_ways)
    ways.apply_file(pbf, locations=True, idx="flex_mem")

    trails, relation_names, route_ends = [], set(), set()
    node_names = defaultdict(set)      # node id -> names of the trails through it
    for rid, (tags, members) in rel.routes.items():
        pieces = []
        rname = tags.get("name")
        for wid, role in members:
            nodes = ways.geom.get(wid)
            if not nodes:
                continue
            route_ends.update((nodes[0][0], nodes[-1][0]))
            if rname:
                for n, _ in nodes:
                    node_names[n].add(rname)
            if role not in SKIP_ROLES:
                pieces.append(nodes)
        name = tags.get("name") or tags.get("name:en") or (f"Route {tags['ref']}" if "ref" in tags else "Unnamed route")
        made = make_trail(f"r{rid}", rid, "osmRelation", name, chains(pieces), tags, 300)
        if made:
            trails.append(made)
            relation_names.add(name.lower())

    for wid, name, tags, nodes in ways.named:
        for n, _ in nodes:
            node_names[n].add(name)
    by_name = defaultdict(list)
    for wid, name, tags, nodes in ways.named:
        if name.lower() not in relation_names:
            by_name[name].append((wid, tags, nodes))
    for name, group in by_name.items():
        end_owner = {}
        for wid, tags, nodes in group:
            end_owner[nodes[0][0]] = end_owner[nodes[-1][0]] = (wid, tags)
        for line in chains([nodes for _, _, nodes in group]):
            first = line[0]
            owner = next(((wid, tags) for wid, tags, nodes in group if any(c == first for _, c in nodes)), (group[0][0], group[0][1]))
            made = make_trail("w%s-%.3f,%.3f" % (name, first[0], first[1]), owner[0], "osmWay", name, [line], owner[1], 400)
            if made:
                trails.append(made)

    pieces, tags_by_end = [], {}
    for wid, tags, nodes in ways.unnamed:
        if nodes[0][0] in route_ends and nodes[-1][0] in route_ends:
            continue
        pieces.append(nodes)
        tags_by_end[nodes[0][0]] = tags_by_end[nodes[-1][0]] = tags
    dropped = 0
    for chain in chains(pieces, with_nodes=True):
        line = [c for _, c in chain]
        # what the ends (and the line) touch
        touch_a = node_names.get(chain[0][0], set())
        touch_z = node_names.get(chain[-1][0], set())
        touched = set().union(*(node_names.get(n, set()) for n, _ in chain)) if chain else set()
        tags = tags_by_end.get(chain[0][0]) or tags_by_end.get(chain[-1][0]) or {}
        mid = middle(line)
        area = finder.find(*mid)
        hiking = any(k in tags for k in HIKING_HINTS) or tags.get("surface") in NATURAL_SURFACE
        if not area and not touched and not hiking and length(line) < 2000:
            dropped += 1
            continue
        if touch_a and touch_z and touch_a != touch_z:
            a, z = sorted(touch_a)[0], sorted(touch_z - touch_a or touch_z)[0]
            name = f"Connector: {a} – {z}"
        elif touch_a or touch_z or touched:
            name = f"{sorted(touch_a or touch_z or touched)[0]} spur"
        else:
            name = "Unnamed trail"
        ka, kz = "%.5f,%.5f" % line[0], "%.5f,%.5f" % line[-1]
        made = make_trail("u" + min(ka, kz) + "|" + max(ka, kz), 0, "osmWay", name, [line], tags, 800)
        if made:
            made[0].setdefault("tags", {})["switchback:unnamed"] = "yes"
            trails.append(made)
    print(f"  dropped {dropped} unnamed paths outside parks that join no trail")

    # every trail's area
    for t, _ in trails:
        lines = [decode(s) for s in t["segments"]]
        main = lines[t.get("pathIndex", 0)] if "pathIndex" in t else decode(t["path"])
        area = finder.find(*middle(main))
        if area:
            t.setdefault("tags", {})["switchback:area"] = area
    return trails

def main():
    pbf, region, out = sys.argv[1], sys.argv[2], sys.argv[3]
    os.makedirs(out, exist_ok=True)
    trails = build(pbf)
    cells = defaultdict(list)
    lats, lons = [], []
    for t, start in trails:
        row, col = math.floor(start[0] / CELL), math.floor(start[1] / CELL)
        cells[f"{row}_{col}"].append(t)
        lats.append(start[0])
        lons.append(start[1])
    index = {"version": os.environ.get("PACK_VERSION", "dev"), "region": region, "cell": CELL,
             "bbox": [min(lats), min(lons), max(lats), max(lons)] if lats else None, "cells": {}}
    total = 0
    for key, ts in sorted(cells.items()):
        raw = json.dumps(ts, ensure_ascii=False, separators=(",", ":")).encode()
        c = zlib.compressobj(9, zlib.DEFLATED, -15)   # raw DEFLATE, which the app reads with NSData's .zlib
        z = c.compress(raw) + c.flush()
        with open(os.path.join(out, f"c_{key}.z"), "wb") as f:
            f.write(z)
        index["cells"][key] = len(z)
        total += len(z)
    with open(os.path.join(out, "index.json"), "w") as f:
        json.dump(index, f, separators=(",", ":"))
    named = sum(1 for t, _ in trails if not t.get("tags", {}).get("switchback:unnamed"))
    print(f"{region}: {len(trails)} trails ({named} named) in {len(cells)} cells, {total / 1024:.0f} KB total, "
          f"largest cell {max(index['cells'].values(), default=0) / 1024:.1f} KB")

if __name__ == "__main__":
    main()
