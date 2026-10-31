#!/usr/bin/env python3
"""Draws Edge's app icon (a page with a sound wave) into Edge/Assets.xcassets."""
import math, os
from PIL import Image, ImageDraw, ImageFilter

S = 1024
img = Image.new("RGB", (S, S))
px = img.load()
top, bottom = (24, 30, 74), (88, 44, 160)
for y in range(S):
    t = y / (S - 1)
    c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    for x in range(S):
        px[x, y] = c

d = ImageDraw.Draw(img, "RGBA")
# soft glow
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(glow).ellipse((180, 160, 844, 824), fill=(140, 120, 255, 90))
img.paste(glow.filter(ImageFilter.GaussianBlur(120)), (0, 0), glow.filter(ImageFilter.GaussianBlur(120)))

# the page
d = ImageDraw.Draw(img, "RGBA")
d.rounded_rectangle((292, 190, 732, 790), radius=48, fill=(250, 250, 255, 255))
d.polygon([(612, 190), (732, 310), (612, 310)], fill=(205, 205, 230, 255))
for i, w in enumerate([300, 340, 260]):
    y = 270 + i * 46
    d.rounded_rectangle((350, y, 350 + w - 70 if i == 0 else 350 + w, y + 18), radius=9, fill=(190, 192, 215, 255))

# the sound wave
cx, cy = 512, 600
bars = [0.25, 0.5, 0.85, 1.0, 0.7, 0.95, 0.55, 0.3]
bw, gap = 30, 16
x0 = cx - (len(bars) * bw + (len(bars) - 1) * gap) / 2
for i, h in enumerate(bars):
    x = x0 + i * (bw + gap)
    hh = 150 * h
    color = (int(90 + 80 * i / 7), int(70 + 20 * i / 7), 235, 255)
    d.rounded_rectangle((x, cy - hh, x + bw, cy + hh), radius=bw // 2, fill=color)

out = os.path.join(os.path.dirname(__file__), "..", "Edge", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")
img.save(out)
print("wrote", os.path.normpath(out))
