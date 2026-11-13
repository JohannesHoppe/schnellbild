#!/usr/bin/env python3
"""Makes the website's icons and guides through its link preview images (docs/).

Icons, from Resources/icon_1024.png with macOS's `sips` (no other tools):

    python3 Scripts/make_site_images.py icons

    docs/favicon.ico            16, 32 and 48 px (PNG images in an ICO container)
    docs/favicon-16.png, -32    the PNG favicons
    docs/apple-touch-icon.png   180 px, the icon's middle 80 % so it has no
                                transparent corners (iOS fills them black)
    docs/icon-192.png, -512     for site.webmanifest (Android, Chrome)

Link preview images (Open Graph, 1200 × 630, one per language: docs/og/<lang>.jpg).
A browser draws them from site/og/card.html; the script prints the steps:

    python3 Scripts/make_site_images.py og        # the steps and the URL of every card
    python3 Scripts/make_site_images.py check     # every image there, right size, not too large

The card shows the app icon, the name, the language's tagline (site/i18n) and the
hero screenshot, the language's own light one where it exists.
"""
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


def sips(*args):
    subprocess.run(["sips", *map(str, args)], check=True, stdout=subprocess.DEVNULL)


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


def icons():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        for size in (16, 32, 48, 192, 512):
            sips("-z", size, size, ICON, "--out", tmp / f"{size}.png")
        middle = tmp / "middle.png"
        sips("-c", 820, 820, ICON, "--out", middle)
        sips("-z", 180, 180, middle, "--out", DOCS / "apple-touch-icon.png")
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
                       ("icon-192.png", 192), ("icon-512.png", 512)]:
        path = DOCS / name
        if not path.exists() or png_size(path) != (size, size):
            problems.append(f"docs/{name} is missing or not {size} px")
    if not (DOCS / "favicon.ico").exists():
        problems.append("docs/favicon.ico is missing")
    if problems:
        sys.exit("\n".join(problems))
    print(f"images are complete ({len(LANGUAGES)} link preview images, icons)")


if __name__ == "__main__":
    {"icons": icons, "og": og, "check": check}.get(sys.argv[1] if len(sys.argv) > 1 else "", lambda: sys.exit(__doc__))()
