"""What the data builders (build_map_data.py, build_globe_data.py) share. Python's standard
library only; the builders run under `python3 -I` and put Scripts/ on sys.path for it."""
import hashlib
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# This repository's release assets: f"{RELEASES}/<tag>/<file>"
RELEASES = "https://github.com/JohannesHoppe/schnellbild/releases/download"


def read_env(name):
    """Scripts/<name>'s KEY=value lines (blank lines and # comments left out)."""
    values = {}
    with open(os.path.join(ROOT, "Scripts", name), encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                key, _, value = line.partition("=")
                values[key] = value
    return values


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()
