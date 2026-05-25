import sys
import os
from PIL import Image, ImageDraw

def process_image(img_path, output_dir):
    try:
        # Load the base standby image
        img = Image.open(img_path).convert("RGBA")
        
        # It's a solid black background with white car (as per the prompt). 
        # Wait, the prompt was: "solid white silhouette ... Solid black background".
        # Let's extract the white part and make the background transparent.
        data = img.getdata()
        new_data = []
        for item in data:
            # item is (R, G, B, A)
            r, g, b = item[:3]
            # If it's bright, keep it as white and solid, if dark, make transparent
            if r > 127 and g > 127 and b > 127:
                new_data.append((255, 255, 255, 255)) # White
            else:
                new_data.append((0, 0, 0, 0)) # Transparent
                
        # This is the "standby dark mode" (white icon)
        standby_dark = Image.new("RGBA", img.size)
        standby_dark.putdata(new_data)
        
        # Crop to the actual icon bounds before resizing to avoid weird padding
        bbox = standby_dark.getbbox()
        if bbox:
            standby_dark = standby_dark.crop(bbox)
        
        # Make it square
        width, height = standby_dark.size
        max_dim = max(width, height)
        square_dark = Image.new("RGBA", (max_dim, max_dim), (0,0,0,0))
        offset = ((max_dim - width) // 2, (max_dim - height) // 2)
        square_dark.paste(standby_dark, offset)
        standby_dark = square_dark

        # The "standby light mode" (black icon)
        black_data = []
        for item in standby_dark.getdata():
            if item[3] > 0: # If not transparent
                black_data.append((0, 0, 0, item[3]))
            else:
                black_data.append((0, 0, 0, 0))
        standby_light = Image.new("RGBA", standby_dark.size)
        standby_light.putdata(black_data)
        
        # Now create processing states by adding some action lines/waves
        # We will just draw a couple of arcs around the car
        def add_processing_lines(base_img, color):
            proc_img = base_img.copy()
            draw = ImageDraw.Draw(proc_img)
            w, h = proc_img.size
            # Draw semi-circle arcs on left and right
            margin = int(w * 0.1)
            lw = max(1, int(w * 0.03))
            bbox_left = [margin, margin, w - margin, h - margin]
            draw.arc(bbox_left, 135, 225, fill=color, width=lw)
            draw.arc(bbox_left, 315, 45, fill=color, width=lw)
            
            bbox_inner_left = [margin*2, margin*2, w - margin*2, h - margin*2]
            draw.arc(bbox_inner_left, 145, 215, fill=color, width=lw)
            draw.arc(bbox_inner_left, 325, 35, fill=color, width=lw)
            return proc_img

        processing_dark = add_processing_lines(standby_dark, (255,255,255,255))
        processing_light = add_processing_lines(standby_light, (0,0,0,255))

        states = {
            "standby_dark": standby_dark,
            "standby_light": standby_light,
            "processing_dark": processing_dark,
            "processing_light": processing_light
        }
        
        sizes = [(18, 18), (36, 36), (16, 16)]
        
        # Save raw crops
        os.makedirs(output_dir, exist_ok=True)
        for state_name, st_img in states.items():
            st_img.save(os.path.join(output_dir, f"{state_name}_raw.png"))
            for sz in sizes:
                resized = st_img.resize(sz, Image.Resampling.LANCZOS)
                suffix = ""
                if sz == (36, 36):
                    suffix = "@2x"
                elif sz == (18, 18):
                    suffix = "_18x18"
                elif sz == (16, 16):
                    suffix = "_16x16"
                resized.save(os.path.join(output_dir, f"{state_name}{suffix}.png"))

        print("Successfully generated menu bar icons.")

    except Exception as e:
        print(f"Error: {e}")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python process.py <input> <output_dir>")
        sys.exit(1)
    process_image(sys.argv[1], sys.argv[2])
