"""Contact sheet of a take: for each time given, the frame that was on screen then (the last one at
or before it), labelled with that frame's own timestamp. Recordings are variable frame rate, so a
plain seek returns the next frame instead and misleads."""
import bisect, subprocess, sys
from PIL import Image, ImageDraw

take, out, times = sys.argv[1], sys.argv[2], [float(t) for t in sys.argv[3:]]
pts = [float(p.strip(",")) for p in subprocess.run(
    ["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "frame=pts_time", "-of", "csv=p=0", take],
    capture_output=True, text=True, check=True).stdout.split()]
indices = sorted({max(0, bisect.bisect_right(pts, t) - 1) for t in times})
select = "+".join(f"eq(n\\,{i})" for i in indices)
TW, TH = 235, 350
raw = subprocess.run(["ffmpeg", "-v", "error", "-i", take, "-vf", f"select='{select}',scale={TW}:{TH}",
                      "-fps_mode", "passthrough", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                     capture_output=True, check=True).stdout
cols = min(len(indices), 8)
rows = (len(indices) + cols - 1) // cols
sheet = Image.new("RGB", (cols * (TW + 2), rows * (TH + 2)), "white")
for n, i in enumerate(indices):
    im = Image.frombytes("RGB", (TW, TH), raw[n * TW * TH * 3:(n + 1) * TW * TH * 3])
    d = ImageDraw.Draw(im)
    d.rectangle((0, 0, 62, 16), fill="black")
    d.text((3, 2), f"{pts[i]:.2f}", fill="white")
    sheet.paste(im, ((n % cols) * (TW + 2), (n // cols) * (TH + 2)))
sheet.save(out)
