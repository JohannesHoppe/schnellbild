#!/usr/bin/env python3
"""The website's moving video: the sample video (Scripts/make_sample_media.swift)
as an animated WebP that docs/site.css lays over the video in the still
screenshots video-light[-<lang>].webp / video-dark[-<lang>].webp, with the
control bar's position and times and the badge's line and time left moving
along. One animation per theme serves
every language: the video has no words, the bar none but its times, and the
window's layout is the same in all of them.

    python3 Scripts/make_video_animation.py <folder> [<Sunset Timelapse.mp4>]

<folder> holds screenshots.yml's English pictures (the artifact
screenshots-en): bartime-<n>-light.png / -dark.png, the paused bar in the
middle of the video's n-th second, give the times. Without a video it draws
the sample media into a temporary folder. Needs ffmpeg and img2webp (libwebp)
and Pillow. Writes

    docs/screenshots/video-motion-<light|dark>-960.webp, -480.webp
    site/video-motion.json   where the video lies in the stills (pixels of
                             the 1072 x 752 shot), the holes the badge and
                             the control bar need and the part of the bar
                             the animation draws itself (pixels of the
                             video), for Scripts/build_site.py

Where the video lies and what covers it is read from the stills in
docs/screenshots: the black letterbox around it, then each still against the
video's frames (the one it shows); what differs there is the badge and the
control bar, taken together over every still. The colours follow the stills
too: AVKit shows the untagged video brighter than ffmpeg decodes it (BT.601),
so each channel gets the power curve that matches the stills best.

The bar's middle (the time played, the position slider, the time left) is
drawn into every frame from the pictures themselves, so it matches the still
pixel for pixel: the bar's flat ground and the slider's track from the
English still (its filled and its empty part, column by column), the knob
cut out of it, placed where the slider puts it for the frame's moment (a
line fitted through the knob in the bartime pictures), and the two times
from the bartime picture of that second. The badge's line and time left the
same way: the line filled up to where a line through the bartime pictures'
ends of the filled part puts it, the time from the bartime picture. The
bar's and the badge's ground is one flat colour around these parts in every
still and bartime picture (checked), so what is drawn meets the still
around it.
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageChops, ImageFilter, ImageStat

ROOT = Path(__file__).resolve().parent.parent
SHOTS = ROOT / "docs" / "screenshots"
GEOMETRY = ROOT / "site" / "video-motion.json"
VIDEO_NAME = "Sunset Timelapse.mp4"
FPS = 10
SECONDS = 6        # the sample video's length: the bartime pictures cover each second
THEMES = ("light", "dark")
WIDTHS = {960: 90, 480: 90}  # width: WebP quality (lower ones leave blocks in the sky)
DIFFERS = 40       # a pixel differing this much from the frame is the app's, not the video's
PAD = 2            # around each hole
MARGIN = 3         # around the bar's part drawn here


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


def holes(still, frame, w, h):
    """The rectangles where the still differs from the video: the badge at
    the top, the control bar at the bottom (solid areas: what is thinner than
    5 px, the water's glitter caught a frame apart, is left out); and, apart
    from them, rows along the top or the bottom edge that differ across the
    whole width (a line the window draws over the video's edge)."""
    mask = ImageChops.difference(still, frame).convert("L").point(lambda v: 255 if v > DIFFERS else 0)
    edges = []
    for rows in (range(0, 3), range(h - 1, h - 4, -1)):
        lined = [r for r in rows if sum(mask.getpixel((x, r)) > 0 for x in range(w)) > 0.9 * w]
        for r in lined:
            mask.paste(0, (0, r, w, r + 1))
            edges.append([0, r, w, r + 1])
    solid = mask.filter(ImageFilter.MinFilter(5))
    found = []
    for y0, y1 in ((0, h // 3), (h * 2 // 3, h)):
        box = solid.crop((0, y0, w, y1)).getbbox()
        if box:
            grow = 2 + PAD   # what the filter took off each side, and the pad
            found.append([max(box[0] - grow, 0), max(box[1] + y0 - grow, 0),
                          min(box[2] + grow, w), min(box[3] + y0 + grow, h)])
    return found, edges


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

        boxes, lines, worst = [], [], 0.0
        for path in all_stills:
            still = crop(path)
            frame = closest(still, decoded, h)
            worst = max(worst, max(ImageStat.Stat(ImageChops.difference(middle(still, h), middle(frame, h))).mean))
            found, edges = holes(still, frame, w, h)
            boxes += found
            lines += [e for e in edges if e not in lines]
        cut = union(boxes)
        print(f"video at {x},{y} {w}x{h}; gamma {gamma}; holes {cut}, lines {lines}; largest mean difference {worst:.1f}")

        # The parts drawn here: the control bar's slider and times in its hole (the
        # lower one), the badge's line and time left in its hole; each in the same
        # place in every still and bartime picture, on one flat ground there
        parts = []
        for hole, reader, frames_of, what in ((max(cut, key=lambda b: b[1]), Slider, bar_frames, "control bar's slider and times"),
                                             (min(cut, key=lambda b: b[1]), Line, badge_frames, "badge's line and time left")):
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

        # Each frame at its moment (half a frame on, so a time is never a whole second)
        # (every frame for the stills above, which show any of them; FPS of them here)
        step = round(len(decoded) / (SECONDS * FPS))
        decoded = decoded[::step]
        moments = [(i + 0.5) / FPS for i in range(len(decoded))]
        if moments[-1] >= SECONDS:
            sys.exit(f"the video lasts longer than {SECONDS} s")
        files = {}
        for theme in THEMES:
            paths = []
            for second in range(1, SECONDS + 1):
                path = folder / f"bartime-{second}-{theme}.png"
                if not path.exists():
                    sys.exit(f"{path} is missing (screenshots.yml's English pictures)")
                paths.append(path)
            drawers = []
            for hole, of, box, frames_of, what in parts:
                bartimes = {second: of(crop(path)) for second, path in enumerate(paths, 1)}
                draw, off = frames_of(of(crop(SHOTS / f"video-{theme}.webp")), bartimes, box)
                print(f"{theme}: the still's {what} drawn again differ by at most {off} (outside the times)")
                drawers.append((draw, (hole[0] + box[0], hole[1] + box[1])))
            composed = tmp / f"composed-{theme}"
            composed.mkdir()
            for i, (frame, t) in enumerate(zip(decoded, moments)):
                image = frame.copy()
                for draw, place in drawers:
                    image.paste(draw(t), place)
                image.save(composed / f"{i:03d}.png")
            files[theme] = {}
            for width, quality in WIDTHS.items():
                pictures = sorted(composed.glob("*.png"))
                if width != w:
                    smaller = tmp / f"w{width}-{theme}"
                    smaller.mkdir()
                    for p in pictures:
                        Image.open(p).resize((width, round(h * width / w)), Image.LANCZOS).save(smaller / p.name)
                    pictures = sorted(smaller.glob("*.png"))
                name = f"video-motion-{theme}-{width}.webp"
                out = SHOTS / name
                run("img2webp", "-loop", "0", "-lossy", "-q", str(quality), "-m", "6",
                    "-d", str(round(1000 / FPS)), *map(str, pictures), "-o", str(out),
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                files[theme][str(width)] = name
                print(f"{out.relative_to(ROOT)}: {len(pictures)} frames, {out.stat().st_size // 1024} KB")

        for old in SHOTS.glob("video-motion-*.webp"):
            if old.name not in [n for f in files.values() for n in f.values()]:
                old.unlink()
                print("deleted", old.relative_to(ROOT))
        drawn = [[hole[0] + box[0], hole[1] + box[1], hole[0] + box[2], hole[1] + box[3]] for hole, _, box, _, _ in parts]
        GEOMETRY.write_text(json.dumps({
            "shot": list(first.size), "area": [x, y, w, h], "holes": cut + lines, "drawn": drawn,
            "files": files}, indent=1) + "\n")
        print(f"{GEOMETRY.relative_to(ROOT)} written")


if __name__ == "__main__":
    main()
