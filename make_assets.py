import os
import math
from PIL import Image, ImageDraw, ImageFont

# Set up paths
font_path = "source/fonts/Rubik.ttf"
os.makedirs("source/images", exist_ok=True)

def generate_text_image(text, font_size, filename):
    font = ImageFont.truetype(font_path, font_size)
    
    # Draw on a large canvas to ensure no clipping
    canvas_size = 400
    img = Image.new('RGBA', (canvas_size, canvas_size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    
    # Draw text somewhere in the middle
    d.text((canvas_size // 2, canvas_size // 2), text, font=font, fill=(0, 0, 0, 255), anchor="mm")
    
    # Get exact bounding box of the inked pixels
    bbox = img.getbbox()
    if bbox:
        # Crop to the exact contents with a small margin just in case
        margin = 1
        crop_box = (
            max(0, bbox[0] - margin),
            max(0, bbox[1] - margin),
            min(canvas_size, bbox[2] + margin),
            min(canvas_size, bbox[3] + margin)
        )
        img = img.crop(crop_box)
    
    img.save(filename)
    # print(f"Generated {filename} size: {img.size}")

generate_text_image("NEUTRALIZE", 42, "source/images/rubik_title.png")

print("Generated rubik_title.png")
