#!/usr/bin/env python3
"""
NAM2Nano app icon generator — flat neural network glyph.

A minimal 1 -> 3 -> 1 neural network on a graphite macOS squircle.
Colour runs left -> right from orange (analog) through violet to cyan (neural).

Usage:
    python3 Tools/generate_icon.py [output_dir]

Default output: NAM2Nano/Resources/Assets.xcassets/AppIcon.appiconset
Requires Pillow only.
"""
import json
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

SS = 4                     # supersampling factor
BASE = 1024
S = BASE * SS

ORANGE = (255, 138, 28)
PINK = (255, 72, 120)
VIOLET = (150, 96, 255)
CYAN = (40, 212, 240)
BG_TOP = (48, 51, 58)
BG_BOTTOM = (20, 21, 25)

# Network geometry (1024 grid)
X_IN, X_HID, X_OUT = 278, 512, 746
Y_SPREAD = 228
LINE_W = 26
R_IN, R_HID, R_OUT = 52, 46, 52


def u(v):
    return v * SS


def lerp(a, b, k):
    return tuple(int(round(x + (y - x) * k)) for x, y in zip(a, b))


def grad(t):
    t = max(0.0, min(1.0, t))
    stops = [(0.0, ORANGE), (0.35, PINK), (0.68, VIOLET), (1.0, CYAN)]
    for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
        if t <= t1:
            return lerp(c0, c1, (t - t0) / (t1 - t0))
    return CYAN


def t_at(x):
    return (x - X_IN) / (X_OUT - X_IN)


def squircle(cx, cy, half, n=5.0, steps=720):
    pts = []
    for i in range(steps):
        a = 2 * math.pi * i / steps
        c, s = math.cos(a), math.sin(a)
        pts.append((cx + half * math.copysign(abs(c) ** (2 / n), c),
                    cy + half * math.copysign(abs(s) ** (2 / n), s)))
    return pts


def render():
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sq = [(u(x), u(y)) for x, y in squircle(512, 512, 412)]
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).polygon(sq, fill=255)

    # soft drop shadow (Apple icon grid style)
    sh = Image.new("L", (S, S), 0)
    ImageDraw.Draw(sh).polygon([(x, y + u(10)) for x, y in sq], fill=100)
    sh = sh.filter(ImageFilter.GaussianBlur(u(14)))
    canvas.paste(Image.new("RGBA", (S, S), (0, 0, 0, 255)), (0, 0), sh)

    # background: plain graphite vertical gradient
    col = Image.new("RGB", (1, S))
    for y in range(S):
        col.putpixel((0, y), lerp(BG_TOP, BG_BOTTOM, y / (S - 1)))
    art = col.resize((S, S)).convert("RGBA")
    d = ImageDraw.Draw(art)

    a = (X_IN, 512)
    hidden = [(X_HID, 512 - Y_SPREAD), (X_HID, 512), (X_HID, 512 + Y_SPREAD)]
    z = (X_OUT, 512)
    nodes = [(a, R_IN)] + [(h, R_HID) for h in hidden] + [(z, R_OUT)]
    edges = [(a, h) for h in hidden] + [(h, z) for h in hidden]

    for p0, p1 in edges:
        steps = 120
        for i in range(steps):
            x0 = p0[0] + (p1[0] - p0[0]) * i / steps
            y0 = p0[1] + (p1[1] - p0[1]) * i / steps
            x1 = p0[0] + (p1[0] - p0[0]) * (i + 1) / steps
            y1 = p0[1] + (p1[1] - p0[1]) * (i + 1) / steps
            c = grad(t_at((x0 + x1) / 2))
            d.line([(u(x0), u(y0)), (u(x1), u(y1))], fill=c, width=int(u(LINE_W)))
            r = u(LINE_W / 2)
            d.ellipse([u(x1) - r, u(y1) - r, u(x1) + r, u(y1) + r], fill=c)

    for (x, y), r in nodes:
        d.ellipse([u(x - r), u(y - r), u(x + r), u(y + r)], fill=grad(t_at(x)))

    canvas.paste(art, (0, 0), mask)
    return canvas.resize((BASE, BASE), Image.LANCZOS)


SIZES = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        root, "NAM2Nano", "Resources", "Assets.xcassets", "AppIcon.appiconset")
    os.makedirs(out, exist_ok=True)
    master = render()
    master.save(os.path.join(out, "icon_1024.png"))
    images = []
    for pt, sc in SIZES:
        name = f"icon_{pt}x{pt}{'@2x' if sc == 2 else ''}.png"
        master.resize((pt * sc, pt * sc), Image.LANCZOS).save(os.path.join(out, name))
        images.append({"idiom": "mac", "size": f"{pt}x{pt}", "scale": f"{sc}x", "filename": name})
    with open(os.path.join(out, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
    print("Icon written to", out)


if __name__ == "__main__":
    main()
