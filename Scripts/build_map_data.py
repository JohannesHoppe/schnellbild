#!/usr/bin/env python3
"""Builds Schnellbild's offline map from OpenStreetMap data (Python's standard library only).

From the Protomaps daily build pinned in Scripts/map_data.env it makes:

  <MAP_FILE>     PMTiles v3 with Mapbox Vector Tiles, zoom 0 to MAP_MAX_ZOOM: the layers
                 earth, water, boundaries and roads, and glaciers from landuse; only the
                 attributes the app draws with, names only on water labels, in the app's
                 20 languages
  <PLACES_FILE>  the place index: every country, region and locality of the tiles up to
                 PLACES_ZOOM (places up to min_zoom PLACES_ZOOM + 1), with names in the app's
                 languages and each place's country code (from Natural Earth), in a grid
                 the app memory-maps (format below and in OfflineMap/PlaceIndex.swift)
  <NOTICE_FILE>  the data's licence notice (also written to Resources/Licenses/OpenStreetMap-data.txt)

Usage:
  python3 -I Scripts/build_map_data.py [--cache DIR] [--out DIR] [--jobs N] [--check]
  python3 -I Scripts/build_map_data.py --upstream --extract DIR [--cache DIR]

  --cache     where the source's directories and tile data are kept between runs
              (default build/map-cache). Tile data is kept as files tiles-<start>-<end>.bin,
              <start>/<end> being byte offsets into the source's tile data section; any set
              of such files is used.
  --out       where the files are written (default build/map)
  --check     fail unless the files' SHA-256 are the ones pinned in map_data.env
  --upstream  take what the cache lacks from Protomaps and naciscdn.org, not from the archive
  --extract   only gather the inputs, write them to DIR as the archive's files (the tile data
              in parts under 2 GiB, GitHub's limit per release asset) and print their pins

The inputs come from the archive: the pre-release SOURCE_RELEASE_TAG of this repository
holds what the build reads of the Protomaps build (its directory up to zoom 10 and the tile
data up to the end of zoom 10, about 3.8 GB) and the Natural Earth zips, each pinned by
SHA-256 in map_data.env. Only when the archive can't be reached does the builder read
Protomaps (by range requests, in pieces of 256 MiB, after checking the build's size and
first 16 KiB) and naciscdn.org. `--upstream --extract` makes the archive's files anew from
upstream while Protomaps still serves the build.
"""
import argparse, gzip, hashlib, io, json, math, multiprocessing as mp, os, re, struct, sys, time, urllib.error, urllib.request, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UA = "Schnellbild-map-pipeline (github.com/JohannesHoppe/schnellbild)"

# The app's 20 languages and the OpenStreetMap name tag each one reads
# (Norwegian Bokmål has its names under name:no in Protomaps' build, Brazilian
# Portuguese under name:pt). The order is the index the place file stores.
LANGUAGES = ["en", "de", "fr", "es", "it", "pt-BR", "nl", "pl", "sv", "da", "nb", "fi", "cs", "tr", "ru", "uk", "ja", "ko", "zh-Hans", "zh-Hant"]
OSM_NAME_KEY = {"pt-BR": "name:pt", "nb": "name:no"}
NAME_KEYS = [OSM_NAME_KEY.get(l, "name:" + l) for l in LANGUAGES]

# Kinds in the place file (OfflineMap/PlaceIndex.swift: Place.Kind)
PLACE_KINDS = ["country", "region", "city", "town", "village", "hamlet", "locality"]


def load_env():
    env = {}
    with open(os.path.join(ROOT, "Scripts", "map_data.env"), encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                k, v = line.split("=", 1)
                env[k] = v
    return env


# --- network -------------------------------------------------------------------------------

def http_range(url, start, length, out=None):
    req = urllib.request.Request(url, headers={"Range": f"bytes={start}-{start + length - 1}", "User-Agent": UA})
    for attempt in range(6):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                if r.status != 206:
                    raise IOError(f"expected 206 Partial Content, got {r.status}")
                if out is None:
                    data = r.read()
                    if len(data) != length:
                        raise IOError(f"short read {len(data)} of {length}")
                    return data
                got = 0
                with open(out + ".part", "wb") as f:
                    while True:
                        chunk = r.read(1 << 20)
                        if not chunk:
                            break
                        f.write(chunk)
                        got += len(chunk)
                if got != length:
                    raise IOError(f"short read {got} of {length}")
                os.replace(out + ".part", out)
                return None
        except Exception as e:  # transient network errors: try again a few times
            print(f"   retry ({e})", file=sys.stderr)
            time.sleep(3 + attempt * 5)
    raise IOError(f"giving up on {url} bytes {start}+{length}")


def http_size(url):
    req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=60) as r:
        return int(r.headers["Content-Length"])


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def archive_url(env, name):
    return f"https://github.com/JohannesHoppe/schnellbild/releases/download/{env['SOURCE_RELEASE_TAG']}/{name}"


def fetch_archived(env, name, sha, path):
    """Downloads the archive's file <name> to <path> (resuming a .part left behind), checked
    against <sha>. False when the archive can't be reached; a file that arrives with another
    SHA-256 stops the build."""
    url = archive_url(env, name)
    part = path + ".part"
    print(f"==> {url}", file=sys.stderr)
    for attempt in range(4):
        have = os.path.getsize(part) if os.path.exists(part) else 0
        headers = {"User-Agent": UA}
        if have:
            headers["Range"] = f"bytes={have}-"
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=120) as r:
                mode = "ab" if have and r.status == 206 else "wb"
                with open(part, mode) as f:
                    while True:
                        chunk = r.read(1 << 20)
                        if not chunk:
                            break
                        f.write(chunk)
            break
        except urllib.error.HTTPError as e:
            if e.code == 416:  # the .part is whole already
                break
            print(f"   archive: {e}", file=sys.stderr)
            if e.code in (403, 404, 410):
                return False
        except Exception as e:  # transient network errors: try again a few times
            print(f"   archive: {e}", file=sys.stderr)
        time.sleep(3 + attempt * 5)
    else:
        return False
    digest = sha256_file(part)
    if digest != sha:
        os.remove(part)
        sys.exit(f"!! {name} from the archive has SHA-256 {digest}, map_data.env pins {sha}")
    os.replace(part, path)
    return True


# --- PMTiles v3 -----------------------------------------------------------------------------

def read_varint(buf, pos):
    result = shift = 0
    while True:
        b = buf[pos]
        pos += 1
        result |= (b & 0x7F) << shift
        if b < 0x80:
            return result, pos
        shift += 7


def write_varint(value, out):
    while True:
        b = value & 0x7F
        value >>= 7
        if value:
            out.append(b | 0x80)
        else:
            out.append(b)
            return


def varint_bytes(value):
    out = bytearray()
    write_varint(value, out)
    return bytes(out)


HEADER_FIELDS = ["root_offset", "root_length", "metadata_offset", "metadata_length", "leaf_offset", "leaf_length",
                 "data_offset", "data_length", "addressed_tiles", "tile_entries", "tile_contents"]


def parse_header(b):
    if b[:7] != b"PMTiles" or b[7] != 3:
        raise ValueError("not a PMTiles v3 file")
    h = dict(zip(HEADER_FIELDS, struct.unpack("<11Q", b[8:96])))
    h.update(zip(["clustered", "internal_compression", "tile_compression", "tile_type", "min_zoom", "max_zoom"], b[96:102]))
    return h


def decompress(data, compression):
    if compression == 1:
        return data
    if compression == 2:
        return gzip.decompress(data)
    raise ValueError(f"compression {compression} not supported")


def parse_directory(data):
    n, p = read_varint(data, 0)
    ids, runs, lengths, offsets = [], [], [], []
    last = 0
    for _ in range(n):
        v, p = read_varint(data, p)
        last += v
        ids.append(last)
    for _ in range(n):
        v, p = read_varint(data, p)
        runs.append(v)
    for _ in range(n):
        v, p = read_varint(data, p)
        lengths.append(v)
    for i in range(n):
        v, p = read_varint(data, p)
        offsets.append(offsets[i - 1] + lengths[i - 1] if v == 0 and i > 0 else v - 1)
    return list(zip(ids, runs, lengths, offsets))


def serialize_directory(entries):
    out = bytearray()
    write_varint(len(entries), out)
    last = 0
    for e in entries:
        write_varint(e[0] - last, out)
        last = e[0]
    for e in entries:
        write_varint(e[1], out)
    for e in entries:
        write_varint(e[2], out)
    for i, e in enumerate(entries):
        if i > 0 and e[3] == entries[i - 1][3] + entries[i - 1][2]:
            write_varint(0, out)
        else:
            write_varint(e[3] + 1, out)
    return gzip_bytes(bytes(out))


def gzip_bytes(data):
    return gzip.compress(data, compresslevel=9, mtime=0)


def first_id(z):
    return (4 ** z - 1) // 3


def zxy_to_id(z, x, y):
    acc = first_id(z)
    n = 1 << z
    d = 0
    s = n >> 1
    while s > 0:
        rx = 1 if (x & s) > 0 else 0
        ry = 1 if (y & s) > 0 else 0
        d += s * s * ((3 * rx) ^ ry)
        if ry == 0:
            if rx == 1:
                x = s - 1 - x
                y = s - 1 - y
            x, y = y, x
        s >>= 1
    return acc + d


def id_to_zxy(tile_id):
    z = 0
    while first_id(z + 1) <= tile_id:
        z += 1
    t = tile_id - first_id(z)
    n = 1 << z
    x = y = 0
    s = 1
    while s < n:
        rx = 1 & (t // 2)
        ry = 1 & (t ^ rx)
        if ry == 0:
            if rx == 1:
                x = s - 1 - x
                y = s - 1 - y
            x, y = y, x
        x += s * rx
        y += s * ry
        t //= 4
        s *= 2
    return z, x, y


def write_pmtiles(path, tiles, metadata, min_zoom, max_zoom):
    """tiles: list of (tile_id, raw MVT bytes), sorted by tile id. Identical tiles are stored once,
    runs of identical tiles in a row as one entry; empty tiles are left out."""
    data = bytearray()
    by_hash = {}
    entries = []
    addressed = 0
    for tile_id, raw in tiles:
        if not raw:
            continue
        addressed += 1
        digest = hashlib.sha256(raw).digest()
        if digest in by_hash:
            offset, length = by_hash[digest]
        else:
            blob = gzip_bytes(raw)
            offset, length = len(data), len(blob)
            data += blob
            by_hash[digest] = (offset, length)
        last = entries[-1] if entries else None
        if last and last[3] == offset and last[0] + last[1] == tile_id:
            entries[-1] = (last[0], last[1] + 1, last[2], last[3])
        else:
            entries.append((tile_id, 1, length, offset))
    # Root directory within the first 16 KiB; else leaf directories, as go-pmtiles does
    root = serialize_directory(entries)
    leaves = b""
    if 127 + len(root) > 16384:
        leaf_size = 4096
        while True:
            root_entries, leaf_blob = [], bytearray()
            for i in range(0, len(entries), leaf_size):
                part = entries[i:i + leaf_size]
                blob = serialize_directory(part)
                root_entries.append((part[0][0], 0, len(blob), len(leaf_blob)))
                leaf_blob += blob
            root = serialize_directory(root_entries)
            if 127 + len(root) <= 16384:
                leaves = bytes(leaf_blob)
                break
            leaf_size = int(leaf_size * 1.2)
    meta = gzip_bytes(json.dumps(metadata, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8"))
    root_offset = 127
    meta_offset = root_offset + len(root)
    leaf_offset = meta_offset + len(meta)
    data_offset = leaf_offset + len(leaves)
    header = bytearray(b"PMTiles\x03")
    header += struct.pack("<11Q", root_offset, len(root), meta_offset, len(meta), leaf_offset, len(leaves),
                          data_offset, len(data), addressed, len(entries), len(by_hash))
    header += bytes([1, 2, 2, 1, min_zoom, max_zoom])  # clustered, gzip directories, gzip tiles, MVT
    header += struct.pack("<4i", -1800000000, -850511287, 1800000000, 850511287)
    header += bytes([0]) + struct.pack("<2i", 0, 0)
    assert len(header) == 127
    with open(path, "wb") as f:
        f.write(header)
        f.write(root)
        f.write(meta)
        f.write(leaves)
        f.write(data)
    return {"entries": len(entries), "contents": len(by_hash), "addressed": addressed, "bytes": data_offset + len(data)}


# --- source --------------------------------------------------------------------------------

class Source:
    """The pinned Protomaps build: header and directories (cached as JSON), and the tile data
    section as cached chunk files tiles-<start>-<end>.bin (offsets relative to its start).
    What the cache lacks comes from the archive (SOURCE_RELEASE_TAG), else from Protomaps."""

    def __init__(self, env, cache, upstream=False):
        self.url = env["PROTOMAPS_URL"]
        self.dir = os.path.join(cache, env["PROTOMAPS_BUILD"])
        os.makedirs(self.dir, exist_ok=True)
        self.env = env
        self.upstream = upstream
        self.head = None

    def check_head(self):
        """The build's first 16 KiB, once its size and their SHA-256 are the pinned ones."""
        if self.head is not None:
            return self.head
        size = http_size(self.url)
        if size != int(self.env["PROTOMAPS_SIZE"]):
            sys.exit(f"!! {self.url} has {size} bytes, map_data.env pins {self.env['PROTOMAPS_SIZE']}: not the same build")
        head = http_range(self.url, 0, 16384)
        digest = hashlib.sha256(head).hexdigest()
        if digest != self.env["PROTOMAPS_HEAD_SHA256"]:
            sys.exit(f"!! the source's first 16 KiB have SHA-256 {digest}, map_data.env pins {self.env['PROTOMAPS_HEAD_SHA256']}")
        self.head = head
        return head

    def archived_tiles(self):
        """The archive's tile data parts: (start, end, name, sha256)."""
        parts = []
        for item in self.env.get("SOURCE_TILES", "").split(","):
            if item:
                name, sha = item.split(":")
                m = re.fullmatch(r"tiles-(\d+)-(\d+)\.bin", name)
                parts.append((int(m.group(1)), int(m.group(2)), name, sha))
        return parts

    def entries(self, max_zoom):
        """Every tile entry up to max_zoom: (tile_id, run_length, length, offset)."""
        name = f"directory-z{max_zoom}.json"
        path = os.path.join(self.dir, name)
        if not os.path.exists(path) and not self.upstream and self.env.get("SOURCE_DIRECTORY") == name:
            fetch_archived(self.env, name, self.env["SOURCE_DIRECTORY_SHA256"], path)
        if os.path.exists(path):
            with open(path) as f:
                cached = json.load(f)
            return cached["header"], [tuple(e) for e in cached["entries"]]
        head = self.check_head()
        h = parse_header(head)
        root = parse_directory(decompress(head[h["root_offset"]:h["root_offset"] + h["root_length"]], h["internal_compression"]))
        limit = first_id(max_zoom + 1)
        out = []
        for tile_id, run, length, offset in root:
            if tile_id >= limit:
                break
            if run == 0:
                leaf = decompress(http_range(self.url, h["leaf_offset"] + offset, length), h["internal_compression"])
                out += [e for e in parse_directory(leaf) if e[0] < limit]
                print(f"   leaf directory at tile {tile_id}: {len(out)} entries so far", file=sys.stderr)
            else:
                out.append((tile_id, run, length, offset))
        with open(path, "w") as f:
            json.dump({"url": self.url, "header": h, "entries": out}, f)
        return h, out

    def chunks(self):
        found = []
        for name in os.listdir(self.dir):
            m = re.fullmatch(r"tiles-(\d+)-(\d+)\.bin", name)
            if m:
                start, end = int(m.group(1)), int(m.group(2))
                if os.path.getsize(os.path.join(self.dir, name)) == end - start:
                    found.append((start, end, os.path.join(self.dir, name)))
        return sorted(found)

    def gaps(self, end):
        """The ranges of the tile data section up to byte <end> that no cached chunk holds."""
        out, pos = [], 0
        for start, stop, _ in self.chunks():
            if pos >= end:
                break
            if start > pos:
                out.append((pos, min(start, end)))
            pos = max(pos, stop)
        if pos < end:
            out.append((pos, end))
        return out

    def ensure_data(self, header, end):
        """Fetches what the cache lacks of the tile data section up to byte <end>: the archive's
        parts that cover a gap, then, for what is still missing, Protomaps in pieces of 256 MiB."""
        if not self.upstream:
            for start, stop, name, sha in self.archived_tiles():
                if any(a < stop and start < b for a, b in self.gaps(end)):
                    if not fetch_archived(self.env, name, sha, os.path.join(self.dir, name)):
                        break
        piece = 256 << 20
        for gap_start, gap_end in self.gaps(end):
            self.check_head()
            pos = gap_start
            while pos < gap_end:
                upto = min(gap_end, pos + piece)
                out = os.path.join(self.dir, f"tiles-{pos}-{upto}.bin")
                print(f"==> Downloading tile data {pos / 1e6:.0f} to {upto / 1e6:.0f} MB of {end / 1e6:.0f} MB", file=sys.stderr)
                http_range(self.url, header["data_offset"] + pos, upto - pos, out)
                pos = upto

    def write_archive(self, max_zoom, end, out_dir):
        """Writes the archive's files for this build into <out_dir>: the directory up to max_zoom
        and the tile data section up to byte <end> in equal parts under 2 GiB. Returns
        [(name, sha256)]."""
        names = [f"directory-z{max_zoom}.json"]
        with open(os.path.join(self.dir, names[0]), "rb") as src, open(os.path.join(out_dir, names[0]), "wb") as dst:
            dst.write(src.read())
        count = -(-end // 2_000_000_000)
        bounds = [end * i // count for i in range(count + 1)]
        reader = TileReader(self.chunks())
        for start, stop in zip(bounds, bounds[1:]):
            name = f"tiles-{start}-{stop}.bin"
            with open(os.path.join(out_dir, name), "wb") as f:
                pos = start
                while pos < stop:
                    data = reader.raw(pos, min(stop - pos, 64 << 20))
                    f.write(data)
                    pos += len(data)
            names.append(name)
        return [(n, sha256_file(os.path.join(out_dir, n))) for n in names]


class TileReader:
    def __init__(self, chunks):
        self.chunks = chunks
        self.files = {}

    def _file(self, path):
        f = self.files.get(path)
        if f is None:
            f = self.files[path] = open(path, "rb")
        return f

    def read(self, offset, length):
        for start, end, path in self.chunks:
            if start <= offset and offset + length <= end:
                f = self._file(path)
                f.seek(offset - start)
                return gzip.decompress(f.read(length))
        raise IOError(f"tile data {offset}+{length} not in the cache")

    def raw(self, offset, length):
        """Up to <length> bytes of the tile data section from <offset>, from the chunk holding
        <offset> (fewer where that chunk ends)."""
        for start, end, path in self.chunks:
            if start <= offset < end:
                f = self._file(path)
                f.seek(offset - start)
                return f.read(min(length, end - offset))
        raise IOError(f"tile data at {offset} not in the cache")


# --- Mapbox Vector Tiles ---------------------------------------------------------------------

def fields(b):
    """(field number, wire type, value, the field's raw bytes including its key)."""
    p = 0
    n = len(b)
    while p < n:
        start = p
        key, p = read_varint(b, p)
        f, t = key >> 3, key & 7
        if t == 0:
            v, p = read_varint(b, p)
        elif t == 2:
            length, p = read_varint(b, p)
            v = b[p:p + length]
            p += length
        elif t == 5:
            v = b[p:p + 4]
            p += 4
        elif t == 1:
            v = b[p:p + 8]
            p += 8
        else:
            raise ValueError(f"wire type {t}")
        yield f, t, v, b[start:p]


def packed(b):
    out = []
    p = 0
    while p < len(b):
        v, p = read_varint(b, p)
        out.append(v)
    return out


def value_of(raw):
    for f, t, x, _ in fields(raw):
        if f == 1:
            return bytes(x).decode("utf-8")
        if f == 2:
            return struct.unpack("<f", x)[0]
        if f == 3:
            return struct.unpack("<d", x)[0]
        if f in (4, 5):
            return x
        if f == 6:
            return (x >> 1) ^ -(x & 1)
        if f == 7:
            return bool(x)
    return None


def field_bytes(number, payload):
    return varint_bytes((number << 3) | 2) + varint_bytes(len(payload)) + payload


# Which attributes each layer keeps (the app draws with nothing else)
NAMES = {"name"} | set(NAME_KEYS)
KEEP_KEYS = {
    "earth": set(),
    "water": {"kind", "min_zoom"},
    "boundaries": {"kind", "kind_detail", "disputed"},
    "roads": {"kind", "min_zoom"},
    "landuse": {"kind"},
}


def string_value(text):
    return field_bytes(1, text.encode("utf-8"))


def decode_lines(geometry):
    """A line feature's parts as lists of (x, y) in tile coordinates."""
    arr = packed(geometry)
    parts, cur, x, y, i = [], [], 0, 0, 0
    while i < len(arr):
        cmd, count = arr[i] & 7, arr[i] >> 3
        i += 1
        if cmd == 7:
            continue
        for _ in range(count):
            x += (arr[i] >> 1) ^ -(arr[i] & 1)
            y += (arr[i + 1] >> 1) ^ -(arr[i + 1] & 1)
            i += 2
            if cmd == 1 and cur:
                parts.append(cur)
                cur = []
            cur.append((x, y))
    if cur:
        parts.append(cur)
    return parts


def encode_lines(parts):
    def zz(v):
        return (v << 1) ^ (v >> 63)
    out, x, y = bytearray(), 0, 0
    for part in parts:
        if len(part) < 2:
            continue
        write_varint((1 << 3) | 1, out)
        write_varint(zz(part[0][0] - x), out)
        write_varint(zz(part[0][1] - y), out)
        x, y = part[0]
        write_varint(((len(part) - 1) << 3) | 2, out)
        for px, py in part[1:]:
            write_varint(zz(px - x), out)
            write_varint(zz(py - y), out)
            x, y = px, py
    return bytes(out)


def tile_to_lat_lon(z, x0, y0, extent, gx, gy):
    n = 1 << z
    lon = (x0 + gx / extent) / n * 360 - 180
    lat = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * (y0 + gy / extent) / n))))
    return lat, lon


def split_border(parts, kind, tile, extent):
    """A border feature's parts split by the European reading: (kept parts, promoted parts). A
    segment near a region of the overrides is judged by the countries on its two sides (2 km
    away, or two tile units at small zooms): a country line with one country on both sides is
    dropped (water on one side shows no other country); returns (kept parts, [])."""
    z, x0, y0 = tile
    units_per_km = extent * (1 << z) / 40075.0
    kept, promoted = [], []
    for part in parts:
        runs = {"keep": [], "promote": []}
        current, current_kind = [part[0]], "keep"
        for a, b in zip(part, part[1:]):
            verdict = "keep"
            mx, my = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2
            lat, lon = tile_to_lat_lon(z, x0, y0, extent, mx, my)
            if near_region(lat, lon):
                dx, dy = b[0] - a[0], b[1] - a[1]
                length = math.hypot(dx, dy)
                if length > 0:
                    off = max(2.0 * units_per_km / max(0.05, math.cos(math.radians(lat))), 2.0)
                    nx, ny = -dy / length * off, dx / length * off
                    left = political_code(*tile_to_lat_lon(z, x0, y0, extent, mx + nx, my + ny))
                    right = political_code(*tile_to_lat_lon(z, x0, y0, extent, mx - nx, my - ny))
                    if kind == "country" and len({left, right} - {""}) == 1:
                        verdict = "drop"
            if verdict == current_kind:
                current.append(b)
            else:
                if current_kind in runs and len(current) > 1:
                    runs[current_kind].append(current)
                current, current_kind = [a, b], verdict
        if current_kind in runs and len(current) > 1:
            runs[current_kind].append(current)
        kept += runs["keep"]
        promoted += runs["promote"]
    return kept, promoted


def added_border_parts(tile, extent):
    """The parts of `_added_borders` that reach the tile (with a margin), in its coordinates."""
    z, x0, y0 = tile
    n = 1 << z
    margin = extent * 0.1
    out = []
    for line in _added_borders:
        pts = []
        for lat, lon in line:
            l = math.radians(max(-85.05, min(85.05, lat)))
            ux = (lon + 180) / 360 * n - x0
            uy = (1 - math.log(math.tan(l) + 1 / math.cos(l)) / math.pi) / 2 * n - y0
            pts.append((round(ux * extent), round(uy * extent)))
        run = []
        for p in pts:
            if -margin <= p[0] <= extent + margin and -margin <= p[1] <= extent + margin:
                run.append(p)
            else:
                if len(run) > 1:
                    out.append(run)
                run = []
        if len(run) > 1:
            out.append(run)
    # vertices that coincide at this zoom are dropped
    cleaned = []
    for run in out:
        r = [run[0]] + [p for i, p in enumerate(run[1:], 1) if p != run[i - 1]]
        if len(r) > 1:
            cleaned.append(r)
    return cleaned


def water_override(attrs):
    """The water label's names from `WATER_NAMES`, or the attributes as they are."""
    english = next((value_of(v) for k, v in attrs if k == "name:en"), None)
    rule = next((r for r in WATER_NAMES if english in r["match"]), None)
    if rule is None:
        return attrs
    names = {NAME_KEYS[LANGUAGES.index(lang)]: text for lang, text in rule["names"].items()}
    out = [(k, v) for k, v in attrs if k not in names and not (k == "name" and "local" in rule)]
    out += [(k, string_value(text)) for k, text in names.items()]
    if "local" in rule:
        out.append(("name", string_value(rule["local"])))
    return out


def thin_layer(name, body, tile=(0, 0, 0)):
    """The layer re-encoded with only the features and attributes the app uses, or None."""
    if name not in KEEP_KEYS:
        return None
    parts = list(fields(body))
    keys, values = [], []
    for f, t, v, raw in parts:
        if f == 3:
            keys.append(bytes(v).decode("utf-8"))
        elif f == 4:
            values.append(bytes(v))
    new_keys, new_values = [], []
    key_index, value_index = {}, {}
    features = []
    extent = 4096
    for f, t, v, raw in parts:
        if f == 5:
            extent = v
        if f != 2:
            continue
        tags, gtype, geometry = [], 0, None
        for ff, tt, x, _ in fields(v):
            if ff == 2:
                tags = packed(x)
            elif ff == 3:
                gtype = x
            elif ff == 4:
                geometry = bytes(x)
        if geometry is None:
            continue
        attrs = [(keys[tags[i]], values[tags[i + 1]]) for i in range(0, len(tags) - 1, 2)]
        kind = next((value_of(val) for k, val in attrs if k == "kind"), None)
        if name == "landuse" and kind != "glacier":
            continue
        if name == "earth" and gtype != 3:
            continue
        keep = KEEP_KEYS[name] | (NAMES if name == "water" and gtype == 1 else set())
        if name == "water" and gtype == 1 and not any(k == "name" for k, _ in attrs):
            continue  # a water point is only a label
        if name == "water" and gtype == 1:
            attrs = water_override(attrs)
        pieces = [(attrs, geometry)]
        if name == "boundaries" and gtype == 2 and kind == "country" and _countries is not None:
            parts = decode_lines(geometry)
            kept, promoted = split_border(parts, kind, tile, extent)
            if kept != parts or promoted:
                _borders_changed[0] = True
                pieces = []
                if kept:
                    pieces.append((attrs, encode_lines(kept)))
                if promoted:
                    pieces.append(([("kind", string_value("country")), ("kind_detail", varint_bytes((4 << 3) | 0) + varint_bytes(2)),
                                    ("disputed", varint_bytes((7 << 3) | 0) + varint_bytes(1))], encode_lines(promoted)))
        for piece_attrs, piece_geometry in pieces:
            new_tags = []
            for k, val in piece_attrs:
                if k not in keep:
                    continue
                if k not in key_index:
                    key_index[k] = len(new_keys)
                    new_keys.append(k)
                if val not in value_index:
                    value_index[val] = len(new_values)
                    new_values.append(val)
                new_tags += [key_index[k], value_index[val]]
            feature = bytearray()
            if new_tags:
                feature += field_bytes(2, b"".join(varint_bytes(i) for i in new_tags))
            feature += varint_bytes((3 << 3) | 0) + varint_bytes(gtype)
            feature += field_bytes(4, piece_geometry)
            features.append(bytes(feature))
    if name == "boundaries" and _added_borders:
        added = added_border_parts(tile, extent)
        if added:
            _borders_changed[0] = True
            attrs = [("kind", string_value("country")), ("kind_detail", varint_bytes((4 << 3) | 0) + varint_bytes(2)),
                     ("disputed", varint_bytes((7 << 3) | 0) + varint_bytes(1))]
            new_tags = []
            for k, val in attrs:
                if k not in key_index:
                    key_index[k] = len(new_keys)
                    new_keys.append(k)
                if val not in value_index:
                    value_index[val] = len(new_values)
                    new_values.append(val)
                new_tags += [key_index[k], value_index[val]]
            feature = field_bytes(2, b"".join(varint_bytes(i) for i in new_tags))
            feature += varint_bytes((3 << 3) | 0) + varint_bytes(2)
            feature += field_bytes(4, encode_lines(added))
            features.append(bytes(feature))
    if not features:
        return None
    out = bytearray(varint_bytes((15 << 3) | 0) + varint_bytes(2))
    out += field_bytes(1, name.encode("utf-8"))
    for feature in features:
        out += field_bytes(2, feature)
    for k in new_keys:
        out += field_bytes(3, k.encode("utf-8"))
    for val in new_values:
        out += field_bytes(4, val)
    out += varint_bytes((5 << 3) | 0) + varint_bytes(extent)
    return bytes(out)


LAYER_ORDER = ["earth", "water", "landuse", "boundaries", "roads"]


def thin_tile(raw, tile=(0, 0, 0)):
    layers = {}
    for f, t, v, _ in fields(raw):
        if f != 3:
            continue
        name = next(bytes(x).decode("utf-8") for ff, tt, x, _ in fields(v) if ff == 1)
        body = thin_layer(name, v, tile)
        if body is not None:
            layers[name] = body
    return b"".join(field_bytes(3, layers[n]) for n in LAYER_ORDER if n in layers)


# --- workers ---------------------------------------------------------------------------------

_reader = None


def _init_worker(chunks):
    global _reader
    _reader = TileReader(chunks)


_borders_changed = [False]


def map_work(batch):
    """(offset, thinned tile, whether a border of it was changed) for each (offset, tile id, length)."""
    out = []
    for offset, tile_id, length in batch:
        _borders_changed[0] = False
        raw = thin_tile(_reader.read(offset, length), id_to_zxy(tile_id))
        out.append((offset, raw, _borders_changed[0]))
    return out


def places_work(batch):
    out = []
    for tile_id, offset, length in batch:
        z, x0, y0 = id_to_zxy(tile_id)
        raw = _reader.read(offset, length)
        for f, t, v, _ in fields(raw):
            if f != 3:
                continue
            parts = list(fields(v))
            if next(bytes(x).decode("utf-8") for a, b, x, _ in parts if a == 1) != "places":
                continue
            keys = [bytes(x).decode("utf-8") for a, b, x, _ in parts if a == 3]
            vals = [value_of(x) for a, b, x, _ in parts if a == 4]
            extent = next((x for a, b, x, _ in parts if a == 5), 4096)
            for a, b, x, _ in parts:
                if a != 2:
                    continue
                tags, point = {}, None
                for ff, tt, xx, _ in fields(x):
                    if ff == 2:
                        arr = packed(xx)
                        for i in range(0, len(arr) - 1, 2):
                            tags[keys[arr[i]]] = vals[arr[i + 1]]
                    elif ff == 4:
                        arr = packed(xx)
                        if len(arr) >= 3 and arr[0] == 9:  # MoveTo, one point
                            point = ((arr[1] >> 1) ^ -(arr[1] & 1), (arr[2] >> 1) ^ -(arr[2] & 1))
                if point is None or not isinstance(tags.get("name"), str):
                    continue
                gx, gy = point
                if not (0 <= gx < extent and 0 <= gy < extent):
                    continue  # the tile's buffer: the place belongs to a neighbouring tile
                kind = tags.get("kind")
                if kind not in ("country", "region", "locality"):
                    continue
                n = 1 << z
                lon = (x0 + gx / extent) / n * 360 - 180
                lat = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * (y0 + gy / extent) / n))))
                names = [tags.get(k) if isinstance(tags.get(k), str) else None for k in NAME_KEYS]
                out.append((lat, lon, kind, tags.get("kind_detail"), tags.get("min_zoom"), tags.get("population_rank"),
                            tags.get("capital"), tags.get("wikidata"), tags["name"], names, z))
    return out


# --- countries (Natural Earth, public domain) -----------------------------------------------

def read_dbf(data):
    count, header_len, record_len = struct.unpack("<xxxxIHH", data[:12])
    columns = []
    i = 32
    while data[i] != 0x0D:
        name = data[i:i + 11].split(b"\0")[0].decode()
        columns.append((name, data[i + 16]))
        i += 32
    records = []
    for r in range(count):
        o = header_len + r * record_len + 1
        rec = {}
        for name, length in columns:
            rec[name] = data[o:o + length].decode("utf-8", "replace").strip(" \0")
            o += length
        records.append(rec)
    return records


def read_shp_polygons(data):
    shapes = []
    i = 100
    while i < len(data):
        _, content_len = struct.unpack(">ii", data[i:i + 8])
        i += 8
        rec = data[i:i + content_len * 2]
        i += content_len * 2
        shape_type = struct.unpack("<i", rec[:4])[0]
        if shape_type == 0:
            shapes.append([])
            continue
        num_parts, num_points = struct.unpack("<ii", rec[36:44])
        starts = list(struct.unpack(f"<{num_parts}i", rec[44:44 + 4 * num_parts])) + [num_points]
        pts = struct.unpack(f"<{2 * num_points}d", rec[44 + 4 * num_parts:44 + 4 * num_parts + 16 * num_points])
        shapes.append([[(pts[2 * k], pts[2 * k + 1]) for k in range(starts[j], starts[j + 1])] for j in range(num_parts)])
    return shapes


def country_code(rec):
    """The ISO 3166 code of a Natural Earth country record."""
    code = rec.get("ISO_A2_EH", "-99")
    if not re.fullmatch(r"[A-Z]{2}", code):
        code = rec.get("ISO_A2", "-99")
    if not re.fullmatch(r"[A-Z]{2}", code):
        code = {"KOS": "XK", "CYN": "CY", "SOL": "SO"}.get(rec.get("ADM0_A3"), "")
    return code or None


class Countries:
    """Point in polygon over Natural Earth polygons (countries, or the regions of the political
    overrides): edges bucketed by quarter degree of latitude, polygons by their bounding boxes
    on a one-degree grid. `code_of` gives a record's code, or None to leave it out."""
    BAND = 0.25

    def __init__(self, zip_bytes, code_of=country_code):
        z = zipfile.ZipFile(io.BytesIO(zip_bytes))
        shp = next(n for n in z.namelist() if n.endswith(".shp"))
        dbf = next(n for n in z.namelist() if n.endswith(".dbf"))
        shapes = read_shp_polygons(z.read(shp))
        records = read_dbf(z.read(dbf))
        self.codes, self.bands, self.grid, self.rings, self.boxes = [], [], {}, [], []
        for rings, rec in zip(shapes, records):
            code = code_of(rec)
            if not code or not rings:
                continue
            index = len(self.codes)
            self.codes.append(code)
            self.rings.append(rings)
            bands = {}
            min_x = min_y = 1e9
            max_x = max_y = -1e9
            for ring in rings:
                for (x1, y1), (x2, y2) in zip(ring, ring[1:] + ring[:1]):
                    if y1 == y2:
                        continue
                    lo, hi = min(y1, y2), max(y1, y2)
                    for band in range(int(math.floor(lo / self.BAND)), int(math.floor(hi / self.BAND)) + 1):
                        bands.setdefault(band, []).append((x1, y1, x2, y2))
                    min_x, max_x = min(min_x, x1, x2), max(max_x, x1, x2)
                    min_y, max_y = min(min_y, lo), max(max_y, hi)
            self.bands.append(bands)
            self.boxes.append((min_x, min_y, max_x, max_y))
            for gx in range(int(math.floor(min_x)), int(math.floor(max_x)) + 1):
                for gy in range(int(math.floor(min_y)), int(math.floor(max_y)) + 1):
                    self.grid.setdefault((gx, gy), []).append(index)

    def code_at(self, lat, lon):
        for index in self.grid.get((int(math.floor(lon)), int(math.floor(lat))), []):
            inside = False
            for x1, y1, x2, y2 in self.bands[index].get(int(math.floor(lat / self.BAND)), ()):
                if (y1 > lat) != (y2 > lat) and lon < x1 + (lat - y1) * (x2 - x1) / (y2 - y1):
                    inside = not inside
            if inside:
                return self.codes[index]
        return ""


# --- political positions ----------------------------------------------------------------
#
# The map shows the world as the EU and Germany read it (CLAUDE.md, "Political positions"). Natural
# Earth's countries as Germany sees them give most of it; these tables put right what they don't.

# Regions of Natural Earth's disputed areas (ne_10m_admin_0_disputed_areas, by BRK_NAME) and the
# country each belongs to. A place or a point in one of them takes this country first; a country
# border with this country on both sides is not drawn (it is the line of an occupation or of a
# de facto authority). Sources for the positions: the EU's non-recognition of the annexation of
# Crimea and of the four oblasts (European Council conclusions, 2014 and 2022); Germany's
# recognition of Kosovo (2008); the EU on Northern Cyprus, Abkhazia, South Ossetia, Transnistria and
# Karabakh as parts of Cyprus, Georgia, Moldova and Azerbaijan; the EU on the Golan Heights (Syrian
# territory occupied by Israel) and on the West Bank, East Jerusalem and Gaza (occupied Palestinian
# territory, UN Security Council resolution 2334); the EU on Western Sahara (a non-self-governing
# territory, judgments of the Court of Justice of the EU, C-104/16 P and C-779/21 P).
REGION_COUNTRIES = {
    "Crimea": "UA",
    "Donetsk People's Republic": "UA",
    "Luhansk People's Republic": "UA",
    "Kosovo": "XK",
    "N. Cyprus": "CY",
    "Cyprus U.N. Buffer Zone": "CY",
    "Abkhazia": "GE",
    "South Ossetia": "GE",
    "Transnistria": "MD",
    "Artsakh": "AZ",
    "Golan Heights": "SY",
    "West Bank": "PS",
    "Gaza": "PS",
    "East Jerusalem": "PS",
    "W. Sahara": "EH",        # both of Natural Earth's parts: the one Morocco and the one the Polisario hold
    "Taiwan": "TW",
}

# Natural Earth countries the app also gets as regions (`write_places`), after the ones above:
# Jerusalem's place has no country of its own (below), so a photo in West Jerusalem needs Israel's
# outline to be "near Jerusalem, Israel" and one in East Jerusalem the override's to be Palestinian.
APP_BASE_COUNTRIES = ["IL"]

# Places whose data a position changes. Matched by kind, local name and a point within `within`
# kilometres; every entry must match exactly one place (the build stops otherwise).
#  - Jerusalem: one point for a city whose eastern part the EU counts as occupied Palestinian
#    territory; its country is the one of the photo's place (the app's regions).
#  - Western Sahara's country label: OpenStreetMap names it the Sahrawi Arab Democratic Republic,
#    which the EU doesn't recognise either; it is labelled Western Sahara (the names: Unicode CLDR's
#    region name EH in each language, as macOS shows it).
#  - Kyiv: "Kyjiw" in German, "Kyiv" in English and every other Latin-script language, "Київ" in
#    Ukrainian; Russian, Japanese, Korean and Chinese keep OpenStreetMap's names (Johannes' decision).
#  - The Palestinian territories' country label: "Palestine" in each language (Unicode CLDR's short
#    form of the region name PS, cldr-json cldr-localenames-full territories "PS-alt-short"), as
#    the app names the country (OfflineMap/CountryNames.swift).
#  - Fort Polk, Louisiana: named Fort Johnson in 2023 and renamed Fort Polk by the US Army in 2025
#    under the Trump administration (Army announcement of June 2025, reported e.g. by Texas Public
#    Radio, https://www.tpr.org/military-veterans-issues/2025-06-12/the-army-is-moving-quickly-to-bring-back-the-original-names-of-bases-named-for-confederates);
#    renamings by that administration are not followed, so it keeps its name from before.
WESTERN_SAHARA = {
    "en": "Western Sahara", "de": "Westsahara", "fr": "Sahara occidental", "es": "Sáhara Occidental",
    "it": "Sahara Occidentale", "pt-BR": "Saara Ocidental", "nl": "Westelijke Sahara", "pl": "Sahara Zachodnia",
    "sv": "Västsahara", "da": "Vestsahara", "nb": "Vest-Sahara", "fi": "Länsi-Sahara", "cs": "Západní Sahara",
    "tr": "Batı Sahra", "ru": "Западная Сахара", "uk": "Західна Сахара", "ja": "西サハラ", "ko": "서사하라",
    "zh-Hans": "西撒哈拉", "zh-Hant": "西撒哈拉",
}
KYIV = {
    "en": "Kyiv", "de": "Kyjiw", "fr": "Kyiv", "es": "Kyiv", "it": "Kyiv", "pt-BR": "Kyiv", "nl": "Kyiv", "pl": "Kyiv",
    "sv": "Kyiv", "da": "Kyiv", "nb": "Kyiv", "fi": "Kyiv", "cs": "Kyiv", "tr": "Kyiv", "ru": "Киев", "uk": "Київ",
    "ja": "キーウ", "ko": "키이우", "zh-Hans": "基辅", "zh-Hant": "基輔",
}
PALESTINE = {
    "en": "Palestine", "de": "Palästina", "fr": "Palestine", "es": "Palestina", "it": "Palestina", "pt-BR": "Palestina",
    "nl": "Palestina", "pl": "Palestyna", "sv": "Palestina", "da": "Palæstina", "nb": "Palestina", "fi": "Palestiina",
    "cs": "Palestina", "tr": "Filistin", "ru": "Палестина", "uk": "Палестина", "ja": "パレスチナ", "ko": "팔레스타인",
    "zh-Hans": "巴勒斯坦", "zh-Hant": "巴勒斯坦",
}
PLACE_OVERRIDES = [
    {"kind": "city", "name": "Київ", "at": (50.45, 30.52), "within": 5, "names": KYIV},
    {"kind": "country", "name": "الأراضي الفلسطينية", "at": (31.52, 35.05), "within": 20, "local": "فلسطين",
     "names": PALESTINE, "country": "PS"},
    {"kind": "city", "name": "ירושלים", "at": (31.78, 35.22), "within": 5, "country": ""},
    {"kind": "country", "name": "República Árabe Saharaui Democrática", "at": (23.36, -13.15), "within": 50,
     "local": "Western Sahara", "names": WESTERN_SAHARA, "country": "EH"},
    {"kind": "village", "name": "Fort Polk", "at": (31.05, -93.21), "within": 5, "local": "Fort Johnson",
     "names": {}},
]

# Water labels: the names a feature keeps in every language, matched by its English name (also
# the name of a renaming that isn't followed). Executive Order 14172 (January 20, 2025,
# https://www.federalregister.gov/documents/2025/01/31/2025-02096/restoring-names-that-honor-american-greatness)
# renamed the Gulf of Mexico for US federal use; Executive Order 14422 (August 27, 2026,
# https://www.federalregister.gov/documents/2026/09/02/2026-18020/honoring-the-american-history-of-the-great-lakes-and-renaming-lake-ontario-as-lake-america)
# Lake Ontario; "Arabian Gulf" for the Persian Gulf was floated in May 2025 and not decreed. The
# names below are the build's own (OpenStreetMap's) where it has them, so a later build can't bring
# a renaming in; added: Swedish for the Persian Gulf, Italian, Norwegian and Turkish for the Sea of
# Japan, and in Korean both of its names, "동해 (일본해)" (East Sea, Sea of Japan; Johannes' decision).
WATER_NAMES = [
    {"match": {"Gulf of Mexico", "Gulf of America"}, "local": "Golfo de México", "names": {
        "en": "Gulf of Mexico", "de": "Golf von Mexiko", "fr": "Golfe du Mexique", "es": "Golfo de México",
        "it": "Golfo del Messico", "pt-BR": "Golfo do México", "nl": "Golf van Mexico", "pl": "Zatoka Meksykańska",
        "sv": "Mexikanska golfen", "da": "Mexicanske Golf", "nb": "Mexicogolfen", "fi": "Meksikonlahti",
        "cs": "Mexický záliv", "tr": "Meksika Körfezi", "ru": "Мексиканский залив", "uk": "Мексиканська затока",
        "ja": "メキシコ湾", "ko": "멕시코만", "zh-Hans": "墨西哥湾", "zh-Hant": "墨西哥灣"}},
    {"match": {"Lake Ontario", "Lake America"}, "local": "Lake Ontario", "names": {
        "en": "Lake Ontario", "de": "Ontariosee", "fr": "Lac Ontario", "es": "Lago Ontario", "it": "Lago Ontario",
        "pt-BR": "Lago Ontário", "nl": "Ontariomeer", "pl": "Jezioro Ontario", "sv": "Ontariosjön", "da": "Ontariosøen",
        "fi": "Ontariojärvi", "cs": "Ontarijské jezero", "tr": "Ontario Gölü", "ru": "озеро Онтарио", "uk": "Онтаріо",
        "ja": "オンタリオ湖", "ko": "온타리오호", "zh-Hans": "安大略湖", "zh-Hant": "安大略湖"}},
    {"match": {"Persian Gulf", "Arabian Gulf"}, "names": {
        "en": "Persian Gulf", "de": "Persischer Golf", "fr": "Golfe Persique", "es": "Golfo Pérsico",
        "it": "Golfo Persico", "pt-BR": "Golfo Pérsico", "nl": "Perzische Golf", "pl": "Zatoka Perska",
        "sv": "Persiska viken", "da": "Den Persiske Golf", "nb": "Persiabukten", "fi": "Persianlahti",
        "cs": "Perský záliv", "tr": "Basra Körfezi", "ru": "Персидский залив", "uk": "Перська затока",
        "ja": "ペルシア湾", "ko": "페르시아 만", "zh-Hans": "波斯湾", "zh-Hant": "波斯灣"}},
    {"match": {"Sea of Japan", "East Sea"}, "names": {
        "en": "Sea of Japan", "de": "Japanisches Meer", "fr": "Mer du Japon", "es": "Mar de Japón",
        "it": "Mar del Giappone", "pt-BR": "Mar do Japão", "nl": "Japanse Zee", "pl": "Morze Japońskie",
        "sv": "Japanska havet", "da": "Japanske Hav", "nb": "Japanhavet", "fi": "Japaninmeri", "cs": "Japonské moře",
        "tr": "Japon Denizi", "ru": "Японское море", "uk": "Японське море", "ja": "日本海", "ko": "동해 (일본해)",
        "zh-Hans": "日本海", "zh-Hant": "日本海"}},
]

# Borders the European reading draws that the build lacks: Western Sahara's border with Morocco
# (27°40' N; OpenStreetMap has no country line there). Drawn as a disputed country border along
# the edge Natural Earth's countries (as Germany sees them) share between the two.
ADDED_BORDERS = [("EH", "MA")]

_countries = None
_regions = None
_region_boxes = []
_added_borders = []   # lines of (latitude, longitude)


def political_code(lat, lon):
    """The country of a point in the European reading: a region of the overrides first, then
    Natural Earth's countries as Germany sees them ('' at sea or where neither knows)."""
    return (_regions.code_at(lat, lon) if _regions else "") or _countries.code_at(lat, lon)


def near_region(lat, lon, margin=0.3):
    return any(x0 - margin <= lon <= x1 + margin and y0 - margin <= lat <= y1 + margin for x0, y0, x1, y1 in _region_boxes)


def load_politics(countries_zip, disputed_zip):
    global _countries, _regions, _region_boxes
    _countries = Countries(countries_zip)
    _regions = Countries(disputed_zip, lambda rec: REGION_COUNTRIES.get(rec.get("BRK_NAME")))
    missing = set(REGION_COUNTRIES) - _region_names(disputed_zip)
    if missing:
        sys.exit(f"!! regions of the overrides not in Natural Earth's disputed areas: {sorted(missing)}")
    _region_boxes = list(_regions.boxes)
    _added_borders.clear()
    for a, b in ADDED_BORDERS:
        lines = shared_edges(_countries, a, b)
        if not lines:
            sys.exit(f"!! Natural Earth's countries {a} and {b} share no edge")
        _added_borders.extend(lines)


def shared_edges(countries, a, b):
    """The edges the polygons of countries a and b share, joined into lines of (lat, lon)."""
    def edges(code):
        out = set()
        for c, rings in zip(countries.codes, countries.rings):
            if c == code:
                for ring in rings:
                    for p, q in zip(ring, ring[1:] + ring[:1]):
                        out.add((p, q))
        return out
    ea, eb = edges(a), edges(b)
    common = [(p, q) for p, q in ea if (q, p) in eb or (p, q) in eb]
    # join into runs
    lines = []
    for p, q in sorted(common):
        for line in lines:
            if line[-1] == p:
                line.append(q)
                break
            if line[0] == q:
                line.insert(0, p)
                break
        else:
            lines.append([p, q])
    return [[(y, x) for x, y in line] for line in lines]


def _region_names(disputed_zip):
    z = zipfile.ZipFile(io.BytesIO(disputed_zip))
    return {rec.get("BRK_NAME") for rec in read_dbf(z.read(next(n for n in z.namelist() if n.endswith(".dbf"))))}


def countries_work(points):
    return [political_code(lat, lon) for lat, lon in points]


# --- place file ------------------------------------------------------------------------------

def place_kind(kind, detail):
    if kind in ("country", "region"):
        return PLACE_KINDS.index(kind)
    if detail in ("city", "town", "village", "hamlet"):
        return PLACE_KINDS.index(detail)
    return PLACE_KINDS.index("locality")


def importance_order(p):
    """Within a grid cell: the most important first (lowest min_zoom, then largest population)."""
    return (p["min_zoom10"], -p["rank"], p["name"])


# Places below this min_zoom (* 10) are the major tier, stored as they are; the others (most of
# them villages) are packed per cell with deflate and unpacked by the app when it reads that cell
MAJOR_BELOW = 90


def write_places(path, places, build):
    """Format (little endian), read by OfflineMap/PlaceIndex.swift:
      header (64 bytes): "SBPLACE1", u32 block count, u32 place count, u32 grid columns, u32 grid
        rows, u32 cell size in microdegrees, u32 offset of the block table, u32 offset and u32 length
        of the country codes (two ASCII letters each; a record's country is an index into them, 0
        unknown), u32 offset and u32 length of the languages (comma-separated, a name's language is
        an index into them), u32 the tiers' split (min_zoom * 10), 8 bytes the source build date,
        u32 offset of the regions (0: none)
      block table (24 bytes per block, sorted by cell, then tier): u32 cell (row * columns + column,
        column from longitude -180, row from latitude -90), u8 tier (0 places below the split, 1
        the others), u8 storage (0 as is, 1 raw deflate), 2 bytes zero, u32 place count, u32 offset,
        u32 stored length, u32 length once unpacked
      a block: its records (16 bytes each, the most important first: lowest min_zoom, then largest
        population), then their names. A record: u32 latitude and u32 longitude in microdegrees from
        the cell's south-west corner, u32 offset of its names from the start of the block, u8 kind
        (low 4 bits) and flags (high 4 bits: 1 capital of a country, 2 capital of a region), u8
        min_zoom * 10, u8 population rank, u8 country index.
        Names: varint length + UTF-8 of the name, u8 count, then per language whose name differs:
        u8 language index, varint length + UTF-8
      regions (the political positions' polygons, in order, the first holding a point wins): u32
        count, then each: 2 bytes ISO 3166 code, u16 ring count, per ring u32 point count and the
        points as i32 latitude, i32 longitude in microdegrees
    """
    import zlib
    columns, rows, cell = 360, 180, 1_000_000

    def cell_of(p):
        c = min(columns - 1, max(0, int(math.floor(p["lon"] + 180))))
        r = min(rows - 1, max(0, int(math.floor(p["lat"] + 90))))
        return r, c

    countries = [""] + sorted({p["country"] for p in places if p["country"]})
    country_index = {c: i for i, c in enumerate(countries)}
    assert len(countries) < 256
    groups = {}
    for p in places:
        r, c = cell_of(p)
        groups.setdefault((r * columns + c, 0 if p["min_zoom10"] < MAJOR_BELOW else 1), []).append(p)
    table, payload = bytearray(), bytearray()
    for (cell_id, tier) in sorted(groups):
        members = sorted(groups[(cell_id, tier)], key=importance_order)
        row, col = divmod(cell_id, columns)
        south, west = (row - 90) * 1_000_000, (col - 180) * 1_000_000
        records, names, offsets = bytearray(), bytearray(), {}
        base = 16 * len(members)
        for p in members:
            blob = bytearray()
            encoded = p["name"].encode("utf-8")
            write_varint(len(encoded), blob)
            blob += encoded
            extra = [(i, t) for i, t in enumerate(p["names"]) if t and t != p["name"]]
            blob.append(len(extra))
            for i, t in extra:
                blob.append(i)
                e = t.encode("utf-8")
                write_varint(len(e), blob)
                blob += e
            blob = bytes(blob)
            if blob not in offsets:
                offsets[blob] = base + len(names)
                names += blob
            lat = min(999_999, max(0, round(p["lat"] * 1e6) - south))
            lon = min(999_999, max(0, round(p["lon"] * 1e6) - west))
            records += struct.pack("<IIIBBBB", lat, lon, offsets[blob], p["kind"] | (p["flags"] << 4),
                                   p["min_zoom10"], p["rank"], country_index[p["country"]])
        raw = bytes(records + names)
        if tier == 1:
            packer = zlib.compressobj(9, zlib.DEFLATED, -15, 9)
            stored, storage = packer.compress(raw) + packer.flush(), 1
        else:
            stored, storage = raw, 0
        table += struct.pack("<IBBxxIIII", cell_id, tier, storage, len(members), len(payload), len(stored), len(raw))
        payload += stored
    country_bytes = "".join(countries[1:]).encode("ascii")
    languages = ",".join(LANGUAGES).encode("utf-8")
    table_offset = 64
    countries_offset = table_offset + len(table)
    languages_offset = countries_offset + len(country_bytes)
    payload_offset = languages_offset + len(languages)
    # block offsets are stored relative to the file: shift them past the header and tables
    fixed = bytearray(table)
    for i in range(0, len(fixed), 24):
        struct.pack_into("<I", fixed, i + 12, struct.unpack_from("<I", fixed, i + 12)[0] + payload_offset)
    header = b"SBPLACE1" + struct.pack("<11I", len(groups), len(places), columns, rows, cell, table_offset,
                                       countries_offset, len(country_bytes), languages_offset, len(languages), MAJOR_BELOW)
    # The regions the app takes a photo's country from (`PlaceIndex.region(at:)`): the overrides'
    # regions, then `APP_BASE_COUNTRIES`; the first that holds a point wins
    regions = bytearray()
    entries = [(code, rings) for code, rings in zip(_regions.codes, _regions.rings)]
    entries += [(code, rings) for code, rings in zip(_countries.codes, _countries.rings) if code in APP_BASE_COUNTRIES]
    regions += struct.pack("<I", len(entries))
    for code, rings in entries:
        regions += code.encode("ascii") + struct.pack("<H", len(rings))
        for ring in rings:
            regions += struct.pack("<I", len(ring))
            for x, y in ring:
                regions += struct.pack("<ii", round(y * 1e6), round(x * 1e6))
    regions_offset = payload_offset + len(payload)
    header += build.encode("ascii")[:8].ljust(8, b"\0") + struct.pack("<I", regions_offset)
    assert len(header) == 64, len(header)
    with open(path, "wb") as f:
        f.write(header)
        f.write(fixed)
        f.write(country_bytes)
        f.write(languages)
        f.write(payload)
        f.write(regions)
    return len(places)


def number(v, default=0.0):
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else default


def build_places(source_rows, jobs):
    # The same place comes from several tiles and zooms: keep it once (by its Wikidata id, else
    # by kind, name and position), with the lowest zoom it came from
    unique = {}
    for row in source_rows:
        lat, lon, kind, detail, min_zoom, rank, capital, wikidata, name, names, z = row
        if number(min_zoom, 99) > 11.0:
            continue
        key = ("w", kind, wikidata) if isinstance(wikidata, str) and wikidata else ("p", kind, name, round(lat, 3), round(lon, 3))
        old = unique.get(key)
        if old is None or z < old[10]:
            unique[key] = row
    rows = sorted(unique.values(), key=lambda r: (round(r[0], 6), round(r[1], 6), r[8]))
    print(f"   {len(rows)} places (countries, regions, localities up to min_zoom 11)", file=sys.stderr)
    points = [(r[0], r[1]) for r in rows]
    batches = [points[i:i + 5000] for i in range(0, len(points), 5000)]
    with mp.get_context("fork").Pool(jobs) as pool:
        codes = [c for part in pool.map(countries_work, batches) for c in part]
    places = []
    for r, code in zip(rows, codes):
        lat, lon, kind, detail, min_zoom, rank, capital, wikidata, name, names, z = r
        flags = 0
        if capital in ("yes", 2, "2", True):
            flags |= 1
        elif capital in (4, "4"):
            flags |= 2
        places.append({"lat": lat, "lon": lon, "kind": place_kind(kind, detail), "name": name, "names": names,
                       "min_zoom10": max(0, min(255, round(number(min_zoom) * 10))),
                       "rank": max(0, min(255, int(number(rank)))), "flags": flags, "country": code})
    # A place outside every country polygon (a small island, a coast drawn coarser than the
    # place lies) takes the country of the nearest place that has one, within two degrees
    grid = {}
    for p in places:
        if p["country"]:
            grid.setdefault((int(math.floor(p["lon"])), int(math.floor(p["lat"]))), []).append(p)
    missing = 0
    for p in places:
        if p["country"]:
            continue
        best, best_d = None, 1e9
        gx, gy = int(math.floor(p["lon"])), int(math.floor(p["lat"]))
        for dx in (-2, -1, 0, 1, 2):
            for dy in (-2, -1, 0, 1, 2):
                for q in grid.get((gx + dx, gy + dy), ()):
                    d = (q["lat"] - p["lat"]) ** 2 + ((q["lon"] - p["lon"]) * math.cos(math.radians(p["lat"]))) ** 2
                    if d < best_d:
                        best, best_d = q, d
        if best is not None and best_d <= 4.0:
            p["country"] = best["country"]
        else:
            missing += 1
    print(f"   {missing} places without a country", file=sys.stderr)
    # The political positions' changes to single places, each matching exactly one
    kinds = {k: i for i, k in enumerate(PLACE_KINDS)}
    for rule in PLACE_OVERRIDES:
        lat0, lon0 = rule["at"]
        hits = [p for p in places if p["kind"] == kinds[rule["kind"]] and p["name"] == rule["name"]
                and math.hypot(p["lat"] - lat0, (p["lon"] - lon0) * math.cos(math.radians(lat0))) * 111.2 <= rule["within"]]
        if len(hits) != 1:
            sys.exit(f"!! the override for {rule['name']} matches {len(hits)} places")
        p = hits[0]
        if "country" in rule:
            p["country"] = rule["country"]
        if "local" in rule:
            p["name"] = rule["local"]
        if "names" in rule:
            p["names"] = [rule["names"].get(lang) for lang in LANGUAGES]
        print(f"   override: {rule['name']} → {p['name']} ({p['country'] or 'its photo’s country'})", file=sys.stderr)
    return places


# --- notice ----------------------------------------------------------------------------------

def notice_text(env, map_stats, places_count):
    build = env["PROTOMAPS_BUILD"]
    date = f"{build[:4]}-{build[4:6]}-{build[6:]}"
    return f"""Schnellbild offline map data ({date})

Files:
  {env['MAP_FILE']}
  {env['PLACES_FILE']}

Map data © OpenStreetMap contributors.
https://www.openstreetmap.org/copyright

These files are a Derivative Database of OpenStreetMap, made available under the
Open Data Commons Open Database License (ODbL) 1.0:
https://opendatacommons.org/licenses/odbl/1-0/

Any rights in individual contents of the database are licensed under the Database
Contents License: https://opendatacommons.org/licenses/dbcl/1-0/

Made from the Protomaps OpenStreetMap build of {date} ({env['PROTOMAPS_URL']},
https://protomaps.com), thanks to Protomaps. The files are not a Protomaps product.
That build's earth and water polygons come from osmdata.openstreetmap.de (made by
osmcoastline, also ODbL); its lowest zooms hold Natural Earth data (public domain).

What was filtered (the rest of the build is left out):
- {env['MAP_FILE']}: zoom 0 to {env['MAP_MAX_ZOOM']} ({map_stats['addressed']} tiles). The layers earth,
  water, boundaries and roads, and from landuse only glaciers. Attributes kept: kind,
  kind_detail and disputed for boundaries; kind and min_zoom for water and roads; names
  (name and the app's 20 languages) only on water label points. Geometry as in the build.
- {env['PLACES_FILE']}: {places_count} countries, regions and localities from the places
  layer of the tiles up to zoom {env['PLACES_ZOOM']} (places up to min_zoom {int(env['PLACES_ZOOM']) + 1}), with their
  kind, min_zoom, population rank, capital status and names in the app's 20 languages.
  Each place's country code comes from Natural Earth's countries as Germany sees
  them (public domain, https://www.naturalearthdata.com), by the country its point
  lies in, else the country of the nearest place within two degrees.

Political positions (the map shows the world as the EU and Germany read it): places in
the regions of Natural Earth's disputed areas listed in build_map_data.py
(REGION_COUNTRIES: Crimea and the occupied oblasts as Ukraine, the Golan Heights as
Syria, the West Bank, East Jerusalem and Gaza as Palestinian, Northern Cyprus as Cyprus,
Abkhazia and South Ossetia as Georgia, Transnistria as Moldova, Kosovo, Western Sahara,
Taiwan ...) take that country; country borders with the same country on both sides in
that reading are left out (lines of occupation or of de facto authorities), and the
border of Western Sahara with Morocco is drawn as a disputed country border. A few
place and water names are set (Western Sahara's label, names from before the US
renamings of 2025 and 2026, the internationally used names of seas); each with its
source in build_map_data.py.

How the files are made: Scripts/build_map_data.py in
https://github.com/JohannesHoppe/schnellbild (the source build and the checksums are
pinned in Scripts/map_data.env). The files are published as assets of the release
{env['RELEASE_TAG']} of that repository.
"""


# --- main ------------------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cache", default=os.path.join(ROOT, "build", "map-cache"))
    ap.add_argument("--out", default=os.path.join(ROOT, "build", "map"))
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) - 1))
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--upstream", action="store_true")
    ap.add_argument("--extract", metavar="DIR")
    args = ap.parse_args()
    env = load_env()
    os.makedirs(args.cache, exist_ok=True)
    max_zoom, places_zoom = int(env["MAP_MAX_ZOOM"]), int(env["PLACES_ZOOM"])

    source = Source(env, args.cache, upstream=args.upstream)
    print(f"==> Source: {env['PROTOMAPS_URL']}" + ("" if args.upstream else f" (archived in {env['SOURCE_RELEASE_TAG']})"), file=sys.stderr)
    header, entries = source.entries(max(max_zoom, places_zoom))
    # Each stored tile once (runs and duplicates point at the same bytes)
    stored = {}
    for tile_id, run, length, offset in entries:
        stored.setdefault(offset, (tile_id, offset, length))
    end = max(offset + length for offset, (_, _, length) in stored.items())
    source.ensure_data(header, end)
    chunks = source.chunks()

    print("==> Natural Earth countries and disputed areas", file=sys.stderr)

    def natural_earth(url_key, sha_key):
        name = os.path.basename(env[url_key])
        path = os.path.join(args.cache, name)
        if os.path.exists(path) and sha256_file(path) != env[sha_key]:
            os.remove(path)
        if not os.path.exists(path) and (args.upstream or not fetch_archived(env, name, env[sha_key], path)):
            req = urllib.request.Request(env[url_key], headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=120) as r, open(path, "wb") as f:
                f.write(r.read())
        if sha256_file(path) != env[sha_key]:
            sys.exit(f"!! {name}: SHA-256 mismatch")
        return path

    natural_earth_zips = [natural_earth("NATURAL_EARTH_URL", "NATURAL_EARTH_SHA256"),
                          natural_earth("NATURAL_EARTH_DISPUTED_URL", "NATURAL_EARTH_DISPUTED_SHA256")]

    if args.extract:
        os.makedirs(args.extract, exist_ok=True)
        print(f"==> The archive's files into {args.extract}", file=sys.stderr)
        files = source.write_archive(max(max_zoom, places_zoom), end, args.extract)
        for path in natural_earth_zips:
            with open(path, "rb") as src, open(os.path.join(args.extract, os.path.basename(path)), "wb") as dst:
                dst.write(src.read())
        for name, sha in files:
            print(f"{name} {os.path.getsize(os.path.join(args.extract, name))} {sha}")
        print(f"SOURCE_DIRECTORY={files[0][0]}\nSOURCE_DIRECTORY_SHA256={files[0][1]}")
        print("SOURCE_TILES=" + ",".join(f"{n}:{s}" for n, s in files[1:]))
        return

    os.makedirs(args.out, exist_ok=True)
    countries_zip, disputed_zip = (open(path, "rb").read() for path in natural_earth_zips)
    load_politics(countries_zip, disputed_zip)

    ctx = mp.get_context("fork")
    # Map tiles: every addressed tile up to max_zoom, thinned (the same source bytes thinned once)
    print(f"==> Map tiles, zoom 0 to {max_zoom}", file=sys.stderr)
    limit = first_id(max_zoom + 1)
    # Each stored tile once, thinned at the first tile that shows it; a border is changed by where
    # the tile lies, so a tile whose border was changed may show in that one place only
    first_tile, uses = {}, {}
    for tile_id, run, length, offset in entries:
        if tile_id < limit:
            first_tile.setdefault(offset, (tile_id, length))
            uses[offset] = uses.get(offset, 0) + min(run, limit - tile_id)
    unique = sorted((offset, tile_id, length) for offset, (tile_id, length) in first_tile.items())
    batches = [unique[i:i + 200] for i in range(0, len(unique), 200)]
    thinned = {}  # by the source offset
    with ctx.Pool(args.jobs, initializer=_init_worker, initargs=(chunks,)) as pool:
        for part in pool.imap_unordered(map_work, batches):
            for offset, raw, changed in part:
                if changed and uses[offset] > 1:
                    sys.exit(f"!! a tile shown in {uses[offset]} places had a border changed by its place")
                thinned[offset] = raw
    tiles = []
    for tile_id, run, length, offset in entries:
        if tile_id >= limit:
            break
        for t in range(tile_id, min(tile_id + run, limit)):
            tiles.append((t, thinned[offset]))
    build = env["PROTOMAPS_BUILD"]
    metadata = {
        "name": f"Schnellbild offline map {build}",
        "description": "OpenStreetMap data for Schnellbild's offline map (earth, water, boundaries, roads, glaciers)",
        "attribution": "© OpenStreetMap contributors",
        "license": "ODbL 1.0 (https://opendatacommons.org/licenses/odbl/1-0/), https://www.openstreetmap.org/copyright",
        "source": env["PROTOMAPS_URL"],
        "type": "baselayer",
        "vector_layers": [{"id": n, "fields": {}, "minzoom": 0, "maxzoom": max_zoom} for n in LAYER_ORDER],
    }
    map_path = os.path.join(args.out, env["MAP_FILE"])
    map_stats = write_pmtiles(map_path, tiles, metadata, 0, max_zoom)
    print(f"   {map_stats}", file=sys.stderr)

    print(f"==> Places from the tiles up to zoom {places_zoom}", file=sys.stderr)
    limit = first_id(places_zoom + 1)
    unique = sorted({(offset, tile_id, length) for tile_id, run, length, offset in entries if tile_id < limit and run == 1})
    batches = [[(t, o, l) for o, t, l in unique[i:i + 300]] for i in range(0, len(unique), 300)]
    rows = []
    with ctx.Pool(args.jobs, initializer=_init_worker, initargs=(chunks,)) as pool:
        for i, part in enumerate(pool.imap_unordered(places_work, batches)):
            rows += part
            if i % 200 == 0:
                print(f"   {i} of {len(batches)} batches", file=sys.stderr)
    places = build_places(rows, args.jobs)
    places_path = os.path.join(args.out, env["PLACES_FILE"])
    count = write_places(places_path, places, build)

    notice = notice_text(env, map_stats, count)
    with open(os.path.join(args.out, env["NOTICE_FILE"]), "w", encoding="utf-8") as f:
        f.write(notice)
    with open(os.path.join(ROOT, "Resources", "Licenses", "OpenStreetMap-data.txt"), "w", encoding="utf-8") as f:
        f.write(notice)

    ok = True
    for key, path in (("MAP_SHA256", map_path), ("PLACES_SHA256", places_path)):
        digest = sha256_file(path)
        size = os.path.getsize(path)
        same = digest == env[key]
        ok &= same
        print(f"{os.path.basename(path)}: {size} bytes ({size / 1e6:.1f} MB), SHA-256 {digest}"
              f"{'' if same else f' (map_data.env {key}: {env[key]})'}")
    if args.check and not ok:
        sys.exit("!! the files differ from the ones pinned in map_data.env")


if __name__ == "__main__":
    main()
