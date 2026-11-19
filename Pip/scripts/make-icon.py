#!/usr/bin/env python3
"""Draws Pip's app icon (a photo with a smaller photo floating over its corner) into Pip/Assets.xcassets."""
import os
from PIL import Image, ImageDraw

S = 1024
img = Image.new("RGB", (S, S))
px = img.load()
top, bottom = (38, 46, 92), (16, 18, 40)
for y in range(S):
    t = y / (S - 1)
    c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    for x in range(S):
        px[x, y] = c
d = ImageDraw.Draw(img, "RGBA")


def photo(box, sky, hill, radius, border):
    x0, y0, x1, y1 = box
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)
    ld.rectangle(box, fill=sky)
    w, h = x1 - x0, y1 - y0
    ld.ellipse((x0 + w * 0.62, y0 + h * 0.16, x0 + w * 0.80, y0 + h * 0.16 + w * 0.18), fill=(255, 226, 130, 255))
    ld.polygon([(x0, y1), (x0 + w * 0.36, y0 + h * 0.42), (x0 + w * 0.62, y0 + h * 0.74), (x0 + w * 0.78, y0 + h * 0.58),
                (x1, y0 + h * 0.86), (x1, y1)], fill=hill)
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    img.paste(layer, (0, 0), mask)
    d.rounded_rectangle(box, radius=radius, outline=(255, 255, 255, 255), width=border)


photo((150, 230, 874, 760), (96, 165, 250, 255), (52, 120, 96, 255), 64, 18)
d.rounded_rectangle((500, 506, 920, 836), radius=58, fill=(0, 0, 0, 90))  # shadow under the floating photo
photo((484, 480, 904, 810), (251, 146, 110, 255), (120, 60, 110, 255), 52, 18)
out = os.path.join(os.path.dirname(__file__), "..", "Pip", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")
img.save(out)
print("wrote", os.path.normpath(out))
