#!/usr/bin/env python3
"""Cuts and encodes the demo video from the recording of
.github/workflows/demo-video.yml (its artifact: raw.mov and marks.txt):

    python3 -I Scripts/make_demo_video.py <artifact folder> <out folder>

Writes into <out folder>

    demo-<w>.mp4          the whole demo for the website, H.264 (plays
                          everywhere), no sound
    demo-<w>.webm         the same as AV1 in WebM (smaller, for browsers that take it)
    demo-short-<w>.mp4 / .webm  its short cut (about 30 s), for a loop
    demo-poster-<w>.webp  their first picture, shown before they play (and .jpg)
    appstore-preview.mp4  the short cut as the App Store's app preview:
                          1920 x 1080, 30 fps, H.264 High at level 4.0, about
                          10 Mbps, a silent stereo AAC track at 48 kHz, 15 to 30 s

for each width w in WIDTHS. Each video is made of parts of the recording
between two marks, joined by a short dissolve: a mark is a scene the test
printed ("DEMO-MARK <time> <scene>") with an offset in seconds, "grid-0.3"
or "tour+9". Each ends with a short fade to white (a loop starts again
from there). It warns about a frame in a part that shows the full view
black or the map empty (`glitches`). Needs ffmpeg (libx264, libsvtav1) and
cwebp (libwebp).
"""
import functools
import re
import subprocess
import sys
import tempfile
from pathlib import Path

WIDTHS = [1280, 960]
# The whole demo: the grid and the full view, dissolving into the Atlas,
# out to the globe and the tour up to its last station's photo; click to play
WEB_PARTS = [("grid-0.3", "full view+5"), ("atlas+2", "atlas again-1.4")]
# About 30 s, for a loop on the website and the App Store: browsing, the
# full view's first photo, the Atlas out to the globe and the tour diving in
# to Bergen's first photos
SHORT_PARTS = [("grid-0.3", "full view+3.4"), ("atlas+2", "tour+10")]
DISSOLVE = 0.5
DARK = 60          # mean luma of the full view black around its badge (with its photo about 130)
BLANK = 220        # mean luma of the Atlas with an empty map (with its tiles about 210)
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


@functools.cache
def brightness(raw):
    """Each frame's time and mean luma (0 to 255) in the recording."""
    probe = subprocess.run(["ffprobe", "-v", "error", "-f", "lavfi", f"movie={raw},signalstats",
                            "-show_entries", "frame=pts_time:frame_tags=lavfi.signalstats.YAVG", "-of", "csv=p=0"],
                           capture_output=True, text=True, check=True)
    frames = []
    for line in probe.stdout.splitlines():
        values = [v for v in line.split(",") if v]
        if len(values) >= 2:
            frames.append((float(values[0]), float(values[1])))
    return sorted(frames)


def at(spec, marks):
    """A mark with an offset in seconds."""
    m = re.fullmatch(r"(.+?)([+-][0-9.]+)?", spec)
    name, offset = m.group(1), m.group(2) or "0"
    if name not in marks:
        sys.exit(f"no mark {name!r} (marks: {', '.join(marks)})")
    return max(0.0, marks[name] + float(offset))


def glitches(raw, marks, spans):
    """The frames within `spans` that show the full view black (in the 5 s
    after the mark "full view") or the map empty (in the 5 s after "globe"):
    (time, what)."""
    found = []
    for t, luma in brightness(raw):
        if not any(a <= t <= b for a, b in spans):
            continue
        if "full view" in marks and marks["full view"] <= t <= marks["full view"] + 5 and luma < DARK:
            found.append((t, "the full view black"))
        if "globe" in marks and marks["globe"] <= t <= marks["globe"] + 5 and luma > BLANK:
            found.append((t, "the map empty"))
    return found


def joined(raw, steady, parts, marks, out, size, fade_out=False):
    """The parts of `steady` (the recording at a steady frame rate) at `size`
    (w, h; scaled to fit, black around), dissolving into each other,
    losslessly into `out`; returns its length. The marks' frames are looked
    up in `raw`."""
    w, h = size
    spans = [(at(a, marks), at(b, marks)) for a, b in parts]
    for t, what in glitches(raw, marks, spans):
        print(f"warning: {what} at {t:.2f} s of the recording")
    inputs, chains = [], []
    for i, (a, b) in enumerate(spans):
        inputs += ["-i", steady]
        chains.append(f"[{i}:v]trim=start={a:.3f}:end={b:.3f},setpts=PTS-STARTPTS,scale={w}:{h}:force_original_aspect_ratio=decrease:flags=lanczos,"
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
        # The recording has a frame only where the screen changed; at a steady
        # rate each picture lasts until the next, and the parts are cut exactly
        steady = tmp / "steady.mkv"
        run("ffmpeg", "-v", "error", "-y", "-i", raw, "-vf", f"fps={FPS}", "-c:v", "libx264", "-preset", "ultrafast",
            "-qp", "0", steady)
        for name, parts in [("demo", WEB_PARTS), ("demo-short", SHORT_PARTS)]:
            cut = tmp / f"{name}.mkv"
            length = joined(raw, steady, parts, marks, cut, (rw, rh), fade_out=True)
            print(f"{name}: {length:.1f} s")
            for w in WIDTHS:
                scale = f"scale={w}:-2:flags=lanczos,format=yuv420p"
                run("ffmpeg", "-v", "error", "-y", "-i", cut, "-vf", scale, "-c:v", "libx264", "-preset", "slow",
                    "-crf", "24", "-profile:v", "high", "-movflags", "+faststart", "-an", out / f"{name}-{w}.mp4")
                run("ffmpeg", "-v", "error", "-y", "-i", cut, "-vf", scale, "-c:v", "libsvtav1", "-preset", "4",
                    "-crf", "38", "-g", "240", "-an", out / f"{name}-{w}.webm")
                if name == "demo":
                    poster = tmp / f"poster-{w}.png"
                    run("ffmpeg", "-v", "error", "-y", "-i", cut, "-frames:v", "1", "-vf",
                        f"scale={w}:-2:flags=lanczos", poster)
                    run("cwebp", "-quiet", "-q", "88", poster, "-o", out / f"demo-poster-{w}.webp")
                    run("ffmpeg", "-v", "error", "-y", "-i", poster, "-q:v", "3", out / f"demo-poster-{w}.jpg")

        store = tmp / "store.mkv"
        length = joined(raw, steady, SHORT_PARTS, marks, store, (1920, 1080), fade_out=True)
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
