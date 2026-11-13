#!/usr/bin/env python3
"""Lists the licence every VLC module in a VLCKit binary states.

Each module of libVLC has a function `vlc_entry_license__<module>` that returns
its licence text; this finds them in the symbol table (nm) and reads the text
each one loads from the disassembly (otool) of the arm64 slice. Prints the
count per licence and every module that isn't LGPL.

    vlckit_licenses.py <VLCKit binary> [--no-gpl] [--local-only]

With --no-gpl it exits with 1 when any module states the GPL, or a licence
can't be read (the build for the Mac App Store must have no GPL module).
With --local-only it exits with 1 when any module Schnellbild leaves out
(Scripts/build_vlckit_lgpl.sh: network access, stream output, discovery,
playlists, stream filters that start programs or fetch, keystores …) is in
the binary.
"""
import collections
import re
import subprocess
import sys


def licences(binary):
    # The names from the symbol table: the linker may fold the identical
    # functions of many modules into one, which the disassembly then names
    # once only
    symbols = subprocess.run(["nm", "-arch", "arm64", binary],
                             capture_output=True, text=True, errors="replace", check=True).stdout
    entries = {}
    for line in symbols.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[2].startswith("_vlc_entry_license__"):
            entries[parts[2][len("_vlc_entry_license__"):]] = int(parts[0], 16)
    # The text each function's address loads (adrp + add, "literal pool for")
    code = subprocess.run(["otool", "-arch", "arm64", "-tV", binary],
                          capture_output=True, text=True, errors="replace", check=True).stdout
    wanted = set(entries.values())
    texts, start, seen = {}, None, 0
    for line in code.splitlines():
        address = re.match(r"^([0-9a-f]{8,})\s", line)
        if not address:
            continue
        at = int(address.group(1), 16)
        if at in wanted:
            start, seen = at, 0
        elif start is not None:
            seen += 1
            if seen > 3:
                start = None
        if start is not None and "literal pool for:" in line:
            texts[start] = line.split("literal pool for:", 1)[1].strip().strip('"')
            start = None
    return {module: texts.get(at, "unknown") for module, at in entries.items()}


# Modules by their names in the binary (vlc_entry__<name>: the source's path
# in VLC's modules/, "/" as "_"). Access modules: only these local ones.
LOCAL_ACCESS = {
    "access_attachment",     # attachment:// (fonts and pictures inside a Matroska file)
    "access_idummy",         # vlc:// (nop, pause, quit)
    "access_imem_access",    # imem://, VLCMedia(stream:) (libvlc_media_new_callbacks)
    "access_libfilesystem",  # file://
    "access_timecode",       # timecode:// (a generated clock)
}
UNNEEDED_PREFIXES = ("access_output_", "services_discovery_", "stream_out_chromecast_", "demux_adaptive_",
                     "demux_playlist_", "keystore_", "stream_extractor_", "lua")
UNNEEDED = {
    "stream_out_libstream_out_standard", "demux_directory", "demux_nsc", "demux_demuxdump",
    "stream_filter_decomp", "stream_filter_hds_libhds", "stream_filter_record", "misc_libsecuretransport",
    "misc_gnutls", "meta_engine_folder", "video_output_flaschen", "audio_output_libafile",
}


def unneeded(module):
    return ((module.startswith("access_") and module not in LOCAL_ACCESS)
            or module.startswith(UNNEEDED_PREFIXES) or module in UNNEEDED or "chromecast" in module)


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
    left_in = sorted(m for m in found if unneeded(m))
    if left_in:
        print(f"{len(left_in)} modules Schnellbild leaves out: " + ", ".join(left_in))
    if "--no-gpl" in sys.argv and (counts.get("GPL") or counts.get("unknown")):
        sys.exit(f"{counts.get('GPL', 0)} modules under the GPL, {counts.get('unknown', 0)} unknown")
    if "--local-only" in sys.argv and left_in:
        sys.exit(f"{len(left_in)} modules in it that Schnellbild leaves out")


main()
