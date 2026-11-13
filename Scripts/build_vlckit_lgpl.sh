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
# complete source (VLCKit and VLC as built, the third-party libraries'
# downloads). Runs on CI (vlckit-lgpl.yml); takes hours.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
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

mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
cd "$WORK"
if [ ! -d vlckit ]; then
    git clone --branch "$TAG" --depth 1 https://code.videolan.org/videolan/VLCKit.git vlckit
fi
[ "$(git -C vlckit rev-parse HEAD)" = "$COMMIT" ] || { echo "!! VLCKit $TAG is not commit $COMMIT" >&2; exit 1; }

# Into the build script's list of modules it deletes before linking (the list
# ends with output_livehttp); the plugin list it links is made from what is left
cd vlckit
python3 -I - "$GPL_MODULES $UNNEEDED_MODULES" <<'EOF'
import sys
path = "buildMobileVLCKit.sh"
text = open(path).read()
end = "    output_livehttp\n    \"\n"
if "    librotate_plugin\n" not in text:
    assert text.count(end) == 1, "the module list in buildMobileVLCKit.sh changed"
    names = "".join(f"    {m}\n" for m in sys.argv[1].split())
    open(path, "w").write(text.replace(end, "    output_livehttp\n" + names + "    \"\n"))
EOF
grep -q librotate_plugin buildMobileVLCKit.sh
grep -q libhttps_plugin buildMobileVLCKit.sh

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

# macOS (-x), arm64 only: Schnellbild runs on Apple silicon only
./buildMobileVLCKit.sh -vx -a aarch64

FRAMEWORK="$(pwd)/build/VLCKit.xcframework"
BINARY="$(find "$FRAMEWORK" -path '*VLCKit.framework/Versions/A/VLCKit' -type f | head -1)"
[ -f "$BINARY" ] || { echo "!! no VLCKit binary in $FRAMEWORK" >&2; exit 1; }
python3 -I "$ROOT/Scripts/vlckit_licenses.py" "$BINARY" --no-gpl --local-only

# What is published with it (vlckit-lgpl.yml)
VLC="$WORK/vlckit/libvlc/vlc"
DIST="$WORK/dist"
rm -rf "$DIST"
mkdir -p "$DIST"

# The licence texts of the third-party libraries. VLC's contrib build
# unpacks each library it builds into a folder of its build folder (the one
# with config.mak) and marks it built with a stamp ".<name>" there; the
# licence files at the top of each such folder are collected, FFmpeg's among
# them. The libraries linked into VLCKit are those in the contrib prefix's lib.
LICENSES="$DIST/VLCKit-third-party-licenses.txt"
{
    echo "Third-party libraries in VLCKit $TAG (libVLC 3.0.24), built by Scripts/build_vlckit_lgpl.sh"
    echo "from VideoLAN's contrib build with --disable-gpl. Each keeps its own licence; their texts follow."
    echo
    echo "Static libraries linked into VLCKit:"
    for library in "$VLC"/contrib/*-apple-darwin*/lib/*.a; do
        if [ -f "$library" ]; then echo "  $(basename "$library")"; fi
    done | LC_ALL=C sort -u
    echo
} > "$LICENSES"
found=0
for config in "$VLC"/contrib/*/config.mak; do
    build="$(dirname "$config")"
    for stamp in "$build"/.[!.]*; do
        name="$(basename "$stamp")"; name="${name#.}"
        package="$build/$name"
        [ -f "$stamp" ] && [ -d "$package" ] || continue
        found=$((found + 1))
        files="$(find "$package" -maxdepth 1 -type f \( -iname 'copying*' -o -iname 'licen[cs]e*' -o -iname 'copyright*' \
            -o -iname 'notice*' -o -iname 'unlicense*' -o -iname 'lgpl*' \) | LC_ALL=C sort)"
        {
            echo "================================================================================"
            echo "$name"
            echo "================================================================================"
            if [ -z "$files" ]; then
                echo "(no licence file at the top of its source; see its source in VLCKit-contrib-sources.tar)"
                echo "!! $name: no licence file at the top of its source" >&2
            fi
            while IFS= read -r file; do
                [ -n "$file" ] || continue
                echo "--- ${file#"$package/"}"
                cat "$file"
                echo
            done <<< "$files"
            echo
        } >> "$LICENSES"
    done
done
[ "$found" -gt 0 ] || { echo "!! no third-party library found in $VLC/contrib" >&2; exit 1; }
grep -q '^ffmpeg$' "$LICENSES" || { echo "!! FFmpeg's licence is missing" >&2; exit 1; }
echo "==> Licences of $found third-party libraries: $LICENSES"

# The complete source of what was built: VLCKit at the tag with this
# script's change to its build script (the diff), VLC with VLCKit's patches
# applied (buildMobileVLCKit.sh commits them with git am), and the
# third-party libraries' downloads (each checked by VLC's build against its
# SHA-512 in contrib/src/<name>/SHA512SUMS)
git -C "$WORK/vlckit" archive --format=tar.gz --prefix="VLCKit-$TAG/" HEAD > "$DIST/VLCKit-$TAG-source.tar.gz"
git -C "$WORK/vlckit" diff -- buildMobileVLCKit.sh > "$DIST/VLCKit-$TAG-build-changes.patch"
git -C "$VLC" archive --format=tar.gz --prefix="vlc-3.0.24-vlckit-$TAG/" HEAD > "$DIST/vlc-3.0.24-vlckit-$TAG-source.tar.gz"
tar -cf "$DIST/VLCKit-contrib-sources.tar" -C "$VLC/contrib" tarballs
echo "==> $FRAMEWORK"
ls -l "$DIST"
