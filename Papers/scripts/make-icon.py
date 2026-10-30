#!/usr/bin/env python3
"""Renders Papers/Assets.xcassets/AppIcon.appiconset/AppIcon.png (1024x1024, no alpha): a page with sound waves."""
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

S = 4096  # supersampled, scaled down at the end
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(__file__), "..", "Papers", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")

TOP, BOTTOM = (38, 92, 196), (20, 44, 120)   # blue -> deep navy
LINE = (176, 190, 214)
ACCENT = (38, 92, 196)

grad = Image.new("RGB", (1, 256))
for y in range(256):
    t = y / 255
    grad.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)))
img = grad.resize((S, S), Image.BICUBIC)

# the page, left of centre, with a folded corner
px0, py0, px1, py1 = int(S * 0.17), int(S * 0.15), int(S * 0.62), int(S * 0.85)
fold = int(S * 0.11)
page = [(px0, py0), (px1 - fold, py0), (px1, py0 + fold), (px1, py1), (px0, py1)]

shadow = Image.new("L", (S, S), 0)
ImageDraw.Draw(shadow).polygon([(x + 40, y + 70) for x, y in page], fill=120)
shadow = shadow.filter(ImageFilter.GaussianBlur(80))
img.paste((5, 15, 50), (0, 0), shadow)

d = ImageDraw.Draw(img)
d.polygon(page, fill="white")
d.polygon([(px1 - fold, py0), (px1 - fold, py0 + fold), (px1, py0 + fold)], fill=(214, 222, 236))

# a title bar and text lines
lw = int(S * 0.028)
d.rounded_rectangle((px0 + int(S * 0.06), py0 + int(S * 0.08), px0 + int(S * 0.27), py0 + int(S * 0.08) + int(lw * 1.6)),
                    lw, fill=ACCENT)
for i in range(7):
    y = py0 + int(S * 0.20) + i * int(S * 0.075)
    right = px1 - int(S * 0.06) - (int(S * 0.12) if i in (3, 6) else 0)
    d.rounded_rectangle((px0 + int(S * 0.06), y, right, y + lw), lw // 2, fill=LINE)

# sound waves coming off the page
wx, wy = int(S * 0.62), int(S * 0.52)
for rad, alpha in [(0.10, 255), (0.17, 215), (0.24, 170)]:
    rr = int(S * rad)
    layer = Image.new("L", (S, S), 0)
    ImageDraw.Draw(layer).arc((wx - rr, wy - rr, wx + rr, wy + rr), -42, 42, fill=alpha, width=int(S * 0.034))
    img.paste((255, 255, 255), (0, 0), layer)

img = img.resize((1024, 1024), Image.LANCZOS)
os.makedirs(os.path.dirname(os.path.abspath(OUT)), exist_ok=True)
img.save(OUT, optimize=True)
print("wrote", os.path.abspath(OUT))
