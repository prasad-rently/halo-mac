import sys
import os
from PIL import Image

def fix_banner(img_path, output_path):
    try:
        img = Image.open(img_path)
        w, h = img.size
        
        # Target aspect ratio is 1280 / 640 = 2.0
        target_ratio = 2.0
        current_ratio = w / h
        
        if current_ratio > target_ratio:
            # Image is wider than needed, crop width
            new_w = int(h * target_ratio)
            new_h = h
        else:
            # Image is taller than needed, crop height
            new_w = w
            new_h = int(w / target_ratio)
            
        left = (w - new_w) / 2
        top = (h - new_h) / 2
        right = (w + new_w) / 2
        bottom = (h + new_h) / 2
        
        img_cropped = img.crop((left, top, right, bottom))
        img_resized = img_cropped.resize((1280, 640), Image.Resampling.LANCZOS)
        
        # Save as RGB to avoid issues
        img_resized = img_resized.convert("RGB")
        img_resized.save(output_path)
        print("Successfully fixed and saved the banner without stretching.")
    except Exception as e:
        print(f"Error: {e}")

if __name__ == "__main__":
    base_img = "/Users/gokulprasadm/.gemini/antigravity/brain/2f936e50-e45a-41ee-80e7-68f4cb3d0862/github_banner_base_1778054495187.png"
    out_img = "/Users/gokulprasadm/Downloads/Halo/Assets/github/github_banner_1280x640.png"
    fix_banner(base_img, out_img)
