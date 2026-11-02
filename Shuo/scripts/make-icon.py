#!/usr/bin/env python3
"""Draws Shuō's app icon (说 with a tone contour) into Shuo/Assets.xcassets. Usage: make-icon.py <CJK font file>"""
import os, sys
from PIL import Image, ImageDraw, ImageFont

S = 1024
img = Image.new("RGB", (S, S))
px = img.load()
top, bottom = (232, 64, 60), (180, 24, 54)
for y in range(S):
    t = y / (S - 1)
    c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    for x in range(S):
        px[x, y] = c
d = ImageDraw.Draw(img, "RGBA")
font = ImageFont.truetype(sys.argv[1], 600)
d.text((S / 2, S / 2 + 40), "说", font=font, fill=(255, 248, 235, 255), anchor="mm")
# a rising-falling tone contour above the character
pts = [(220, 230), (360, 180), (512, 150), (664, 180), (804, 260)]
d.line(pts, fill=(255, 214, 102, 255), width=26, joint="curve")
for p in (pts[0], pts[-1]):
    d.ellipse((p[0] - 13, p[1] - 13, p[0] + 13, p[1] + 13), fill=(255, 214, 102, 255))
out = os.path.join(os.path.dirname(__file__), "..", "Shuo", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")
img.save(out)
print("wrote", os.path.normpath(out))
