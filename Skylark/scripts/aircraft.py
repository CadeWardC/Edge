#!/usr/bin/env python3
"""Checks every aircraft file and draws them, the same way the app does.

    aircraft.py check            validate Skylark/Aircraft/*.json
    aircraft.py sheet out.png    draw all of them on one sheet
"""
import glob, json, math, os, sys
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
FOLDER = os.path.join(HERE, "..", "Skylark", "Aircraft")
TYPES = {"plane", "helicopter"}
SHAPES = {"ellipse", "rect", "polygon"}
ANIMATIONS = {"none", "propeller", "rotor", "spin", "blink"}


def color(text):
    text = text.lstrip("#")
    if len(text) not in (6, 8):
        raise ValueError(f"bad colour #{text}")
    values = [int(text[i:i + 2], 16) for i in range(0, len(text), 2)]
    return tuple(values + [255] if len(values) == 3 else values)


def check(spec, name):
    for key in ("id", "name", "type", "parts"):
        assert key in spec, f"{name}: missing '{key}'"
    assert spec["type"] in TYPES, f"{name}: unknown type {spec['type']}"
    assert spec["parts"], f"{name}: no parts"
    for i, part in enumerate(spec["parts"]):
        where = f"{name}: part {i + 1}"
        assert part.get("shape") in SHAPES, f"{where}: unknown shape"
        assert part.get("animation", "none") in ANIMATIONS, f"{where}: unknown animation"
        color(part["color"])
        if "outline" in part:
            color(part["outline"])
        if part["shape"] == "polygon":
            assert len(part["points"]) >= 3 and all(len(p) == 2 for p in part["points"]), f"{where}: bad points"
        else:
            assert part["width"] > 0 and part["height"] > 0, f"{where}: needs width and height"


def outline_points(part):
    """The part's outline as points in aircraft units (x forward, y up), and its pivot."""
    shape = part["shape"]
    if shape == "polygon":
        pts = [tuple(p) for p in part["points"]]
        xs, ys = [p[0] for p in pts], [p[1] for p in pts]
        pivot = ((min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2)
        if part.get("smooth"):
            n, out = len(pts), []
            mid = lambda a, b: ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)
            for i in range(n):
                start, ctrl, end = mid(pts[i], pts[(i + 1) % n]), pts[(i + 1) % n], mid(pts[(i + 1) % n], pts[(i + 2) % n])
                for s in range(12):
                    t = s / 12
                    out.append(((1 - t) ** 2 * start[0] + 2 * (1 - t) * t * ctrl[0] + t * t * end[0],
                                (1 - t) ** 2 * start[1] + 2 * (1 - t) * t * ctrl[1] + t * t * end[1]))
            pts = out
    else:
        cx, cy, w, h = part.get("x", 0), part.get("y", 0), part["width"], part["height"]
        pivot = (cx, cy)
        if shape == "ellipse":
            pts = [(cx + w / 2 * math.cos(a), cy + h / 2 * math.sin(a)) for a in (2 * math.pi * i / 48 for i in range(48))]
        else:
            r = min(part.get("radius", 0), w / 2, h / 2)
            pts = []
            for qx, qy, a0 in ((1, 1, 0), (-1, 1, 90), (-1, -1, 180), (1, -1, 270)):
                ox, oy = cx + qx * (w / 2 - r), cy + qy * (h / 2 - r)
                for s in range(7):
                    a = math.radians(a0 + 15 * s)
                    pts.append((ox + r * math.cos(a), oy + r * math.sin(a)))
    angle = math.radians(part.get("rotation", 0))
    if angle:
        c, s = math.cos(angle), math.sin(angle)
        pts = [(pivot[0] + (x - pivot[0]) * c - (y - pivot[1]) * s, pivot[1] + (x - pivot[0]) * s + (y - pivot[1]) * c) for x, y in pts]
    return pts


def draw(spec, image, center, scale, hitbox=False):
    for part in spec["parts"]:
        layer = Image.new("RGBA", image.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        pts = [(center[0] + x * scale, center[1] - y * scale) for x, y in outline_points(part)]
        d.polygon(pts, fill=color(part["color"]))
        if "outline" in part:
            d.line(pts + [pts[0]], fill=color(part["outline"]), width=max(1, round(1.5 * scale)))
        image.alpha_composite(layer)
    if hitbox and "hitbox" in spec:
        w, h = spec["hitbox"]["width"] * scale / 2, spec["hitbox"]["height"] * scale / 2
        ImageDraw.Draw(image).rectangle((center[0] - w, center[1] - h, center[0] + w, center[1] + h), outline=(255, 0, 255, 255), width=2)


def load_all():
    specs = []
    for path in sorted(glob.glob(os.path.join(FOLDER, "*.json"))):
        spec = json.load(open(path))
        check(spec, os.path.basename(path))
        assert spec["id"] + ".json" == os.path.basename(path), f"{path}: the file name should be the id"
        specs.append(spec)
    assert len({s["id"] for s in specs}) == len(specs), "two aircraft share an id"
    return specs


if __name__ == "__main__":
    specs = load_all()
    print("ok:", ", ".join(s["id"] for s in specs))
    if len(sys.argv) > 2 and sys.argv[1] == "sheet":
        scale, cell = 5, (640, 420)
        sheet = Image.new("RGBA", (cell[0] * 3, cell[1] * ((len(specs) + 2) // 3)), (135, 196, 235, 255))
        for i, spec in enumerate(specs):
            draw(spec, sheet, (cell[0] * (i % 3) + cell[0] // 2, cell[1] * (i // 3) + cell[1] // 2), scale, hitbox=True)
        sheet.save(sys.argv[2])
