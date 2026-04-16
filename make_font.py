import sys
import math
from PIL import Image, ImageDraw, ImageFont

def make_font(ttf_path, size, name, weight=None):
    font = ImageFont.truetype(ttf_path, size)
    if weight is not None:
        font.set_variation_by_axes([weight])
    
    # Supported characters: Space to '~' (ASCII 32-126)
    chars = [chr(i) for i in range(32, 127)]
    
    # Measure characters to find max width and max height
    widths = []
    max_w = 0
    max_h = 0
    for c in chars:
        bbox = font.getbbox(c)
        if bbox is None:
            w = font.getlength(c)
            h = size
        else:
            w = max(1, int(round(font.getlength(c))))
            h = bbox[3] - bbox[1]
        
        if c == " ": w = int(size * 0.3)
        widths.append(w)
        max_w = max(max_w, max(1, int(math.ceil(font.getlength(c) + 2))))
        max_h = max(max_h, size + 10) # uniform height
        
    # Create uniform grid image table: 1 row, len(chars) columns
    # Playdate's pdc needs uniform cells for font image tables.
    table_w = max_w
    table_h = max_h
    img = Image.new('RGBA', (table_w * len(chars), table_h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    
    fnt_lines = ["tracking=1"]
    for i, c in enumerate(chars):
        w = widths[i]
        char_label = c
        if c == ' ': char_label = "space"
        
        fnt_lines.append(f"{char_label} {w}")
        
        # Draw character in its uniform cell
        d.text((i * table_w, 0), c, font=font, fill=(0, 0, 0, 255))
        
    img.save(f"{name}-table-{table_w}-{table_h}.png")
    
    with open(f"{name}.fnt", "w") as f:
        f.write("\n".join(fnt_lines) + "\n")

ttf = "source/fonts/Rubik.ttf"

# Light (300) — thin/delicate text
make_font(ttf, 48, "source/fonts/Rubik-Light-48", weight=300)
make_font(ttf, 36, "source/fonts/Rubik-Light-36", weight=300)
make_font(ttf, 24, "source/fonts/Rubik-Light-24", weight=300)
make_font(ttf, 16, "source/fonts/Rubik-Light-16", weight=300)

# Regular (400) — body/UI text
make_font(ttf, 48, "source/fonts/Rubik-Regular-48", weight=400)
make_font(ttf, 36, "source/fonts/Rubik-Regular-36", weight=400)
make_font(ttf, 24, "source/fonts/Rubik-Regular-24", weight=400)

# Medium (500) — bold/emphasis text
make_font(ttf, 48, "source/fonts/Rubik-Medium-48", weight=500)
make_font(ttf, 36, "source/fonts/Rubik-Medium-36", weight=500)
make_font(ttf, 24, "source/fonts/Rubik-Medium-24", weight=500)

# Bold (700) — thick title text
make_font(ttf, 64, "source/fonts/Rubik-Bold-64", weight=700)

# ExtraBold (800) — extra thick title text
make_font(ttf, 64, "source/fonts/Rubik-ExtraBold-64", weight=800)
make_font(ttf, 16, "source/fonts/Rubik-Medium-16", weight=500)
make_font(ttf, 16, "source/fonts/Rubik-Bold-16", weight=700)
make_font(ttf, 48, "source/fonts/Rubik-Bold-48", weight=700)
