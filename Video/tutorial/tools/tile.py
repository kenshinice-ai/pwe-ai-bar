"""Tile rendered stills side by side for a quick look. Usage: tile.py out.png width file..."""
import sys
from PIL import Image
out, width, files = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
ims = [Image.open(f) for f in files]
h = int(ims[0].height * width / ims[0].width)
sheet = Image.new("RGB", (width * len(ims) + 4 * (len(ims) - 1), h), "white")
for i, im in enumerate(ims):
    sheet.paste(im.resize((width, h), Image.LANCZOS), (i * (width + 4), 0))
sheet.save(out)
