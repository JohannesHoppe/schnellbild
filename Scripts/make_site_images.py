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

Screenshot variants, from every PNG in docs/screenshots (1072 × 752, 1x with the
window shadow on transparent ground), so a phone loads a small file and a large
screen the full width:

    python3 Scripts/make_site_images.py shots

    docs/screenshots/sized/<name>-<width>.<hash>.avif   sips, quality 80
    docs/screenshots/sized/<name>-<width>.<hash>.webp   cwebp (Homebrew's webp), quality 90,
                                                        lossless alpha, sharp RGB→YUV

for the widths in SHOT_WIDTHS below the PNG's own and the PNG's own width. <hash>
is the start of the PNG's SHA-256, so a changed PNG needs new variants (the
build's --check says so) and a browser never keeps an old one. Variants that
exist are kept; those of PNGs that are gone or changed are deleted. The page
offers AVIF, then WebP, then the PNG (picture, srcset and sizes in
Scripts/build_site.py); the lightbox loads the largest.

Link preview images (Open Graph, 1200 × 630, one per language: docs/og/<lang>.jpg).
A browser draws them from site/og/card.html; the script prints the steps:

    python3 Scripts/make_site_images.py og        # the steps and the URL of every card
    python3 Scripts/make_site_images.py check     # every image there, right size, not too large

The card shows the app icon, the name, the language's tagline (site/i18n) and the
hero screenshot, the language's own light one where it exists.
"""
import hashlib
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
ICON = ROOT / "Resources" / "icon_1024.png"
LANGUAGES = ["en", "de", "fr", "es", "it", "pt-BR", "nl", "pl", "sv", "da", "nb", "fi",
             "cs", "tr", "ru", "uk", "ja", "ko", "zh-Hans", "zh-Hant"]
HERO_SHOT = "grid"
OG_SIZE = (1200, 630)
OG_LIMIT = 300_000
PORT = 8917
SHOTS = DOCS / "screenshots"
SIZED = SHOTS / "sized"
SHOT_WIDTHS = (400, 640, 860)
SHOT_FORMATS = ("avif", "webp")


def sips(*args):
    subprocess.run(["sips", *map(str, args)], check=True, stdout=subprocess.DEVNULL)


def webp(source, out, *args):
    """Lossy WebP at quality 90 with lossless alpha (shadows without banding) and sharp RGB→YUV (text)."""
    cwebp = shutil.which("cwebp") or sys.exit("cwebp is missing (brew install webp)")
    subprocess.run([cwebp, "-quiet", "-q", "90", "-alpha_q", "100", "-sharp_yuv", "-m", "6", "-metadata", "none",
                    *map(str, args), source, "-o", out], check=True)


def png_size(path):
    data = path.read_bytes()[:24]
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return struct.unpack(">II", data[16:24])
    return jpeg_size(path)


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


def shot_hash(png):
    return hashlib.sha256(png.read_bytes()).hexdigest()[:10]


def shot_variants(png):
    """{format: [(width, path), …]} of a screenshot PNG, narrowest first; the last is the PNG's own width."""
    width, _ = png_size(png)
    digest = shot_hash(png)
    widths = [w for w in SHOT_WIDTHS if w < width] + [width]
    return {fmt: [(w, SIZED / f"{png.stem}-{w}.{digest}.{fmt}") for w in widths] for fmt in SHOT_FORMATS}


def shot_problems():
    """What is missing in docs/screenshots/sized, and what lies there without a PNG."""
    wanted = {path for png in SHOTS.glob("*.png") for variants in shot_variants(png).values() for _, path in variants}
    problems = [f"{path.relative_to(ROOT)} is missing" for path in sorted(wanted) if not path.exists()]
    problems += [f"{path.relative_to(ROOT)} belongs to no PNG" for path in sorted(SIZED.glob("*")) if path not in wanted]
    return problems


def shots():
    SIZED.mkdir(exist_ok=True)
    wanted, made = set(), 0
    for png in sorted(SHOTS.glob("*.png")):
        for fmt, variants in shot_variants(png).items():
            for width, path in variants:
                wanted.add(path)
                if path.exists():
                    continue
                if fmt == "webp":
                    webp(png, path, "-resize", width, 0)
                else:
                    sips("--resampleWidth", width, "-s", "format", "avif", "-s", "formatOptions", 80, png, "--out", path)
                made += 1
    for path in SIZED.glob("*"):
        if path not in wanted:
            path.unlink()
            print("deleted", path.relative_to(ROOT))
    print(f"{made} screenshot variants written, {len(wanted)} in docs/screenshots/sized")


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
    print("icons written to docs/")


def card_shot(code):
    own = DOCS / "screenshots" / f"{HERO_SHOT}-light-{code}.png"
    return own.name if code != "en" and own.exists() else f"{HERO_SHOT}-light.png"


def og():
    print(f"""1. Serve the repository on this Mac only:
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
    {"icons": icons, "shots": shots, "og": og, "check": check}.get(sys.argv[1] if len(sys.argv) > 1 else "", lambda: sys.exit(__doc__))()
