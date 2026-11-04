#!/usr/bin/env python3
"""Draws Switchback's app icon (a mountain with a zig-zag trail) into Switchback/Assets.xcassets."""
import os
from PIL import Image, ImageDraw, ImageFilter

S = 1024
img = Image.new("RGB", (S, S))
px = img.load()
top, bottom = (255, 196, 120), (233, 110, 80)   # dusk sky
for y in range(S):
    t = y / (S - 1)
    c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    for x in range(S):
        px[x, y] = c

d = ImageDraw.Draw(img, "RGBA")
d.ellipse((620, 150, 800, 330), fill=(255, 240, 200, 255))           # sun
d.polygon([(-40, 820), (250, 430), (430, 640), (560, 470), (1064, 900), (1064, 1064), (-40, 1064)],
          fill=(120, 70, 90, 255))                                     # far ridge
peak = (470, 250)
d.polygon([(-60, 1064), peak, (1084, 1064)], fill=(30, 78, 56, 255))  # main mountain
d.polygon([peak, (395, 360), (440, 340), (470, 380), (510, 345), (548, 362)], fill=(240, 245, 240, 255))  # snow

# the switchback trail
pts = [(250, 1000), (690, 880), (330, 760), (620, 650), (420, 560), (540, 470), (480, 400)]
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).line(pts, fill=(0, 0, 0, 90), width=46, joint="curve")
img.paste(shadow.filter(ImageFilter.GaussianBlur(10)), (0, 8), shadow.filter(ImageFilter.GaussianBlur(10)))
d = ImageDraw.Draw(img, "RGBA")
d.line(pts, fill=(255, 214, 120, 255), width=34, joint="curve")
for p in pts:
    d.ellipse((p[0] - 17, p[1] - 17, p[0] + 17, p[1] + 17), fill=(255, 214, 120, 255))

out = os.path.join(os.path.dirname(__file__), "..", "Switchback", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")
img.save(out)
print("wrote", os.path.normpath(out))
