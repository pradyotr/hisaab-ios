"""Generates App/Assets.xcassets/AppIcon.appiconset/AppIcon.png.

Style: inspired by a Japanese noren (shop curtain): a flat wine-red background with a golden-white
palm-leaf manuscript (pothi) bound at the left and fanned out evenly above and below the centre line.
Needs Pillow: `pip install pillow`.
Usage: python scripts/make-icon.py [output.png]
"""
import random
import sys

from PIL import Image, ImageDraw, ImageFilter

OUT = sys.argv[1] if len(sys.argv) > 1 else "App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
K = 2                      # supersampling factor
S = 1024 * K

WINE = (112, 28, 42)
GOLD = (240, 226, 190)     # golden white
GOLD_DEEP = (206, 172, 108)
INK = (124, 38, 48)

random.seed(7)


def px(v):
    return int(round(v * K))


# ---------- manuscript ----------
LEAF_LEN, LEAF_H = 650, 104
PIVOT = (282, 512)                  # binding hole, vertically centred
ANGLES = [15, -15, 7.5, -7.5, 0]    # back to front: outer leaves first, the written leaf on top
HOLE_X = 70                         # hole distance from the leaf's left end


def leaf_layer(front):
    """One leaf drawn horizontally with its hole at PIVOT, as an RGBA layer."""
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)
    x0 = PIVOT[0] - HOLE_X
    y0 = PIVOT[1] - LEAF_H / 2
    box = [px(x0), px(y0), px(x0 + LEAF_LEN), px(y0 + LEAF_H)]
    r = px(LEAF_H * 0.42)
    # Wine "resist" outline separates overlapping leaves, like an undyed line on cloth.
    ld.rounded_rectangle([box[0] - px(7), box[1] - px(7), box[2] + px(7), box[3] + px(7)],
                         radius=r + px(7), fill=WINE + (255,))
    ld.rounded_rectangle(box, radius=r, fill=GOLD + (255,))
    ld.rounded_rectangle([box[0] + px(9), box[1] + px(9), box[2] - px(9), box[3] - px(9)],
                         radius=r - px(9), outline=GOLD_DEEP + (255,), width=px(2.5))
    if front:
        # Rows of script: short strokes with a headline, hinting at Devanagari.
        for i in range(3):
            y = y0 + LEAF_H * (0.30 + 0.21 * i)
            x = x0 + HOLE_X + 46
            end = x0 + LEAF_LEN - 40
            while x < end:
                w = min(random.uniform(16, 52), end - x)
                ld.line([(px(x), px(y)), (px(x + w), px(y))], fill=INK + (255,), width=px(3))
                for _ in range(random.randint(1, 3)):
                    sx = random.uniform(x + 2, x + w - 2)
                    ld.line([(px(sx), px(y)), (px(sx + random.uniform(-3, 3)), px(y + random.uniform(7, 12)))],
                            fill=INK + (255,), width=px(2.5))
                x += w + random.uniform(8, 16)
        # Ruled margins at both ends, as on real pothis.
        for mx in (x0 + HOLE_X + 28, x0 + LEAF_LEN - 26):
            ld.line([(px(mx), px(y0 + 14)), (px(mx), px(y0 + LEAF_H - 14))], fill=GOLD_DEEP + (255,), width=px(2.5))
    return layer


def bezier(p0, p1, p2, p3, n=80):
    pts = []
    for i in range(n + 1):
        t = i / n
        u = 1 - t
        pts.append(tuple(px(u**3 * a + 3 * u * u * t * b + 3 * u * t * t * c + t**3 * e)
                         for a, b, c, e in zip(p0, p1, p2, p3)))
    return pts


art = Image.new("RGBA", (S, S), (0, 0, 0, 0))
for i, ang in enumerate(ANGLES):
    layer = leaf_layer(front=(i == len(ANGLES) - 1))
    # PIL rotates counter-clockwise; a positive angle here tilts the leaf's right end down.
    layer = layer.rotate(-ang, resample=Image.BICUBIC, center=(px(PIVOT[0]), px(PIVOT[1])))
    art = Image.alpha_composite(art, layer)

ad = ImageDraw.Draw(art)
# Binding hole and the cord through it, ending in a knot and tassel.
hx, hy = px(PIVOT[0]), px(PIVOT[1])
ad.ellipse([hx - px(17), hy - px(17), hx + px(17), hy + px(17)], fill=WINE + (255,))
ad.ellipse([hx - px(9), hy - px(9), hx + px(9), hy + px(9)], fill=GOLD_DEEP + (255,))
cord = bezier(PIVOT, (PIVOT[0] - 60, PIVOT[1] - 70), (PIVOT[0] - 130, PIVOT[1] + 10), (PIVOT[0] - 95, PIVOT[1] + 150))
ad.line(cord, fill=WINE + (255,), width=px(17), joint="curve")
ad.line(cord, fill=GOLD + (255,), width=px(8), joint="curve")
kx, ky = PIVOT[0] - 95, PIVOT[1] + 150
ad.ellipse([px(kx - 15), px(ky - 15), px(kx + 15), px(ky + 15)], fill=GOLD + (255,), outline=WINE + (255,), width=px(4))
for dx in (-9, -3, 3, 9):
    ad.line([(px(kx + dx * 0.6), px(ky + 10)), (px(kx + dx), px(ky + 64))], fill=GOLD + (255,), width=px(4))

# Slight softness on the art edges.
art = art.filter(ImageFilter.GaussianBlur(px(0.6)))
img = Image.alpha_composite(Image.new("RGBA", (S, S), WINE + (255,)), art).convert("RGB")

out = img.resize((1024, 1024), Image.LANCZOS)
out.save(OUT, "PNG")
print("wrote", OUT, out.size, out.mode)
