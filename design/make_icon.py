#!/usr/bin/env python3
"""Install the prepared, transparent third icon: python3 design/make_icon.py."""
from pathlib import Path
from shutil import copyfile

DESIGN = Path(__file__).parent
SOURCE = DESIGN / "icon-variants" / "3-flat-tie-clean.png"
APP_ICON = DESIGN.parent / "Sources/Agenticious/Resources/AppIcon.png"

copyfile(SOURCE, APP_ICON)
