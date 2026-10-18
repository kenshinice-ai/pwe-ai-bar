#!/usr/bin/env python3
"""Feature cards for a LinkedIn image post: 1080 x 1350 (4:5), one feature each.

Each card is a crop of a panel the app drew itself (`--panel` for real data, `--stress` for sample
figures), on the film's ground, with the new line ringed in amber and everything else dimmed.

    python3 Video/cards/cards.py <panel-render-dir> <stress-render-dir> <out-dir>

The crops are in the renders' pixels (2x points). If the panel's layout changes, check them against
a fresh render before posting: a ring around the wrong line is worse than no card.
"""
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1080, 1350
GROUND_TOP, GROUND_BOTTOM = (13, 22, 38), (18, 29, 48)   # the film's ground
INK, MUTED, AMBER = (255, 255, 255), (168, 180, 200), (245, 179, 53)
SF = "/System/Library/Fonts/SFNS.ttf"
SPOT_DIM = 0.34
PANEL_W = 920

HERE = Path(__file__).parent


def font(size, weight="Semibold"):
    f = ImageFont.truetype(SF, size)
    f.set_variation_by_name(weight)
    return f


def ground():
    im = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(im)
    for y in range(H):
        t = y / (H - 1)
        d.line([(0, y), (W, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(GROUND_TOP, GROUND_BOTTOM)))
    return im


def wrap(text, f, width):
    """One line if it fits, else two lines as even as the words allow: no word left alone below."""
    if f.getlength(text) <= width:
        return [text]
    words = text.split()
    splits = [(" ".join(words[:i]), " ".join(words[i:])) for i in range(1, len(words))]
    fitting = [p for p in splits if max(map(f.getlength, p)) <= width] or splits
    return list(min(fitting, key=lambda p: max(map(f.getlength, p))))


def card(spec, renders, out):
    im = ground()
    d = ImageDraw.Draw(im)
    x0 = (W - PANEL_W) // 2

    label = font(26, "Semibold")
    d.text((x0, 104), "PWE AI BAR  ·  " + spec["version"], font=label, fill=AMBER)

    title_f, sub_f = font(60, "Bold"), font(34, "Regular")
    y = 158
    for line in wrap(spec["title"], title_f, PANEL_W):
        d.text((x0, y), line, font=title_f, fill=INK)
        y += 74
    y += 14
    for line in wrap(spec["subtitle"], sub_f, PANEL_W):
        d.text((x0, y), line, font=sub_f, fill=MUTED)
        y += 46

    src = Image.open(renders[spec["render"]]).convert("RGB")
    top, bottom = spec["crop"]
    pad = spec.get("pad", 0)
    crop = src.crop((0, top, src.width, bottom))
    if pad:  # a short crop gets the panel's own ground around it, so it still reads as the panel
        bg = src.getpixel((4, top + 2))
        framed = Image.new("RGB", (crop.width, crop.height + 2 * pad), bg)
        framed.paste(crop, (0, pad))
        crop = framed
    scale = PANEL_W / crop.width
    # The app renders at the screen's 2x; scaling up past that softens the type, so sharpen it back.
    panel = crop.resize((PANEL_W, round(crop.height * scale)), Image.LANCZOS)
    panel = panel.filter(ImageFilter.UnsharpMask(radius=1.2, percent=60, threshold=2))

    # Spotlight: dim everything but the new line, then ring it.
    ring = None
    if "spot" in spec and spec.get("dim", True):
        a, b = spec["spot"]
        a, b = round((a - top + pad) * scale), round((b - top + pad) * scale)
        dim = Image.blend(panel, Image.new("RGB", panel.size, (0, 0, 0)), SPOT_DIM)
        mask = Image.new("L", panel.size, 0)
        ImageDraw.Draw(mask).rectangle((0, a, panel.width, b), fill=255)
        panel = Image.composite(panel, dim, mask)
        ring = (a, b)
    elif "spot" in spec:
        a, b = spec["spot"]
        ring = (round((a - top + pad) * scale), round((b - top + pad) * scale))

    # Centred in the space between the words above and the tag below.
    room_top, room_bottom = y + 40, H - 150
    py = room_top + max(0, (room_bottom - room_top - panel.height) // 2)
    radius = 30
    shadow = Image.new("L", (W, H), 0)
    ImageDraw.Draw(shadow).rounded_rectangle((x0, py + 16, x0 + panel.width, py + panel.height + 16),
                                             radius, fill=150)
    im.paste((5, 9, 18), (0, 0), shadow.filter(ImageFilter.GaussianBlur(28)))
    mask = Image.new("L", panel.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, panel.width - 1, panel.height - 1), radius, fill=255)
    im.paste(panel, (x0, py), mask)
    d = ImageDraw.Draw(im)
    d.rounded_rectangle((x0, py, x0 + panel.width - 1, py + panel.height - 1), radius,
                        outline=(48, 60, 84), width=2)
    if ring:
        a, b = ring
        d.rounded_rectangle((x0 + 18, py + a - 6, x0 + panel.width - 18, py + b + 6), 16, outline=AMBER, width=4)

    tag = font(28, "Regular")
    d.text((W // 2, H - 92), spec["tag"], font=tag, fill=MUTED, anchor="mm")
    im.save(out)
    return out


def main():
    panel_dir, stress_dir, out_dir = map(Path, sys.argv[1:4])
    renders = {"panel": panel_dir / "panel-standard-dark.png", "stress": stress_dir / "stress-panel-dark.png"}
    out_dir.mkdir(parents=True, exist_ok=True)
    specs = json.loads((HERE / "cards.json").read_text())
    for i, spec in enumerate(specs["cards"], 1):
        spec.setdefault("version", specs["version"])
        print(card(spec, renders, out_dir / f"card-{i}-{spec['id']}.png"))


if __name__ == "__main__":
    main()
