#!/usr/bin/env python3
"""Makes the website's icons and screenshot variants and guides through its link
preview images (docs/).

Icons, from Resources/icon_1024.png with macOS's `sips` (no other tools):

    python3 Scripts/make_site_images.py icons

    docs/favicon.ico            16, 32 and 48 px (PNG images in an ICO container)
    docs/favicon-16.png, -32    the PNG favicons
    docs/apple-touch-icon.png   180 px, the icon's middle 80 % so it has no
                                transparent corners (iOS fills them black)
    docs/icon-192.png, -512     for site.webmanifest (Android, Chrome)
    docs/icon-64.png, .webp     the bar's icon (32 px at 2x)
    docs/icon.webp              256 px for the home page (docs/icon.png the fallback)
    Resources/icon-256.png      256 px for the README

Screenshots live in the repository only as WebP, never as PNG. The masters,
docs/screenshots/<name>.webp (1072 × 752, 1x with the window shadow on
transparent ground), are lossless WebP made from the PNGs screenshots.yml
uploads (one artifact per language, unpacked into a folder each):

    python3 Scripts/make_site_images.py import <folder> …

    docs/screenshots/<name>.webp   cwebp -lossless -z 9: English all of them (README),
                                   every other language only those the website shows
                                   (HERO_SHOT, GLOBE_SHOT, FEATURE_SHOTS) and the light ones the
                                   App Store shows (STORE_SHOTS)

Their variants, so a phone loads a small file and a large screen the full width:

    python3 Scripts/make_site_images.py shots

    docs/screenshots/sized/<name>-<width>.<hash>.webp   cwebp, quality 90, lossless alpha,
                                                        sharp RGB→YUV

for the widths in SHOT_WIDTHS below the master's own and the master's own width.
<hash> is the start of the master's SHA-256, so a changed master needs new
variants (the build's --check says so) and a browser never keeps an old one.
Variants that exist are kept; those of masters that are gone or changed are
deleted. The page offers the variants through picture, srcset and sizes
(Scripts/build_site.py), the master as the img's src; the lightbox loads the
widest variant. docs/screenshots/video-motion-*.webp (the moving video,
Scripts/make_video_animation.py) are no masters.

Link preview images (Open Graph, 1200 × 630, one per language: docs/og/<lang>.jpg).
A browser draws them from site/og/card.html; the script prints the steps:

    python3 Scripts/make_site_images.py og        # the steps and the URL of every card
    python3 Scripts/make_site_images.py check     # every image there, right size, not too large

The card shows the app icon, the name, the language's tagline (site/i18n) and the
hero screenshot, the language's own light one where it exists.
"""
import hashlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
ICON = ROOT / "Resources" / "icon_1024.png"
LANGUAGES = ["en", "de", "fr", "es", "it", "pt-BR", "nl", "pl", "sv", "da", "nb", "fi",
             "cs", "tr", "ru", "uk", "ja", "ko", "zh-Hans", "zh-Hant"]
HERO_SHOT = "grid"
# The Atlas view's globe: the maps alternatives' picture (site_alternatives.py)
GLOBE_SHOT = "atlas-globe"
# The website's feature pictures, in the order of the features (site/i18n); a feature
# whose picture has no master in docs/screenshots yet is shown as text alone
FEATURE_SHOTS = ["full", "atlas", "video", "archives", "dualpane", "search", "adjust", "inspector", "help", "settings"]
# The App Store's pictures (light), in their order there (by name)
STORE_SHOTS = ["archive-inside", "dualpane", "full", "grid", "inspector", "video"]
OG_SIZE = (1200, 630)
OG_LIMIT = 300_000
PORT = 8917
SHOTS = DOCS / "screenshots"
SIZED = SHOTS / "sized"
SHOT_WIDTHS = (400, 640, 860)


def sips(*args):
    subprocess.run(["sips", *map(str, args)], check=True, stdout=subprocess.DEVNULL)


def webp(source, out, *args):
    """Lossy WebP at quality 90 with lossless alpha (shadows without banding) and sharp RGB→YUV (text)."""
    cwebp = shutil.which("cwebp") or sys.exit("cwebp is missing (brew install webp)")
    subprocess.run([cwebp, "-quiet", "-q", "90", "-alpha_q", "100", "-sharp_yuv", "-m", "6", "-metadata", "none",
                    *map(str, args), source, "-o", out], check=True)


def png_size(path):
    """Width and height of a PNG, JPEG or WebP."""
    data = path.read_bytes()[:30]
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return struct.unpack(">II", data[16:24])
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return webp_size(data)
    return jpeg_size(path)


def webp_size(data):
    """From the first chunk: VP8X (extended), VP8L (lossless) or VP8 (lossy)."""
    chunk = data[12:16]
    if chunk == b"VP8X":
        return (int.from_bytes(data[24:27], "little") + 1, int.from_bytes(data[27:30], "little") + 1)
    if chunk == b"VP8L":
        bits = int.from_bytes(data[21:25], "little")
        return (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
    if chunk == b"VP8 ":
        return int.from_bytes(data[26:28], "little") & 0x3FFF, int.from_bytes(data[28:30], "little") & 0x3FFF
    raise ValueError("not a WebP this script reads")


def jpeg_size(path):
    data = path.read_bytes()
    i = 2
    while i < len(data):
        marker, length = data[i + 1], struct.unpack(">H", data[i + 2:i + 4])[0]
        if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
            height, width = struct.unpack(">HH", data[i + 5:i + 9])
            return width, height
        i += 2 + length
    raise ValueError(f"{path}: no JPEG frame header")


def masters():
    """The screenshot masters: every WebP in docs/screenshots but the moving video's."""
    return sorted(p for p in SHOTS.glob("*.webp") if not p.name.startswith("video-motion-"))


def shot_hash(master):
    return hashlib.sha256(master.read_bytes()).hexdigest()[:10]


def shot_variants(master):
    """[(width, path), …] of a screenshot master, narrowest first; the last is the master's own width."""
    width, _ = png_size(master)
    digest = shot_hash(master)
    widths = [w for w in SHOT_WIDTHS if w < width] + [width]
    return [(w, SIZED / f"{master.stem}-{w}.{digest}.webp") for w in widths]


def shot_problems():
    """What is missing in docs/screenshots/sized, and what lies there without a master."""
    wanted = {path for master in masters() for _, path in shot_variants(master)}
    problems = [f"{path.relative_to(ROOT)} is missing" for path in sorted(wanted) if not path.exists()]
    problems += [f"{path.relative_to(ROOT)} belongs to no master" for path in sorted(SIZED.glob("*")) if path not in wanted]
    problems += [f"{path.relative_to(ROOT)}: screenshots only as WebP" for path in sorted(SHOTS.glob("*.png"))]
    return problems


def shots():
    SIZED.mkdir(exist_ok=True)
    wanted, todo = set(), []
    for master in masters():
        for width, path in shot_variants(master):
            wanted.add(path)
            if not path.exists():
                todo.append((master, path, width))
    with ThreadPoolExecutor() as pool:
        list(pool.map(lambda job: webp(job[0], job[1], "-resize", job[2], 0), todo))
    for path in SIZED.glob("*"):
        if path not in wanted:
            path.unlink()
            print("deleted", path.relative_to(ROOT))
    print(f"{len(todo)} screenshot variants written, {len(wanted)} in docs/screenshots/sized")


def kept(name):
    """Whether a screenshot, <motif>-<light|dark>[-<lang>], goes into docs/screenshots."""
    motif, mode, language = re.fullmatch(r"(.+?)-(light|dark)(?:-(.+))?", name).groups()
    return not language or motif in [HERO_SHOT, GLOBE_SHOT, *FEATURE_SHOTS] or (motif in STORE_SHOTS and mode == "light")


def import_shots(folders):
    """Lossless WebP masters from the PNGs of screenshots.yml's artifacts."""
    cwebp = shutil.which("cwebp") or sys.exit("cwebp is missing (Homebrew's webp)")
    pngs = [p for folder in folders for p in sorted(Path(folder).glob("*.png")) if kept(p.stem)]
    if not pngs:
        sys.exit("no screenshots in " + ", ".join(folders))

    def convert(png):
        subprocess.run([cwebp, "-quiet", "-lossless", "-z", "9", "-metadata", "none", png, "-o", SHOTS / f"{png.stem}.webp"],
                       check=True)
    with ThreadPoolExecutor() as pool:
        list(pool.map(convert, pngs))
    print(f"{len(pngs)} masters written to docs/screenshots; next: shots, then build_site.py")


def icons():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        for size in (16, 32, 48, 192, 512):
            sips("-z", size, size, ICON, "--out", tmp / f"{size}.png")
        middle = tmp / "middle.png"
        sips("-c", 820, 820, ICON, "--out", middle)
        sips("-z", 180, 180, middle, "--out", DOCS / "apple-touch-icon.png")
        sips("-z", 64, 64, ICON, "--out", DOCS / "icon-64.png")
        webp(DOCS / "icon-64.png", DOCS / "icon-64.webp")
        sips("-z", 256, 256, ICON, "--out", tmp / "256.png")
        webp(tmp / "256.png", DOCS / "icon.webp")
        (ROOT / "Resources" / "icon-256.png").write_bytes((tmp / "256.png").read_bytes())
        for size in (16, 32):
            (DOCS / f"favicon-{size}.png").write_bytes((tmp / f"{size}.png").read_bytes())
        for size in (192, 512):
            (DOCS / f"icon-{size}.png").write_bytes((tmp / f"{size}.png").read_bytes())
        # ICO: a header, one directory entry per image, then the PNGs as they are.
        images = [(size, (tmp / f"{size}.png").read_bytes()) for size in (16, 32, 48)]
        header = struct.pack("<HHH", 0, 1, len(images))
        offset = len(header) + 16 * len(images)
        entries, blobs = b"", b""
        for size, png in images:
            entries += struct.pack("<BBBBHHII", size, size, 0, 0, 1, 32, len(png), offset + len(blobs))
            blobs += png
        (DOCS / "favicon.ico").write_bytes(header + entries + blobs)
    print("icons written to docs/ and Resources/icon-256.png")


def card_shot(code, motif=None):
    """The screenshot on a language's card: the home page's hero (the grid, or `motif`),
    the language's own where there is one, light."""
    for name in [motif or HERO_SHOT]:
        own = DOCS / "screenshots" / (f"{name}-light.webp" if code == "en" else f"{name}-light-{code}.webp")
        if own.exists():
            return own.name
    return f"{HERO_SHOT}-light.webp"


CHROME = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
# Headless Chrome lays a page out shorter than its window (--window-size=1200,630 gave
# innerHeight 543), so the window is taller and the card is cut from its top left. sips
# centres a crop whose offset is 0, 0, so the card is drawn one pixel to the right (inset=1)
# and cut from x = 1.
CHROME_WINDOW = (OG_SIZE[0] + 1, 1000)


def og_render(codes, motif=None):
    """Each card drawn by Chrome itself (headless, its own screenshot at 1200 × 630) from
    site/og/card.html, served from the repository on this Mac only, then saved as JPEG
    with sips at the highest quality from 80 that stays under OG_LIMIT."""
    import functools, http.server, threading
    if not CHROME.exists():
        sys.exit(f"Google Chrome is missing ({CHROME}); draw the cards by hand: python3 Scripts/make_site_images.py og")
    if not ICON.exists():
        sys.exit("Resources/icon_1024.png is missing: swift Scripts/make_icon.swift Resources/icon_1024.png")
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass
    handler = functools.partial(Quiet, directory=str(ROOT))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_address[1]
    try:
        with tempfile.TemporaryDirectory() as tmp:
            for code in codes:
                png = Path(tmp) / f"{code}.png"
                url = f"http://127.0.0.1:{port}/site/og/card.html?lang={code}&shot={card_shot(code, motif)}&inset=1"
                subprocess.run([str(CHROME), "--headless=new", "--disable-gpu", "--hide-scrollbars",
                                f"--user-data-dir={tmp}/profile", "--force-device-scale-factor=1",
                                "--virtual-time-budget=10000", f"--window-size={CHROME_WINDOW[0]},{CHROME_WINDOW[1]}",
                                f"--screenshot={png}", url], check=True, capture_output=True)
                sips("-c", OG_SIZE[1], OG_SIZE[0], "--cropOffset", 0, 1, png)
                if png_size(png) != OG_SIZE:
                    sys.exit(f"{code}: Chrome drew {png_size(png)}, not {OG_SIZE}")
                out = DOCS / "og" / f"{code}.jpg"
                for quality in (80, 75, 70):
                    sips("-s", "format", "jpeg", "-s", "formatOptions", quality, png, "--out", out)
                    if out.stat().st_size <= OG_LIMIT:
                        break
                print(f"docs/og/{code}.jpg  {card_shot(code, motif)}  {out.stat().st_size // 1000} kB")
    finally:
        server.shutdown()


def og():
    print(f"""Drawn by Chrome: python3 Scripts/make_site_images.py og render [<lang> …]
By hand:
1. Serve the repository on this Mac only:
     python3 -m http.server {PORT} --bind 127.0.0.1 --directory {ROOT}
2. In the Playwright browser set the viewport to {OG_SIZE[0]} × {OG_SIZE[1]}, open each URL below
   and take a JPEG screenshot of the viewport (not the full page); the page sets
   document.title to "ready" once its pictures and fonts are there.
3. Copy each screenshot to its file below (JPEG keeps them under {OG_LIMIT // 1000} kB).
4. python3 Scripts/make_site_images.py check
""")
    for code in LANGUAGES:
        print(f"  http://127.0.0.1:{PORT}/site/og/card.html?lang={code}&shot={card_shot(code)}  ->  docs/og/{code}.jpg")


def check():
    problems = []
    for code in LANGUAGES:
        path = DOCS / "og" / f"{code}.jpg"
        if not path.exists():
            problems.append(f"{path.relative_to(ROOT)} is missing")
            continue
        if jpeg_size(path) != OG_SIZE:
            problems.append(f"{path.relative_to(ROOT)} is {jpeg_size(path)}, not {OG_SIZE}")
        if path.stat().st_size > OG_LIMIT:
            problems.append(f"{path.relative_to(ROOT)} has {path.stat().st_size} bytes, more than {OG_LIMIT}")
    for name, size in [("apple-touch-icon.png", 180), ("favicon-16.png", 16), ("favicon-32.png", 32),
                       ("icon-64.png", 64), ("icon-192.png", 192), ("icon-512.png", 512)]:
        path = DOCS / name
        if not path.exists() or png_size(path) != (size, size):
            problems.append(f"docs/{name} is missing or not {size} px")
    for name in ("favicon.ico", "icon.webp", "icon-64.webp"):
        if not (DOCS / name).exists():
            problems.append(f"docs/{name} is missing")
    problems += shot_problems()
    if problems:
        sys.exit("\n".join(problems))
    print(f"images are complete ({len(LANGUAGES)} link preview images, icons, screenshot variants)")


if __name__ == "__main__":
    if sys.argv[1:2] == ["import"] and len(sys.argv) > 2:
        import_shots(sys.argv[2:])
    elif sys.argv[1:3] == ["og", "render"]:
        og_render(sys.argv[3:] or LANGUAGES)
    else:
        {"icons": icons, "shots": shots, "og": og, "check": check}.get(sys.argv[1] if len(sys.argv) > 1 else "", lambda: sys.exit(__doc__))()
