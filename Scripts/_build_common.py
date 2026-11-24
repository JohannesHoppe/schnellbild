"""What the data builders (build_map_data.py, build_globe_data.py) share. Python's standard
library only; the builders run under `python3 -I` and put Scripts/ on sys.path for it."""
import hashlib
import os
import sys
import time
import urllib.error
import urllib.request

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


def download(url, path, sha=None, pins=None, user_agent=None, timeout=120):
    """Downloads <url> to <path> through <path>.part, resuming a .part left behind with a
    Range request (a server that sends the whole file again starts it over), in up to four
    attempts against transient errors. With <sha> the file must have that SHA-256: another
    stops the build (<pins>: the file in Scripts/ that pins it). False when the server
    can't be reached or doesn't have the file; <path> is then not there."""
    part = path + ".part"
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    print(f"==> {url}", file=sys.stderr)
    for attempt in range(4):
        have = os.path.getsize(part) if os.path.exists(part) else 0
        headers = {"User-Agent": user_agent} if user_agent else {}
        if have:
            headers["Range"] = f"bytes={have}-"
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=timeout) as r:
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
            print(f"   {e}", file=sys.stderr)
            if e.code in (403, 404, 410):
                return False
        except Exception as e:  # transient network errors: try again a few times
            print(f"   {e}", file=sys.stderr)
        time.sleep(3 + attempt * 5)
    else:
        return False
    if sha:
        digest = sha256_file(part)
        if digest != sha:
            os.remove(part)
            sys.exit(f"!! {os.path.basename(path)} from {url} has SHA-256 {digest}, {pins} pins {sha}")
    os.replace(part, path)
    return True


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()
