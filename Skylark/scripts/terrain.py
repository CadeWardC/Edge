"""Draws a map of the island the game generates (same noise as World/Terrain.swift) and lists flat places for runways.
Usage: terrain.py [x,z,EW|NS ...]   writes terrain.png   (needs numpy and Pillow)"""
import numpy as np, sys
from PIL import Image, ImageDraw
N, SP = 220, 60.0
HALF = N * SP / 2
def value(i, j):
    i = i.astype(np.int64) & 0xffffffff; j = j.astype(np.int64) & 0xffffffff
    h = (i * 374761393 + j * 668265263 + 1013904223) & 0xffffffff
    h = ((h ^ (h >> 13)) * 1274126177) & 0xffffffff
    h ^= h >> 16
    return h / 4294967296.0
def noise(x, z, wl):
    gx, gz = x / wl, z / wl
    i, j = np.floor(gx), np.floor(gz)
    fx, fz = gx - i, gz - j
    ux, uz = fx * fx * (3 - 2 * fx), fz * fz * (3 - 2 * fz)
    a, b, c, d = value(i, j), value(i + 1, j), value(i, j + 1), value(i + 1, j + 1)
    return (a + (b - a) * ux) + ((c + (d - c) * ux) - (a + (b - a) * ux)) * uz
def fbm(x, z):
    t = 0
    for o in range(5):
        t += noise(x + 1000 * o, z - 700 * o, 2800 / 2 ** o) * 0.5 ** o
    return t / 1.9375
def smooth(a, b, v):
    t = np.clip((v - a) / (b - a), 0, 1); return t * t * (3 - 2 * t)
def raw(x, z):
    f = fbm(x, z)
    mask = 1 - smooth(0.5, 0.95, np.hypot(x, z) / HALF)
    return mask * (18 + 2200 * np.maximum(f - 0.3, 0) ** 1.9) - 40 * (1 - mask)
xs = np.arange(N + 1) * SP - HALF
X, Z = np.meshgrid(xs, xs)   # row = z index
H = raw(X, Z)
print("max", H.max(), "land frac", (H > 0).mean(), "pct<40", ((H > 0) & (H < 40)).mean())
# candidate flat spots: lowest height range in 1500x500 window, both orientations
best = []
for hd, (wx, wz) in (("EW", (13, 5)), ("NS", (5, 13))):
    for zi in range(20, N - 20 - 2 * wz, 3):
        for xi in range(20, N - 20 - 2 * wx, 3):
            w = H[zi:zi + 2 * wz, xi:xi + 2 * wx]
            if w.min() > 8: best.append((w.max() - w.min(), w.mean(), hd, xs[xi + wx], xs[zi + wz]))
best.sort()
for b in best[:14]: print([round(float(v), 1) if not isinstance(v, str) else v for v in b])
img = np.zeros((N + 1, N + 1, 3), np.uint8)
gy, gx = np.gradient(H, SP)
shade = np.clip(0.75 + (-gx - gy) * 0.9, 0.35, 1.25)
col = np.where(H[..., None] < 0, [60, 120, 190], np.where(H[..., None] < 4, [220, 205, 150], np.where(H[..., None] < 260, [92, 148, 72], np.where(H[..., None] < 480, [120, 112, 102], [242, 245, 250]))))
img = np.clip(col * np.where(H[..., None] < 0, 1, shade[..., None]), 0, 255).astype(np.uint8)
im = Image.fromarray(img).resize((884, 884), Image.NEAREST)
d = ImageDraw.Draw(im)
for a in sys.argv[1:]:
    x, z, hd = a.split(","); x, z = float(x), float(z)
    px, pz = (x + HALF) / SP * 4, (z + HALF) / SP * 4
    L = 600 / SP * 4
    d.line((px - L, pz, px + L, pz) if hd == "EW" else (px, pz - L, px, pz + L), fill=(255, 0, 0), width=4)
im.save("terrain.png")
