#!/usr/bin/env python3
"""Renders Edge/Assets.xcassets/AppIcon.appiconset/AppIcon.png (1024x1024, no alpha)."""
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

S = 4096  # supersampled, scaled down at the end
FONT = "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc"
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(__file__), "..", "Edge", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")

TOP, BOTTOM = (240, 78, 56), (178, 24, 44)   # vermilion -> deep red
INK = (196, 36, 48)

# vertical gradient background
grad = Image.new("RGB", (1, 256))
for y in range(256):
    t = y / 255
    grad.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)))
img = grad.resize((S, S), Image.BICUBIC)

# speech bubble, slightly left of centre to leave room for the sound waves
bx0, by0, bx1, by1 = int(S * 0.15), int(S * 0.20), int(S * 0.71), int(S * 0.70)
radius = int(S * 0.13)
tail = [(int(S * 0.27), by1 - 10), (int(S * 0.22), int(S * 0.83)), (int(S * 0.43), by1 - 10)]

shadow = Image.new("L", (S, S), 0)
sd = ImageDraw.Draw(shadow)
sd.rounded_rectangle((bx0, by0 + 60, bx1, by1 + 60), radius, fill=110)
sd.polygon([(x, y + 60) for x, y in tail], fill=110)
shadow = shadow.filter(ImageFilter.GaussianBlur(70))
img.paste((90, 0, 20), (0, 0), shadow)

d = ImageDraw.Draw(img)
d.rounded_rectangle((bx0, by0, bx1, by1), radius, fill="white")
d.polygon(tail, fill="white")

# 说 (speak) centred in the bubble
font = ImageFont.truetype(FONT, int(S * 0.36))
cx, cy = (bx0 + bx1) / 2, (by0 + by1) / 2
l, t, r, b = d.textbbox((0, 0), "说", font=font)
d.text((cx - (l + r) / 2, cy - (t + b) / 2), "说", font=font, fill=INK)

# sound waves to the right of the bubble
wx, wy = int(S * 0.70), int((by0 + by1) / 2)
for i, (rad, alpha) in enumerate([(0.10, 255), (0.17, 215), (0.24, 170)]):
    rr = int(S * rad)
    layer = Image.new("L", (S, S), 0)
    ImageDraw.Draw(layer).arc((wx - rr, wy - rr, wx + rr, wy + rr), -42, 42, fill=alpha, width=int(S * 0.034))
    img.paste((255, 255, 255), (0, 0), layer)

img = img.resize((1024, 1024), Image.LANCZOS)
os.makedirs(os.path.dirname(os.path.abspath(OUT)), exist_ok=True)
img.save(OUT, optimize=True)
print("wrote", os.path.abspath(OUT))
