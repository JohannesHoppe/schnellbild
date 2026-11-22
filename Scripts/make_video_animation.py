#!/usr/bin/env python3
"""The website's moving video: the sample video (Scripts/make_sample_media.swift)
with the app's badge and control bar over it, as the app shows it playing, for
docs/site.css to lay over the video in the still screenshots
video-light[-<lang>].webp / video-dark[-<lang>].webp. The control bar's
position and times and the badge's line and time left move along. One video
per theme serves every language: the video has no words, the bar none but its
times, and the window's layout is the same in all of them.

    python3 Scripts/make_video_animation.py <folder> [<Sunset Timelapse.mp4>]

<folder> holds screenshots.yml's English pictures (the artifact
screenshots-en): bartime-<n>-light.png / -dark.png, the paused bar in the
middle of the video's n-th second, give the times. Without a video it draws
the sample media into a temporary folder. Needs ffmpeg (libsvtav1, libx264)
and Pillow. Writes

    docs/screenshots/video-motion-<light|dark>.webm   AV1
    docs/screenshots/video-motion-<light|dark>.mp4    H.264, for browsers without AV1
    site/video-motion.json   where the video lies in the stills (pixels of the
                             1072 x 752 shot) and the files, for Scripts/build_site.py

Where the video lies is read from the stills in docs/screenshots (the black
letterbox around it), and so are the colours: AVKit shows the untagged video
brighter than ffmpeg decodes it (BT.601), so each channel gets the power curve
that matches the stills best, and the result is tagged BT.709, as a browser
shows it.

The badge and the bar are the English still's own pixels, laid over every
frame of the video (30 a second): what differs between each still and the
video frame it shows is the badge at the top and the bar at the bottom, two
rectangles with the app's rounded corners (CORNERS); inside them the still,
outside the video, and in a corner's partly covered pixels the still with the
video's change since its frame added for the part not covered. Their middles
move: the time played, the position slider and the time left in the bar, the
line and the time left in the badge, drawn from the pictures themselves so they
match the still pixel for pixel: the flat ground, the slider's track and the
badge's line from the English still (their filled and their empty part, column
by column), the knob cut out of it, placed where the slider puts it for the
frame's moment (a line fitted through the knob in the bartime pictures), the
badge's line filled up to where a line through the bartime pictures' ends puts
it, and the times from the bartime picture of that second. Every other still
of the theme, laid over its own frame the same way, must come out as itself
(checked, outside the moving parts), and the ground is one flat colour around
the drawn parts in every still and bartime picture (checked).
"""
import json
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path

from PIL import Image, ImageChops, ImageFilter, ImageStat

ROOT = Path(__file__).resolve().parent.parent
SHOTS = ROOT / "docs" / "screenshots"
GEOMETRY = ROOT / "site" / "video-motion.json"
VIDEO_NAME = "Sunset Timelapse.mp4"
SECONDS = 6        # the sample video's length: the bartime pictures cover each second
THEMES = ("light", "dark")
DIFFERS = 40       # a pixel differing this much from the frame is the app's, not the video's
PAD = 2            # around each overlay's rectangle, where the drawn parts look for their ground
MARGIN = 3         # around the bar's and the badge's parts drawn here
# The overlays' corner radii in points (1 px in the shots): the badge's
# RoundedRectangle(cornerRadius: 14) in ContentView.positionBadge, the bar's
# 12 in VideoControlBar
CORNERS = {"badge": 14, "bar": 12}
# Still and video differ by this much at most where only the video is (the
# screenshot's and ffmpeg's decoding): more, and the overlay doesn't fit
FITS = 24


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


def frames(video, width, height, folder):
    """Every frame of the video, as ffmpeg decodes it."""
    folder.mkdir(parents=True, exist_ok=True)
    run("ffmpeg", "-v", "error", "-y", "-i", str(video), "-vf",
        f"scale={width}:{height}:in_color_matrix=bt601:in_range=tv:flags=lanczos,format=rgb24",
        str(folder / "%03d.png"))
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


def overlay(still, frame, w, h, top):
    """The rectangle where the still differs from the video in the top or the
    bottom third: the badge or the bar (solid areas only: what is thinner than
    9 px, the water's glitter caught a frame apart, is left out)."""
    mask = ImageChops.difference(still, frame).convert("L").point(lambda v: 255 if v > DIFFERS else 0)
    y0, y1 = (0, h // 3) if top else (h * 2 // 3, h)
    box = mask.filter(ImageFilter.MinFilter(9)).crop((0, y0, w, y1)).getbbox()
    # the filter takes 4 px off each side
    return box and [box[0] - 4, box[1] + y0 - 4, box[2] + 4, box[3] + y0 + 4]


def coverage(box, radius):
    """How much of each pixel of the box the rounded rectangle covers, 0 … 255,
    sampled 8 x 8 per pixel."""
    x0, y0, x1, y1 = box
    image = Image.new("L", (x1 - x0, y1 - y0), 255)
    n = 8
    for cx, cy, sx, sy in ((0, 0, 1, 1), (x1 - x0 - 1, 0, -1, 1), (0, y1 - y0 - 1, 1, -1), (x1 - x0 - 1, y1 - y0 - 1, -1, -1)):
        for i in range(radius):
            for j in range(radius):
                inside = 0
                for a in range(n):
                    for b in range(n):
                        # distance from the corner's centre, the pixel's sample point measured from the outer edge
                        u, v = radius - (i + (a + 0.5) / n), radius - (j + (b + 0.5) / n)
                        inside += u <= 0 or v <= 0 or u * u + v * v <= radius * radius
                image.putpixel((cx + sx * i, cy + sy * j), round(255 * inside / (n * n)))
    return image


def laid_over(still, still_frame, frame, cover):
    """The still's overlay on another frame of the video: the still where it
    covers, the frame where it doesn't, and in between the still with the
    frame's change since the still's own frame for the part not covered."""
    out = Image.composite(still, frame, cover.point(lambda v: 255 if v == 255 else 0))
    px, s, f0, f1, c = out.load(), still.load(), still_frame.load(), frame.load(), cover.load()
    for yy in range(cover.height):
        for xx in range(cover.width):
            a = c[xx, yy] / 255
            if 0 < a < 1:
                px[xx, yy] = tuple(max(0, min(255, round(s[xx, yy][k] + (1 - a) * (f1[xx, yy][k] - f0[xx, yy][k])))) for k in range(3))
    return out


def encode(pictures, out, kind):
    """The frames as AV1 in WebM or H.264 in MP4, BT.709, no sound."""
    common = ["ffmpeg", "-v", "error", "-y", "-framerate", "30", "-i", str(pictures / "%03d.png"),
              "-vf", "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p",
              "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-color_range", "tv", "-an"]
    if kind == "webm":
        run(*common, "-c:v", "libsvtav1", "-preset", "4", "-crf", "26", "-g", "180", str(out))
    else:
        run(*common, "-c:v", "libx264", "-preset", "slow", "-crf", "18", "-profile:v", "high", "-level:v", "3.1",
            "-movflags", "+faststart", str(out))


# The control bar's middle

def is_blue(p):
    return p[2] > 150 and p[2] > p[0] + 80


class Slider:
    """The position slider and the times beside it, read from one picture of
    the bar (a crop of the bar's hole): the ground's colour, the track's rows
    and ends, the knob, and the runs of drawn columns (grip, play button, time
    played, slider, time left, …)."""

    def __init__(self, bar):
        self.bar = bar
        px = bar.load()
        w, h = bar.size
        self.ground = max(bar.getcolors(w * h), key=lambda c: c[0])[1]
        rows = [y for y in range(h) if sum(is_blue(px[x, y]) for x in range(w)) > 20]
        if not rows:
            raise ValueError("no slider in the bar")
        self.track = (rows[0], rows[-1] + 1)
        y = (rows[0] + rows[-1]) // 2
        self.row = y
        blue = [x for x in range(w) if is_blue(px[x, y])]
        self.left = blue[0]
        # The knob: from the end of the filled part to where the empty track's colour comes back
        filled_end = next(x for x in range(self.left, w) if not is_blue(px[x, y]))
        # the empty track's colour: the most common colour on the row right of the knob, other than the ground
        colours = {}
        for x in range(filled_end, w):
            if px[x, y] != self.ground and not is_blue(px[x, y]):
                colours[px[x, y]] = colours.get(px[x, y], 0) + 1
        empty = max(colours, key=colours.get)
        # the knob ends where the empty track runs on (a few pixels of its colour in a row)
        knob_end = next(x for x in range(filled_end, w - 6) if all(px[x + i, y] == empty for i in range(6)))
        self.knob = (filled_end, knob_end)
        self.centre = (filled_end + knob_end) / 2
        # the track's right end: the last column of its run of the empty colour (and the cap after it)
        x = knob_end
        while x + 1 < w and px[x + 1, y] != self.ground:
            x += 1
        self.right = x
        # Runs of columns that hold anything but the ground, over the slider's rows and a little more
        top, bottom = max(self.track[0] - 8, 0), min(self.track[1] + 8, h)
        drawn = [any(px[x, y] != self.ground for y in range(top, bottom)) for x in range(w)]
        runs, start = [], None
        for x, d in enumerate(drawn + [False]):
            if d and start is None:
                start = x
            if not d and start is not None:
                runs.append([start, x])
                start = None
        # runs closer than 3 px belong together (a time's characters)
        self.runs = []
        for run_ in runs:
            if self.runs and run_[0] - self.runs[-1][1] < 3:
                self.runs[-1][1] = run_[1]
            else:
                self.runs.append(run_)
        slider = next(i for i, r in enumerate(self.runs) if r[0] <= self.left < r[1])
        self.played, self.remaining = self.runs[slider - 1], self.runs[slider + 1]
        self.before, self.after = self.runs[slider - 2], self.runs[slider + 2]

    def region(self):
        """The part of the bar drawn here: the times and the slider with a margin
        that stays clear of the controls beside them, the rows of anything drawn
        in those columns."""
        px = self.bar.load()
        x0 = self.played[0] - min(MARGIN, (self.played[0] - self.before[1]) // 2)
        x1 = self.remaining[1] + min(MARGIN, (self.after[0] - self.remaining[1]) // 2)
        near = range(max(self.track[0] - 12, 0), min(self.track[1] + 12, self.bar.height))
        rows = [y for y in near if any(px[x, y] != self.ground for x in range(x0, x1))]
        return [x0, rows[0] - MARGIN, x1, rows[-1] + 1 + MARGIN]


def bar_frames(still, bartimes, box):
    """A function giving the bar's part `box` (in the bar's crop) at a moment
    of the video, drawn from the theme's English still and its bartime
    pictures; and the largest difference between the still and what it gives
    for the still's own knob (outside the times)."""
    ref = Slider(still)
    x0, y0, x1, y1 = box
    ground = Image.new("RGB", (x1 - x0, y1 - y0), ref.ground)

    def column(x):
        return still.crop((x, y0, x + 1, y1))

    filled, empty = column(ref.left + 4), column(ref.right - 4)
    cap_left = still.crop((ref.left, y0, ref.left + 3, y1))
    cap_right = still.crop((ref.right - 2, y0, ref.right + 1, y1))

    def track(boundary):
        image = ground.copy()
        for x in range(ref.left, ref.right + 1):
            image.paste(filled if x < boundary else empty, (x - x0, 0))
        image.paste(cap_left, (ref.left - x0, 0))
        image.paste(cap_right, (ref.right - 2 - x0, 0))
        return image

    # The knob: what differs in the still from the bare track filled up to the knob's middle
    k0, k1 = ref.knob[0] - 4, ref.knob[1] + 4
    actual = still.crop((x0, y0, x1, y1))
    bare = track(round(ref.centre))
    knob_box = (k0 - x0, 0, k1 - x0, y1 - y0)
    knob = actual.crop(knob_box)
    mask = ImageChops.difference(knob, bare.crop(knob_box)).convert("L").point(lambda v: 255 if v else 0)

    # Where the knob stands for a position: a line through the bartime pictures' knobs
    points = []
    times = {}
    for second, picture in bartimes.items():
        slider = Slider(picture)
        if (slider.left, slider.right, slider.track) != (ref.left, ref.right, ref.track):
            sys.exit(f"bartime-{second}: the slider lies elsewhere than in the still")
        points.append(((second - 0.5) / SECONDS, slider.centre))
        times[second] = (picture.crop((x0, y0, ref.left - 1, y1)), picture.crop((ref.right + 2, y0, x1, y1)))
    offset, slope = line(points, "the knob's places")

    def draw(t):
        """The part at the video's time t (seconds, never a whole one)."""
        second = int(t) + 1
        centre = offset + slope * t / SECONDS
        image = track(round(centre))
        played, left = times[second]
        image.paste(played, (0, 0))
        image.paste(left, (ref.right + 2 - x0, 0))
        # the knob last: near either end it reaches past the track
        image.paste(knob, (k0 - x0 + round(centre - ref.centre), 0), mask)
        return image

    # Outside the times, the still's own state drawn again must be the still
    check = track(round(ref.centre))
    check.paste(knob, (k0 - x0, 0), mask)
    keep = (ref.left - 1 - x0, 0, ref.right + 2 - x0, y1 - y0)
    worst = max(ImageStat.Stat(ImageChops.difference(check.crop(keep), actual.crop(keep))).extrema, key=lambda e: e[1])[1]
    return draw, worst


class Line:
    """The badge's progress line and the time left after it, read from one
    picture of the badge (a crop of its hole): the ground's colour, the line's
    rows and ends, where its filled part ends, and the time's columns."""

    def __init__(self, badge):
        self.badge = badge
        px = badge.load()
        w, h = badge.size
        self.ground = max(badge.getcolors(w * h), key=lambda c: c[0])[1]

        def run_at(y):
            """The longest run of columns other than the ground on row y with
            the ground on both sides (inside the badge)."""
            best, start = (0, 0), None
            for x in range(w + 1):
                drawn = x < w and px[x, y] != self.ground
                if drawn and start is None:
                    start = x
                if not drawn and start is not None:
                    if start > 0 and x < w:
                        best = max(best, (x - start, start))
                    start = None
            return best
        rows = [y for y in range(h) if run_at(y)[0] > w // 2]
        if not rows:
            raise ValueError("no progress line in the badge")
        self.track = (rows[0], rows[-1] + 1)
        y = self.row = (rows[0] + rows[-1]) // 2
        length, self.left = run_at(y)
        self.right = self.left + length - 1
        filled = px[self.left + 3, y]
        self.boundary = next(x for x in range(self.left + 3, self.right) if px[x, y] != filled)
        near = range(max(self.track[0] - 8, 0), min(self.track[1] + 8, h))
        columns = [x for x in range(self.right + 2, w) if any(px[x, r] != self.ground for r in near)]
        self.time = [columns[0], columns[0]]
        for x in columns:
            if x - self.time[1] > 3:
                break
            self.time[1] = x + 1

    def region(self):
        """The line and the time with a margin, the rows of anything drawn in those columns."""
        px = self.badge.load()
        x0, x1 = self.left - MARGIN, self.time[1] + MARGIN
        near = range(max(self.track[0] - 8, 0), min(self.track[1] + 8, self.badge.height))
        rows = [y for y in near if any(px[x, y] != self.ground for x in range(x0, x1))]
        return [x0, rows[0] - MARGIN, x1, rows[-1] + 1 + MARGIN]


def line(points, what):
    """The straight line through (position, x) points: offset and slope."""
    n = len(points)
    mp, mc = sum(p for p, _ in points) / n, sum(c for _, c in points) / n
    slope = sum((p - mp) * (c - mc) for p, c in points) / sum((p - mp) ** 2 for p, _ in points)
    offset = mc - slope * mp
    fit = max(abs(offset + slope * p - c) for p, c in points)
    if fit > 1:
        sys.exit(f"{what} don't lie on a line ({fit:.1f} px off)")
    return offset, slope


def badge_frames(still, bartimes, box):
    """As bar_frames for the badge's progress line and time left: the line
    filled up to where the bartime pictures say, the time of that second."""
    ref = Line(still)
    x0, y0, x1, y1 = box
    ground = Image.new("RGB", (x1 - x0, y1 - y0), ref.ground)
    filled = still.crop((ref.left + 3, y0, ref.left + 4, y1))
    empty = still.crop((ref.right - 3, y0, ref.right - 2, y1))
    cap_left = still.crop((ref.left, y0, ref.left + 2, y1))
    cap_right = still.crop((ref.right - 1, y0, ref.right + 1, y1))
    # the filled part is a capsule of its own: its rounded end goes along with it
    end = still.crop((ref.boundary - 3, y0, ref.boundary, y1))

    def track(boundary):
        image = ground.copy()
        for x in range(ref.left, ref.right + 1):
            image.paste(filled if x < boundary else empty, (x - x0, 0))
        image.paste(cap_left, (ref.left - x0, 0))
        image.paste(cap_right, (ref.right - 1 - x0, 0))
        if boundary - 3 >= ref.left + 2:
            image.paste(end, (boundary - 3 - x0, 0))
        return image

    points, times = [], {}
    for second, picture in bartimes.items():
        found = Line(picture)
        if (found.left, found.right, found.track) != (ref.left, ref.right, ref.track):
            sys.exit(f"bartime-{second}: the badge's line lies elsewhere than in the still")
        points.append(((second - 0.5) / SECONDS, found.boundary))
        times[second] = picture.crop((ref.right + 2, y0, x1, y1))
    offset, slope = line(points, "the ends of the badge's filled line")

    def draw(t):
        image = track(round(offset + slope * t / SECONDS))
        image.paste(times[int(t) + 1], (ref.right + 2 - x0, 0))
        return image

    actual = still.crop((x0, y0, x1, y1))
    keep = (0, 0, ref.right + 2 - x0, y1 - y0)
    check = track(ref.boundary)
    worst = max(ImageStat.Stat(ImageChops.difference(check.crop(keep), actual.crop(keep))).extrema, key=lambda e: e[1])[1]
    return draw, worst


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    folder = Path(sys.argv[1])
    with tempfile.TemporaryDirectory() as name:
        tmp = Path(name)
        video = Path(sys.argv[2]) if len(sys.argv) > 2 else sample_video(tmp)
        all_stills = stills()
        first = Image.open(all_stills[0]).convert("RGBA")
        x, y, w, h = video_area(first)
        for path in all_stills:
            image = Image.open(path).convert("RGBA")
            if image.size != first.size or video_area(image) != (x, y, w, h):
                sys.exit(f"{path.name}: the video lies elsewhere than in {all_stills[0].name}")

        # Colours: the curve that matches the first still, from a plain decode
        plain = frames(video, w, h, tmp / "plain")
        decoded = [Image.open(p).convert("RGB") for p in plain]
        crop = lambda p: Image.open(p).convert("RGB").crop((x, y, x + w, y + h))
        reference = crop(all_stills[0])
        gamma = fit_gamma(reference, closest(reference, decoded, h), h)
        decoded = [f.point(sum((curve(g) for g in gamma), [])) for f in decoded]

        # Each still's frame; the badge and the bar where any still shows them
        matched, worst = {}, 0.0
        found = {"badge": [], "bar": []}
        for path in all_stills:
            still = crop(path)
            frame = closest(still, decoded, h)
            matched[path] = (still, frame)
            worst = max(worst, max(ImageStat.Stat(ImageChops.difference(middle(still, h), middle(frame, h))).mean))
            for name, top in (("badge", True), ("bar", False)):
                box = overlay(still, frame, w, h, top)
                if box:
                    found[name].append(box)
        # the rectangle most stills show: where the overlay's ground is near the
        # video's colours a still shows less of it, where a glitter stroke touches
        # it more (the check below makes sure it fits every still)
        rects = {name: list(Counter(map(tuple, boxes)).most_common(1)[0][0]) for name, boxes in found.items()}
        print(f"video at {x},{y} {w}x{h}; gamma {gamma}; badge {rects['badge']}, bar {rects['bar']}; "
              f"largest mean difference {worst:.1f}")

        # The parts drawn here, in each overlay's rectangle with PAD around it
        holes = {name: [r[0] - PAD, r[1] - PAD, r[2] + PAD, r[3] + PAD] for name, r in rects.items()}
        parts = []
        for name, reader, frames_of, what in (("bar", Slider, bar_frames, "control bar's slider and times"),
                                              ("badge", Line, badge_frames, "badge's line and time left")):
            hole = holes[name]
            of = lambda image, hole=hole: image.crop(tuple(hole))
            pictures = {path: of(crop(path)) for path in all_stills + sorted(folder.glob("bartime-*.png"))}
            regions = [reader(picture).region() for picture in pictures.values()]
            box = [min(r[0] for r in regions), min(r[1] for r in regions), max(r[2] for r in regions), max(r[3] for r in regions)]
            for path, picture in pictures.items():
                region = picture.crop(box)
                edge = [region.getpixel((i, j)) for i in range(region.width) for j in (0, region.height - 1)]
                edge += [region.getpixel((i, j)) for j in range(region.height) for i in (0, region.width - 1)]
                if len(set(edge)) != 1:
                    sys.exit(f"{path.name}: the ground isn't one colour around the {what}")
            parts.append((hole, of, box, frames_of, what))

        covers = {name: coverage(rect, CORNERS[name]) for name, rect in rects.items()}

        def lay(still, still_frame, frame):
            """The still's badge and bar over a frame."""
            image = frame.copy()
            for name, rect in rects.items():
                r = tuple(rect)
                image.paste(laid_over(still.crop(r), still_frame.crop(r), frame.crop(r), covers[name]), r[:2])
            return image

        moving = [(hole[0] + box[0], hole[1] + box[1], hole[0] + box[2], hole[1] + box[3]) for hole, _, box, _, _ in parts]
        # What differs between the languages in the badge and the bar (the title's
        # font in Chinese and Japanese) stays the still's own: a rectangle on the
        # flat ground around it, where the page lets the still show through
        def differing(theme):
            reference, reference_frame = matched[SHOTS / f"video-{theme}.webp"]
            for path, (still, frame) in matched.items():
                if path.name.startswith(f"video-{theme}"):
                    laid = lay(reference, reference_frame, frame)
                    for r in moving:
                        laid.paste(still.crop(r), r[:2])
                    yield path, laid, still
        kept = []
        for name, rect in rects.items():
            r = tuple(rect)
            # (only where the overlay covers a pixel wholly: around it is the video)
            inside = covers[name].point(lambda v: 255 if v == 255 else 0)
            boxes = [ImageChops.multiply(ImageChops.difference(laid.crop(r), still.crop(r)).convert("L")
                                         .point(lambda v: 255 if v > FITS else 0), inside).getbbox()
                     for theme in THEMES for _, laid, still in differing(theme)]
            boxes = [b for b in boxes if b]
            if boxes:
                kept.append([r[0] + min(b[0] for b in boxes) - MARGIN, r[1] + min(b[1] for b in boxes) - MARGIN,
                             r[0] + max(b[2] for b in boxes) + MARGIN, r[1] + max(b[3] for b in boxes) + MARGIN])
        for k in kept:
            for path, (still, _) in matched.items():
                region = still.crop(tuple(k))
                edge = [region.getpixel((i, j)) for i in range(region.width) for j in (0, region.height - 1)]
                edge += [region.getpixel((i, j)) for j in range(region.height) for i in (0, region.width - 1)]
                if len(set(edge)) != 1:
                    sys.exit(f"{path.name}: the ground isn't one colour around {k}, which differs between the languages")
        print(f"the still's own: {kept}")

        files = {}
        for theme in THEMES:
            reference, reference_frame = matched[SHOTS / f"video-{theme}.webp"]
            # Every still of the theme laid over its own frame from the English one: itself
            off = 0
            for path, laid, still in differing(theme):
                for k in kept:
                    laid.paste(still.crop(tuple(k)), tuple(k[:2]))
                for rect in rects.values():
                    r = tuple(rect)
                    diff = ImageChops.difference(laid.crop(r), still.crop(r))
                    off = max(off, max(e[1] for e in diff.getextrema()))
            print(f"{theme}: the badge and bar laid over each still's own frame differ from it by at most {off}")
            if off > FITS:
                sys.exit(f"{theme}: the badge and the bar don't fit the stills (difference {off})")

            paths = []
            for second in range(1, SECONDS + 1):
                path = folder / f"bartime-{second}-{theme}.png"
                if not path.exists():
                    sys.exit(f"{path} is missing (screenshots.yml's English pictures)")
                paths.append(path)
            drawers = []
            for hole, of, box, frames_of, what in parts:
                bartimes = {second: of(crop(path)) for second, path in enumerate(paths, 1)}
                draw, off = frames_of(of(reference), bartimes, box)
                print(f"{theme}: the still's {what} drawn again differ by at most {off} (outside the times)")
                drawers.append((draw, (hole[0] + box[0], hole[1] + box[1])))
            composed = tmp / f"composed-{theme}"
            composed.mkdir()
            for i, frame in enumerate(decoded):
                t = (i + 0.5) / 30   # the frame's moment, half a frame on: never a whole second
                image = lay(reference, reference_frame, frame)
                for draw, place in drawers:
                    image.paste(draw(t), place)
                image.save(composed / f"{i:03d}.png")
            files[theme] = {}
            for kind in ("webm", "mp4"):
                name = f"video-motion-{theme}.{kind}"
                encode(composed, SHOTS / name, kind)
                files[theme][kind] = name
                print(f"docs/screenshots/{name}: {len(decoded)} frames, {(SHOTS / name).stat().st_size // 1024} KB")

        for old in SHOTS.glob("video-motion-*"):
            if old.name not in [n for f in files.values() for n in f.values()]:
                old.unlink()
                print("deleted", old.relative_to(ROOT))
        GEOMETRY.write_text(json.dumps({"shot": list(first.size), "area": [x, y, w, h], "still": kept, "files": files}, indent=1) + "\n")
        print(f"{GEOMETRY.relative_to(ROOT)} written")


if __name__ == "__main__":
    main()
