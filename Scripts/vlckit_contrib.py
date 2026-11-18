#!/usr/bin/env python3
"""Checks the third-party libraries VLC's contrib build linked into VLCKit
and writes their licence texts.

    vlckit_contrib.py <VLC tree> <VLCKit binary> <licences file> [--report <file>]

VideoLAN's build links every static library in the contrib prefix
(contrib/*-apple-darwin*/lib/*.a) into VLCKit. For each of them:

- It must be one of LIBRARIES, whose licences were read from their sources;
  a library not in that list fails the build until someone has read its
  licence and added it.
- Each object file of it the binary holds (one of its symbols is defined in
  the binary) is traced to its source file in the library's unpacked source
  (by name, and among sources of the same name by the symbols it defines),
  and that file's licence header is read: a file under the GPL (and not under
  another licence as well) fails the build, as does an object whose source
  isn't found.
- Its licence files (those at the top of its source, and EXTRA_LICENCE_FILES)
  go into the licences file, one section per library; a library without any
  fails the build.

Exits with 1 on any of these, after printing all of them (and writing them to
the report file). Run by Scripts/build_vlckit_lgpl.sh once VLCKit is built.
"""
import collections
import glob
import os
import re
import subprocess
import sys

# Every static library VLC's contrib build may link into VLCKit, by the
# contrib package (contrib/src/<package>/rules.mak) that builds it, with the
# licence its source states (read from the source of the archived contrib
# downloads; files under other licences inside them are checked one by one
# when built).
LIBRARIES = {
    "libavcodec.a": "ffmpeg", "libavformat.a": "ffmpeg", "libavutil.a": "ffmpeg", "libswscale.a": "ffmpeg",  # LGPL-2.1+
    "libBasicUsageEnvironment.a": "live555", "libUsageEnvironment.a": "live555",  # LGPL-2.1+
    "libgroupsock.a": "live555", "libliveMedia.a": "live555",
    "libFLAC.a": "flac",                 # libFLAC: BSD-3-Clause (Xiph); the GPL tools aren't built into it
    "libaom.a": "aom",                   # BSD-2-Clause, AOM patent licence
    "libarchive.a": "libarchive",        # BSD-2-Clause
    "libass.a": "ass",                   # ISC
    "libdav1d.a": "dav1d",               # BSD-2-Clause
    "libdsm.a": "libdsm",                # LGPL-2.1+
    "libdvbpsi.a": "dvbpsi",             # LGPL-2.1+
    "libebml.a": "ebml",                 # LGPL-2.1+
    "libebur128.a": "libebur128",        # MIT
    "libfreetype.a": "freetype2",        # FreeType License (or GPL-2+, at the user's choice; FTL taken)
    "libfribidi.a": "fribidi",           # LGPL-2.1+
    "libgcrypt.a": "gcrypt",             # LGPL-2.1+ (and the BSD / MIT parts its LICENSES lists)
    "libgpg-error.a": "gpg-error",       # LGPL-2.1+
    "libgsm.a": "gsm",                   # its own permissive licence (COPYRIGHT)
    "libharfbuzz.a": "harfbuzz", "libharfbuzz-gpu.a": "harfbuzz", "libharfbuzz-raster.a": "harfbuzz",  # MIT ("Old MIT")
    "libharfbuzz-subset.a": "harfbuzz", "libharfbuzz-vector.a": "harfbuzz",
    "libixml.a": "upnp", "libupnp.a": "upnp",  # BSD-3-Clause
    "libmatroska.a": "matroska",         # LGPL-2.1+
    "libmodplug.a": "modplug",           # public domain
    "libmp3lame.a": "lame",              # LGPL-2+
    "libmpg123.a": "mpg123", "libsyn123.a": "mpg123",  # LGPL-2.1
    "libmysofa.a": "mysofa",             # BSD-3-Clause
    "libnfs.a": "nfs",                   # library LGPL-2.1+, protocol files BSD-2-Clause
    "libogg.a": "ogg",                   # BSD-3-Clause
    "libopenjp2.a": "openjpeg",          # BSD-2-Clause
    "libopus.a": "opus",                 # BSD-3-Clause
    "libplacebo.a": "libplacebo",        # LGPL-2.1+
    "libpng.a": "png", "libpng16.a": "png",  # libpng licence
    "libprotobuf.a": "protobuf", "libprotobuf-lite.a": "protobuf",  # BSD-3-Clause
    "librist.a": "librist",              # BSD-2-Clause
    "libshout.a": "shout",               # LGPL-2+
    "libsmb2.a": "smb2",                 # LGPL-2.1+
    "libsoxr.a": "soxr",                 # LGPL-2.1+
    "libspatialaudio.a": "spatialaudio", # LGPL-2.1+
    "libspeex.a": "speex", "libspeexdsp.a": "speexdsp",  # BSD-3-Clause (Xiph)
    "libssh2.a": "ssh2",                 # BSD-3-Clause
    "libtag.a": "taglib",                # LGPL-2.1 or MPL-1.1
    "libtasn1.a": "libtasn1",            # library LGPL-2.1+ (its GPL tools aren't built into it)
    "libtheora.a": "theora", "libtheoradec.a": "theora", "libtheoraenc.a": "theora",  # BSD-3-Clause
    "libvorbis.a": "vorbis", "libvorbisenc.a": "vorbis", "libvorbisfile.a": "vorbis",  # BSD-3-Clause
    "libvpx.a": "vpx",                   # BSD-3-Clause, WebM patent grant
    "libxml2.a": "libxml2",              # MIT
    "libz.a": "zlib",                    # zlib licence
}
# Libraries that must never be linked: their licence is the GPL, or GPL
# files are part of what VLC's contrib builds of them
FORBIDDEN = {
    "libzvbi.a": "GPL-2 (src/packet-830.*, src/pdc.*), GPL-2+ (src/exp-vtx.c)",
    "libpostproc.a": "GPL-2+ (FFmpeg's LICENSE.md)",
    "libx264.a": "GPL-2+", "libx262.a": "GPL-2+", "libx265.a": "GPL-2+", "liba52.a": "GPL-2+",
    "libfaad.a": "GPL-2+", "libmpeg2.a": "GPL-2+", "libdca.a": "GPL-2+", "libmad.a": "GPL-2+",
    "libdvdcss.a": "GPL-2+", "libdvdread.a": "GPL-2+", "libdvdnav.a": "GPL-2+",
    "libsamplerate.a": "GPL-2+ (before 0.1.9)", "libvncclient.a": "GPL-2+", "libaribb24.a": "LGPL-3+ / GPL",
}
# Packages compiled into another library without a library of their own
COMPILED_IN = {
    "utfcpp": "taglib",  # header-only; Boost Software License 1.0
}
# Licence files below the top of a package's source that its top-level
# files point to
EXTRA_LICENCE_FILES = {
    "freetype2": ["docs/FTL.TXT", "src/bdf/README", "src/pcf/README"],
}
# Credits a licence asks for in the documentation, by package: the FreeType
# License's (docs/FTL.TXT), with the year of the version built
def freetype_credit(folder):
    with open(os.path.join(folder, "include", "freetype", "freetype.h"), encoding="utf-8", errors="replace") as f:
        year = re.search(r"Copyright \(C\) \d{4}-(\d{4})", f.read()).group(1)
    return (f"Portions of this software are copyright © {year} The FreeType Project (https://freetype.org). "
            "All rights reserved.")


CREDITS = {
    "freetype2": freetype_credit,
}
LICENCE_NAME = re.compile(r"^(copying|licen[cs]e|copyright|notice|unlicense|lgpl|patents)", re.IGNORECASE)
SOURCE_SUFFIXES = (".c", ".cc", ".cpp", ".cxx", ".m", ".mm", ".S", ".s", ".asm")


def states_gpl(head):
    """Whether a source file's header puts it under the GPL (or AGPL) alone:
    not the Lesser / Library GPL, and not one licence among others (such as
    BSD "ALTERNATIVELY" GPL)."""
    spdx = re.search(r"SPDX-License-Identifier:\s*([^\n]*)", head)
    if spdx:
        ident = re.sub(r"\*/.*", "", spdx.group(1)).strip()
        if re.search(r"\bOR\b", ident):
            return False
        return bool(re.search(r"(?<![\w-])A?GPL", ident))
    text = " ".join(head.split())
    if "Affero General Public License" in text:
        return True
    if "General Public License" not in text:
        return False
    if re.search(r"Lesser General Public|Library General Public", text):
        return False
    return not re.search(r"alternatively|dual[- ]licen[cs]ed|at your choice", text, re.IGNORECASE)


def archive_members(nm_output):
    """nm's output for a static library (a line per member, "member.o:" as
    Xcode's nm writes it or "…lib.a(member.o):", then "<address> <type>
    <name>" lines) as [(member, [defined external names])], in the
    archive's order: two members of the same name stay apart."""
    members = []
    for line in nm_output.splitlines():
        header = re.match(r"^(?:.*\(([^()]+)\)|(\S[^()]*?)):$", line)
        if header:
            members.append((header.group(1) or os.path.basename(header.group(2)), []))
            continue
        parts = line.split()
        if members and len(parts) == 3 and parts[1] not in "UuIi" and parts[1].isupper():
            members[-1][1].append(parts[2])
    return members


def member_stems(member):
    """The source file names (without suffix) an object can come from:
    foo.o (make), foo.c.o (CMake, Meson), lib_la-foo.o (libtool), and the
    parts of a Meson path flattened with "_" (src_foo.c.o)."""
    name = member[:-2] if member.endswith(".o") else member
    for suffix in SOURCE_SUFFIXES:
        if name.endswith(suffix):
            name = name[:-len(suffix)]
            break
    stems = [name]
    if "_la-" in name:
        stems.append(name.split("_la-", 1)[1])
    parts = name.split("_")
    stems += ["_".join(parts[i:]) for i in range(1, len(parts))]
    return list(dict.fromkeys(s for s in stems if s))


# Folders of a package's source that hold no part of its library: its
# tests, examples, tools and documentation (a source there of the same name
# as one of the library's is not the library's)
NOT_LIBRARY = {"test", "tests", "testing", "checkasm", "example", "examples", "doc", "docs", "tools", "fftools",
               "utils", "contrib", "bin", "programs", "demo", "demos", "fuzz", "fuzzing", "benchmark", "benchmarks"}


def trailing_match(a, b):
    """How many folder names the two paths share at their end."""
    count = 0
    for x, y in zip(reversed(a), reversed(b)):
        if x != y:
            break
        count += 1
    return count


class SourceIndex:
    """The source files of one package's unpacked folder by name without
    suffix, and its object files by name (the build leaves them there: in
    the source folders, or in a build folder that repeats their paths)."""

    def __init__(self, folder):
        self.folder = folder
        self.by_stem = collections.defaultdict(list)
        self.objects = collections.defaultdict(list)
        for root, dirs, files in os.walk(folder):
            parts = os.path.relpath(root, folder).split(os.sep)
            # CMake puts a folder's objects into CMakeFiles/<target>.dir there
            if "CMakeFiles" in parts:
                at = parts.index("CMakeFiles")
                parts = parts[:at] + [p for p in parts[at + 2:]]
            for name in files:
                if name.endswith(SOURCE_SUFFIXES):
                    self.by_stem[os.path.splitext(name)[0]].append(os.path.join(root, name))
                elif name.endswith(".o"):
                    self.objects[name].append(parts)
        self.texts = {}

    def text(self, path):
        if path not in self.texts:
            with open(path, "rb") as f:
                self.texts[path] = f.read().decode("latin-1")
        return self.texts[path]

    def sources(self, member, symbols):
        """The source files the object `member`, defining `symbols`, was
        compiled from, among those of its name: the ones whose folders an
        object file of that name repeats furthest (libavcodec/ac3dsp.c for
        …/libavcodec/ac3dsp.o, not tests/checkasm/ac3dsp.c), then those
        outside tests and tools (NOT_LIBRARY), then those that name one of
        its symbols."""
        names = [s[1:] if s.startswith("_") else s for s in symbols][:50]
        objects = self.objects.get(member, [])
        for stem in member_stems(member):
            candidates = self.by_stem.get(stem)
            if not candidates:
                continue
            flattened = member[:-2] if member.endswith(".o") else member

            def score(path):
                relative = os.path.relpath(path, self.folder)
                parts = os.path.dirname(relative).split(os.sep)
                depth = max((trailing_match(parts, o) for o in objects), default=0)
                # Meson names an object by its source's path, "/" as "_"
                if relative.replace(os.sep, "_") == flattened:
                    depth = max(depth, len(parts) + 1)
                library = not any(p.lower() in NOT_LIBRARY or p.lower().startswith("test") for p in parts)
                naming = any(n in self.text(path) for n in names)
                return (depth, library, naming)
            scores = {c: score(c) for c in candidates}
            best = max(scores.values())
            return [c for c in candidates if scores[c] == best]
        return []


def package_folder(vlc, build, package):
    """The folder VLC's contrib build unpacked `package` into: the first
    prerequisite of its stamp rule (".<package>: <folder> …") in
    contrib/src/<package>/rules.mak."""
    rules = os.path.join(vlc, "contrib", "src", package, "rules.mak")
    folder = package
    if os.path.exists(rules):
        with open(rules, encoding="utf-8", errors="replace") as f:
            stamp = re.search(rf"^\.{re.escape(package)}:\s*(\S+)", f.read(), re.MULTILINE)
        if stamp and "$" not in stamp.group(1):
            folder = stamp.group(1)
    return os.path.join(build, folder)


def licence_files(folder, package):
    """The licence files of a package's source: those at its top, then
    EXTRA_LICENCE_FILES; None when it has none at its top or an extra one
    is missing."""
    if not os.path.isdir(folder):
        return None
    files = sorted(os.path.join(folder, n) for n in os.listdir(folder)
                   if LICENCE_NAME.match(n) and os.path.isfile(os.path.join(folder, n)))
    extra = [os.path.join(folder, p) for p in EXTRA_LICENCE_FILES.get(package, [])]
    if not files or not all(os.path.isfile(f) for f in extra):
        return None
    return files + extra


def nm(path, *options):
    return subprocess.run(["nm", *options, path], capture_output=True, text=True, errors="replace", check=True).stdout


def check(vlc, binary_symbols, libraries, build, nm_archive=None):
    """Checks the static libraries `libraries` (paths) against the names
    defined in the binary. Returns (problems, linked packages {package:
    [library]}, report lines)."""
    nm_archive = nm_archive or (lambda path: nm(path, "--defined-only", "-g"))
    problems, report = [], []
    packages = collections.defaultdict(list)
    indexes = {}
    total = 0
    for library in sorted(libraries):
        name = os.path.basename(library)
        if name in FORBIDDEN:
            problems.append(f"{name}: never to be linked, {FORBIDDEN[name]}")
            continue
        package = LIBRARIES.get(name)
        if package is None:
            problems.append(f"{name}: not one of LIBRARIES in vlckit_contrib.py; read its licence and add it")
            continue
        packages[package].append(name)
        folder = package_folder(vlc, build, package)
        if not os.path.isdir(folder):
            problems.append(f"{name}: its source {folder} isn't there")
            continue
        index = indexes.setdefault(package, SourceIndex(folder))
        linked = 0
        for member, symbols in archive_members(nm_archive(library)):
            # The compiler's helpers every C++ object defines (weak) say
            # nothing about which object the linker took
            if not any(s in binary_symbols for s in symbols if not s.startswith("___clang_")):
                continue
            linked += 1
            sources = index.sources(member, symbols)
            if not sources:
                problems.append(f"{name}({member}): linked, its source not found in {folder}")
                continue
            for source in sources:
                relative = os.path.relpath(source, folder)
                if states_gpl(index.text(source)[:8000]):
                    problems.append(f"{name}({member}): linked, its source {package}/{relative} states the GPL")
                report.append(f"{name}({member}) {package}/{relative}")
        report.append(f"{name}: {linked} objects linked")
        total += linked
    # A binary that holds none of the libraries' objects, or a symbol table
    # not read right, would pass every library unchecked
    if packages and total == 0:
        problems.append("no object of any library found in the binary: the symbols weren't read")
    return problems, packages, report


def write_licences(path, vlc, build, packages, libraries):
    """The licences file: what is linked, then a section per package (a line
    of 80 "=", its name, a line of 80 "="; Schnellbild's About window splits
    it there). Returns the packages without a licence file."""
    missing = []
    rule = "=" * 80
    with open(path, "w", encoding="utf-8") as out:
        out.write("Third-party libraries in VLCKit 3.7.5 (libVLC 3.0.24), built by Scripts/build_vlckit_lgpl.sh\n"
                  "from VideoLAN's contrib build with --disable-gpl. Each keeps its own licence; their texts follow.\n\n"
                  "Static libraries linked into VLCKit (and the library each comes from):\n")
        for library in sorted(libraries, key=str.lower):
            out.write(f"  {library} ({LIBRARIES[library]})\n")
        for package, into in sorted(COMPILED_IN.items()):
            if into in packages:
                out.write(f"  {package}, compiled into {into}\n")
        out.write("\n")
        sections = sorted(set(packages) | {p for p, into in COMPILED_IN.items() if into in packages})
        for package in sections:
            folder = package_folder(vlc, build, package)
            files = licence_files(folder, package)
            if files is None:
                missing.append(package)
                files = []
            out.write(f"{rule}\n{package}\n{rule}\n")
            if package in CREDITS:
                try:
                    out.write(CREDITS[package](folder) + "\n\n")
                except (OSError, AttributeError):
                    missing.append(package)
            for file in files:
                out.write(f"--- {os.path.relpath(file, folder)}\n")
                with open(file, "rb") as f:
                    out.write(f.read().decode("utf-8", errors="replace").rstrip("\n") + "\n\n")
            out.write("\n")
    return missing


def main():
    args = sys.argv[1:]
    report_path = None
    if "--report" in args:
        i = args.index("--report")
        report_path = args[i + 1]
        del args[i:i + 2]
    if len(args) != 3:
        sys.exit(__doc__)
    vlc, binary, licences_path = args
    configs = glob.glob(os.path.join(vlc, "contrib", "*", "config.mak"))
    prefixes = [p for p in glob.glob(os.path.join(vlc, "contrib", "*-apple-darwin*", "lib")) if os.path.isdir(p)]
    if len(configs) != 1 or len(prefixes) != 1:
        sys.exit(f"!! expected one contrib build folder and one prefix: {configs} {prefixes}")
    build = os.path.dirname(configs[0])
    libraries = sorted(glob.glob(os.path.join(prefixes[0], "*.a")))
    if not libraries:
        sys.exit(f"!! no static libraries in {prefixes[0]}")
    symbols = nm(binary, "-arch", "arm64", "--defined-only")
    defined = {line.split()[2] for line in symbols.splitlines() if len(line.split()) == 3}
    # Without the local symbols the binary can't tell which objects are in it
    if sum(1 for line in symbols.splitlines() if " t " in line) < 1000:
        sys.exit("!! the binary has no local symbols: can't tell which objects are linked")
    problems, packages, report = check(vlc, defined, libraries, build)
    linked_names = [os.path.basename(l) for l in libraries if os.path.basename(l) in LIBRARIES]
    missing = write_licences(licences_path, vlc, build, packages, linked_names)
    problems += [f"{package}: no licence file in its source" for package in missing]
    if report_path:
        with open(report_path, "w") as f:
            f.write("\n".join(report + ["", "Problems:"] + problems) + "\n")
    print(f"==> {len(libraries)} static libraries of {len(packages)} packages; licences: {licences_path}")
    for problem in problems:
        print(f"!! {problem}", file=sys.stderr)
    if problems:
        sys.exit(f"!! {len(problems)} problems with the third-party libraries")


if __name__ == "__main__":
    main()
