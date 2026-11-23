#!/usr/bin/env python3
"""Checks every aircraft file and draws rough side, top and front views of them.

    aircraft.py check            validate Skylark/Aircraft/*.json
    aircraft.py sheet out.png    draw all of them on one sheet (needs Pillow and numpy)
"""
import glob, json, math, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
FOLDER = os.path.join(HERE, "..", "Skylark", "Aircraft")
TYPES = {"plane", "helicopter"}
SHAPES = {"box", "sphere", "cylinder", "cone", "wing", "fin"}
SPINS = {"none", "propeller", "rotor", "tailrotor"}


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
        assert part.get("spin", "none") in SPINS, f"{where}: unknown spin"
        color(part["color"])
        assert len(part["size"]) == 3 and all(v > 0 for v in part["size"]), f"{where}: size needs three numbers above 0"
        for key in ("position", "rotation"):
            assert len(part.get(key, [0, 0, 0])) == 3, f"{where}: {key} needs three numbers"


def points(part):
    """Sample points on the part's surface in aircraft axes (x forward, y up, z right)."""
    import numpy as np
    sx, sy, sz = part["size"]
    shape = part["shape"]
    if shape == "box":
        pts = [(a * sx / 2, b * sy / 2, c * sz / 2) for a in (-1, 1) for b in (-1, 1) for c in (-1, 1)]
    elif shape == "sphere":
        pts = [(sx / 2 * math.cos(v) * math.cos(u), sy / 2 * math.sin(v), sz / 2 * math.cos(v) * math.sin(u))
               for u in np.linspace(0, 2 * math.pi, 20) for v in np.linspace(-math.pi / 2, math.pi / 2, 9)]
    elif shape in ("cylinder", "cone"):
        taper = part.get("taper", 1 if shape == "cylinder" else 0)
        pts = [(end * sx / 2, r * sy / 2 * math.cos(u), r * sz / 2 * math.sin(u))
               for end, r in ((-1, 1), (1, taper)) for u in np.linspace(0, 2 * math.pi, 20)]
    else:
        taper, sweep, dihedral = part.get("taper", 1), part.get("sweep", 0), part.get("dihedral", 0)
        span = sz if shape == "wing" else sy
        thick = sy if shape == "wing" else sz
        pts = []
        for s, chord, t, dx, dy in ((0, sx, thick, 0, 0), (span, sx * taper, thick * max(taper, 0.4), -sweep, dihedral)):
            for a in (-1, 1):
                for b in (-1, 1):
                    p = (dx + a * chord / 2, dy + b * t / 2, s)
                    pts.append(p if shape == "wing" else (p[0], p[2], p[1]))
    pts = np.array(pts, float)
    rx, ry, rz = (math.radians(v) for v in part.get("rotation", [0, 0, 0]))
    Rx = np.array([[1, 0, 0], [0, math.cos(rx), -math.sin(rx)], [0, math.sin(rx), math.cos(rx)]])
    Ry = np.array([[math.cos(ry), 0, math.sin(ry)], [0, 1, 0], [-math.sin(ry), 0, math.cos(ry)]])
    Rz = np.array([[math.cos(rz), -math.sin(rz), 0], [math.sin(rz), math.cos(rz), 0], [0, 0, 1]])
    pts = pts @ (Rz @ Ry @ Rx).T + np.array(part.get("position", [0, 0, 0]), float)
    out = [pts]
    if part.get("mirror"):
        out.append(pts * np.array([1, 1, -1]))
    return out


def hull(pts):
    pts = sorted(set(map(tuple, pts)))
    if len(pts) < 3:
        return pts
    def half(seq):
        h = []
        for p in seq:
            while len(h) >= 2 and (h[-1][0] - h[-2][0]) * (p[1] - h[-2][1]) - (h[-1][1] - h[-2][1]) * (p[0] - h[-2][0]) <= 0:
                h.pop()
            h.append(p)
        return h[:-1]
    return half(pts) + half(reversed(pts))


def draw(spec, image, center, scale, view):
    """view: (horizontal axis, vertical axis, depth axis, depth sign)"""
    from PIL import Image, ImageDraw
    h, v, dep, sign = view
    shapes = []
    for part in spec["parts"]:
        for pts in points(part):
            flat = [(center[0] + p[h] * scale, center[1] - p[v] * scale) for p in pts]
            shapes.append((sign * pts[:, dep].mean(), hull(flat), color(part["color"])))
    for _, outline, fill in sorted(shapes, key=lambda s: s[0]):
        layer = Image.new("RGBA", image.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        if len(outline) >= 3:
            d.polygon(outline, fill=fill)
            d.line(outline + [outline[0]], fill=(0, 0, 0, 70), width=1)
        image.alpha_composite(layer)


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
        from PIL import Image
        scale, cell = 26, (400, 300)
        sheet = Image.new("RGBA", (cell[0] * 3, cell[1] * len(specs)), (135, 196, 235, 255))
        for row, spec in enumerate(specs):
            y = cell[1] * row + cell[1] // 2
            draw(spec, sheet, (200, y), scale, (0, 1, 2, 1))     # side
            draw(spec, sheet, (600, y), scale, (0, 2, 1, 1))     # top (right wing towards the top of the page)
            draw(spec, sheet, (1000, y), scale, (2, 1, 0, 1))    # front
        sheet.save(sys.argv[2])
