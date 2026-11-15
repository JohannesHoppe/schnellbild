#!/usr/bin/env python3
"""Makes the globe's data files from their public sources (Scripts/globe_data.env).

  python3 -I Scripts/build_globe_data.py [--check]

Python's standard library only, plus `swift Scripts/convert_globe_images.swift`
(ImageIO) for the two pictures. Downloads go to build/globe-cache/, the files to
build/globe/:

- HEIGHTMAP_FILE: NOAA ETOPO 2022 (30 arc-seconds, surface elevation, CC0 1.0),
  every fifth sample read through NOAA's OPeNDAP server in eight bands, each
  3 × 3 block of them averaged into a cell of 1/8 degree (2880 × 1440 cells,
  each block centred on its cell), rounded to whole metres. Format "SBHM",
  described in OfflineMap/GlobeData.swift (`Heightmap`).
- SKYMAP_FILE: NASA SVS's "Deep Star Maps 2020" star map (4096 × 2048, public
  domain), tone-mapped to an 8-bit sRGB JPEG (right ascension 0h in the middle,
  increasing to the left, as SVS has it).
- CITYLIGHTS_FILE: NASA Earth Observatory's Black Marble 2016 (grey), resized to
  LIGHTS_WIDTH × LIGHTS_WIDTH/2.
- NOTICE_FILE: the sources and their terms.

The pictures are checked against SKY_SHA256 / LIGHTS_SHA256 once those are set
(the first run prints them). The heightmap is the same bytes for the same data;
the JPEGs are ImageIO's and may differ between macOS versions, so `--check`
compares the heightmap only and prints the others.
"""

import array
import hashlib
import os
import struct
import subprocess
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, "build", "globe-cache")
OUT = os.path.join(ROOT, "build", "globe")

ROWS, COLUMNS = 21600, 43200      # ETOPO 2022 at 30 arc-seconds, south to north, west to east
STRIDE, BLOCK = 5, 3              # every fifth sample, 3 × 3 of them per cell (15 × 15 source cells)
BANDS = 8


def env():
    values = {}
    for line in open(os.path.join(ROOT, "Scripts", "globe_data.env")):
        line = line.strip()
        if line and not line.startswith("#"):
            key, _, value = line.partition("=")
            values[key] = value
    return values


def download(url, path):
    if not os.path.exists(path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        print(f"==> {url}")
        with urllib.request.urlopen(url, timeout=600) as response, open(path + ".part", "wb") as f:
            while True:
                chunk = response.read(1 << 20)
                if not chunk:
                    break
                f.write(chunk)
        os.replace(path + ".part", path)
    return path


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def pinned(path, want, name):
    got = sha256(path)
    if want and got != want:
        sys.exit(f"!! {name}: SHA-256 {got}, globe_data.env pins {want}")
    if not want:
        print(f"   {name} SHA-256 (pin it in globe_data.env): {got}")


def dap_floats(data, start):
    """An OPeNDAP array in XDR: its length twice, then big-endian floats."""
    n, _ = struct.unpack(">ii", data[start:start + 8])
    values = array.array("f", data[start + 8:start + 8 + 4 * n])
    if sys.byteorder == "little":
        values.byteswap()
    return values, start + 8 + 4 * n


def heightmap(cfg):
    sampled_rows, sampled_columns = ROWS // STRIDE, COLUMNS // STRIDE      # 4320 × 8640
    width, height = sampled_columns // BLOCK, sampled_rows // BLOCK         # 2880 × 1440
    per_band = sampled_rows // BANDS
    sums = [array.array("d", bytes(8 * width)) for _ in range(height)]
    for band in range(BANDS):
        first = 2 + STRIDE * per_band * band
        last = first + STRIDE * (per_band - 1)
        url = f"{cfg['ETOPO_DAP_URL']}.dods?z[{first}:{STRIDE}:{last}][2:{STRIDE}:{COLUMNS - 1}]"
        path = download(url, os.path.join(CACHE, f"etopo-band-{band}.dods"))
        data = open(path, "rb").read()
        z, _ = dap_floats(data, data.index(b"\nData:\n") + 7)
        if len(z) != per_band * sampled_columns:
            sys.exit(f"!! band {band}: {len(z)} values, expected {per_band * sampled_columns}")
        for r in range(per_band):
            row = (band * per_band + r) // BLOCK                       # from the south
            target = sums[row]
            base = r * sampled_columns
            for c in range(sampled_columns):
                target[c // BLOCK] += z[base + c]
    out = bytearray(b"SBHM" + struct.pack("<HHII", 1, 0, width, height))
    for row in reversed(range(height)):                                # the file runs from the north
        values = array.array("h", (max(-32768, min(32767, round(s / (BLOCK * BLOCK)))) for s in sums[row]))
        if sys.byteorder == "big":
            values.byteswap()
        out += values.tobytes()
    return bytes(out)


NOTICE = """Schnellbild's globe data ({tag})

{heightmap}: elevation and ocean depth in cells of 1/8 degree, made from
NOAA National Centers for Environmental Information. 2022: ETOPO 2022 15 Arc-Second
Global Relief Model (here its 30 arc-second surface elevation grid).
https://doi.org/10.25921/fd45-gt74
NOAA waives any potential copyright and related rights in these data worldwide
through the Creative Commons Zero 1.0 Universal Public Domain Dedication (CC0-1.0).
Not to be used for navigation.

{sky}: the night sky, made from "Deep Star Maps 2020", NASA/Goddard Space Flight
Center Scientific Visualization Studio (https://svs.gsfc.nasa.gov/4851), with
source data courtesy of Gaia DR2 (ESA/Gaia/DPAC), Hipparcos and Tycho-2. SVS
content is in the public domain. No endorsement by NASA is implied.

{lights}: the lights of the night side, made from "Black Marble 2016" (grey),
NASA Earth Observatory
(https://science.nasa.gov/earth/earth-observatory/earth-at-night/maps/).
Used under NASA's media usage guidelines; no endorsement by NASA is implied.

Made by Scripts/build_globe_data.py of https://github.com/JohannesHoppe/schnellbild.
"""


def main():
    check = "--check" in sys.argv
    cfg = env()
    os.makedirs(OUT, exist_ok=True)

    path = os.path.join(OUT, cfg["HEIGHTMAP_FILE"])
    data = heightmap(cfg)
    if check:
        got = hashlib.sha256(data).hexdigest()
        if got != cfg["HEIGHTMAP_SHA256"]:
            sys.exit(f"!! heightmap SHA-256 {got}, pinned {cfg['HEIGHTMAP_SHA256']}")
        print("heightmap matches the pinned SHA-256")
    open(path, "wb").write(data)

    sky = download(cfg["SKY_URL"], os.path.join(CACHE, os.path.basename(cfg["SKY_URL"])))
    if os.path.getsize(sky) != int(cfg["SKY_SIZE"]):
        sys.exit(f"!! {sky}: size {os.path.getsize(sky)}, expected {cfg['SKY_SIZE']}")
    pinned(sky, cfg["SKY_SHA256"], "star map")
    lights = download(cfg["LIGHTS_URL"], os.path.join(CACHE, os.path.basename(cfg["LIGHTS_URL"])))
    pinned(lights, cfg["LIGHTS_SHA256"], "Black Marble")

    convert = os.path.join(ROOT, "Scripts", "convert_globe_images.swift")
    subprocess.run(["swift", convert, "sky", sky, os.path.join(OUT, cfg["SKYMAP_FILE"])], check=True)
    subprocess.run(["swift", convert, "lights", lights, os.path.join(OUT, cfg["CITYLIGHTS_FILE"]), cfg["LIGHTS_WIDTH"]], check=True)

    with open(os.path.join(OUT, cfg["NOTICE_FILE"]), "w") as f:
        f.write(NOTICE.format(tag=cfg["RELEASE_TAG"], heightmap=cfg["HEIGHTMAP_FILE"], sky=cfg["SKYMAP_FILE"], lights=cfg["CITYLIGHTS_FILE"]))
    for key in ("HEIGHTMAP_FILE", "SKYMAP_FILE", "CITYLIGHTS_FILE"):
        p = os.path.join(OUT, cfg[key])
        print(f"{key[:-5]}_SHA256={sha256(p)}  ({os.path.getsize(p)} bytes)")


if __name__ == "__main__":
    main()
