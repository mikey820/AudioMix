from PIL import Image, ImageDraw, ImageFont

def generate_icon(output_path, size=(512, 512)):
    img = Image.new('RGBA', size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    
    # Create a nice radial-like gradient or a smooth linear one
    for y in range(size[1]):
        for x in range(size[0]):
            # Calculate distance from center for a slight radial effect
            dist = ((x - size[0]/2)**2 + (y - size[1]/2)**2)**0.5
            max_dist = (size[0]**2 + size[1]**2)**0.5 / 2
            ratio = dist / max_dist
            
            r = int(120 * (1-ratio) + 80 * ratio)
            g = int(60 * (1-ratio) + 40 * ratio)
            b = int(220 * (1-ratio) + 180 * ratio)
            draw.point((x, y), fill=(r, g, b, 255))

    # Draw a more detailed music note
    # Using a larger size for better quality then resizing
    note_color = (255, 255, 255, 255)
    
    # Heads (beamed note)
    h_w, h_h = size[0] // 5, size[1] // 7
    draw.ellipse([size[0]//4, size[1]*2//3, size[0]//4 + h_w, size[1]*2//3 + h_h], fill=note_color)
    draw.ellipse([size[0]*3//5, size[1]*2//3 - size[1]//10, size[0]*3//5 + h_w, size[1]*2//3 - size[1]//10 + h_h], fill=note_color)
    
    # Stems
    s_w = size[0] // 25
    draw.rectangle([size[0]//4 + h_w - s_w, size[1]//4, size[0]//4 + h_w, size[1]*2//3 + h_h//2], fill=note_color)
    draw.rectangle([size[0]*3//5 + h_w - s_w, size[1]//4 - size[1]//10, size[0]*3//5 + h_w, size[1]*2//3 - size[1]//10 + h_h//2], fill=note_color)
    
    # Beam
    draw.polygon([
        (size[0]//4 + h_w - s_w, size[1]//4),
        (size[0]*3//5 + h_w, size[1]//4 - size[1]//10),
        (size[0]*3//5 + h_w, size[1]//4 - size[1]//10 + size[1]//8),
        (size[0]//4 + h_w - s_w, size[1]//4 + size[1]//8)
    ], fill=note_color)

    # Add a subtle "glow" or border if needed, but simple is often better
    img.save(output_path)

if __name__ == "__main__":
    generate_icon("icon.png")
