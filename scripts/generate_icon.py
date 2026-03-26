#!/usr/bin/env python3
"""Generate Omni ASR app icon: layered PNGs for Liquid Glass + flat fallback."""

import json
import os
from pathlib import Path

from PIL import Image, ImageDraw

ICON_SIZE = 1024

# Brand colours (from AppTheme.accentGradient: indigo → purple)
INDIGO = (88, 86, 214)
PURPLE = (175, 82, 222)

# Waveform bar spec (5 bars, symmetric mountain shape)
BAR_WIDTH = 60
BAR_GAP = 30
BAR_HEIGHTS = [180, 300, 420, 300, 180]  # outer → center → outer

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent / "omni-asr"
ICON_PKG_DIR = PROJECT_DIR / "Resources" / "AppIcon.icon"
APPICONSET_DIR = PROJECT_DIR / "Assets.xcassets" / "AppIcon.appiconset"


def draw_gradient(size: int = ICON_SIZE) -> Image.Image:
    """Render diagonal indigo→purple gradient."""
    img = Image.new("RGBA", (size, size))
    pixels = img.load()
    denom = 2 * size - 2 if size > 1 else 1
    for y in range(size):
        for x in range(size):
            t = (x + y) / denom
            r = int(INDIGO[0] + (PURPLE[0] - INDIGO[0]) * t)
            g = int(INDIGO[1] + (PURPLE[1] - INDIGO[1]) * t)
            b = int(INDIGO[2] + (PURPLE[2] - INDIGO[2]) * t)
            pixels[x, y] = (r, g, b, 255)
    return img


def draw_waveform(size: int = ICON_SIZE) -> Image.Image:
    """Draw 5 white pill-shaped waveform bars on transparent canvas."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    num_bars = len(BAR_HEIGHTS)
    total_width = num_bars * BAR_WIDTH + (num_bars - 1) * BAR_GAP
    start_x = (size - total_width) / 2
    center_y = size / 2

    for i, height in enumerate(BAR_HEIGHTS):
        x0 = start_x + i * (BAR_WIDTH + BAR_GAP)
        y0 = center_y - height / 2
        x1 = x0 + BAR_WIDTH
        y1 = center_y + height / 2
        radius = BAR_WIDTH / 2
        draw.rounded_rectangle([x0, y0, x1, y1], radius=radius, fill=(255, 255, 255, 255))

    return img


def write_icon_json(dest: Path) -> None:
    """Write icon.json manifest for Liquid Glass .icon package."""
    manifest = {
        "format-version": 1,
        "groups": [
            {
                "name": "Background",
                "assets": [{"filename": "background.png"}],
                "properties": {},
            },
            {
                "name": "Foreground",
                "assets": [{"filename": "foreground.png"}],
                "properties": {"glass": True, "translucency": 0.5},
            },
        ],
    }
    dest.mkdir(parents=True, exist_ok=True)
    (dest / "icon.json").write_text(json.dumps(manifest, indent=2) + "\n")


def main() -> None:
    print("Generating icon assets...")

    background = draw_gradient()
    foreground = draw_waveform()

    # Flat composite (RGB, opaque) for legacy / App Store
    composite = background.copy()
    composite.paste(foreground, (0, 0), foreground)
    flat = composite.convert("RGB")

    # --- Liquid Glass .icon package ---
    assets_dir = ICON_PKG_DIR / "Assets"
    assets_dir.mkdir(parents=True, exist_ok=True)
    background.save(assets_dir / "background.png")
    foreground.save(assets_dir / "foreground.png")
    write_icon_json(ICON_PKG_DIR)
    print(f"  .icon package → {ICON_PKG_DIR}")

    # --- Flat fallback into appiconset ---
    APPICONSET_DIR.mkdir(parents=True, exist_ok=True)
    flat.save(APPICONSET_DIR / "icon_1024x1024.png")
    print(f"  flat icon      → {APPICONSET_DIR / 'icon_1024x1024.png'}")

    print("Done.")


if __name__ == "__main__":
    main()
