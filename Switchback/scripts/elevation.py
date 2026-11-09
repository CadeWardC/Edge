"""Detailed elevation for trail packs, kept small.

For each trail's main line: sample the terrain every 10 m (AWS Terrain Tiles, terrarium PNGs, zoom 13 ≈ 15 m), work
out gain / descent / lowest / highest from those raw samples, then keep only the points the chart can't redraw within
1.5 m (Douglas–Peucker on the profile) and store them as deltas: distance in 10 m steps, height in whole metres,
encoded like the shapes. Typically a fifth to a third of the samples survive.
"""
import io, math, os, urllib.request
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor

import numpy as np

ZOOM = 13
STEP = 10.0          # metres between samples
TOLERANCE = 1.5      # metres of height the simplified chart may be off by
THRESHOLD = 2.0      # ignore wiggles smaller than this when adding up the climb (as the app does)
TILE_URL = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"

def tile_xy(lat, lon, z=ZOOM):
    n = 2 ** z
    x = (lon + 180) / 360 * n
    r = math.radians(max(-85.05, min(85.05, lat)))
    y = (1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * n
    return x, y

class Terrain:
    """Terrain tiles, downloaded once into a folder and decoded on demand (a few thousand kept in memory)."""
    def __init__(self, cache_dir, keep=3000):
        self.dir = cache_dir
        os.makedirs(cache_dir, exist_ok=True)
        self.mem = OrderedDict()
        self.keep = keep

    def fetch_all(self, tiles, workers=32):
        todo = [t for t in tiles if not os.path.exists(self._path(t))]
        def get(t):
            z, x, y = t
            for attempt in range(4):
                try:
                    req = urllib.request.Request(TILE_URL.format(z=z, x=x, y=y), headers={"User-Agent": "Switchback trail packs"})
                    with urllib.request.urlopen(req, timeout=30) as r:
                        data = r.read()
                    with open(self._path(t), "wb") as f:
                        f.write(data)
                    return True
                except Exception:
                    pass
            return False
        with ThreadPoolExecutor(workers) as ex:
            ok = sum(ex.map(get, todo))
        return ok, len(todo)

    def _path(self, t):
        return os.path.join(self.dir, "%d_%d_%d.png" % t)

    def grid(self, t):
        if t in self.mem:
            self.mem.move_to_end(t)
            return self.mem[t]
        from PIL import Image
        try:
            img = np.asarray(Image.open(self._path(t)).convert("RGB"), dtype=np.float32)
            g = img[:, :, 0] * 256 + img[:, :, 1] + img[:, :, 2] / 256 - 32768
        except Exception:
            g = None
        self.mem[t] = g
        if len(self.mem) > self.keep:
            self.mem.popitem(last=False)
        return g

    def sample(self, pts):
        """Heights (m) at the points, bilinear within each tile; None where there's no data."""
        out = []
        for lat, lon in pts:
            x, y = tile_xy(lat, lon)
            tx, ty = int(x), int(y)
            g = self.grid((ZOOM, tx, ty))
            if g is None:
                out.append(None)
                continue
            px, py = (x - tx) * 256 - 0.5, (y - ty) * 256 - 0.5
            x0, y0 = int(max(0, min(254, math.floor(px)))), int(max(0, min(254, math.floor(py))))
            fx, fy = max(0.0, min(1.0, px - x0)), max(0.0, min(1.0, py - y0))
            v = (g[y0, x0] * (1 - fx) * (1 - fy) + g[y0, x0 + 1] * fx * (1 - fy)
                 + g[y0 + 1, x0] * (1 - fx) * fy + g[y0 + 1, x0 + 1] * fx * fy)
            out.append(float(v))
        return out

def resample(pts, dist):
    """Points every STEP metres along the line (at most 3000)."""
    cum = [0.0]
    for i in range(1, len(pts)):
        cum.append(cum[-1] + dist(pts[i - 1], pts[i]))
    total = cum[-1]
    if total <= 0:
        return [pts[0]]
    n = min(3000, int(total // STEP) + 1)
    step = total / max(1, n - 1) if n > 1 else 0
    out, j = [], 0
    for i in range(n):
        d = step * i
        while j < len(pts) - 2 and cum[j + 1] < d:
            j += 1
        seg = cum[j + 1] - cum[j]
        t = (d - cum[j]) / seg if seg > 0 else 0
        out.append((pts[j][0] + (pts[j + 1][0] - pts[j][0]) * t, pts[j][1] + (pts[j + 1][1] - pts[j][1]) * t))
    return out, step

def needed_tiles(paths, dist):
    tiles = set()
    for pts in paths:
        r = resample(pts, dist)
        if isinstance(r, tuple):
            for lat, lon in r[0][::5] + [r[0][-1]]:
                x, y = tile_xy(lat, lon)
                tiles.add((ZOOM, int(x), int(y)))
    return tiles

def simplify_profile(ds, es, tol=TOLERANCE):
    """Douglas–Peucker on the profile, measuring the vertical error."""
    n = len(ds)
    if n < 3:
        return list(range(n))
    keep = [False] * n
    keep[0] = keep[-1] = True
    stack = [(0, n - 1)]
    while stack:
        a, b = stack.pop()
        if b <= a + 1:
            continue
        best, idx = 0.0, a
        span = ds[b] - ds[a]
        for i in range(a + 1, b):
            t = (ds[i] - ds[a]) / span if span else 0
            err = abs(es[i] - (es[a] + (es[b] - es[a]) * t))
            if err > best:
                best, idx = err, i
        if best > tol:
            keep[idx] = True
            stack += [(a, idx), (idx, b)]
    return [i for i in range(n) if keep[i]]

def profile(pts, terrain, dist, encode_ints):
    """The stored elevation for a line, or None without terrain data."""
    r = resample(pts, dist)
    if not isinstance(r, tuple):
        return None
    samples, step = r
    hs = terrain.sample(samples)
    if not hs or sum(h is None for h in hs) > len(hs) // 4:
        return None
    last = next(h for h in hs if h is not None)
    filled = []
    for h in hs:                      # fill gaps with the last known height
        last = h if h is not None else last
        filled.append(last)
    # a light median filter removes single-pixel spikes without flattening real bumps
    sm = [sorted(filled[max(0, i - 1):i + 2])[len(filled[max(0, i - 1):i + 2]) // 2] for i in range(len(filled))]
    gain = loss = 0.0
    ref = sm[0]
    for e in sm[1:]:
        if e - ref >= THRESHOLD:
            gain += e - ref
            ref = e
        elif ref - e >= THRESHOLD:
            loss += ref - e
            ref = e
    ds = [i * step for i in range(len(sm))]
    keep = simplify_profile(ds, sm)
    # deltas: steps of `step` metres, whole metres of height
    ints, pi, pe = [], 0, 0
    for i in keep:
        e = int(round(sm[i]))
        ints += [i - pi, e - pe]
        pi, pe = i, e
    return {"s": round(step, 2), "p": encode_ints(ints), "g": round(gain), "l": round(loss),
            "mn": round(min(sm)), "mx": round(max(sm))}
