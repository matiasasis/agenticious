#!/usr/bin/env python3
"""Cut the seventh variant's face out onto a transparent app icon:
uv run --with pillow --with numpy --with scipy design/make_icon.py
"""
from pathlib import Path
from shutil import copyfile

import numpy as np
from PIL import Image
from scipy import ndimage

DESIGN = Path(__file__).parent
SOURCE = DESIGN / "icon-variants" / "7-face-full-bg.jpg"
VARIANT = DESIGN / "icon-variants" / "8-face-transparent.png"
APP_ICON = DESIGN.parent / "Sources/Agenticious/Resources/AppIcon.png"

CANVAS = 1024
FIT = 900
EDGE = 3  # pixels of anti-aliased edge re-matted around the cut-out
MIN_SHAPE = 2000  # smaller islands, like the generator's sparkle watermark, are dropped

src = np.asarray(Image.open(SOURCE).convert("RGB")).astype(float)
bg = np.median(src[:40, :40].reshape(-1, 3), axis=0)

# The background is the teal connected to the image border, so teal inside the face survives.
labels, _ = ndimage.label(np.linalg.norm(src - bg, axis=2) < 60)
border = np.unique(np.concatenate([labels[0], labels[-1], labels[:, 0], labels[:, -1]]))
shapes, count = ndimage.label(~np.isin(labels, border[border > 0]))
sizes = ndimage.sum(shapes > 0, shapes, range(1, count + 1))
fg = ndimage.binary_fill_holes(np.isin(shapes, 1 + np.flatnonzero(sizes >= MIN_SHAPE)))

# Edge pixels are blends of teal and the nearest solid colour: solve for alpha, keep that colour.
core = ndimage.binary_erosion(fg, iterations=EDGE)
_, (iy, ix) = ndimage.distance_transform_edt(~core, return_indices=True)
solid = src[iy, ix]
edge = ndimage.binary_dilation(fg, iterations=2) & ~core
toward = solid - bg
blend = ((src - bg) * toward).sum(2) / np.maximum((toward * toward).sum(2), 1)
alpha = np.where(core, 1.0, 0.0)
alpha[edge] = np.clip(blend[edge], 0, 1)
alpha = np.where(alpha < 0.08, 0, np.where(alpha > 0.92, 1, alpha))
rgb = np.where(edge[..., None], solid, src)

face = Image.fromarray(np.dstack([rgb, alpha * 255]).clip(0, 255).astype(np.uint8), "RGBA")
face = face.crop(face.getchannel("A").getbbox())
scale = FIT / max(face.size)
face = face.resize((round(face.width * scale), round(face.height * scale)), Image.LANCZOS)

icon = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
icon.alpha_composite(face, ((CANVAS - face.width) // 2, (CANVAS - face.height) // 2))
icon.save(VARIANT)
copyfile(VARIANT, APP_ICON)
