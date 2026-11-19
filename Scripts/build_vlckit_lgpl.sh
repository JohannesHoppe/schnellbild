#!/bin/bash
# Builds VLCKit for macOS from VideoLAN's source without VLC's modules under the
# GPL and without the modules a viewer of local files never needs (network
# access, streaming, discovery, playlists, helpers that fetch or start
# programs), the VLCKit every Schnellbild build contains (Scripts/fetch_vlckit.sh
# fetches it once published): the Mac App Store's terms don't go with the GPL. Everything else is VideoLAN's own
# build (buildMobileVLCKit.sh, its patches, its third-party libraries built with
# --disable-gpl); only its list of modules to leave out gets those modules too.
#
#   Scripts/build_vlckit_lgpl.sh <work dir>
#
# Leaves <work dir>/vlckit/build/VLCKit.xcframework and checks that no module in
# it states the GPL and none of the left-out ones is in it
# (Scripts/vlckit_licenses.py --no-gpl --local-only). Leaves in <work dir>/dist
# what is published next to it: the licence texts of every third-party
# library VLC's build compiled in (VLCKit-third-party-licenses.txt) and the
# complete source (VLCKit and VLC as built, the third-party libraries' and
# the build tools' downloads). Runs on CI (vlckit-lgpl.yml); takes hours.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
source "$ROOT/Scripts/fetch_verified.sh"
WORK="${1:?usage: build_vlckit_lgpl.sh <work dir>}"

TAG="3.7.5"
COMMIT="a213fd113c5c014556b40765966e77d439f0ddf9"   # the tag; it builds VLC 3.0.24 (6de05adc)
# Modules are deleted by their library names (VLC's modules/*/Makefile.am,
# lib<name>_plugin); buildMobileVLCKit.sh deletes every file whose name
# contains an entry, so each entry is a whole library name.
#
# VLC's GPL modules: Dolby Surround decoder, mono downmix, the dummy
# interface, syslog logging, the RTSP video-on-demand server, stream output's
# cycle and RTP, and the rotate filter (any angle, by hand).
GPL_MODULES="libdolby_surround_decoder_plugin libmono_plugin libdummy_plugin libsyslog_plugin
libvod_rtsp_plugin libstream_out_cycle_plugin libstream_out_rtp_plugin librotate_plugin"
# Modules Schnellbild never needs, which a file someone else made could
# reach: Schnellbild plays local files (access "file", "imem" for
# VLCMedia(stream:)), with the one demuxer VLCSafety names.
# - network access: HTTP (old and new), FTP, SFTP, SMB (libsmb2, libdsm),
#   NFS, RTSP (live555), UDP, TCP, RIST, SAT>IP, MMS, RTP and SDP, FFmpeg's
#   avio (FFmpeg's network protocols), SRT; concat (chains other inputs);
#   VDR (tried first on every local file: in a VDR recording's folder it
#   opens the other files there)
# - stream output to anywhere: every access_output, the standard stream
#   output (HTTP, UDP, files), Chromecast (output and its demuxer)
# - discovery of network services: Bonjour, UPnP, mDNS
# - readers of lists that point elsewhere: playlists (M3U, PLS, XSPF …),
#   adaptive streaming (HLS, DASH, Smooth), directories, NSC
# - stream filters that start programs or fetch: decomp (zcat, bzcat, xzcat
#   on compressed content), HDS; record (writes files)
# - VLC's own archive reader (Schnellbild reads archives itself), the
#   keystores (passwords for network access, also in the keychain), TLS,
#   the folder art finder (opens other files of the folder), Lua scripts
# - outputs and dumps that write files or send: the Flaschen-Taschen video
#   output (UDP), the audio file output, the demux dumper
UNNEEDED_MODULES="libhttp_plugin libhttps_plugin libftp_plugin libsftp_plugin libsmb2_plugin libdsm_plugin
libnfs_plugin liblive555_plugin libudp_plugin libtcp_plugin librist_plugin libsatip_plugin
libaccess_mms_plugin librtp_plugin libsdp_plugin libavio_plugin libaccess_srt_plugin libaccess_concat_plugin libvdr_plugin
libaccess_output_ libstream_out_standard_plugin libstream_out_chromecast_plugin libdemux_chromecast_plugin
libbonjour_plugin libupnp_plugin libmicrodns_plugin
libplaylist_plugin libadaptive_plugin libdirectory_demux_plugin libnsc_plugin
libdecomp_plugin libhds_plugin librecord_plugin
libarchive_plugin libfile_keystore_plugin libkeychain_plugin libmemory_keystore_plugin libsecuretransport_plugin
libgnutls_plugin libfolder_plugin liblua_plugin
libflaschen_plugin libafile_plugin libdemuxdump_plugin"

# The sources come from a pre-release of this repository first (one of our
# earlier builds of this tag published them), each pinned by SHA-256; VideoLAN's
# servers are asked only for what isn't there or can't be reached.
# - VLCKit at the tag (`git archive`), and VLC with VLCKit's patches applied:
#   then buildMobileVLCKit.sh runs with -n (no clone, no `git am`).
# - the third-party libraries' downloads (contrib/tarballs): `make fetch`
#   checks each against contrib/src/<name>/SHA512SUMS and downloads only those
#   missing.
# - the build tools' downloads (extras/tools), checked here against
#   extras/tools/SHA512SUMS; the tools' make downloads those missing.
# VLC's changeset string (`git describe` of the patched tree, which holds the
# date `git am` committed at) is written as src/revision.txt, the one our
# build of SOURCE_RELEASE carries.
SOURCE_RELEASE="vlckit-3.7.5-lgpl-12"
SOURCE_BASE="$RELEASES/$SOURCE_RELEASE"
VLCKIT_SOURCE_SHA256="b4f31dcdbb6c5e9300a81a01abe2dc55f1c67c7cc49f19fa2b7d3c22a9cfcd10"
VLC_SOURCE_SHA256="59d6086a1b3743c3c2d217bc63f06bec23077530c153c8cb697b4d46b79e0fb3"
CONTRIB_SOURCES_SHA256="d37d40482f176d8c615effe8ab70be280721159e1e7563059d8603bb233bdd45"
TOOLS_SOURCES_SHA256="b0e8a2bf63055a76f2d54f1923c7a52755f6deae89adeb772c802d15b30fc07f"
VLC_REVISION="3.0.24-43-g6037734914"

# from_release <file> <sha256>: SOURCE_RELEASE's <file> into $WORK/src; fails
# (for the fallback) when nothing is pinned or the release can't be reached,
# aborts on another SHA-256.
from_release() {
    [ -n "$2" ] || return 1
    mkdir -p "$WORK/src"
    [ -f "$WORK/src/$1" ] && [ "$(sha256_of "$WORK/src/$1")" = "$2" ] && return 0
    curl -fsSL --retry 5 --retry-delay 5 -o "$WORK/src/$1" "$SOURCE_BASE/$1" \
        || { echo "==> $1 not available from $SOURCE_RELEASE, VideoLAN's servers instead" >&2; rm -f "$WORK/src/$1"; return 1; }
    [ "$(sha256_of "$WORK/src/$1")" = "$2" ] \
        || { echo "!! $1 from $SOURCE_RELEASE: SHA-256 mismatch" >&2; exit 1; }
    echo "==> $1 from $SOURCE_RELEASE, SHA-256 ok" >&2
}

mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
cd "$WORK"
# No git repository above the work folder answers for VLC's tree (`git describe`)
export GIT_CEILING_DIRECTORIES="$WORK"
VLC="$WORK/vlckit/libvlc/vlc"
VLCKIT_ARCHIVE="VLCKit-$TAG-source.tar.gz"
VLC_ARCHIVE="vlc-3.0.24-vlckit-$TAG-source.tar.gz"
if [ ! -d vlckit ]; then
    if from_release "$VLCKIT_ARCHIVE" "$VLCKIT_SOURCE_SHA256"; then
        mkdir vlckit
        tar -xzf "src/$VLCKIT_ARCHIVE" -C vlckit --strip-components 1
    else
        git clone --branch "$TAG" --depth 1 https://code.videolan.org/videolan/VLCKit.git vlckit
    fi
fi
if [ -d vlckit/.git ]; then
    [ "$(git -C vlckit rev-parse HEAD)" = "$COMMIT" ] || { echo "!! VLCKit $TAG is not commit $COMMIT" >&2; exit 1; }
fi
if [ ! -d "$VLC" ] && from_release "$VLC_ARCHIVE" "$VLC_SOURCE_SHA256"; then
    mkdir -p "$VLC"
    tar -xzf "src/$VLC_ARCHIVE" -C "$VLC" --strip-components 1
    printf '%s\n' "$VLC_REVISION" > "$VLC/src/revision.txt"
fi
NETWORK_FLAG=""
if [ -d "$VLC" ] && [ ! -d "$VLC/.git" ]; then
    NETWORK_FLAG="-n"
fi
CONTRIB_ARCHIVED=""
if [ -d "$VLC" ] && from_release VLCKit-contrib-sources.tar "$CONTRIB_SOURCES_SHA256"; then
    tar -xf src/VLCKit-contrib-sources.tar -C "$VLC/contrib"
    CONTRIB_ARCHIVED=1
fi
TOOLS_ARCHIVED=""
if [ -d "$VLC" ] && from_release VLC-tools-sources.tar "$TOOLS_SOURCES_SHA256"; then
    TOOLS_ARCHIVED=1
    tar -xf src/VLC-tools-sources.tar -C "$VLC/extras/tools"
    (
        cd "$VLC/extras/tools"
        for file in $(tar -tf "$WORK/src/VLC-tools-sources.tar"); do
            grep -E "  (\./)?$file\$" SHA512SUMS | /usr/bin/shasum -a 512 -c - >/dev/null \
                || { echo "!! $file: not the download extras/tools/SHA512SUMS names" >&2; exit 1; }
        done
    )
fi

# Schnellbild's own changes to VLC (Scripts/vlc-patches/*.patch, each with
# its reason at the top), applied to the tree as VLCKit's patches left it and
# published next to its source (VLC-schnellbild-changes.patch). They need
# VLC's tree before VideoLAN's build starts, so VLC's source must come from
# SOURCE_RELEASE.
[ -d "$VLC" ] || { echo "!! Scripts/vlc-patches need VLC's source from $SOURCE_RELEASE" >&2; exit 1; }
for change in "$ROOT"/Scripts/vlc-patches/*.patch; do
    if patch -d "$VLC" -p1 -R -N -f -s --dry-run -i "$change" >/dev/null 2>&1; then
        echo "==> $(basename "$change"): applied already" >&2
    else
        patch -d "$VLC" -p1 -N -s -i "$change"
        echo "==> $(basename "$change")" >&2
    fi
done

# Into the build script's list of modules it deletes before linking (the list
# ends with output_livehttp); the plugin list it links is made from what is
# left. And libzvbi out of its third-party libraries and VLC's configure.
cd vlckit
[ -f "$WORK/buildMobileVLCKit.sh.orig" ] || cp buildMobileVLCKit.sh "$WORK/buildMobileVLCKit.sh.orig"
python3 -I - "$GPL_MODULES $UNNEEDED_MODULES" <<'EOF'
import sys
path = "buildMobileVLCKit.sh"
text = open(path).read()
end = "    output_livehttp\n    \"\n"
if "    librotate_plugin\n" not in text:
    assert text.count(end) == 1, "the module list in buildMobileVLCKit.sh changed"
    names = "".join(f"    {m}\n" for m in sys.argv[1].split())
    text = text.replace(end, "    output_livehttp\n" + names + "    \"\n")
# libzvbi is left out of the third-party libraries and VLC's zvbi module
# with it: its Teletext packet 8/30 and PDC decoders (src/packet-830.*,
# src/pdc.*) are under the GPL 2. VLC's own Teletext decoder (telx, LGPL)
# decodes Teletext subtitles in its place.
for old, new in (("        --enable-zvbi \\\n", "        --disable-zvbi \\\n"),
                 ('SCARYFLAG="--enable-dvbpsi --enable-avcodec"',
                  'SCARYFLAG="--enable-dvbpsi --enable-avcodec --disable-zvbi --enable-telx"')):
    if new not in text:
        assert text.count(old) == 1, f"buildMobileVLCKit.sh changed: {old!r}"
        text = text.replace(old, new)
open(path, "w").write(text)
EOF
grep -q librotate_plugin buildMobileVLCKit.sh
grep -q libhttps_plugin buildMobileVLCKit.sh
grep -q -e '--disable-zvbi --enable-telx' buildMobileVLCKit.sh
if grep -q -e '--enable-zvbi' buildMobileVLCKit.sh; then echo "!! buildMobileVLCKit.sh still builds libzvbi" >&2; exit 1; fi

# VLC checks every download with GNU's `sha512sum -c`, the check lines on
# standard input; macOS's sha512sum doesn't read them from there, its shasum
# does. VLC's build puts VLC_PATH on its PATH ahead of the system's.
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexec /usr/bin/shasum -a 512 "$@"\n' > "$WORK/bin/sha512sum"
chmod +x "$WORK/bin/sha512sum"
export VLC_PATH="$WORK/bin"

# One make step at a time: VLC's ninja (1.13) joins the jobserver of the make
# that runs it, which macOS's make (3.81) can't share ("read jobs pipe:
# Resource temporarily unavailable"); with -j1 make has no jobserver, and
# ninja still builds each library on every core
export MAKE_JOBS=1

# VLCKIT_OFFLINE=1: VideoLAN's build gets no network. Its sources must have
# come from SOURCE_RELEASE; the build tools' downloads, when SOURCE_RELEASE
# has none, are fetched first (each checked against extras/tools/SHA512SUMS
# by its download rule). Every proxy variable then points at a closed port,
# so curl and git fail at once on any download the build still tries.
OFFLINE_ENV=()
if [ "${VLCKIT_OFFLINE:-}" = 1 ]; then
    if [ "$NETWORK_FLAG" != "-n" ] || [ -z "$CONTRIB_ARCHIVED" ] || [ -d "$WORK/vlckit/.git" ]; then
        echo "!! VLCKIT_OFFLINE: VLCKit, VLC and the contrib downloads must come from $SOURCE_RELEASE" >&2
        exit 1
    fi
    if [ -z "$TOOLS_ARCHIVED" ]; then
        echo "==> The build tools' downloads (not in $SOURCE_RELEASE), before the network goes" >&2
        (cd "$VLC/extras/tools" && ./bootstrap && PATH="$WORK/bin:$PATH" make fetch-all)
    fi
    closed="http://127.0.0.1:9"
    OFFLINE_ENV=(http_proxy="$closed" https_proxy="$closed" HTTP_PROXY="$closed" HTTPS_PROXY="$closed"
                 ALL_PROXY="$closed" all_proxy="$closed" ftp_proxy="$closed" FTP_PROXY="$closed" no_proxy= NO_PROXY=)
    echo "==> buildMobileVLCKit.sh without network" >&2
fi

# macOS (-x), arm64 only: Schnellbild runs on Apple silicon only
env ${OFFLINE_ENV[@]+"${OFFLINE_ENV[@]}"} ./buildMobileVLCKit.sh -vx $NETWORK_FLAG -a aarch64

FRAMEWORK="$(pwd)/build/VLCKit.xcframework"
BINARY="$(find "$FRAMEWORK" -path '*VLCKit.framework/Versions/A/VLCKit' -type f | head -1)"
[ -f "$BINARY" ] || { echo "!! no VLCKit binary in $FRAMEWORK" >&2; exit 1; }

# What is published with it (vlckit-lgpl.yml)
DIST="$WORK/dist"
rm -rf "$DIST"
mkdir -p "$DIST"

# The third-party libraries linked into it (every static library in the
# contrib prefix): each one audited (Scripts/vlckit_contrib.py LIBRARIES),
# no object of it in the binary from a source file under the GPL, and the
# licence texts of each into VLCKit-third-party-licenses.txt. Then the VLC
# modules: every one LGPL, no GPL code by its symbols, none of the left-out
# ones. What was checked stays in $WORK/check (vlckit-lgpl.yml keeps it when
# the build fails).
mkdir -p "$WORK/check"
for library in "$VLC"/contrib/*-apple-darwin*/lib/*.a; do
    nm --defined-only -g "$library" > "$WORK/check/$(basename "$library").nm" 2>&1 || true
done
nm -arch arm64 --defined-only "$BINARY" > "$WORK/check/VLCKit.nm"
(cd "$VLC/contrib" && find . -type f \( -name '*.[cSsm]' -o -name '*.cc' -o -name '*.cpp' -o -name '*.cxx' -o -name '*.asm' \) \
    -not -path './tarballs/*' | LC_ALL=C sort) > "$WORK/check/contrib-sources.txt"
contrib=0
python3 -I "$ROOT/Scripts/vlckit_contrib.py" "$VLC" "$BINARY" "$DIST/VLCKit-third-party-licenses.txt" \
    --report "$WORK/check/contrib-report.txt" || contrib=$?
python3 -I "$ROOT/Scripts/vlckit_licenses.py" "$BINARY" --no-gpl --local-only
[ "$contrib" -eq 0 ] || exit "$contrib"

# The complete source of what was built: VLCKit at the tag with this
# script's change to its build script (the diff), VLC with VLCKit's patches
# applied (buildMobileVLCKit.sh commits them with git am), and the
# third-party libraries' downloads (each checked by VLC's build against its
# SHA-512 in contrib/src/<name>/SHA512SUMS), and the build tools' downloads
# (extras/tools, every tool it knows, also those this runner didn't build).
# Trees and the tools' downloads from SOURCE_RELEASE are published as they
# came; VideoLAN's servers only for what SOURCE_RELEASE doesn't hold.
if [ -d "$WORK/vlckit/.git" ]; then
    git -C "$WORK/vlckit" archive --format=tar.gz --prefix="VLCKit-$TAG/" HEAD > "$DIST/$VLCKIT_ARCHIVE"
else
    cp "$WORK/src/$VLCKIT_ARCHIVE" "$DIST/"
fi
diff -u --label a/buildMobileVLCKit.sh --label b/buildMobileVLCKit.sh \
    "$WORK/buildMobileVLCKit.sh.orig" "$WORK/vlckit/buildMobileVLCKit.sh" > "$DIST/VLCKit-$TAG-build-changes.patch" || [ $? -eq 1 ]
if [ -d "$VLC/.git" ]; then
    git -C "$VLC" archive --format=tar.gz --prefix="vlc-3.0.24-vlckit-$TAG/" HEAD > "$DIST/$VLC_ARCHIVE"
else
    cp "$WORK/src/$VLC_ARCHIVE" "$DIST/"
fi
cat "$ROOT"/Scripts/vlc-patches/*.patch > "$DIST/VLC-schnellbild-changes.patch"
tar -cf "$DIST/VLCKit-contrib-sources.tar" -C "$VLC/contrib" tarballs
if [ -n "$TOOLS_ARCHIVED" ]; then
    cp "$WORK/src/VLC-tools-sources.tar" "$DIST/"
else
    make -C "$VLC/extras/tools" fetch-all
    (cd "$VLC/extras/tools" && tar -cf "$DIST/VLC-tools-sources.tar" $(ls | grep -E '\.(tar\.(gz|bz2|xz)|tgz|zip)$'))
fi
echo "==> $FRAMEWORK"
ls -l "$DIST"
