#!/usr/bin/env python3
"""Lists the licence every VLC module in a VLCKit binary states.

Each module of libVLC has a function `vlc_entry_license__<module>` that returns
its licence text; this finds them in the symbol table (nm) and reads the text
each one loads from the disassembly (otool) of the arm64 slice. Prints the
count per licence and every module that isn't LGPL.

    vlckit_licenses.py <VLCKit binary> [--no-gpl] [--local-only]

With --no-gpl it exits with 1 when any module states the GPL, a licence
can't be read, or the binary defines a symbol of third-party code under the
GPL (GPL_SYMBOLS: libraries and files VLC's contrib build can link in; the
build for the Mac App Store must have no GPL code). Scripts/vlckit_contrib.py
checks the libraries' sources themselves while VLCKit is built.
With --local-only it exits with 1 when any module Schnellbild leaves out
(Scripts/build_vlckit_lgpl.sh: network access, stream output, discovery,
playlists, stream filters that start programs or fetch, keystores …) is in
the binary, or one it needs (REQUIRED) is not.
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


# Modules a local-only build must still have
REQUIRED = {
    "codec_telx": "Teletext subtitles (VLC's own decoder; libzvbi's is left out)",
}


def unneeded(module):
    return ((module.startswith("access_") and module not in LOCAL_ACCESS)
            or module.startswith(UNNEEDED_PREFIXES) or module in UNNEEDED or "chromecast" in module)


# Third-party code under the GPL that VLC's contrib build can link into
# VLCKit, by the symbols it defines (a name; a prefix ending in "*"; "*…*"
# anywhere in the name). The libraries VLC's contrib marks as GPL
# (contrib/src/*/rules.mak, REQUIRE_GPL) and the GPL files of libraries
# that are otherwise not.
GPL_SYMBOLS = {
    # libzvbi: its Teletext packet 8/30 and PDC decoders (src/packet-830.*,
    # src/pdc.*) are GPL-2, src/exp-vtx.c GPL-2+; the whole library stays out
    "libzvbi": ["_vbi_*", "_vbi3_*", "_vlc_entry__codec_libzvbi"],
    # FFmpeg 8.1's AArch64 AC-3 DSP and CRC code (GPL-2+ headers;
    # Scripts/vlc-patches/0006) and libpostproc (GPL by FFmpeg's LICENSE.md)
    "FFmpeg (GPL files)": ["_ff_ac3dsp_init_aarch64", "_ff_ac3_exponent_min_neon", "_ff_ac3_extract_exponents_neon",
                           "_ff_float_to_fixed24_neon", "_ff_ac3_sum_square_butterfly_int32_neon",
                           "_ff_ac3_sum_square_butterfly_float_neon", "_ff_crc32_aarch64",
                           "_postproc_*", "_pp_postprocess", "_pp_get_context"],
    "x264": ["_x264_*"], "x262": ["_x262_*"], "x265": ["_x265_*"],
    "liba52": ["_a52_*"], "faad2": ["_NeAACDec*"], "libmpeg2": ["_mpeg2_*"],
    "libdca": ["_dca_init", "_dca_frame", "_dca_block"], "libmad": ["_mad_*"], "libdvdcss": ["_dvdcss_*"],
    "libdvdread": ["_DVDOpen*", "_DVDReadBlocks"], "libdvdnav": ["_dvdnav_*"],
    "libsamplerate": ["_src_new", "_src_process", "_src_simple"], "libvncclient": ["_rfbInitClient", "_rfbGetClient"],
    "aribb24": ["_arib_*"], "libsidplay2": ["*sidplay2*"],
}


def gpl_symbols(lines):
    """The symbols of third-party code under the GPL among nm's lines
    ("<address> <type> <name>"), by library. A whole name matches a defined
    symbol of any type (the linker makes hidden ones local; they are in the
    binary all the same), a prefix only an external one: local names such as
    FFmpeg's own static mpeg2_* are not a library's API."""
    found = collections.defaultdict(list)
    for line in lines:
        parts = line.split()
        if len(parts) != 3 or parts[1] in "UuIi":
            continue
        name, external = parts[2], parts[1].isupper()
        for library, patterns in GPL_SYMBOLS.items():
            for pattern in patterns:
                if pattern.startswith("*") and pattern.endswith("*"):
                    hit = external and pattern.strip("*") in name
                elif pattern.endswith("*"):
                    hit = external and name.startswith(pattern[:-1])
                else:
                    hit = name == pattern
                if hit:
                    found[library].append(name)
                    break
    return dict(found)


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
    symbols = subprocess.run(["nm", "-arch", "arm64", "--defined-only", sys.argv[1]],
                             capture_output=True, text=True, errors="replace", check=True).stdout
    gpl = gpl_symbols(symbols.splitlines())
    if not found:
        sys.exit("no VLC modules found (not a VLCKit binary?)")
    counts = collections.Counter(kind(t) for t in found.values())
    print(f"{len(found)} modules: " + ", ".join(f"{n} {k}" for k, n in counts.most_common()))
    for module, text in sorted(found.items()):
        if kind(text) != "LGPL":
            print(f"  {module}: {text}")
    for library, names in sorted(gpl.items()):
        print(f"GPL code of {library}: {len(names)} symbols, e.g. " + ", ".join(sorted(names)[:4]))
    left_in = sorted(m for m in found if unneeded(m))
    if left_in:
        print(f"{len(left_in)} modules Schnellbild leaves out: " + ", ".join(left_in))
    if "--no-gpl" in sys.argv and (counts.get("GPL") or counts.get("unknown") or gpl):
        sys.exit(f"{counts.get('GPL', 0)} modules under the GPL, {counts.get('unknown', 0)} unknown, "
                 f"GPL code of {len(gpl)} third-party libraries")
    missing = sorted(m for m in REQUIRED if m not in found)
    for module in missing:
        print(f"missing: {module}, {REQUIRED[module]}")
    if "--local-only" in sys.argv and (left_in or missing):
        sys.exit(f"{len(left_in)} modules in it that Schnellbild leaves out, {len(missing)} missing")


if __name__ == "__main__":
    main()
