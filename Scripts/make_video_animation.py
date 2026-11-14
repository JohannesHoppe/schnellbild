#!/usr/bin/env python3
"""The website's moving video: the sample video (Scripts/make_sample_media.swift)
as an animated WebP that docs/site.css lays over the video in the still
screenshots video-light[-<lang>].webp / video-dark[-<lang>].webp. One animation
serves every language and theme: the video has no words, and the window's
layout is the same in all of them.

    python3 Scripts/make_video_animation.py [<Sunset Timelapse.mp4>]

Without a video it draws the sample media into a temporary folder. Needs
ffmpeg and img2webp (libwebp) and Pillow. Writes

    docs/screenshots/video-motion-960.webp, video-motion-480.webp
    site/video-motion.json   where the video lies in the stills (pixels of
                             the 1072 x 752 shot) and the holes the badge and
                             the control bar need (pixels of the video), for
                             Scripts/build_site.py

Where the video lies and what covers it is read from the stills in
docs/screenshots: the black letterbox around it, then each still against the
video's frames (the one it shows); what differs there is the badge and the
control bar, taken together over every still. The colours follow the stills
too: AVKit shows the untagged video brighter than ffmpeg decodes it (BT.601),
so each channel gets the power curve that matches the stills best.
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageChops, ImageStat

ROOT = Path(__file__).resolve().parent.parent
SHOTS = ROOT / "docs" / "screenshots"
GEOMETRY = ROOT / "site" / "video-motion.json"
VIDEO_NAME = "Sunset Timelapse.mp4"
FPS = 15
WIDTHS = {960: 90, 480: 90}  # width: WebP quality
DIFFERS = 40       # a pixel differing this much from the frame is the app's, not the video's
PAD = 2            # around each hole


def run(*args, **kw):
    return subprocess.run(args, check=True, **kw)


def sample_video(tmp):
    folder = tmp / "sample"
    run("swift", str(ROOT / "Scripts" / "make_sample_media.swift"), str(folder))
    return folder / VIDEO_NAME


def stills():
    found = sorted(p for p in SHOTS.glob("video-*.webp") if p.name.startswith(("video-light", "video-dark")))
    if not found:
        sys.exit("no video stills in docs/screenshots")
    return found


def video_area(still):
    """The video's rectangle in a still: between the letterbox's black bars,
    the window's width."""
    image = still.convert("RGB")
    width, height = image.size
    x = width // 3
    column = [image.getpixel((x, y)) for y in range(height)]
    black = [max(c) < 8 for c in column]
    top = next(y for y in range(height) if black[y] and y > 60)        # the bar above the video
    top = next(y for y in range(top, height) if not black[y])
    bottom = next(y for y in range(top, height) if black[y])
    alpha = still.getchannel("A")
    row = [alpha.getpixel((x, (top + bottom) // 2)) for x in range(width)]
    left = next(x for x in range(width) if row[x] == 255)
    right = max(x for x in range(width) if row[x] == 255) + 1
    return left, top, right - left, bottom - top


def frames(video, width, height, gamma, folder):
    folder.mkdir(parents=True, exist_ok=True)
    curves = ":".join(f"{c}='255*pow(val/255\\,{g})'" for c, g in zip("rgb", gamma))
    run("ffmpeg", "-v", "error", "-y", "-i", str(video), "-vf",
        f"scale={width}:{height}:in_color_matrix=bt601:in_range=tv:flags=lanczos,format=rgb24,"
        f"lutrgb={curves},fps={FPS}", str(folder / "%03d.png"))
    return sorted(folder.glob("*.png"))


def curve(gamma):
    return [round(255 * (v / 255) ** gamma) for v in range(256)]


def middle(image, h):
    """Rows away from the badge (top) and the control bar (bottom)."""
    return image.crop((0, h // 4, image.width, h * 3 // 4))


def closest(still, decoded, h):
    """The decoded frame the still shows."""
    target = middle(still, h)
    return min(decoded, key=lambda f: sum(ImageStat.Stat(ImageChops.difference(target, middle(f, h))).mean))


def fit_gamma(still, frame, h):
    target, source = middle(still, h), middle(frame, h)
    best = []
    for c in range(3):
        t, s = target.getchannel(c), source.getchannel(c)
        best.append(min((ImageStat.Stat(ImageChops.difference(t, s.point(curve(g / 1000)))).mean[0], g / 1000)
                        for g in range(800, 1001, 4))[1])
    return best


def holes(still, frame, w, h):
    """The rectangles where the still differs from the video: the badge at
    the top, the control bar at the bottom."""
    mask = ImageChops.difference(still, frame).convert("L").point(lambda v: 255 if v > DIFFERS else 0)
    found = []
    for y0, y1 in ((0, h // 3), (h * 2 // 3, h)):
        box = mask.crop((0, y0, w, y1)).getbbox()
        if box:
            found.append([max(box[0] - PAD, 0), max(box[1] + y0 - PAD, 0),
                          min(box[2] + PAD, w), min(box[3] + y0 + PAD, h)])
    return found


def union(boxes):
    """Boxes overlapping each other merged."""
    merged = []
    for box in sorted(boxes):
        for m in merged:
            if box[0] < m[2] and m[0] < box[2] and box[1] < m[3] and m[1] < box[3]:
                m[:] = [min(m[0], box[0]), min(m[1], box[1]), max(m[2], box[2]), max(m[3], box[3])]
                break
        else:
            merged.append(list(box))
    return merged


def main():
    with tempfile.TemporaryDirectory() as name:
        tmp = Path(name)
        video = Path(sys.argv[1]) if len(sys.argv) > 1 else sample_video(tmp)
        all_stills = stills()
        first = Image.open(all_stills[0]).convert("RGBA")
        x, y, w, h = video_area(first)
        for path in all_stills:
            image = Image.open(path).convert("RGBA")
            if image.size != first.size or video_area(image) != (x, y, w, h):
                sys.exit(f"{path.name}: the video lies elsewhere than in {all_stills[0].name}")

        # Colours: the curve that matches the first still, from a plain decode
        plain = frames(video, w, h, (1, 1, 1), tmp / "plain")
        decoded = [Image.open(p).convert("RGB") for p in plain]
        crop = lambda p: Image.open(p).convert("RGB").crop((x, y, x + w, y + h))
        reference = crop(all_stills[0])
        gamma = fit_gamma(reference, closest(reference, decoded, h), h)
        decoded = [f.point(sum((curve(g) for g in gamma), [])) for f in decoded]

        boxes, worst = [], 0.0
        for path in all_stills:
            still = crop(path)
            frame = closest(still, decoded, h)
            worst = max(worst, max(ImageStat.Stat(ImageChops.difference(middle(still, h), middle(frame, h))).mean))
            boxes += holes(still, frame, w, h)
        cut = union(boxes)
        print(f"video at {x},{y} {w}x{h}; gamma {gamma}; holes {cut}; largest mean difference {worst:.1f}")

        for width, quality in WIDTHS.items():
            height = round(h * width / w)
            pictures = frames(video, width, height, gamma, tmp / f"w{width}")
            out = SHOTS / f"video-motion-{width}.webp"
            run("img2webp", "-loop", "0", "-lossy", "-q", str(quality), "-m", "4",
                "-d", str(round(1000 / FPS)), *map(str, pictures), "-o", str(out), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            print(f"{out.relative_to(ROOT)}: {len(pictures)} frames, {out.stat().st_size // 1024} KB")

        GEOMETRY.write_text(json.dumps({
            "shot": list(first.size), "area": [x, y, w, h], "holes": cut,
            "files": {str(width): f"video-motion-{width}.webp" for width in WIDTHS}}, indent=1) + "\n")
        print(f"{GEOMETRY.relative_to(ROOT)} written")


if __name__ == "__main__":
    main()
