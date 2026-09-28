#!/usr/bin/env python3
"""Cuts the app icon out of design/icon-source.png (the tile rendered on a backdrop) and writes the app's AppIcon.png:
the tile scaled to Apple's 824 px icon body, centered on a transparent 1024 px canvas with a soft shadow.

    python3 design/make_icon.py

Needs ImageMagick (`magick`). If icon-source.png is replaced, re-measure TILE and RADIUS.
"""
import subprocess
from pathlib import Path

DESIGN = Path(__file__).parent
SOURCE = DESIGN / "icon-source.png"
APP_ICON = DESIGN.parent / "Sources/Agenticious/Resources/AppIcon.png"

TILE = "612x612+398+79"  # the rounded tile inside the 1408x768 source
RADIUS = 136             # its corner radius in source pixels
INSET = 3                # trims the backdrop's anti-aliased fringe
BODY = 824

size = 612 - 2 * INSET
subprocess.run(
    [
        "magick",
        # Tile, cut to its rounded shape.
        "(", SOURCE, "-crop", TILE, "+repage", "-shave", f"{INSET}x{INSET}",
        "(", "-size", f"{size}x{size}", "xc:none", "-fill", "white",
        "-draw", f"roundrectangle 0,0 {size - 1},{size - 1} {RADIUS - INSET},{RADIUS - INSET}", ")",
        "-alpha", "set", "-compose", "DstIn", "-composite",
        "-filter", "Lanczos", "-resize", f"{BODY}x{BODY}", ")",
        "-compose", "Over",
        # Shadow under it, then both centered on the canvas.
        "(", "+clone", "-background", "black", "-shadow", "40x14+0+12", ")",
        "+swap", "-background", "none", "-layers", "merge", "+repage",
        "-gravity", "center", "-extent", "1024x1024",
        APP_ICON,
    ],
    check=True,
)
