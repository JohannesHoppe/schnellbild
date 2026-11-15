#!/usr/bin/env python3
"""Makes the globe's data files from their public sources (Scripts/globe_data.env).

  python3 -I Scripts/build_globe_data.py [--check]
  python3 -I Scripts/build_globe_data.py --upstream --extract DIR

Python's standard library only, the pictures too (OpenEXR with ZIP compression
and TIFF with LZW read here, a baseline JPEG and a PNG written here): the same
inputs give the same bytes.
Downloads go to build/globe-cache/, the files to build/globe/.

The inputs come from the archive: the pre-release SOURCE_RELEASE_TAG of this
repository holds the eight ETOPO bands as NOAA's OPeNDAP server answers them
(etopo-band-<n>.dods, pinned by ETOPO_BANDS_SHA256), the star map and the Black
Marble picture under their own names. Each is checked against its SHA-256; only
when the archive can't be reached does the script ask NOAA, SVS and NASA.
`--upstream` reads the sources themselves, `--extract DIR` only gathers the
inputs into DIR (the archive's files) and prints their SHA-256.


- HEIGHTMAP_FILE: NOAA ETOPO 2022 (30 arc-seconds, surface elevation, CC0 1.0),
  every fifth sample read through NOAA's OPeNDAP server in eight bands, each
  3 × 3 block of them averaged into a cell of 1/8 degree (2880 × 1440 cells,
  each block centred on its cell), rounded to whole metres. Format "SBHM",
  described in OfflineMap/GlobeData.swift (`Heightmap`).
- SKYMAP_FILE: NASA SVS's "Deep Star Maps 2020" star map (4096 × 2048, public
  domain), tone-mapped to 8-bit sRGB, a JPEG of quality SKY_QUALITY, 4:4:4
  (right ascension 0h in the middle,
  increasing to the left, as SVS has it).
- CITYLIGHTS_FILE: NASA Earth Observatory's Black Marble 2016 (grey GeoTIFF,
  13500 × 6750), reduced to LIGHTS_WIDTH × LIGHTS_WIDTH/2, a grey PNG.
- NOTICE_FILE: the sources and their terms.

The inputs are checked against their pins once those are set (the first run
prints them). `--check` makes every file and fails unless each matches its
pinned SHA-256 (HEIGHTMAP_SHA256, SKYMAP_SHA256, CITYLIGHTS_SHA256).
"""

import array
import hashlib
import itertools
import math
import operator
import os
import struct
import sys
import zlib
import urllib.error
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


UPSTREAM = "--upstream" in sys.argv


def obtain(cfg, name, want, url):
    """build/globe-cache/<name>: kept while its SHA-256 is <want>, else from the archive
    (SOURCE_RELEASE_TAG), else from <url>. Without a pin (<want> empty) only from <url>."""
    path = os.path.join(CACHE, name)
    if os.path.exists(path) and want and sha256(path) != want:
        os.remove(path)
    if not os.path.exists(path) and want and not UPSTREAM:
        archived = f"https://github.com/JohannesHoppe/schnellbild/releases/download/{cfg['SOURCE_RELEASE_TAG']}/{name}"
        try:
            download(archived, path)
        except (urllib.error.URLError, OSError) as e:
            print(f"   archive: {e}")
    return download(url, path)


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


def band_pins(cfg):
    pins = [p for p in cfg.get("ETOPO_BANDS_SHA256", "").split(",") if p]
    return pins if len(pins) == BANDS else [""] * BANDS


def dap_floats(data, start):
    """An OPeNDAP array in XDR: its length twice, then big-endian floats."""
    n, _ = struct.unpack(">ii", data[start:start + 8])
    values = array.array("f", data[start + 8:start + 8 + 4 * n])
    if sys.byteorder == "little":
        values.byteswap()
    return values, start + 8 + 4 * n


SAMPLED_ROWS, SAMPLED_COLUMNS = ROWS // STRIDE, COLUMNS // STRIDE      # 4320 × 8640
PER_BAND = SAMPLED_ROWS // BANDS


def etopo_band(cfg, band):
    """The band's every fifth row and column of ETOPO, as NOAA's OPeNDAP server answers."""
    first = 2 + STRIDE * PER_BAND * band
    last = first + STRIDE * (PER_BAND - 1)
    url = f"{cfg['ETOPO_DAP_URL']}.dods?z[{first}:{STRIDE}:{last}][2:{STRIDE}:{COLUMNS - 1}]"
    name = f"etopo-band-{band}.dods"
    want = band_pins(cfg)[band]
    path = obtain(cfg, name, want, url)
    pinned(path, want, f"{name} (ETOPO_BANDS_SHA256, {band + 1} of {BANDS})")
    return path


def heightmap(bands):
    sampled_rows, sampled_columns = SAMPLED_ROWS, SAMPLED_COLUMNS
    width, height = sampled_columns // BLOCK, sampled_rows // BLOCK         # 2880 × 1440
    per_band = PER_BAND
    sums = [array.array("d", bytes(8 * width)) for _ in range(height)]
    for band, path in enumerate(bands):
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


# ---------------------------------------------------------------------------
# A baseline JPEG encoder (ITU-T T.81 / JFIF 1.02), written here so the same
# pixels always give the same bytes: no library, every step fixed.
# - Colour: JFIF's YCbCr (BT.601 full range), chroma 4:2:0 (each Cb / Cr
#   sample the mean of 2 × 2 pixels); grey: one component.
# - Each 8 × 8 block: level shift by 128, the DCT-II as T.81 A.3.3 defines it
#   (double precision, separable, a fixed cosine table and summation order),
#   divided by the quantisation table and rounded half away from zero.
# - Quantisation: T.81 Annex K's luminance and chrominance tables scaled by
#   the IJG quality formula (q < 50: 5000 / q %, else 200 − 2q %, each entry
#   rounded and held within 1 ... 255).
# - Huffman: optimal tables for the picture (T.81 K.2, lengths held to 16
#   bits as K.2's figure K.3 does), one DC and one AC table for luma and one
#   pair for chroma; restart markers none.


ZIGZAG = [
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
]
# T.81 Annex K, tables K.1 and K.2 (in row order)
LUMA_QUANT = [
    16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55,
    14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
    18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
    49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
]
CHROMA_QUANT = [
    17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99,
    24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99,
] + [99] * 32
# cos((2x + 1) u π / 16), with C(0) = 1/√2, halved: the 1-D DCT's matrix
DCT = [[(math.sqrt(0.5) if u == 0 else 1.0) * 0.5 * math.cos((2 * x + 1) * u * math.pi / 16) for x in range(8)] for u in range(8)]


def jpeg_quant(table, quality):
    scale = 5000 // quality if quality < 50 else 200 - 2 * quality
    return [max(1, min(255, (v * scale + 50) // 100)) for v in table]


def jpeg_block(pixels, quant):
    """One 8 × 8 block (64 samples 0 ... 255, row order) to its 64 quantised
    coefficients in zig-zag order."""
    rows = []
    for y in range(8):
        r = [pixels[8 * y + x] - 128 for x in range(8)]
        rows.append([sum(c[x] * r[x] for x in range(8)) for c in DCT])
    coefficients = [0] * 64
    for u in range(8):
        column = [rows[y][u] for y in range(8)]
        for v in range(8):
            c = DCT[v]
            value = sum(c[y] * column[y] for y in range(8)) / quant[8 * v + u]
            coefficients[8 * v + u] = int(value + 0.5) if value >= 0 else -int(-value + 0.5)
    return [coefficients[k] for k in ZIGZAG]


def jpeg_category(value):
    return 0 if value == 0 else abs(value).bit_length()


def jpeg_symbols(blocks):
    """The Huffman symbols of a component's blocks: (dc symbol, dc bits, [(ac symbol, bits)…]) per block."""
    out, previous = [], 0
    for block in blocks:
        diff = block[0] - previous
        previous = block[0]
        ac, run = [], 0
        last = 63
        while last > 0 and block[last] == 0:
            last -= 1
        for k in range(1, last + 1):
            v = block[k]
            if v == 0:
                run += 1
                continue
            while run > 15:
                ac.append((0xF0, 0, 0))
                run -= 16
            size = jpeg_category(v)
            ac.append(((run << 4) | size, size, v))
            run = 0
        if last < 63:
            ac.append((0x00, 0, 0))
        size = jpeg_category(diff)
        out.append(((size, size, diff), ac))
    return out


def jpeg_huffman(frequencies):
    """T.81 K.2: code lengths for the symbols' frequencies (a reserved code
    point so no code is all ones), held to 16 bits; returns (bits[1..16],
    symbols in order) and a code table symbol → (code, length)."""
    freq = [0] * 257
    for s, f in frequencies.items():
        freq[s] = f
    freq[256] = 1
    codesize = [0] * 257
    others = [-1] * 257
    while True:
        v1 = v2 = -1
        for i in range(257):     # the least frequent, the larger symbol on ties (K.2's figure K.1)
            if freq[i] and (v1 < 0 or freq[i] <= freq[v1]):
                v1 = i
        for i in range(257):
            if freq[i] and i != v1 and (v2 < 0 or freq[i] <= freq[v2]):
                v2 = i
        if v2 < 0:
            break
        freq[v1] += freq[v2]
        freq[v2] = 0
        codesize[v1] += 1
        while others[v1] >= 0:
            v1 = others[v1]
            codesize[v1] += 1
        others[v1] = v2
        codesize[v2] += 1
        while others[v2] >= 0:
            v2 = others[v2]
            codesize[v2] += 1
    bits = [0] * 33
    for i in range(257):
        if codesize[i]:
            bits[codesize[i]] += 1
    i = 32                       # K.2's figure K.3: no code longer than 16 bits
    while i > 16:
        while bits[i] > 0:
            j = i - 2
            while bits[j] == 0:
                j -= 1
            bits[i] -= 2
            bits[i - 1] += 1
            bits[j + 1] += 2
            bits[j] -= 1
        i -= 1
    while bits[i] == 0:
        i -= 1
    bits[i] -= 1                 # the reserved code point
    order = sorted((s for s in range(256) if codesize[s]), key=lambda s: (codesize[s], s))
    lengths = [n for n in range(1, 17) for _ in range(bits[n])]
    codes, code, k = {}, 0, 0
    for n in range(1, 17):
        for _ in range(bits[n]):
            codes[order[k]] = (code, n)
            code += 1
            k += 1
        code <<= 1
    assert len(lengths) == len(order)
    return bits[1:17], order, codes


class JpegBits:
    def __init__(self):
        self.out = bytearray()
        self.acc = 0
        self.n = 0

    def put(self, value, length):
        self.acc = (self.acc << length) | (value & ((1 << length) - 1))
        self.n += length
        while self.n >= 8:
            self.n -= 8
            byte = (self.acc >> self.n) & 0xFF
            self.out.append(byte)
            if byte == 0xFF:
                self.out.append(0)
        self.acc &= (1 << self.n) - 1

    def flush(self):
        if self.n:
            self.put((1 << (8 - self.n)) - 1, 8 - self.n)   # pad with ones


def jpeg(width, height, planes, quality, subsampled=False):
    """A baseline JPEG of `planes`: [Y] (grey) or [Y, Cb, Cr], Cb and Cr at
    full size (4:4:4) or, `subsampled`, at half the size in each direction
    (4:2:0); each plane a list of rows of samples."""
    colour = len(planes) == 3
    quants = [jpeg_quant(LUMA_QUANT, quality)] + ([jpeg_quant(CHROMA_QUANT, quality)] if colour else [])

    def blocks_of(plane, w, h, qi):
        out = []
        for by in range(0, h, 8):
            for bx in range(0, w, 8):
                pixels = []
                for y in range(by, by + 8):
                    row = plane[min(y, h - 1)]
                    pixels += [row[min(x, w - 1)] for x in range(bx, bx + 8)]
                out.append(jpeg_block(pixels, quants[qi]))
        return out

    if colour and subsampled:
        mw, mh = (width + 15) // 16, (height + 15) // 16
        lw, lh = mw * 16, mh * 16
    else:
        mw, mh = (width + 7) // 8, (height + 7) // 8
        lw, lh = mw * 8, mh * 8
    # Blocks in the order they go into the scan (interleaved MCUs for colour)
    y_blocks = blocks_of(planes[0], width, height, 0)
    if colour and not subsampled:
        components = [jpeg_symbols(y_blocks), jpeg_symbols(blocks_of(planes[1], width, height, 1)),
                      jpeg_symbols(blocks_of(planes[2], width, height, 1))]
    elif colour:
        cw, ch = (width + 1) // 2, (height + 1) // 2
        cb_blocks = blocks_of(planes[1], cw, ch, 1)
        cr_blocks = blocks_of(planes[2], cw, ch, 1)
        ybw = (width + 7) // 8
        ybh = (height + 7) // 8
        cbw = (cw + 7) // 8
        luma_order, chroma_index = [], []
        for my in range(mh):
            for mx in range(mw):
                for dy in range(2):
                    for dx in range(2):
                        by, bx = min(2 * my + dy, ybh - 1), min(2 * mx + dx, ybw - 1)
                        luma_order.append(y_blocks[by * ybw + bx])
                chroma_index.append(min(my, (ch + 7) // 8 - 1) * cbw + min(mx, cbw - 1))
        cb_order = [cb_blocks[i] for i in chroma_index]
        cr_order = [cr_blocks[i] for i in chroma_index]
        components = [jpeg_symbols(luma_order), jpeg_symbols(cb_order), jpeg_symbols(cr_order)]
    else:
        components = [jpeg_symbols(y_blocks)]

    # Optimal tables: luma's own, chroma's shared by Cb and Cr
    def tables(lists):
        dc, ac = {}, {}
        for symbols in lists:
            for (d, _, _), acs in symbols:
                dc[d] = dc.get(d, 0) + 1
                for s, _, _ in acs:
                    ac[s] = ac.get(s, 0) + 1
        return jpeg_huffman(dc), jpeg_huffman(ac)
    huff = [tables(components[:1])] + ([tables(components[1:])] if colour else [])

    bits = JpegBits()
    table_of = [0, 1, 1] if colour else [0]
    if colour:
        for m in range(mw * mh):
            for c, count in ((0, 4 if subsampled else 1), (1, 1), (2, 1)):
                (dcb, dco, dcc), (acb, aco, acc) = huff[table_of[c]]
                for (d, size, diff), acs in components[c][m * count:(m + 1) * count]:
                    code, length = dcc[d]
                    bits.put(code, length)
                    if size:
                        bits.put(diff if diff > 0 else diff - 1, size)
                    for s, size, v in acs:
                        code, length = acc[s]
                        bits.put(code, length)
                        if size:
                            bits.put(v if v > 0 else v - 1, size)
    else:
        (dcb, dco, dcc), (acb, aco, acc) = huff[0]
        for (d, size, diff), acs in components[0]:
            code, length = dcc[d]
            bits.put(code, length)
            if size:
                bits.put(diff if diff > 0 else diff - 1, size)
            for s, size, v in acs:
                code, length = acc[s]
                bits.put(code, length)
                if size:
                    bits.put(v if v > 0 else v - 1, size)
    bits.flush()

    def segment(marker, payload):
        return struct.pack(">BBH", 0xFF, marker, len(payload) + 2) + payload
    out = bytearray(b"\xFF\xD8")
    out += segment(0xE0, b"JFIF\0" + struct.pack(">BBBHHBB", 1, 2, 0, 1, 1, 0, 0))
    for i, q in enumerate(quants):
        out += segment(0xDB, bytes([i]) + bytes(q[k] for k in ZIGZAG))
    if colour:
        sof = struct.pack(">BHHB", 8, height, width, 3) + bytes([1, 0x22 if subsampled else 0x11, 0, 2, 0x11, 1, 3, 0x11, 1])
    else:
        sof = struct.pack(">BHHB", 8, height, width, 1) + bytes([1, 0x11, 0])
    out += segment(0xC0, sof)
    for t, ((dcb, dco, _), (acb, aco, _)) in enumerate(huff):
        out += segment(0xC4, bytes([0x00 | t]) + bytes(dcb) + bytes(dco))
        out += segment(0xC4, bytes([0x10 | t]) + bytes(acb) + bytes(aco))
    if colour:
        sos = bytes([3, 1, 0x00, 2, 0x11, 3, 0x11, 0, 63, 0])
    else:
        sos = bytes([1, 1, 0x00, 0, 63, 0])
    out += segment(0xDA, sos)
    out += bits.out
    out += b"\xFF\xD9"
    return bytes(out)


def jpeg_rgb(width, height, rows, quality):
    """RGB rows (bytes, 3 per pixel) as a 4:4:4 JPEG in JFIF's YCbCr, each
    sample rounded half up (stars are single pixels: their colour isn't
    shared with their neighbours)."""
    planes = ([], [], [])
    for row in rows:
        r, g, b = row[0::3], row[1::3], row[2::3]
        planes[0].append([int(0.299 * p + 0.587 * q + 0.114 * t + 0.5) for p, q, t in zip(r, g, b)])
        planes[1].append([max(0, min(255, int(-0.168736 * p - 0.331264 * q + 0.5 * t + 128.5))) for p, q, t in zip(r, g, b)])
        planes[2].append([max(0, min(255, int(0.5 * p - 0.418688 * q - 0.081312 * t + 128.5))) for p, q, t in zip(r, g, b)])
    return jpeg(width, height, list(planes), quality)


# ---------------------------------------------------------------------------
# The two pictures, decoded and written by this script alone (no ImageIO), so
# the same inputs give the same bytes on every Mac (the PNG's deflate at
# level 9 is zlib's, stable across zlib 1.2.x); `--check` compares them with
# their pins.


def png(width, height, rows, colour):
    """A PNG: 8-bit grey (colour 0) or RGB (colour 2), each row filtered with
    `Sub` (the difference to the pixel to its left), deflated at level 9."""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    channels = 3 if colour == 2 else 1
    raw = bytearray()
    for row in rows:
        row = bytes(row)
        left = bytes(channels) + row[:-channels]
        raw.append(1)
        raw += bytes(map(SUB_TABLE.__getitem__, map(operator.sub, row, left)))
    header = struct.pack(">IIBBBBB", width, height, 8, colour, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")


# (a - b) mod 256 for a - b in -255 ... 255
SUB_TABLE = {d: d & 0xFF for d in range(-255, 256)}


def read_exr_zip(path):
    """An OpenEXR scanline file with ZIP compression (16 lines a block) and
    HALF channels: the channel names and, per channel, the rows of raw
    half-float bit patterns (array 'H'), from the top."""
    data = open(path, "rb").read()
    if data[:4] != b"\x76\x2f\x31\x01":
        sys.exit(f"!! {path}: not an OpenEXR file")
    i, attributes = 8, {}
    while data[i] != 0:
        name_end = data.index(b"\0", i)
        name = data[i:name_end].decode()
        type_end = data.index(b"\0", name_end + 1)
        size = struct.unpack("<I", data[type_end + 1:type_end + 5])[0]
        attributes[name] = data[type_end + 5:type_end + 5 + size]
        i = type_end + 5 + size
    i += 1
    if attributes["compression"] != b"\x03":
        sys.exit(f"!! {path}: compression {attributes['compression'][0]}, only ZIP (3) is read")
    channels, c = [], attributes["channels"]
    while c[0] != 0:
        end = c.index(b"\0")
        kind = struct.unpack("<i", c[end + 1:end + 5])[0]
        if kind != 1:
            sys.exit(f"!! {path}: channel type {kind}, only HALF (1) is read")
        channels.append(c[:end].decode())
        c = c[end + 17:]
    x0, y0, x1, y1 = struct.unpack("<4i", attributes["dataWindow"])
    width, height = x1 - x0 + 1, y1 - y0 + 1
    blocks = (height + 15) // 16
    offsets = struct.unpack(f"<{blocks}Q", data[i:i + 8 * blocks])
    rows = {name: [] for name in channels}
    for offset in offsets:
        y, size = struct.unpack("<ii", data[offset:offset + 8])
        packed = zlib.decompress(data[offset + 8:offset + 8 + size])
        # Undo the predictor (each byte the sum of the ones before, less 128 each), then the interleaving
        deltas = bytearray(packed)
        sums = itertools.accumulate(itertools.chain(deltas[:1], (b - 128 for b in deltas[1:])))
        t = bytes(map((0xFF).__and__, sums))
        half = (len(t) + 1) // 2
        plain = bytearray(len(t))
        plain[0::2] = t[:half]
        plain[1::2] = t[half:]
        lines = min(16, y1 + 1 - y)
        k = 0
        for _ in range(lines):
            for name in channels:
                row = array.array("H", plain[k:k + 2 * width])
                if sys.byteorder == "big":
                    row.byteswap()
                rows[name].append(row)
                k += 2 * width
    return width, height, rows


def half_value(bits):
    return struct.unpack("<e", struct.pack("<H", bits))[0]


def sky_jpeg(path, quality):
    """The star map tone-mapped: scaled so the 99.95th percentile of the
    brightness is white, linear up to 0.8, a soft shoulder above,
    sRGB-encoded; a JPEG of the same size (`jpeg_rgb`)."""
    width, height, rows = read_exr_zip(path)
    value = [half_value(b) for b in range(65536)]
    value = [v if v == v and v > 0 and v != float("inf") else (65504.0 if v == float("inf") else 0.0) for v in value]
    luminance = array.array("d")
    for r, g, b in zip(rows["R"], rows["G"], rows["B"]):
        luminance.extend(0.2126 * value[x] + 0.7152 * value[y] + 0.0722 * value[z] for x, y, z in zip(r, g, b))
    ordered = sorted(luminance)
    white = max(1e-6, ordered[min(len(ordered) - 1, int(len(ordered) * 0.9995))])
    print(f"   sky {width}×{height}: median {ordered[len(ordered) // 2]:.6f}, 99.95 % {white:.6f}, max {ordered[-1]:.6f}")

    def encode(v):
        x = v / white
        if x > 0.8:
            x = 0.8 + 0.2 * (1 - math.exp(-(x - 0.8) / 0.2))
        s = 12.92 * x if x <= 0.0031308 else 1.055 * x ** (1 / 2.4) - 0.055
        return max(0, min(255, int(math.floor(s * 255 + 0.5))))
    table = bytes(encode(v) for v in value)
    out_rows = []
    for r, g, b in zip(rows["R"], rows["G"], rows["B"]):
        line = bytearray(3 * width)
        line[0::3] = bytes(map(table.__getitem__, r))
        line[1::3] = bytes(map(table.__getitem__, g))
        line[2::3] = bytes(map(table.__getitem__, b))
        out_rows.append(line)
    return jpeg_rgb(width, height, out_rows, quality)


def lzw_decode(data):
    """TIFF's LZW (codes from 9 to 12 bits, most significant bit first, the
    width growing one code early, 256 clear, 257 end)."""
    out = bytearray()
    table = [bytes([i]) for i in range(256)] + [b"", b""]
    bits, nbits, width, previous = 0, 0, 9, None
    for byte in data:
        bits = (bits << 8) | byte
        nbits += 8
        while nbits >= width:
            nbits -= width
            code = (bits >> nbits) & ((1 << width) - 1)
            bits &= (1 << nbits) - 1
            if code == 256:
                table = table[:258]
                width, previous = 9, None
                continue
            if code == 257:
                return bytes(out)
            if previous is None:
                entry = table[code]
            else:
                entry = table[code] if code < len(table) else previous + previous[:1]
                table.append(previous + entry[:1])
            out += entry
            previous = entry
            if len(table) + 1 >= (1 << width) and width < 12:
                width += 1
    return bytes(out)


def read_tiff_strips(path):
    """A baseline TIFF (little-endian, 8 bits per sample, LZW or none, one
    strip per row as NASA's GeoTIFFs have it): width, height, samples per
    pixel and the rows as bytes, from the top."""
    data = open(path, "rb").read()
    if data[:4] != b"II*\0":
        sys.exit(f"!! {path}: not a little-endian TIFF")
    offset = struct.unpack("<I", data[4:8])[0]
    count = struct.unpack("<H", data[offset:offset + 2])[0]
    tags = {}
    for k in range(count):
        tag, kind, n, value = struct.unpack("<HHII", data[offset + 2 + 12 * k:offset + 14 + 12 * k])
        size = {3: 2, 4: 4}.get(kind)
        if size is None:
            continue
        if n * size <= 4:
            raw = data[offset + 10 + 12 * k:offset + 10 + 12 * k + n * size]
        else:
            raw = data[value:value + n * size]
        tags[tag] = struct.unpack("<" + ("H" if size == 2 else "I") * n, raw)
    width, height = tags[256][0], tags[257][0]
    samples = tags.get(277, (1,))[0]
    compression = tags.get(259, (1,))[0]
    if any(b != 8 for b in tags.get(258, (8,))) or compression not in (1, 5) or tags.get(317, (1,))[0] != 1 \
            or tags.get(278, (height,))[0] != 1:
        sys.exit(f"!! {path}: only 8-bit, uncompressed or LZW without predictor, one row per strip")
    rows = []
    for start, length in zip(tags[273], tags[279]):
        strip = data[start:start + length]
        row = lzw_decode(strip) if compression == 5 else strip
        if len(row) < width * samples:
            sys.exit(f"!! {path}: a row decodes to {len(row)} bytes, expected {width * samples}")
        rows.append(row[:width * samples])
    return width, height, samples, rows


def lights_png(path, out_width):
    """Black Marble's grey GeoTIFF (13500 × 6750, its red channel) reduced by
    2.5 in each direction: every 5 × 5 source pixels give 2 × 2, each source
    pixel weighted by how much of it the target pixel covers (2, 2, 1 / 1, 2, 2
    in each direction), rounded; a grey PNG."""
    width, height, samples, rows = read_tiff_strips(path)
    if width * 2 != out_width * 5 or height * 2 != out_width // 2 * 5:
        sys.exit(f"!! {path}: {width}×{height} doesn't reduce by 2.5 to {out_width}")
    print(f"   lights {width}×{height} → {out_width}×{out_width // 2}")

    def across(row):
        a, b, c, d, e = (row[k::5 * samples] for k in range(0, 5 * samples, samples))
        first = [2 * p + 2 * q + r for p, q, r in zip(a, b, c)]
        second = [r + 2 * s + 2 * t for r, s, t in zip(c, d, e)]
        line = [0] * (2 * len(first))
        line[0::2], line[1::2] = first, second
        return line
    out_rows = []
    for k in range(0, height, 5):
        a, b, c, d, e = (across(rows[k + j]) for j in range(5))
        out_rows.append(bytes((2 * p + 2 * q + r + 12) // 25 for p, q, r in zip(a, b, c)))
        out_rows.append(bytes((r + 2 * s + 2 * t + 12) // 25 for r, s, t in zip(c, d, e)))
    return png(out_width, out_width // 2, out_rows, 0)


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

{lights}: the lights of the night side, made from "Earth at Night (Black Marble)
2016 Grayscale Maps": NASA Earth Observatory images by Joshua Stevens, using
Suomi NPP VIIRS data from Miguel Román, NASA GSFC
(https://science.nasa.gov/earth/earth-observatory/earth-at-night/maps/).
Used under NASA's media usage guidelines; no endorsement by NASA is implied.

Made by Scripts/build_globe_data.py of https://github.com/JohannesHoppe/schnellbild.
"""


def main():
    check = "--check" in sys.argv
    extract = sys.argv[sys.argv.index("--extract") + 1] if "--extract" in sys.argv else None
    cfg = env()

    bands = [etopo_band(cfg, band) for band in range(BANDS)]
    sky = obtain(cfg, os.path.basename(cfg["SKY_URL"]), cfg["SKY_SHA256"], cfg["SKY_URL"])
    if os.path.getsize(sky) != int(cfg["SKY_SIZE"]):
        sys.exit(f"!! {sky}: size {os.path.getsize(sky)}, expected {cfg['SKY_SIZE']}")
    pinned(sky, cfg["SKY_SHA256"], "star map")
    lights = obtain(cfg, os.path.basename(cfg["LIGHTS_URL"]), cfg["LIGHTS_SHA256"], cfg["LIGHTS_URL"])
    pinned(lights, cfg["LIGHTS_SHA256"], "Black Marble")

    if extract:
        os.makedirs(extract, exist_ok=True)
        for p in bands + [sky, lights]:
            with open(p, "rb") as src, open(os.path.join(extract, os.path.basename(p)), "wb") as dst:
                dst.write(src.read())
            print(f"{os.path.basename(p)} {os.path.getsize(p)} {sha256(p)}")
        print("ETOPO_BANDS_SHA256=" + ",".join(sha256(p) for p in bands))
        return

    os.makedirs(OUT, exist_ok=True)
    made = [("HEIGHTMAP", heightmap(bands)), ("SKYMAP", sky_jpeg(sky, int(cfg["SKY_QUALITY"]))), ("CITYLIGHTS", lights_png(lights, int(cfg["LIGHTS_WIDTH"])))]
    failed = False
    for key, data in made:
        open(os.path.join(OUT, cfg[key + "_FILE"]), "wb").write(data)
        if check:
            got = hashlib.sha256(data).hexdigest()
            if got != cfg[key + "_SHA256"]:
                print(f"!! {cfg[key + '_FILE']}: SHA-256 {got}, pinned {cfg[key + '_SHA256']}")
                failed = True
            else:
                print(f"{cfg[key + '_FILE']} matches the pinned SHA-256")
    if failed:
        sys.exit(1)

    with open(os.path.join(OUT, cfg["NOTICE_FILE"]), "w") as f:
        f.write(NOTICE.format(tag=cfg["RELEASE_TAG"], heightmap=cfg["HEIGHTMAP_FILE"], sky=cfg["SKYMAP_FILE"], lights=cfg["CITYLIGHTS_FILE"]))
    for key in ("HEIGHTMAP_FILE", "SKYMAP_FILE", "CITYLIGHTS_FILE"):
        p = os.path.join(OUT, cfg[key])
        print(f"{key[:-5]}_SHA256={sha256(p)}  ({os.path.getsize(p)} bytes)")


if __name__ == "__main__":
    main()
