#!/usr/bin/env python3
"""Draws Skylark's app icon (the Sky Hopper climbing past a star) into Skylark/Assets.xcassets."""
import json, math, os
from PIL import Image, ImageDraw
import aircraft

S = 1024
img = Image.new("RGBA", (S, S))
px = img.load()
top, bottom = (58, 150, 228), (190, 232, 252)
for y in range(S):
    t = y / (S - 1)
    c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,)
    for x in range(S):
        px[x, y] = c
d = ImageDraw.Draw(img, "RGBA")
for cx, cy, r in ((250, 800, 90), (370, 760, 120), (500, 810, 95), (380, 840, 100), (760, 250, 60), (840, 225, 78), (915, 262, 56)):
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(255, 255, 255, 235))
star = [(215 + math.cos(math.pi / 2 + i * math.pi / 5) * (95 if i % 2 == 0 else 42), 235 - math.sin(math.pi / 2 + i * math.pi / 5) * (95 if i % 2 == 0 else 42)) for i in range(10)]
d.polygon(star, fill=(255, 214, 26, 255))
d.line(star + [star[0]], fill=(242, 153, 26, 255), width=12, joint="curve")

spec = json.load(open(os.path.join(aircraft.FOLDER, "sky-hopper.json")))
layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
aircraft.draw(spec, layer, (S // 2 - 20, S // 2 + 40), 8.6)
img.alpha_composite(layer.rotate(16, resample=Image.BICUBIC, center=(S // 2, S // 2)))
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Skylark", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")
img.convert("RGB").save(out)
print("wrote", os.path.normpath(out))
