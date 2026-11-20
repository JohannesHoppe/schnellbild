#!/usr/bin/env python3
"""Cuts and encodes the demo video from the recording of
.github/workflows/demo-video.yml (its artifact: raw.mov and marks.txt):

    python3 -I Scripts/make_demo_video.py <artifact folder> <out folder>

Writes into <out folder>

    demo-<w>.mp4          the website's video, H.264 (plays everywhere), no sound
    demo-<w>.webm         the same as AV1 in WebM (smaller, for browsers that take it)
    demo-poster-<w>.webp  its first picture, shown before it plays (and .jpg)
    appstore-preview.mp4  the App Store's app preview: 1920 x 1080, 30 fps,
                          H.264 High at level 4.0, about 10 Mbps, a silent
                          stereo AAC track at 48 kHz, 15 to 30 s

for each width w in WIDTHS. Each video is made of parts of the recording
between two marks, joined by a short dissolve: a mark is a scene the test
printed ("DEMO-MARK <time> <scene>") with an offset in seconds, "grid-0.3"
or "tour+9". Both end with a short fade to white (the website's loop
starts again from there). Needs ffmpeg (libx264, libsvtav1) and cwebp (libwebp).
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

WIDTHS = [1280, 960]
# The whole demo (each video ends with a short fade): the grid, the full view, the Atlas, the globe and the tour
# up to its last station's photo
WEB_PARTS = [("grid-0.3", "atlas again-1.4")]
# 30 s at most: browsing, the full view's first photo, the Atlas out to the
# globe and the tour diving in to Bergen's first photos
APPSTORE_PARTS = [("grid-0.3", "full view+3.2"), ("atlas-0.2", "tour+9.4")]
DISSOLVE = 0.5
FADE = 0.6
FPS = 30


def run(*args):
    subprocess.run([str(a) for a in args], check=True)


def read_marks(path):
    marks, start = {}, None
    for line in path.read_text().splitlines():
        kind, _, rest = line.partition(" ")
        time, _, name = rest.partition(" ")
        if kind == "DEMO-RECORDING":
            start = float(time)
        elif kind == "DEMO-MARK":
            marks[name] = float(time)
    if start is None:
        sys.exit(f"{path}: no DEMO-RECORDING line")
    return {name: t - start for name, t in marks.items()}


def at(spec, marks):
    m = re.fullmatch(r"(.+?)([+-][0-9.]+)?", spec)
    name, offset = m.group(1), float(m.group(2) or 0)
    if name not in marks:
        sys.exit(f"no mark {name!r} (marks: {', '.join(marks)})")
    return max(0.0, marks[name] + offset)


def joined(raw, parts, marks, out, size, fade_out=False):
    """The parts at `size` (w, h; scaled to fit, black around), 30 fps,
    dissolving into each other, losslessly into `out`; returns its length."""
    w, h = size
    spans = [(at(a, marks), at(b, marks)) for a, b in parts]
    inputs, chains = [], []
    for i, (a, b) in enumerate(spans):
        inputs += ["-ss", f"{a:.3f}", "-t", f"{b - a:.3f}", "-i", raw]
        chains.append(f"[{i}:v]fps={FPS},scale={w}:{h}:force_original_aspect_ratio=decrease:flags=lanczos,"
                      f"pad={w}:{h}:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,format=yuv444p[p{i}]")
    label, length = "p0", spans[0][1] - spans[0][0]
    for i in range(1, len(spans)):
        offset = length - DISSOLVE
        chains.append(f"[{label}][p{i}]xfade=transition=fade:duration={DISSOLVE}:offset={offset:.3f}[x{i}]")
        label, length = f"x{i}", offset + spans[i][1] - spans[i][0]
    if fade_out:
        chains.append(f"[{label}]fade=t=out:st={length - FADE:.3f}:d={FADE}:color=white[out]")
        label = "out"
    run("ffmpeg", "-v", "error", "-y", *inputs, "-filter_complex", ";".join(chains), "-map", f"[{label}]",
        "-c:v", "libx264", "-preset", "veryfast", "-qp", "0", out)
    return length


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: make_demo_video.py <artifact folder> <out folder>")
    folder, out = Path(sys.argv[1]), Path(sys.argv[2])
    raw, marks = folder / "raw.mov", read_marks(folder / "marks.txt")
    out.mkdir(parents=True, exist_ok=True)
    probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                            "stream=width,height", "-of", "csv=p=0", raw], capture_output=True, text=True, check=True)
    rw, rh = (int(v) for v in probe.stdout.strip().split(","))
    print(f"recording {rw} x {rh}; marks: " + ", ".join(f"{k} {v:.1f}" for k, v in marks.items()))

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        web = tmp / "web.mkv"
        length = joined(raw, WEB_PARTS, marks, web, (rw, rh), fade_out=True)
        print(f"website: {length:.1f} s")
        for w in WIDTHS:
            scale = f"scale={w}:-2:flags=lanczos,format=yuv420p"
            run("ffmpeg", "-v", "error", "-y", "-i", web, "-vf", scale, "-c:v", "libx264", "-preset", "slow",
                "-crf", "24", "-profile:v", "high", "-movflags", "+faststart", "-an", out / f"demo-{w}.mp4")
            run("ffmpeg", "-v", "error", "-y", "-i", web, "-vf", scale, "-c:v", "libsvtav1", "-preset", "4",
                "-crf", "36", "-g", "240", "-svtav1-params", "tune=0", "-an", out / f"demo-{w}.webm")
            poster = tmp / f"poster-{w}.png"
            run("ffmpeg", "-v", "error", "-y", "-i", web, "-frames:v", "1", "-vf", f"scale={w}:-2:flags=lanczos", poster)
            run("cwebp", "-quiet", "-q", "88", poster, "-o", out / f"demo-poster-{w}.webp")
            run("ffmpeg", "-v", "error", "-y", "-i", poster, "-q:v", "3", out / f"demo-poster-{w}.jpg")

        store = tmp / "store.mkv"
        length = joined(raw, APPSTORE_PARTS, marks, store, (1920, 1080), fade_out=True)
        print(f"App Store: {length:.1f} s")
        if not 15 <= length <= 30:
            sys.exit(f"the App Store preview lasts {length:.1f} s: 15 to 30 s")
        run("ffmpeg", "-v", "error", "-y", "-i", store,
            "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000", "-shortest",
            "-map", "0:v", "-map", "1:a", "-vf", "format=yuv420p",
            "-c:v", "libx264", "-preset", "slow", "-profile:v", "high", "-level:v", "4.0",
            "-b:v", "10M", "-maxrate", "12M", "-bufsize", "20M", "-r", str(FPS),
            "-c:a", "aac", "-b:a", "256k", "-ar", "48000", "-ac", "2", "-movflags", "+faststart",
            out / "appstore-preview.mp4")
    for f in sorted(out.iterdir()):
        print(f"{f.name}: {f.stat().st_size / 1e6:.2f} MB")


if __name__ == "__main__":
    main()
