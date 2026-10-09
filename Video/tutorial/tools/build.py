"""Build the tutorial video from edit.json, a script file and the narration audio.

    python3 tools/build.py script.zh.json --plan            print the timeline, render nothing
    python3 tools/build.py script.zh.json --stills 3 12.5   write PNG frames at those seconds
    python3 tools/build.py script.zh.json                   render build/tutorial-<lang>.mp4
    python3 tools/build.py script.zh.json --layout wide     the same edit at 1920 x 1080: build/tutorial-<lang>-wide.mp4
    python3 tools/build.py script.loop.json --edit loop.json --layout loop --silent
                                                            the silent page loop: build/loop.mp4

Narration sets the clock: a step marked "fit" holds its last frame until the cues started so far
have finished, so one edit serves every language. The camera rests unless a step names a target,
and it never moves while the recorded screen is animating; that is a rule of the edit, kept by
choosing which steps carry "cam".

Ported from the PWE Loan Calculator tutorial (~/Documents/PWE/PWE Loan Calculator/Video/tutorial).
What differs, because this is a Mac window and not a phone:
  - the recording is drawn at its own size, one recorded pixel to one frame pixel, so nothing is resampled;
  - the window appears at once, as it does in the app: no entrance is added to it;
  - a step may carry "keys", drawn as a keycap, for a shortcut the viewer cannot see being pressed;
  - a step of kind "image" shows a file the app wrote (the exported card) in the window's place.
Names still say "phone" where the Loan Calculator code did, to keep the two files comparable.

What is specific to one product is in film.json beside the edit: its name on the title card, its icon,
and for each take its size in pixels, its width in points and its corner radius. A take is fitted into
the layout's stage, so a film may cut between recordings of different sizes (a panel, a strip of the
menu bar). A cue may give "dur" instead of having audio: its caption shows for that long and nothing is
spoken, which is how a film with captions and music but no voice is timed.
"""
import argparse, bisect, json, pathlib, subprocess, wave
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent   # the film's folder; --root points this copy at another film
REPO = ROOT.parent.parent

# Frame and phone window, in output pixels.
W, H = 1080, 1920
STAGE = (70, 290, 940, 1400)               # x, y, width, height: where a take is fitted, never enlarged past its own pixels
FILM = {}                                  # film.json
LAYOUT = "tall"
# Set by use_take() for the take being drawn:
SRC_W, SRC_H, WIN_PT = 940, 1400, 470      # recording pixels, and the recording's width in points
PHONE_W, PHONE_H, PHONE_X, PHONE_Y, PHONE_RADIUS, MAX_ZOOM = 940, 1400, 70, 290, 36, 1.14

CHIP_Y, CAPTION_Y, TAG_Y = 96, 186, 1846
COVER_SOLID, COVER_END = 246, 286          # where the ground closes over an enlarged window; the window at rest starts at 290
SPOT_DIM = 0.34                            # how far the spotlight darkens everything else
GROUND_TOP, GROUND_BOTTOM = (13, 22, 38), (18, 29, 48)
INK, MUTED = (255, 255, 255), (168, 180, 200)

TEXT_X = W // 2                            # centre of the chip, the caption and the sample tag
CARD_W = 1040                              # width of an exported card shown in the window's place
CAPTION_SIZE = {"zh": 46, "en": 40}
CAPTION_WRAP = None                        # widest caption line in pixels; None keeps captions on one line
COVER = True                               # the ground closes over an enlarged window above and below it
CARD = {"title_label": 800, "title_line": 920, "title_step": 124, "end_icon": 560, "end_head": 760,
        "end_lines": 930, "end_step": 78, "foot_step": 48}


def set_layout(name):
    """The frame the same edit is drawn into. 'tall' is the vertical tutorial and the default."""
    global W, H, STAGE, LAYOUT, TEXT_X, CARD_W, CAPTION_SIZE, CAPTION_WRAP
    global COVER, CHIP_Y, CAPTION_Y, TAG_Y, CARD
    LAYOUT = name
    if name == "wide":
        # 16:9. Words on the left, the window on the right at 70% so its whole height fits the frame.
        W, H = 1920, 1080
        STAGE = (1072, 50, 658, 980)
        TEXT_X, CHIP_Y, CAPTION_Y, TAG_Y = 536, 430, 548, 1012
        CARD_W, COVER = 900, False
        CAPTION_SIZE, CAPTION_WRAP = {"zh": 60, "en": 54}, 840
        # The opening line is spoken over the title; in this frame it sits under the title, not beside it.
        CARD = {"title_label": 300, "title_line": 410, "title_step": 120, "title_caption": 700, "end_icon": 170, "end_head": 322,
                "end_lines": 430, "end_step": 70, "foot_step": 44}
    elif name == "loop":
        # The window alone on its ground, for a product page: no words above it, nothing to read but the app.
        # The frame is the main take plus a margin, so each product's loop is the size of its own window.
        main = FILM["takes"][FILM.get("main") or next(iter(FILM["takes"]))]
        sw, sh = main["size"]
        W, H = (sw + 60) // 2 * 2, (sh + 100) // 2 * 2
        STAGE = (30, 36, sw, sh)
        TEXT_X, TAG_Y, CARD_W, COVER = W // 2, sh + 68, sw, False
    elif name != "tall":
        raise SystemExit(f"no layout called {name}")


def use_take(name):
    """Fit one take into the stage and make it the one the drawing code works on."""
    global SRC_W, SRC_H, WIN_PT, PHONE_W, PHONE_H, PHONE_X, PHONE_Y, PHONE_RADIUS, MAX_ZOOM
    take = FILM["takes"][name]
    SRC_W, SRC_H = take["size"]
    WIN_PT = take["points"]
    sx, sy, sw, sh = STAGE
    scale = min(sw / SRC_W, sh / SRC_H, take.get("max_scale", 1.0))
    PHONE_W, PHONE_H = round(SRC_W * scale), round(SRC_H * scale)
    PHONE_X = sx + (sw - PHONE_W) // 2
    PHONE_Y = sy + (sh - PHONE_H) // 2 if take.get("align") == "middle" else sy
    PHONE_RADIUS = max(1, round(take.get("radius", 36) * scale))
    MAX_ZOOM = max(1.0, min(W / PHONE_W, 1 / scale)) if LAYOUT == "tall" else 1.0   # a push-in stops at the take's own pixels


CUE_GAP = 0.30
SAMPLE_RATE = 48000
PAUSE_CAP = 0.32                           # seconds; longer silences inside a cue are shortened to this
PINGFANG = "/System/Library/AssetsV2/com_apple_MobileAsset_Font8/86ba2c91f017a3749571a82f2c6d890ac7ffb2fb.asset/AssetData/PingFang.ttc"
SF = "/System/Library/Fonts/SFNS.ttf"


def smooth(u):
    u = min(1.0, max(0.0, u))
    return u * u * u * (u * (6 * u - 15) + 10)


# ---------------------------------------------------------------- type

def font(size, weight="Semibold", lang="zh"):
    if lang == "zh":
        return ImageFont.truetype(PINGFANG, size, index={"Regular": 3, "Medium": 7, "Semibold": 11}[weight])
    f = ImageFont.truetype(SF, size)
    f.set_variation_by_name(weight)
    return f


def text_image(text, size, weight, lang, fill=INK, tracking=0.0):
    """One line of text on a transparent image, drawn at 2x and reduced for clean edges."""
    f = font(size * 2, weight, lang)
    advance = [f.getlength(ch) + tracking * size * 2 for ch in text]
    width, height = int(sum(advance)) + 8, int(size * 2 * 1.5)
    im = Image.new("RGBA", (max(width, 2), height), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    if tracking:
        x = 4
        for ch, a in zip(text, advance):
            d.text((x, height // 2), ch, font=f, fill=fill, anchor="lm")
            x += a
    else:
        d.text((4, height // 2), text, font=f, fill=fill, anchor="lm")
    return im.resize((im.width // 2, im.height // 2), Image.LANCZOS)


def paste_centered(canvas, im, cx, cy, alpha=1.0):
    if alpha <= 0.003:
        return
    if alpha < 0.997:
        im = im.copy()
        im.putalpha(im.getchannel("A").point(lambda a: int(a * alpha)))
    canvas.alpha_composite(im, (int(cx - im.width / 2), int(cy - im.height / 2)))


# ---------------------------------------------------------------- narration

def read_wav(path):
    with wave.open(str(path)) as w:
        rate, n = w.getframerate(), w.getnframes()
        data = np.frombuffer(w.readframes(n), np.int16).astype(np.float32) / 32768
        if w.getnchannels() == 2:
            data = data.reshape(-1, 2).mean(axis=1)
    return rate, data


def silences(x, rate, floor_db=-42.0, window=0.010):
    """Runs of quiet as (start, end) in seconds, ignoring blips under 30 ms between two runs."""
    hop = int(rate * window)
    n = len(x) // hop
    rms = np.sqrt((x[:n * hop].reshape(n, hop) ** 2).mean(axis=1) + 1e-12)
    quiet = 20 * np.log10(rms) < floor_db
    for i in range(1, n - 3):                 # a breath or click inside a pause is still the pause
        if quiet[i - 1] and not quiet[i] and quiet[i + 1:i + 4].any():
            quiet[i] = True
    runs, start = [], None
    for i, q in enumerate(quiet):
        if q and start is None:
            start = i
        elif not q and start is not None:
            runs.append((start * window, i * window)); start = None
    if start is not None:
        runs.append((start * window, n * window))
    return runs


def cap_pauses(x, rate, cap=PAUSE_CAP):
    """Shorten the pauses inside a cue. The head and tail silences are left exactly as made."""
    runs = silences(x, rate)
    duration = len(x) / rate
    keep, cursor = [], 0
    for a, b in runs:
        if a < 0.05 or b > duration - 0.05 or b - a <= cap:
            continue
        cut_from = int((a + cap / 2) * rate)
        cut_to = int((b - cap / 2) * rate)
        keep.append(x[cursor:cut_from]); cursor = cut_to
    keep.append(x[cursor:])
    return np.concatenate(keep)


def resample(x, rate, to=SAMPLE_RATE):
    if rate == to:
        return x
    n = int(round(len(x) * to / rate))
    return np.interp(np.linspace(0, len(x) - 1, n), np.arange(len(x)), x).astype(np.float32)


def units(text):
    """Rough spoken weight of a caption part, to guess where one part hands over to the next."""
    return sum(1.0 if ch.isalnum() else 0.2 for ch in text)


def load_cues(script):
    """Each cue's audio, its length, and where its caption parts change."""
    lang, out = script["lang"], {}
    for cue in script["cues"]:
        if "dur" in cue:                          # a caption with nothing spoken
            n = len(cue["parts"])
            out[cue["id"]] = {"audio": np.zeros(int(cue["dur"] * SAMPLE_RATE), np.float32), "dur": float(cue["dur"]), "silent": True,
                              "parts": [(cue["dur"] * i / n, cue["dur"] * (i + 1) / n, p["show"]) for i, p in enumerate(cue["parts"])]}
            continue
        rate, x = read_wav(ROOT / "build/audio" / lang / f"{cue['id']}.wav")
        x = resample(cap_pauses(x, rate), rate)
        duration = len(x) / SAMPLE_RATE
        runs = [r for r in silences(x, SAMPLE_RATE) if r[0] > 0.25 and r[1] < duration - 0.3]
        voiced_from = next((b for a, b in silences(x, SAMPLE_RATE) if a < 0.05), 0.0)
        voiced_to = next((a for a, b in reversed(silences(x, SAMPLE_RATE)) if b > duration - 0.05), duration)
        weights = [units(p["say"]) for p in cue["parts"]]
        bounds, acc = [], 0.0
        for w in weights[:-1]:
            acc += w
            guess = voiced_from + (voiced_to - voiced_from) * acc / sum(weights)
            near = min(runs, key=lambda r: abs((r[0] + r[1]) / 2 - guess), default=None)
            bounds.append((near[0] + near[1]) / 2 if near and abs((near[0] + near[1]) / 2 - guess) < 0.9 else guess)
        edges = [max(0.0, voiced_from - 0.05)] + bounds + [min(duration, voiced_to + 0.15)]
        out[cue["id"]] = {"audio": x, "dur": duration,
                          "parts": [(edges[i], edges[i + 1], p["show"]) for i, p in enumerate(cue["parts"])]}
    return out


# ---------------------------------------------------------------- timeline

def plan(edit, cues):
    """Give every step a start and a length, and every cue a start."""
    t, last_cue_end, placed, steps = 0.0, -1.0, {}, []
    for raw in edit["steps"]:
        s = dict(raw)
        s["start"] = t
        speed = s.get("speed", 1.0)
        play = (s.get("out", 0) - s.get("in", 0)) / speed
        for cue_id, offset in s.get("cues", []):
            at = max(t + (offset or 0.0), last_cue_end + CUE_GAP) if offset is not None else last_cue_end + CUE_GAP
            placed[cue_id] = at
            last_cue_end = at + cues[cue_id]["dur"]
        dur = max(play, s.get("dur", 0.0))
        if s.get("fit"):
            dur = max(dur, last_cue_end + s.get("tail", 0.3) - t)
        s["play"], s["len"] = play, dur
        t += dur
        steps.append(s)
    return steps, placed, t


def source_time(step, t):
    return step["in"] + min((t - step["start"]) * step.get("speed", 1.0), step["out"] - step["in"])


def output_time(step, src_t):
    return step["start"] + (src_t - step["in"]) / step.get("speed", 1.0)


# ---------------------------------------------------------------- recording frames

class Take:
    """Sequential reader over a constant-frame-rate proxy; frame(t) may only move forward."""

    def __init__(self, path, start, size):
        self.size = size
        self.first = int(round(start * 60))
        self.proc = subprocess.Popen(
            ["ffmpeg", "-v", "error", "-ss", f"{self.first / 60:.5f}", "-i", str(path), "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
            stdout=subprocess.PIPE)
        self.index, self.image = self.first - 1, None

    def frame(self, t):
        want = max(self.first, int(round(t * 60)))
        while self.index < want:
            raw = self.proc.stdout.read(self.size[0] * self.size[1] * 3)
            if len(raw) < self.size[0] * self.size[1] * 3:
                break
            self.index += 1
            if self.index == want:
                self.image = Image.frombuffer("RGB", self.size, raw)
        return self.index, self.image

    def close(self):
        self.proc.kill(); self.proc.wait()


# ---------------------------------------------------------------- drawing

def rounded_mask(size, radius, scale=4):
    big = Image.new("L", (size[0] * scale, size[1] * scale), 0)
    ImageDraw.Draw(big).rounded_rectangle((0, 0, big.width - 1, big.height - 1), radius * scale, fill=255)
    return big.resize(size, Image.LANCZOS)


def ring_sprite(diameter=132):
    """The touch mark: a soft dark disc with a light rim, so it reads on white cards and on blue buttons."""
    big = Image.new("RGBA", (diameter * 4, diameter * 4), (0, 0, 0, 0))
    d = ImageDraw.Draw(big)
    m = 10 * 4
    d.ellipse((m, m, big.width - m, big.height - m), fill=(18, 30, 54, 56), outline=(255, 255, 255, 225), width=14)
    d.ellipse((m - 6, m - 6, big.width - m + 6, big.height - m + 6), outline=(18, 30, 54, 120), width=6)
    return big.resize((diameter, diameter), Image.LANCZOS)


class Renderer:
    def __init__(self, script, edit, cues):
        self.script, self.lang = script, script["lang"]
        self.steps, self.cue_at, self.total = plan(edit, cues)
        for step in self.steps:                   # a script may point the edit's take names at its own recordings
            if "take" in step:
                step["take"] = script.get("takes", {}).get(step["take"], step["take"])
        self.cues, self.edit = cues, edit
        self.starts = [s["start"] for s in self.steps]
        self.take_assets, self.current_take, self.width_logs = {}, None, {}
        self.ring = ring_sprite()
        self.ground = self._ground()
        self.text_cache, self.reader, self.reader_take = {}, None, None
        self._camera_keys()
        self._captions()
        self.icon = self._icon()

    # -- static pieces

    def _ground(self):
        column = np.linspace(0, 1, H)[:, None]
        grad = np.array(GROUND_TOP)[None, :] * (1 - column) + np.array(GROUND_BOTTOM)[None, :] * column
        rgb = np.repeat(grad[:, None, :], W, axis=1).astype(np.uint8)
        self.ground_rgb = rgb
        self.before_dissolve = None
        return Image.fromarray(rgb, "RGB").convert("RGBA")

    def enter_take(self, name):
        """Switch the drawing code to a take: its place on the frame, its mask, its shadow, its cover."""
        if name == self.current_take:
            return
        use_take(name)
        if name not in self.take_assets:
            pad = 140
            shadow = Image.new("L", (PHONE_W + pad * 2, PHONE_H + pad * 2), 0)
            ImageDraw.Draw(shadow).rounded_rectangle((pad, pad, pad + PHONE_W, pad + PHONE_H), PHONE_RADIUS, fill=150)
            # Opaque ground over the caption band, fading out below it, and a short one above the sample tag.
            alpha = np.zeros((H, W), np.uint8)
            alpha[:COVER_SOLID] = 255
            alpha[COVER_SOLID:COVER_END] = np.linspace(255, 0, COVER_END - COVER_SOLID).astype(np.uint8)[:, None]
            below = min(H - 37, PHONE_Y + PHONE_H + 3)
            alpha[below:below + 36] = np.linspace(0, 255, 36).astype(np.uint8)[:, None]
            alpha[below + 36:] = 255
            self.take_assets[name] = (rounded_mask((PHONE_W, PHONE_H), PHONE_RADIUS), shadow.filter(ImageFilter.GaussianBlur(46)),
                                      Image.fromarray(np.dstack([self.ground_rgb, alpha]), "RGBA"))
        self.mask, self.shadow_sprite, self.top_cover = self.take_assets[name]
        self.current_take = name

    def _icon(self):
        size = 208
        icon = Image.open(REPO / FILM["icon"]).convert("RGBA").resize((size, size), Image.LANCZOS)
        if FILM.get("icon_round", True):          # a full square with its corners baked in: cut them
            icon.putalpha(rounded_mask((size, size), int(size * 0.235)))
        return icon

    def _camera_keys(self):
        self.cam_keys = [(0.0, 0.75, (0.0, 0.0, 1.0))]
        for s in self.steps:
            if "cam" in s:
                cx, cy, z = s["cam"]
                self.cam_keys.append((s["start"], s.get("cam_dur", 0.75), (float(cx), float(cy), float(z))))

    def camera(self, t):
        i = max(0, bisect.bisect_right([k[0] for k in self.cam_keys], t) - 1)
        start, dur, target = self.cam_keys[i]
        if i == 0:
            return target
        before = self.cam_keys[i - 1][2]
        u = smooth((t - start) / dur)
        return tuple(a + (b - a) * u for a, b in zip(before, target))

    def _captions(self):
        self.caption_spans = []
        for cue_id, at in sorted(self.cue_at.items(), key=lambda kv: kv[1]):
            for a, b, show in self.cues[cue_id]["parts"]:
                self.caption_spans.append((at + a, at + b, show, cue_id))

    def text(self, text, size, weight="Semibold", fill=INK, tracking=0.0, lang=None):
        key = (text, size, weight, fill, tracking, lang or self.lang)
        if key not in self.text_cache:
            use = lang or ("en" if text.isascii() else self.lang)
            self.text_cache[key] = text_image(text, size, weight, use, fill, tracking)
        return self.text_cache[key]

    # -- per-frame state

    def step_at(self, t):
        return self.steps[max(0, min(len(self.steps) - 1, bisect.bisect_right(self.starts, t) - 1))]

    def phone_presence(self, t):
        """Whether the window is on screen: exactly while a step shows the take. It arrives at once, as
        the app's window does; the title, the exported card and the end card take its place."""
        return 1.0 if "take" in self.step_at(t) else 0.0

    def keycap(self, canvas, step, t):
        """A shortcut the viewer cannot see being pressed, shown as a key for about a second."""
        for src_t, label in step.get("keys", []):
            dt = t - (output_time(step, src_t) - 0.05)
            if not 0 <= dt < 1.25:
                continue
            alpha = min(smooth(dt / 0.10), smooth((1.25 - dt) / 0.25))
            glyph = self.text(label, 76, "Semibold", lang="en")
            cap = Image.new("RGBA", (glyph.width + 96, 150), (0, 0, 0, 0))
            d = ImageDraw.Draw(cap)
            d.rounded_rectangle((0, 0, cap.width - 1, 149), 30, fill=(18, 30, 54, 240), outline=(255, 255, 255, 110), width=3)
            cap.alpha_composite(glyph, (48, (150 - glyph.height) // 2))
            paste_centered(canvas, cap, PHONE_X + PHONE_W / 2, PHONE_Y + PHONE_H * 0.82, alpha)

    def image_card(self, canvas, step, t):
        """A file the app wrote, shown whole at the width of the frame. A step may carry
        "push": [zoom, start, ease]: after `start` seconds the card grows about its top-left corner, so
        the name and the headline figure can be read on a phone, and it returns to whole before the step
        ends. The right-hand side leaves the frame only while it is enlarged."""
        key = step["image"]
        if key not in self.text_cache:
            self.text_cache[key] = Image.open(ROOT / key).convert("RGBA")
        full = self.text_cache[key]
        width = step.get("width", CARD_W)
        zoom, start, ease = step.get("push", [1.0, 0.0, 0.75])
        into, left = t - step["start"], step["start"] + step["len"] - t
        u = min(smooth((into - start) / ease), smooth((left - 1.3) / ease))
        z = 1.0 + (zoom - 1.0) * max(0.0, u)
        w = round(width * z)
        h = round(full.height * w / full.width)
        cache = ("card", key, w)
        if cache not in self.text_cache:
            if len([k for k in self.text_cache if isinstance(k, tuple) and k[0] == "card"]) > 2:
                for k in [k for k in self.text_cache if isinstance(k, tuple) and k[0] == "card"]:
                    del self.text_cache[k]
            self.text_cache[cache] = full.resize((w, h), Image.LANCZOS)
        im = self.text_cache[cache]
        rest_h = round(full.height * width / full.width)
        x, y = STAGE[0] + (STAGE[2] - width) // 2, STAGE[1] + (STAGE[3] - rest_h) // 2
        pad = 120
        shadow = Image.new("L", (w + pad * 2, h + pad * 2), 0)
        ImageDraw.Draw(shadow).rectangle((pad, pad, pad + w, pad + h), fill=150)
        canvas.paste((0, 0, 0), (x - pad, y - pad + 22), shadow.filter(ImageFilter.GaussianBlur(40)))
        canvas.alpha_composite(im.crop((0, 0, min(w, W - x), min(h, H - y))), (x, y))

    def touches(self, step, t):
        """Touch marks alive at time t: (x, y, scale, alpha) in points."""
        marks = []
        for src_t, x, y in step.get("taps", []):
            dt = t - (output_time(step, src_t) - 0.06)
            if 0 <= dt < 0.16:
                marks.append((x, y, 1.0, 1.0))
            elif 0.16 <= dt < 0.38:
                u = (dt - 0.16) / 0.22
                marks.append((x, y, 1.0 + 0.15 * u, 1.0 - u))
        moves = [(d["t0"], self.edit["paths"][d["path"]]) for d in step.get("drags", [])]
        for t0, x1, y1, x2, y2, dur in step.get("swipes", []):
            moves.append((t0, [[0, x1, y1]] + [[dur * 1000 / 8, x1 + (x2 - x1) * i / 8, y1 + (y2 - y1) * i / 8] for i in range(1, 9)]))
        for t0, path in moves:
            dt = (t - output_time(step, t0)) * step.get("speed", 1.0)
            elapsed, previous = 0.0, path[0]
            if dt < 0:
                continue
            for point in path[1:]:
                span = point[0] / 1000
                if dt <= elapsed + span:
                    u = (dt - elapsed) / span if span else 1.0
                    marks.append((previous[1] + (point[1] - previous[1]) * u, previous[2] + (point[2] - previous[2]) * u, 1.0, 1.0))
                    break
                elapsed, previous = elapsed + span, point
            else:
                after = dt - elapsed
                if after < 0.22:
                    marks.append((previous[1], previous[2], 1.0 + 0.15 * after / 0.22, 1.0 - after / 0.22))
        return marks

    def spot(self, step, t):
        if "spot" not in step:
            return None, 0.0
        into, left = t - step["start"], step["start"] + step["len"] - t
        return step["spot"], min(smooth(into / 0.25), smooth(left / 0.20))

    # -- composing

    def phone_layer(self, step, t, zoom):
        """The recording at the camera's scale, with the touch marks and the spotlight drawn on it."""
        take_path = ROOT / "build/work" / (step["take"] + ".cfr.mp4")
        src_t = source_time(step, t)
        if self.reader is None or self.reader_take != step["take"] or int(round(src_t * 60)) < self.reader.index:
            if self.reader:
                self.reader.close()
            self.reader, self.reader_take = Take(take_path, src_t, (SRC_W, SRC_H)), step["take"]
        index, frame = self.reader.frame(src_t)
        # A take of the menu bar icon is wider than the icon, with the neighbour in the spare room; the
        # recorder noted the icon's own width as it changed, and only that much of the frame is shown.
        shown = self.shown_width(step["take"], src_t)
        if shown < frame.width:
            frame = frame.crop((0, 0, shown, frame.height))
        size = (int(round(PHONE_W * zoom * frame.width / SRC_W)), int(round(PHONE_H * zoom)))
        marks = self.touches(step, t)
        rect, spot_alpha = self.spot(step, t)
        key = (step["take"], index, size, tuple(marks), rect and tuple(rect), round(spot_alpha, 3))
        if key == getattr(self, "_phone_key", None):
            return self._phone
        paint = FILM["takes"][step["take"]].get("paint")
        if paint:                                 # rectangles of the recording to black out: the simulator blinks the Dynamic Island off
            frame = frame.copy()
            for x0, y0, x1, y1 in paint:
                ImageDraw.Draw(frame).rounded_rectangle((x0, y0, x1, y1), (y1 - y0) // 2, fill=(0, 0, 0))
        layer = (frame if size == frame.size else frame.resize(size, Image.LANCZOS)).convert("RGBA")
        k = size[0] / WIN_PT                   # output pixels per point

        if rect and spot_alpha > 0.003:
            x, y, w, h = rect
            veil = Image.new("L", (size[0] // 2, size[1] // 2), int(255 * SPOT_DIM * spot_alpha))
            ImageDraw.Draw(veil).rounded_rectangle((x * k / 2, y * k / 2, (x + w) * k / 2, (y + h) * k / 2), 18 * k / 2, fill=0)
            veil = veil.filter(ImageFilter.GaussianBlur(1.2)).resize(size, Image.BILINEAR)
            layer.alpha_composite(Image.merge("RGBA", (*[Image.new("L", size, 8)] * 3, veil)))
        for px, py, scale, alpha in marks:
            d = int(FILM.get("tap_points", 30) * k * scale * 1.08)   # a pointer's click by default; 44 for a finger
            sprite = self.ring.resize((d, d), Image.LANCZOS)
            if alpha < 0.997:
                sprite.putalpha(sprite.getchannel("A").point(lambda a: int(a * alpha)))
            layer.alpha_composite(sprite, (int(px * k - d / 2), int(py * k - d / 2)))
        self._phone_key, self._phone = key, layer
        return layer

    def shown_width(self, take, src_t):
        """Pixels of a take's frame to show at a moment: all of it, unless film.json names a widths file."""
        path = FILM["takes"][take].get("widths")
        if not path:
            return SRC_W
        if take not in self.width_logs:
            self.width_logs[take] = json.loads((ROOT / path).read_text())
        log = self.width_logs[take]
        now = [w for at, w in log if at <= src_t]
        return min(SRC_W, int(round((now[-1] if now else log[0][1]) * SRC_W / WIN_PT)))

    def draw_phone(self, canvas, step, t, presence):
        _, focus, zoom = self.camera(t)
        zoom = round(min(zoom, MAX_ZOOM) * PHONE_W) / PHONE_W     # never past the take's own pixels
        layer = self.phone_layer(step, t, zoom)
        scale = (0.96 + 0.04 * presence)
        if scale < 0.9995:
            layer = layer.resize((int(layer.width * scale), int(layer.height * scale)), Image.LANCZOS)
        w, h = layer.size
        # The focus height keeps its place on the frame while the phone grows around it.
        x = PHONE_X + (PHONE_W - w) // 2
        y = int(round(PHONE_Y + focus * (PHONE_W / WIN_PT) * (1 - zoom) + (PHONE_H * zoom - h) / 2))
        mask = self.mask if (w, h) == self.mask.size else self.mask.resize((w, h), Image.LANCZOS)
        if presence < 0.997:
            mask = mask.point(lambda a: int(a * presence))
        shadow = self.shadow_sprite if (w, h) == (PHONE_W, PHONE_H) else self.shadow_sprite.resize(
            (int(self.shadow_sprite.width * w / PHONE_W), int(self.shadow_sprite.height * h / PHONE_H)), Image.BILINEAR)
        if presence < 0.997:
            shadow = shadow.point(lambda a: int(a * presence))
        pad = (shadow.width - w) // 2
        canvas.paste((0, 0, 0), (x - pad, y - pad + int(26 * w / PHONE_W)), shadow)
        canvas.paste(layer, (x, y), mask)
        if presence >= 0.997:                       # a hairline of light on the glass edge
            rim = Image.new("RGBA", (w, h), (0, 0, 0, 0))
            ImageDraw.Draw(rim).rounded_rectangle((0, 0, w - 1, h - 1), int(PHONE_RADIUS * w / PHONE_W), outline=(255, 255, 255, 46), width=2)
            canvas.paste(rim, (x, y), rim)
        return zoom

    def frame(self, t):
        step = self.step_at(t)
        canvas = self.ground.copy()
        kind = step.get("kind")
        presence = self.phone_presence(t)
        zoom = 1.0

        if kind == "image":
            self.image_card(canvas, step, t)
            if self.before_dissolve is not None and t - step["start"] < step.get("dissolve", 0.4):
                canvas = Image.blend(self.before_dissolve, canvas, smooth((t - step["start"]) / step.get("dissolve", 0.4)))
            else:
                self.before_dissolve = self.after_image = canvas.copy()
        elif kind == "end" and getattr(self, "after_image", None) is not None and t - step["start"] < 0.45:
            canvas = Image.blend(self.after_image, canvas, smooth((t - step["start"]) / 0.45))
        elif presence > 0.003:
            holder = step if "take" in step else self.steps[self.steps.index(step) - 1]
            hold_t = t if "take" in step else holder["start"] + holder["len"] - 1e-3
            self.enter_take(holder["take"])
            zoom = self.draw_phone(canvas, holder, hold_t, presence)
            if step.get("dissolve") and self.before_dissolve is not None and t - step["start"] < step["dissolve"]:
                canvas = Image.blend(self.before_dissolve, canvas, smooth((t - step["start"]) / step["dissolve"]))
            elif "take" in step:
                self.before_dissolve = canvas
                canvas = canvas.copy()
        # An enlarged phone passes under the caption band and the sample tag; the ground closes over it
        # there. At rest the phone touches neither, so the cover is simply always on.
        if kind is None and COVER:
            canvas.alpha_composite(self.top_cover)

        if kind == "title":
            self.title_card(canvas, t - step["start"], step["len"])
        if kind == "end":
            self.end_card(canvas, t, step)
        else:
            self.keycap(canvas, step, t)
            self.chip(canvas, t)
            self.caption(canvas, t)
            # The line under the picture says what the viewer is looking at. A step may name one of the
            # script's "tags" (real data here, sample states there); otherwise it is the film's one tag.
            tag = self.script.get("tags", {}).get(step.get("tag")) or self.script.get("sample_tag")
            if presence > 0.5 and tag:
                paste_centered(canvas, self.text(tag, 26, "Regular", MUTED), TEXT_X, TAG_Y, (presence - 0.5) * 2 * 0.8)
        return canvas.convert("RGB")

    def chip(self, canvas, t):
        step = self.step_at(t)
        current = step.get("ch")
        index = self.steps.index(step)
        change = step["start"]
        while index > 0 and self.steps[index - 1].get("ch") == current:
            index -= 1; change = self.steps[index]["start"]
        previous = self.steps[index - 1].get("ch") if index > 0 else None
        u = smooth((t - change) / 0.2)
        for name, alpha in ((previous, 1 - u), (current, u)):
            if name and alpha > 0.003:
                label = self.text(self.script["chapters"][name], 30, "Medium", (214, 224, 240))
                pill = Image.new("RGBA", (label.width + 44, 56), (0, 0, 0, 0))
                ImageDraw.Draw(pill).rounded_rectangle((0, 0, pill.width - 1, 55), 28, fill=(255, 255, 255, 26))
                pill.alpha_composite(label, (22, (56 - label.height) // 2))
                paste_centered(canvas, pill, TEXT_X, CHIP_Y, alpha)

    def caption_lines(self, show):
        """One line, or two balanced ones where the layout sets a width and the line is wider than it."""
        size = CAPTION_SIZE[self.lang]
        if CAPTION_WRAP is None or self.text(show, size, "Semibold").width <= CAPTION_WRAP:
            return [show]
        breaks = [i for i, ch in enumerate(show) if ch in " ,,、:"] or [len(show) // 2]
        cut = min(breaks, key=lambda i: abs(i - len(show) / 2))
        first, second = show[:cut + (show[cut] != " ")].strip(), show[cut + 1:].strip()
        return [first.rstrip(",,、"), second] if second else [show]

    def caption(self, canvas, t):
        for a, b, show, _ in self.caption_spans:
            if a - 0.02 <= t <= b + 0.02:
                alpha = min(smooth((t - a) / 0.10), smooth((b - t) / 0.10))
                size = CAPTION_SIZE[self.lang]
                under_title = self.step_at(t).get("kind") == "title" and "title_caption" in CARD
                lines = [show] if under_title else self.caption_lines(show)
                x, base = (W / 2, CARD["title_caption"]) if under_title else (TEXT_X, CAPTION_Y)
                for i, line in enumerate(lines):
                    y = base + (i - (len(lines) - 1) / 2) * size * 1.4
                    paste_centered(canvas, self.text(line, size, "Semibold"), x, y, alpha)

    def title_card(self, canvas, into, length):
        alpha = min(smooth(into / 0.45), smooth((length - into) / 0.35))
        paste_centered(canvas, self.text(FILM["label"], 28, "Medium", MUTED, tracking=0.12, lang="en"), W / 2, CARD["title_label"], alpha)
        for i, line in enumerate(self.script["title"]):
            paste_centered(canvas, self.text(line, 88, "Semibold"), W / 2, CARD["title_line"] + i * CARD["title_step"], alpha)

    def end_card(self, canvas, t, step):
        into = t - step["start"]
        base = smooth((into - 0.3) / 0.5)
        end = self.script["end"]
        paste_centered(canvas, self.icon, W / 2, CARD["end_icon"], base)
        paste_centered(canvas, self.text(end["headline"], 62, "Semibold", lang="en"), W / 2, CARD["end_head"], base)
        y = CARD["end_lines"]
        for cue_id, lines in end["with_cues"].items():
            parts = self.cues[cue_id]["parts"]
            for i, line in enumerate(lines):
                at = self.cue_at[cue_id] + (parts[min(i, len(parts) - 1)][0] if len(parts) > 1 else 0.0)
                paste_centered(canvas, self.text(line, 44, "Medium"), W / 2, y, smooth((t - at) / 0.35))
                y += CARD["end_step"]
            y += 34
        y += 40
        for line in end["foot"]:                    # an empty line is a gap
            if line:
                paste_centered(canvas, self.text(line, 28, "Regular", MUTED), W / 2, y, base * 0.9)
            y += CARD["foot_step"]

    def close(self):
        if self.reader:
            self.reader.close()


# ---------------------------------------------------------------- sound

def mix(renderer, music_path, out_path):
    total = int(renderer.total * SAMPLE_RATE)
    voice = np.zeros(total, np.float32)
    speaking = np.zeros(total, np.float32)
    for cue_id, at in renderer.cue_at.items():
        if renderer.cues[cue_id].get("silent"):
            continue
        x = renderer.cues[cue_id]["audio"]
        a = int(at * SAMPLE_RATE)
        b = min(total, a + len(x))
        voice[a:b] += x[:b - a]
        speaking[a:b] = 1.0
    loud = voice[speaking > 0]
    if len(loud):
        voice *= (10 ** (-20 / 20)) / (np.sqrt((loud ** 2).mean()) + 1e-9)
    ceiling = 10 ** (-2.0 / 20)                 # leave 2 dB for the encoder; soften only what passes it
    over = np.abs(voice) > ceiling * 0.8
    voice[over] = np.sign(voice[over]) * ceiling * (0.8 + 0.2 * np.tanh((np.abs(voice[over]) / ceiling - 0.8) / 0.2))
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(music_path), "-f", "f32le", "-ac", "2", "-ar", str(SAMPLE_RATE), "-"],
                         capture_output=True, check=True).stdout
    music = np.frombuffer(raw, np.float32).reshape(-1, 2)[:total]
    if len(music) < total - SAMPLE_RATE // 10:
        raise SystemExit(f"the music is {len(music) / SAMPLE_RATE:.1f}s and the video {total / SAMPLE_RATE:.1f}s: shorten a hold")
    if len(music) < total:
        music = np.concatenate([music, np.zeros((total - len(music), 2), np.float32)])
    music_rms = np.sqrt((music ** 2).mean()) + 1e-9
    # Under the voice the bed sits 19 dB below it; in the gaps it comes up by 5 dB, slowly.
    kernel = np.ones(int(0.7 * SAMPLE_RATE), np.float32); kernel /= kernel.sum()
    presence = np.clip(np.convolve(speaking, kernel, mode="same") * 1.6, 0, 1)
    open_db = renderer.script.get("music_db", -34.0)     # the bed's level where nobody is speaking
    gain_db = open_db * (1 - presence) + -39.0 * presence
    gain = (10 ** (gain_db / 20)) / music_rms
    fade = np.minimum(np.linspace(0, total / SAMPLE_RATE / 0.4, total), 1.0) * np.minimum(np.linspace(total / SAMPLE_RATE / 2.2, 0, total), 1.0)
    out = music * (gain * fade)[:, None] + voice[:, None]
    out = np.clip(out, -0.89, 0.89)
    with wave.open(str(out_path), "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SAMPLE_RATE)
        w.writeframes((out * 32767).astype(np.int16).tobytes())


def write_srt(renderer, path):
    def stamp(t):
        ms = int(round(t * 1000))
        return f"{ms // 3600000:02d}:{ms // 60000 % 60:02d}:{ms // 1000 % 60:02d},{ms % 1000:03d}"
    lines = [f"{i}\n{stamp(a)} --> {stamp(b)}\n{show}\n" for i, (a, b, show, _) in enumerate(renderer.caption_spans, 1)]
    path.write_text("\n".join(lines))


# ---------------------------------------------------------------- entry

def main():
    global ROOT, REPO
    ap = argparse.ArgumentParser()
    ap.add_argument("script")
    ap.add_argument("--plan", action="store_true")
    ap.add_argument("--stills", nargs="*", type=float)
    ap.add_argument("--fps", type=int, default=60)
    ap.add_argument("--music", help="default: build/music.wav in the film's folder")
    ap.add_argument("--edit", default="edit.json")
    ap.add_argument("--layout", default="tall", choices=["tall", "wide", "loop"])
    ap.add_argument("--silent", action="store_true", help="no narration, no music: the picture only")
    ap.add_argument("--name", help="the output's file name without .mp4, when the default would collide")
    ap.add_argument("--root", help="another film's folder: its film.json, scripts, edits and build/ are used instead of this copy's")
    args = ap.parse_args()
    if args.root:
        ROOT = pathlib.Path(args.root).resolve()
        REPO = ROOT.parent.parent
    FILM.update(json.loads((ROOT / "film.json").read_text()))
    script = json.loads((ROOT / args.script).read_text())
    if "main" in script:                            # the take the loop's frame is sized to, per language
        FILM["main"] = script["main"]
    set_layout(args.layout)

    edit = json.loads((ROOT / args.edit).read_text())
    for step in edit["steps"]:                      # a language may shorten or lengthen a hold
        step.update(script.get("overrides", {}).get(step["id"], {}))
    renderer = Renderer(script, edit, load_cues(script))
    lang = script["lang"]

    if args.plan:
        for s in renderer.steps:
            said = " ".join(f"{c}@{renderer.cue_at[c]:.2f}(+{renderer.cues[c]['dur']:.2f})" for c, _ in s.get("cues", []))
            print(f"{s['start']:7.2f} {s['len']:5.2f}  {s['id']:<14} play {s['play']:4.2f}  {said}")
        voiced = sum(c["dur"] for c in renderer.cues.values())
        print(f"total {renderer.total:.2f}s   narration {voiced:.2f}s   camera moves {len(renderer.cam_keys) - 1}")
        return

    if args.stills is not None:
        out = ROOT / "build/work/stills"; out.mkdir(parents=True, exist_ok=True)
        for t in sorted(args.stills):
            renderer.frame(t).save(out / f"{lang}-{args.layout}-{t:06.2f}.png")
            print(out / f"{lang}-{args.layout}-{t:06.2f}.png")
        renderer.close()
        return

    stem = pathlib.Path(args.edit).stem.replace("edit", "tutorial")
    name = args.name or (stem if args.silent else f"{stem}-{lang}" + ("" if args.layout == "tall" else f"-{args.layout}"))
    silent = ROOT / f"build/work/{name}.silent.mp4"
    # A keyframe where each step starts and where each dissolve ends. Without one after a dissolve the
    # encoder leaves a faint ghost of the outgoing picture on a still frame, and the page loop's last
    # frame then differs from its first: the join shows.
    keys = sorted({round(s["start"], 3) for s in renderer.steps}
                  | {round(s["start"] + s.get("dissolve", 0.4), 3) for s in renderer.steps if s.get("dissolve") or s.get("kind") == "image"})
    (ROOT / f"build/work/{name}.keys.txt").write_text(",".join(f"{k:.3f}" for k in keys))
    encoder = subprocess.Popen(
        ["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(args.fps), "-i", "-",
         "-c:v", "libx264", "-preset", "medium", "-crf", "17", "-pix_fmt", "yuv420p", "-force_key_frames", ",".join(f"{k:.3f}" for k in keys),
         "-movflags", "+faststart", str(silent)],
        stdin=subprocess.PIPE)
    count = int(renderer.total * args.fps)
    for n in range(count):
        encoder.stdin.write(renderer.frame(n / args.fps).tobytes())
        if n % (args.fps * 5) == 0:
            print(f"{n / args.fps:6.1f}s / {renderer.total:.1f}s", flush=True)
    encoder.stdin.close(); encoder.wait(); renderer.close()

    final = ROOT / f"build/{name}.mp4"
    if args.silent:
        silent.replace(final)
        print(final)
        return
    audio = ROOT / f"build/work/{name}.wav"
    mix(renderer, args.music or ROOT / "build/music.wav", audio)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(silent), "-i", str(audio), "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
                    "-shortest", "-movflags", "+faststart", str(final)], check=True)
    write_srt(renderer, ROOT / f"build/{name}.srt")
    print(final)


if __name__ == "__main__":
    main()
