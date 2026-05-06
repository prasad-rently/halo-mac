"""
process_app_icons.py
Copies source images from Assets/app_icons/ into the Xcode AppIcon.appiconset,
converting each file to true PNG format via Pillow.

Source → Appiconset slot mapping (macOS icon set convention):
  icon_16x16.png     → icon_16x16@1x.png   (16px)
  icon_32x32.png     → icon_16x16@2x.png   (32px  = 16@2x)
  icon_32x32.png     → icon_32x32@1x.png   (32px)
  icon_64x64.png     → icon_32x32@2x.png   (64px  = 32@2x)
  icon_128x128.png   → icon_128x128@1x.png (128px)
  icon_256x256.png   → icon_128x128@2x.png (256px = 128@2x)
  icon_256x256.png   → icon_256x256@1x.png (256px)
  icon_512x512.png   → icon_256x256@2x.png (512px = 256@2x)
  icon_512x512.png   → icon_512x512@1x.png (512px)
  icon_1024x1024.png → icon_512x512@2x.png (1024px = 512@2x)
"""

import os
from PIL import Image

# ── Paths ────────────────────────────────────────────────────────────────────
SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
SRC_DIR     = os.path.join(SCRIPT_DIR, "app_icons")
ASSET_DIR   = os.path.join(SCRIPT_DIR, "..",
              "Halo", "Resources", "Assets.xcassets",
              "AppIcon.appiconset")

# ── Mapping: source filename → one or more destination filenames ─────────────
MAPPING = [
    ("icon_16x16.png",     "icon_16x16@1x.png"),
    ("icon_32x32.png",     "icon_16x16@2x.png"),
    ("icon_32x32.png",     "icon_32x32@1x.png"),
    ("icon_64x64.png",     "icon_32x32@2x.png"),
    ("icon_128x128.png",   "icon_128x128@1x.png"),
    ("icon_256x256.png",   "icon_128x128@2x.png"),
    ("icon_256x256.png",   "icon_256x256@1x.png"),
    ("icon_512x512.png",   "icon_256x256@2x.png"),
    ("icon_512x512.png",   "icon_512x512@1x.png"),
    ("icon_1024x1024.png", "icon_512x512@2x.png"),
]

def process():
    os.makedirs(ASSET_DIR, exist_ok=True)
    print(f"Source : {SRC_DIR}")
    print(f"Dest   : {ASSET_DIR}\n")

    for src_name, dst_name in MAPPING:
        src_path = os.path.join(SRC_DIR, src_name)
        dst_path = os.path.join(ASSET_DIR, dst_name)

        if not os.path.exists(src_path):
            print(f"  [SKIP]  {src_name} not found")
            continue

        img = Image.open(src_path).convert("RGBA")
        img.save(dst_path, format="PNG")
        w, h = img.size
        size_kb = os.path.getsize(dst_path) / 1024
        print(f"  [OK]  {src_name:22s} → {dst_name:26s}  {w}x{h}px  {size_kb:.1f} KB")

    print("\nAll app icons processed.")

if __name__ == "__main__":
    process()
