#!/usr/bin/env python3
"""Draws Vanguard's app icon (a tank under a crystal sky) into Vanguard/Assets.xcassets."""
import math, os
from PIL import Image, ImageDraw, ImageFilter

S = 1024
img = Image.new("RGB", (S, S))
px = img.load()
top, bottom = (14, 22, 48), (38, 70, 120)
for y in range(S):
    t = y / (S - 1)
    c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    for x in range(S):
        px[x, y] = c

def glow(box, color, blur):
    g = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(g).ellipse(box, fill=color)
    g = g.filter(ImageFilter.GaussianBlur(blur))
    img.paste(g, (0, 0), g)

glow((200, 120, 824, 700), (90, 200, 255, 110), 140)

d = ImageDraw.Draw(img, "RGBA")
# crystals on the horizon
for cx, h, w in [(220, 260, 70), (300, 340, 80), (380, 220, 60), (660, 240, 64), (740, 330, 84), (820, 230, 60)]:
    base = 640
    pts = [(cx - w // 2, base), (cx - w // 3, base - h), (cx, base - h - 40), (cx + w // 3, base - h), (cx + w // 2, base)]
    d.polygon(pts, fill=(80, 210, 240, 235))
    d.polygon([(cx, base - h - 40), (cx + w // 3, base - h), (cx + w // 2, base), (cx, base)], fill=(40, 150, 200, 235))
    d.line([(cx - w // 6, base - h + 20), (cx - w // 4, base - 20)], fill=(220, 255, 255, 200), width=6)
# ground
d.polygon([(0, 640), (S, 600), (S, S), (0, S)], fill=(34, 58, 40, 255))
d.polygon([(0, 700), (S, 660), (S, S), (0, S)], fill=(28, 46, 33, 255))

# tank (seen from the front-left, chunky and readable)
blue, dblue, lblue = (52, 132, 255), (24, 64, 140), (130, 190, 255)
cx, cy = 512, 720
d.rounded_rectangle((cx - 300, cy - 30, cx + 300, cy + 110), radius=50, fill=(36, 38, 46))
for i in range(7):
    x = cx - 250 + i * 83
    d.ellipse((x - 32, cy + 10, x + 32, cy + 74), fill=(70, 74, 84), outline=(20, 20, 24), width=6)
d.polygon([(cx - 280, cy - 20), (cx + 280, cy - 20), (cx + 230, cy - 120), (cx - 230, cy - 120)], fill=blue)
d.polygon([(cx - 230, cy - 120), (cx + 230, cy - 120), (cx + 200, cy - 140), (cx - 200, cy - 140)], fill=lblue)
d.rectangle((cx - 280, cy - 34, cx + 280, cy - 20), fill=dblue)
# turret and barrel
d.rounded_rectangle((cx - 40, cy - 250, cx + 420, cy - 205), radius=18, fill=(48, 52, 62))
d.rounded_rectangle((cx + 390, cy - 262, cx + 440, cy - 193), radius=10, fill=(30, 32, 38))
d.rounded_rectangle((cx - 170, cy - 300, cx + 150, cy - 140), radius=60, fill=blue)
d.rounded_rectangle((cx - 150, cy - 300, cx + 120, cy - 250), radius=30, fill=lblue)
d.ellipse((cx - 90, cy - 265, cx - 40, cy - 215), fill=(150, 240, 255))
# muzzle glow
glow((cx + 400, cy - 300, cx + 520, cy - 160), (255, 200, 90, 160), 30)

out = os.path.join(os.path.dirname(__file__), "..", "Vanguard", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")
img.save(out)
print("wrote", out)
