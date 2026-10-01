#!/usr/bin/env python3
"""Put the app icon's face on a rounded tile in the app's purple ink, for the bundle icon macOS shows on notifications:
uv run --with pillow design/make_bundle_icon.py
"""
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).parent.parent
FACE = ROOT / "Sources/Agenticious/Resources/AppIcon.png"
OUT = ROOT / "Resources/BundleIcon.png"

CANVAS = 1024
TILE = 824  # Apple's macOS icon grid: an 824pt rounded square centred on 1024
RADIUS = 185
FIT = 700

INK = (14, 11, 23)  # AgenticiousStyle.ink
PANEL = (26, 20, 38)  # AgenticiousStyle.panel
VIOLET = (194, 125, 245)  # AgenticiousStyle.violet

origin = (CANVAS - TILE) // 2
mask = Image.new("L", (CANVAS, CANVAS), 0)
ImageDraw.Draw(mask).rounded_rectangle((origin, origin, origin + TILE, origin + TILE), RADIUS, fill=255)

# Ink at the bottom fading up to panel, with a violet glow behind the face.
tile = Image.new("RGB", (CANVAS, CANVAS))
draw = ImageDraw.Draw(tile)
for y in range(CANVAS):
    t = y / (CANVAS - 1)
    draw.line([(0, y), (CANVAS, y)], fill=tuple(round(PANEL[i] * (1 - t) + INK[i] * t) for i in range(3)))
glow = Image.new("L", (CANVAS, CANVAS), 0)
ImageDraw.Draw(glow).ellipse((262, 232, 762, 732), fill=70)
glow = glow.filter(ImageFilter.GaussianBlur(120))
tile = Image.composite(Image.new("RGB", (CANVAS, CANVAS), VIOLET), tile, glow)

icon = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
shadow.putalpha(ImageChops.offset(mask, 0, 12).point(lambda a: a * 0.45).filter(ImageFilter.GaussianBlur(18)))
icon.alpha_composite(shadow)
icon.paste(tile, (0, 0), mask)

border = Image.new("L", (CANVAS, CANVAS), 0)
ImageDraw.Draw(border).rounded_rectangle((origin, origin, origin + TILE, origin + TILE), RADIUS, outline=90, width=4)
icon.paste(Image.new("RGB", (CANVAS, CANVAS), VIOLET), (0, 0), border)

face = Image.open(FACE).convert("RGBA")
face = face.crop(face.getchannel("A").getbbox())
scale = FIT / max(face.size)
face = face.resize((round(face.width * scale), round(face.height * scale)), Image.LANCZOS)
icon.alpha_composite(face, ((CANVAS - face.width) // 2, (CANVAS - face.height) // 2 + 8))

icon.save(OUT)
