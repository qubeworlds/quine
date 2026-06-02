#!/usr/bin/env python3
"""Process the source app icon into a clean, transparent PNG icon set.

Pipeline (matches what is committed under assets/):
  1. crop   — trim to the logo's content bounds, kept square and centered.
  2. remove — derive an alpha matte from luminance. The source is a glow on a
              near-black background, so brightness *is* the correct matte:
              compositing the result over black reproduces the original.
  3. resize — emit a transparent PNG size set (16-1024 px).

Source : assets/icon.png   (committed; never modified by this script)
Outputs: assets/icon-transparent.png (1024 master) and assets/icons/icon-*.png

Usage:  python3 assets/process_icon.py
Requires: Pillow, numpy  (pip install Pillow numpy)
"""
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "icon.png"
ICONS = ROOT / "icons"
PNG_SIZES = [16, 32, 48, 64, 128, 256, 512, 1024]


def main() -> None:
    ICONS.mkdir(exist_ok=True)
    src = Image.open(SRC).convert("RGB")
    arr = np.asarray(src).astype(np.float32)
    h, w, _ = arr.shape
    lum = arr.max(axis=2)

    # 1. crop to content, square + centered
    ys, xs = np.where(lum > 30)
    cx, cy = (xs.min() + xs.max()) / 2, (ys.min() + ys.max()) / 2
    half = max(xs.max() - xs.min(), ys.max() - ys.min()) / 2
    box = (
        max(int(round(cx - half)), 0), max(int(round(cy - half)), 0),
        min(int(round(cx + half)), w), min(int(round(cy + half)), h),
    )
    tile = src.crop(box)

    # 2. background removal — alpha matte from luminance
    crop = np.asarray(tile).astype(np.float32)
    alpha = np.clip((crop.max(axis=2) - 6.0) * 1.45, 0, 255)
    transparent = Image.fromarray(
        np.dstack([crop, alpha]).astype(np.uint8), "RGBA"
    )

    # 3. resize / export transparent PNG set
    transparent.resize((1024, 1024), Image.LANCZOS).save(ROOT / "icon-transparent.png")
    for s in PNG_SIZES:
        transparent.resize((s, s), Image.LANCZOS).save(ICONS / f"icon-{s}.png")
    print("transparent PNG icon set regenerated under assets/")


if __name__ == "__main__":
    main()
