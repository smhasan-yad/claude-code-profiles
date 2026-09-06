#!/usr/bin/env python
"""Regenerate the repo banner. Run from the repo root:  python assets/make_banner.py

Draws directly with Pillow rather than rasterising an SVG, so it needs no
external converter. Fonts are read from the system; substitute your own paths
on macOS/Linux (e.g. Menlo / SF Pro, or DejaVu Sans Mono / DejaVu Sans).
"""
import os
from PIL import Image, ImageDraw, ImageFont

W, H = 1280, 640
BG      = (13, 17, 23)      # GitHub dark canvas
PANEL   = (22, 27, 34)
BORDER  = (48, 54, 61)
FG      = (230, 237, 243)
MUTED   = (125, 133, 144)
ACCENT  = (210, 153, 111)   # warm, matches Claude's palette
GREEN   = (126, 186, 129)
BLUE    = (110, 168, 226)

FONTS = r"C:\Windows\Fonts"
def font(name, size):
    return ImageFont.truetype(os.path.join(FONTS, name), size)

f_title  = font("segoeuib.ttf", 62)
f_sub    = font("segoeui.ttf",  27)
f_mono   = font("consola.ttf",  25)
f_monob  = font("consolab.ttf", 25)
f_small  = font("segoeui.ttf",  21)
f_statb  = font("consolab.ttf", 40)
f_stat   = font("segoeui.ttf",  21)

img = Image.new("RGB", (W, H), BG)
d = ImageDraw.Draw(img)

# thin accent rule down the left edge
d.rectangle([0, 0, 6, H], fill=ACCENT)

X = 78
d.text((X, 72),  "claude-code-profiles", font=f_title, fill=FG)
d.text((X, 152), "Run Claude Code as several commands, each on a different set of models.",
       font=f_sub, fill=MUTED)

# ---- command panel -------------------------------------------------------
PT, PB = 218, 430
d.rounded_rectangle([X, PT, W - 78, PB], radius=10, fill=PANEL, outline=BORDER, width=1)

rows = [
    ("claude-free",   "free providers only", "never touches a paid quota",     GREEN),
    ("claude-tiered", "delegates by itself", "best model plans, cheap models execute", BLUE),
    ("claude-pro",    "paid account first",  "drops to free when quota runs out", ACCENT),
]
y = PT + 34
for cmd, what, note, colour in rows:
    d.text((X + 34, y), "$", font=f_mono, fill=MUTED)
    d.text((X + 60, y), cmd, font=f_monob, fill=colour)
    d.text((X + 330, y), what, font=f_mono, fill=FG)
    d.text((X + 620, y), note, font=f_small, fill=MUTED)
    y += 56

# ---- the finding ---------------------------------------------------------
SY = 478
d.text((X, SY), "60", font=f_statb, fill=MUTED)
d.text((X + 58, SY + 8), "→", font=f_statb, fill=MUTED)
d.text((X + 108, SY), "14", font=f_statb, fill=GREEN)
d.text((X + 168, SY + 12), "paid calls for the same task", font=f_stat, fill=FG)
d.text((X, SY + 62),
       "Claude Code fans work out to subagents that inherit your expensive model. Tiering stops that.",
       font=f_small, fill=MUTED)

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "banner.png")
img.save(out, "PNG", optimize=True)
print(f"wrote {out}  ({W}x{H}, {os.path.getsize(out)/1024:.0f} KB)")
