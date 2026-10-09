"""List the bursts of on-screen change in a take, with where on the screen each one began.
A burst is a run of changed frames; gaps under `--join` seconds are bridged. Coordinates are
points (470 x 700), so they compare directly with the taps that produced the take."""
import argparse, json, subprocess, sys
import numpy as np

W, H = 118, 175  # a quarter of the point grid


def frames(path):
    pts = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "frame=pts_time",
                          "-of", "csv=p=0", path], capture_output=True, text=True, check=True).stdout.split()
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-vf", f"scale={W}:{H}:flags=area,format=gray",
                          "-fps_mode", "passthrough", "-f", "rawvideo", "-"], capture_output=True, check=True).stdout
    data = np.frombuffer(raw, np.uint8).reshape(-1, H, W).astype(np.int16)
    times = np.array([float(p.strip(",")) for p in pts[:len(data)]])
    return times, data


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("take")
    ap.add_argument("--join", type=float, default=0.45)
    ap.add_argument("--min", type=float, default=0.0008, help="share of the screen that must change")
    args = ap.parse_args()
    times, data = frames(args.take)
    bursts, current = [], None
    for i in range(1, len(data)):
        changed = np.abs(data[i] - data[i - 1]) > 12
        share = changed.mean()
        if share < args.min:
            continue
        ys, xs = np.nonzero(changed)
        box = (int(xs.min()) * 4, int(ys.min()) * 4, int(xs.max()) * 4 + 4, int(ys.max()) * 4 + 4)
        if current and times[i] - current["end"] <= args.join:
            current["end"] = float(times[i]); current["peak"] = max(current["peak"], float(share))
        else:
            current = {"start": float(times[i]), "end": float(times[i]), "peak": float(share), "first_box": box}
            bursts.append(current)
    for n, b in enumerate(bursts):
        print(f"{n:3d}  {b['start']:7.2f} → {b['end']:7.2f}  ({b['end'] - b['start']:5.2f}s)  peak {b['peak']:.3f}  first change {b['first_box']}")
    print(f"frames {len(data)}  length {times[-1]:.2f}s", file=sys.stderr)


if __name__ == "__main__":
    main()
