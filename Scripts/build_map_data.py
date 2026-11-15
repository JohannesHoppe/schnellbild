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

  --cache  where the source's directories and tile data are kept between runs
           (default build/map-cache). Tile data is kept as files tiles-<start>-<end>.bin,
           <start>/<end> being byte offsets into the source's tile data section; any set of
           such files is used, the gaps are downloaded in pieces of 256 MiB (about 3.8 GB
           for zoom 0 to 10).
  --out    where the files are written (default build/map)
  --check  fail unless the files' SHA-256 are the ones pinned in map_data.env
"""
import argparse, gzip, hashlib, io, json, math, multiprocessing as mp, os, re, struct, sys, time, urllib.request, zipfile

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
    section as cached chunk files tiles-<start>-<end>.bin (offsets relative to its start)."""

    def __init__(self, env, cache):
        self.url = env["PROTOMAPS_URL"]
        self.dir = os.path.join(cache, env["PROTOMAPS_BUILD"])
        os.makedirs(self.dir, exist_ok=True)
        self.env = env

    def check_head(self):
        size = http_size(self.url)
        if size != int(self.env["PROTOMAPS_SIZE"]):
            sys.exit(f"!! {self.url} has {size} bytes, map_data.env pins {self.env['PROTOMAPS_SIZE']}: not the same build")
        head = http_range(self.url, 0, 16384)
        digest = hashlib.sha256(head).hexdigest()
        if digest != self.env["PROTOMAPS_HEAD_SHA256"]:
            sys.exit(f"!! the source's first 16 KiB have SHA-256 {digest}, map_data.env pins {self.env['PROTOMAPS_HEAD_SHA256']}")
        return head

    def entries(self, max_zoom):
        """Every tile entry up to max_zoom: (tile_id, run_length, length, offset)."""
        path = os.path.join(self.dir, f"directory-z{max_zoom}.json")
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

    def ensure_data(self, header, end):
        """Downloads what the cache lacks of the tile data section up to byte <end>."""
        pos = 0
        piece = 256 << 20
        for start, stop, _ in self.chunks() + [(end, end, None)]:
            while pos < min(start, end):
                upto = min(start, end, pos + piece)
                out = os.path.join(self.dir, f"tiles-{pos}-{upto}.bin")
                print(f"==> Downloading tile data {pos / 1e6:.0f} to {upto / 1e6:.0f} MB of {end / 1e6:.0f} MB", file=sys.stderr)
                http_range(self.url, header["data_offset"] + pos, upto - pos, out)
                pos = upto
            pos = max(pos, stop)
            if pos >= end:
                break


class TileReader:
    def __init__(self, chunks):
        self.chunks = chunks
        self.files = {}

    def read(self, offset, length):
        for start, end, path in self.chunks:
            if start <= offset and offset + length <= end:
                f = self.files.get(path)
                if f is None:
                    f = self.files[path] = open(path, "rb")
                f.seek(offset - start)
                return gzip.decompress(f.read(length))
        raise IOError(f"tile data {offset}+{length} not in the cache")


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


def thin_layer(name, body):
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
        new_tags = []
        for k, val in attrs:
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
        feature += field_bytes(4, geometry)
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


def thin_tile(raw):
    layers = {}
    for f, t, v, _ in fields(raw):
        if f != 3:
            continue
        name = next(bytes(x).decode("utf-8") for ff, tt, x, _ in fields(v) if ff == 1)
        body = thin_layer(name, v)
        if body is not None:
            layers[name] = body
    return b"".join(field_bytes(3, layers[n]) for n in LAYER_ORDER if n in layers)


# --- workers ---------------------------------------------------------------------------------

_reader = None


def _init_worker(chunks):
    global _reader
    _reader = TileReader(chunks)


def map_work(batch):
    return [(tile_id, thin_tile(_reader.read(offset, length))) for tile_id, offset, length in batch]


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


class Countries:
    """Point in polygon over Natural Earth's countries: edges bucketed by quarter degree of
    latitude, countries by their bounding boxes on a one-degree grid."""
    BAND = 0.25

    def __init__(self, zip_bytes):
        z = zipfile.ZipFile(io.BytesIO(zip_bytes))
        shp = next(n for n in z.namelist() if n.endswith(".shp"))
        dbf = next(n for n in z.namelist() if n.endswith(".dbf"))
        shapes = read_shp_polygons(z.read(shp))
        records = read_dbf(z.read(dbf))
        self.codes, self.bands, self.grid = [], [], {}
        for rings, rec in zip(shapes, records):
            code = rec.get("ISO_A2_EH", "-99")
            if not re.fullmatch(r"[A-Z]{2}", code):
                code = rec.get("ISO_A2", "-99")
            if not re.fullmatch(r"[A-Z]{2}", code):
                code = {"KOS": "XK", "CYN": "CY", "SOL": "SO"}.get(rec.get("ADM0_A3"), "")
            if not code or not rings:
                continue
            index = len(self.codes)
            self.codes.append(code)
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


_countries = None


def countries_work(points):
    return [_countries.code_at(lat, lon) for lat, lon in points]


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
        4 bytes zero
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
    header += build.encode("ascii")[:8].ljust(8, b"\0") + b"\0" * 4
    assert len(header) == 64, len(header)
    with open(path, "wb") as f:
        f.write(header)
        f.write(fixed)
        f.write(country_bytes)
        f.write(languages)
        f.write(payload)
    return len(places)


def number(v, default=0.0):
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else default


def build_places(source_rows, countries_zip, jobs):
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
    global _countries
    _countries = Countries(countries_zip)
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
    args = ap.parse_args()
    env = load_env()
    os.makedirs(args.out, exist_ok=True)
    max_zoom, places_zoom = int(env["MAP_MAX_ZOOM"]), int(env["PLACES_ZOOM"])

    source = Source(env, args.cache)
    print(f"==> Source: {env['PROTOMAPS_URL']}", file=sys.stderr)
    source.check_head()
    header, entries = source.entries(max(max_zoom, places_zoom))
    # Each stored tile once (runs and duplicates point at the same bytes)
    stored = {}
    for tile_id, run, length, offset in entries:
        stored.setdefault(offset, (tile_id, offset, length))
    end = max(offset + length for offset, (_, _, length) in stored.items())
    source.ensure_data(header, end)
    chunks = source.chunks()

    print("==> Natural Earth countries", file=sys.stderr)
    ne_path = os.path.join(args.cache, os.path.basename(env["NATURAL_EARTH_URL"]))
    if not os.path.exists(ne_path) or sha256_file(ne_path) != env["NATURAL_EARTH_SHA256"]:
        req = urllib.request.Request(env["NATURAL_EARTH_URL"], headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=120) as r, open(ne_path, "wb") as f:
            f.write(r.read())
    if sha256_file(ne_path) != env["NATURAL_EARTH_SHA256"]:
        sys.exit("!! Natural Earth: SHA-256 mismatch")
    with open(ne_path, "rb") as f:
        countries_zip = f.read()

    ctx = mp.get_context("fork")
    # Map tiles: every addressed tile up to max_zoom, thinned (the same source bytes thinned once)
    print(f"==> Map tiles, zoom 0 to {max_zoom}", file=sys.stderr)
    limit = first_id(max_zoom + 1)
    unique = sorted({(offset, length) for tile_id, run, length, offset in entries if tile_id < limit})
    batches = [unique[i:i + 200] for i in range(0, len(unique), 200)]
    thinned = {}  # by the source offset
    with ctx.Pool(args.jobs, initializer=_init_worker, initargs=(chunks,)) as pool:
        for part in pool.imap_unordered(map_work, [[(o, o, l) for o, l in b] for b in batches]):
            for offset, raw in part:
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
    places = build_places(rows, countries_zip, args.jobs)
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
