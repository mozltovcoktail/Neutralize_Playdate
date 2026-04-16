#!/usr/bin/env python3
"""
Generate Playdate .fnt + spritesheet .png from a variable TTF.

Playdate font format:
  - <name>.fnt  : text file, first line "tracking=N", then "glyph advance_width" per line
  - <name>-table-<cellW>-<cellH>.png : horizontal sprite sheet, one cell per glyph,
    cells laid out left-to-right. Each cell is cellW×cellH pixels, 1-bit (black on white).
    The glyph is drawn at the left of the cell; advance width in the .fnt is the
    cell-content width (not the full cellW).

The SDK pdc compiles these into the .pdx bundle.
"""

import sys, os, math
sys.path.insert(0, '/Users/Aaron/Library/Python/3.9/lib/python/site-packages')

from PIL import Image, ImageDraw
import freetype
from fontTools.ttLib import TTFont
from fontTools.varLib.mutator import instantiateVariableFont

FONT_DIR = os.path.join(os.path.dirname(__file__), "source/fonts")
SRC_TTF  = os.path.join(FONT_DIR, "Rubik.ttf")

# Characters to include (printable ASCII 32-126)
CHARS = [chr(c) for c in range(32, 127)]

# Fonts to generate: (output_name, weight, px_size, tracking, threshold)
# weight: 400=Regular 500=Medium 700=Bold
# px_size: rendered pixel height
# tracking: extra pixels between glyphs (like Caps "tracking" slider)
# threshold: pixel is black if grayscale value <= threshold (after AA inversion).
# 0=covered/black, 255=background/white after inversion.
# Higher threshold = more pixels become black = BOLDER. Lower = THINNER.
TARGETS = [
    # Small UI: labels, hints, drawer text
    ("Rubik-Medium-11", 500, 11, 1, 110),  # kept for reference
    ("Rubik-Bold-11",   700, 11, 1, 168),  # kept for reference
    ("Rubik-Medium-13", 500, 13, 1, 110),
    ("Rubik-Bold-13",   700, 13, 1, 210),
    # Body / sidebar numbers
    ("Rubik-Medium-16", 500, 16, 1, 110),
    ("Rubik-Bold-16",   700, 16, 1, 160),
    # Mid-size: PAUSED, game-over text
    ("Rubik-Medium-20", 500, 20, 0, 110),
    # Large display: scores, level numbers
    ("Rubik-Medium-24", 500, 24, 0, 110),
    ("Rubik-Bold-24",   700, 24, 0, 160),
]

def instantiate_weight(src_ttf_path, weight):
    """Return a fontTools TTFont instantiated at the given wght."""
    tt = TTFont(src_ttf_path)
    if 'fvar' not in tt:
        return src_ttf_path  # static font, use as-is
    # Write a temp file with the instantiated weight
    tmp = f"/tmp/Rubik-w{weight}.ttf"
    if not os.path.exists(tmp):
        from fontTools.varLib.mutator import instantiateVariableFont
        instantiateVariableFont(tt, {"wght": float(weight)})
        tt.save(tmp)
    return tmp

def render_font(output_name, weight, px_size, tracking, threshold):
    print(f"  Generating {output_name} (w={weight}, {px_size}px, tracking={tracking}, threshold={threshold})")

    ttf_path = instantiate_weight(SRC_TTF, weight)

    face = freetype.Face(ttf_path)
    # Use 26.6 fixed-point: multiply px by 64
    face.set_pixel_sizes(0, px_size)

    # ── Measure all glyphs ──────────────────────────────────────────
    metrics = {}   # char -> (advance_px, bitmap_left, bitmap_top, bitmap_w, bitmap_h, buffer)
    max_above = 0  # max pixels above baseline
    max_below = 0  # max pixels below baseline (descent, positive number)

    for ch in CHARS:
        # FT_LOAD_RENDER with default target = antialiased grayscale (8bpp).
        # This lets the threshold in the 1-bit conversion control stroke weight:
        # lower threshold = fatter/bolder, higher = thinner/lighter.
        face.load_char(ch, freetype.FT_LOAD_RENDER)
        g = face.glyph
        bm = g.bitmap
        advance = g.advance.x >> 6  # 26.6 → integer pixels
        left    = g.bitmap_left
        top     = g.bitmap_top     # pixels above baseline
        w       = bm.width
        h       = bm.rows
        buf     = bytes(bm.buffer) if bm.buffer else b''
        metrics[ch] = (advance, left, top, w, h, buf, bm.pitch)

        above = top
        below = h - top
        if above > max_above: max_above = above
        if below > max_below: max_below = below

    cell_h = max_above + max_below
    baseline = max_above  # row index of baseline within cell

    # ── Build sprite sheet ─────────────────────────────────────────
    # Playdate requires ALL cells in the PNG to be the same width (cell_w).
    # cell_w = max advance across all glyphs. The per-glyph advance in .fnt tells
    # the renderer how many pixels to step; it can be <= cell_w.

    advances = {}
    glyph_renders = {}  # ch -> (bm_img or None, left, baseline-top)

    for ch in CHARS:
        advance, left, top, w, h, buf, pitch = metrics[ch]
        advances[ch] = advance

        bm_img = None
        if w > 0 and h > 0 and buf:
            # Grayscale bitmap: 1 byte per pixel, value 0=black..255=white (inverted)
            bm_img = Image.new('L', (w, h), 255)
            px = bm_img.load()
            for row in range(h):
                for col in range(w):
                    byte_idx = row * abs(pitch) + col
                    if byte_idx < len(buf):
                        # FreeType grayscale: 0=transparent, 255=fully covered → invert for white bg
                        px[col, row] = 255 - buf[byte_idx]
        glyph_renders[ch] = (bm_img, left, baseline - top)

    # Uniform cell width = max advance (pdc strict requirement)
    cell_w = max(advances.values())

    # Build strip: cell_w * num_chars wide, cell_h tall
    num_chars = len(CHARS)
    strip = Image.new('L', (cell_w * num_chars, max(cell_h, 1)), 255)

    for i, ch in enumerate(CHARS):
        bm_img, left, paste_y = glyph_renders[ch]
        if bm_img is not None:
            paste_x = i * cell_w + left
            # Clamp so glyph doesn't bleed into adjacent cell
            if paste_x < i * cell_w:
                paste_x = i * cell_w
            strip.paste(bm_img, (paste_x, paste_y))

    # Convert to 1-bit
    strip_1bit = strip.point(lambda p: 0 if p <= threshold else 255, '1')

    png_name = f"{output_name}-table-{cell_w}-{cell_h}.png"
    out_png = os.path.join(FONT_DIR, png_name)
    strip_1bit.save(out_png)

    # ── Write .fnt ─────────────────────────────────────────────────
    fnt_name = f"{output_name}.fnt"
    out_fnt = os.path.join(FONT_DIR, fnt_name)
    with open(out_fnt, 'w') as f:
        f.write(f"tracking={tracking}\n")
        for ch in CHARS:
            adv = advances[ch]
            label = "space" if ch == ' ' else ch
            f.write(f"{label} {adv}\n")

    print(f"    → {fnt_name}  +  {png_name}  (cell {cell_w}×{cell_h})")

def main():
    print(f"Source TTF: {SRC_TTF}")
    print(f"Output dir: {FONT_DIR}")
    print()
    for target in TARGETS:
        render_font(*target)
    print("\nDone.")

if __name__ == "__main__":
    main()
