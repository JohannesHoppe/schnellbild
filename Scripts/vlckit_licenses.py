#!/usr/bin/env python3
"""Lists the licence every VLC module in a VLCKit binary states.

Each module of libVLC has a function `vlc_entry_license__<module>` that returns
its licence text; this reads them from the disassembly (otool) of the arm64
slice. Prints the count per licence and every module that isn't LGPL.

    vlckit_licenses.py <VLCKit binary> [--no-gpl]

With --no-gpl it exits with 1 when any module states the GPL (the build for the
Mac App Store must have none).
"""
import collections
import re
import subprocess
import sys


def licences(binary):
    out = subprocess.run(["otool", "-arch", "arm64", "-tV", binary],
                         capture_output=True, text=True, errors="replace", check=True).stdout
    found, current = {}, None
    for line in out.splitlines():
        entry = re.match(r"^_vlc_entry_license__(\S+):", line)
        if entry:
            current = entry.group(1)
        elif current and "literal pool for:" in line:
            found[current] = line.split("literal pool for:", 1)[1].strip().strip('"')
            current = None
        elif re.match(r"^_\S+:", line):
            current = None
    return found


def kind(text):
    if "Lesser General Public" in text:
        return "LGPL"
    if "General Public" in text:
        return "GPL"
    return text


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    found = licences(sys.argv[1])
    if not found:
        sys.exit("no VLC modules found (not a VLCKit binary?)")
    counts = collections.Counter(kind(t) for t in found.values())
    print(f"{len(found)} modules: " + ", ".join(f"{n} {k}" for k, n in counts.most_common()))
    for module, text in sorted(found.items()):
        if kind(text) != "LGPL":
            print(f"  {module}: {text}")
    if "--no-gpl" in sys.argv and counts.get("GPL"):
        sys.exit(f"{counts['GPL']} modules under the GPL")


main()
