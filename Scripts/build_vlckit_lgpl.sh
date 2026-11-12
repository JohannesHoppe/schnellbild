#!/bin/bash
# Builds VLCKit for macOS from VideoLAN's source, the same version Schnellbild
# vendors (Scripts/fetch_vlckit.sh), without VLC's modules under the GPL: the
# Mac App Store's terms don't go with the GPL. Everything else is VideoLAN's own
# build (buildMobileVLCKit.sh, its patches, its third-party libraries built with
# --disable-gpl); only its list of modules to leave out gets the GPL ones too.
#
#   Scripts/build_vlckit_lgpl.sh <work dir>
#
# Leaves <work dir>/vlckit/build/VLCKit.xcframework and checks that no module in
# it states the GPL (Scripts/vlckit_licenses.py). Runs on CI (vlckit-lgpl.yml);
# takes hours.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
WORK="${1:?usage: build_vlckit_lgpl.sh <work dir>}"

TAG="3.6.0"
COMMIT="c73b779f2d1e3d3c1598a27811679ce2c1a005db"   # the tag; libVLC dd8bfdba, as in fetch_vlckit.sh's package
# VLC's GPL modules in VLCKit 3.6.0 (their build names, VLC's modules/*/Makefile.am):
# Dolby Surround decoder, mono downmix, the dummy interface, syslog logging, the
# RTSP video-on-demand server, stream output's cycle and RTP, and the rotate
# filter (any angle, by hand). Schnellbild only plays local files and needs none
# of them.
GPL_MODULES="libdolby_surround_decoder_plugin libmono_plugin libdummy_plugin libsyslog_plugin
libvod_rtsp_plugin libstream_out_cycle_plugin libstream_out_rtp_plugin librotate_plugin"

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
python3 -I - "$GPL_MODULES" <<'EOF'
import sys
path = "buildMobileVLCKit.sh"
text = open(path).read()
end = "    output_livehttp\n    \"\n"
assert text.count(end) == 1, "the module list in buildMobileVLCKit.sh changed"
names = "".join(f"    {m}\n" for m in sys.argv[1].split())
open(path, "w").write(text.replace(end, "    output_livehttp\n" + names + "    \"\n"))
EOF
grep -q librotate_plugin buildMobileVLCKit.sh

# Fixes of our own for VLC 3.0's third-party libraries with today's SDK
# (Scripts/vlckit-patches): the build script applies every patch in
# libvlc/patches to VLC, in name order, after VideoLAN's own
cp "$ROOT"/Scripts/vlckit-patches/*.patch libvlc/patches/

# VLC checks every download with GNU's `sha512sum -c`, the check lines on
# standard input; macOS's sha512sum doesn't read them from there, its shasum
# does. VLC's build puts VLC_PATH on its PATH ahead of the system's.
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexec /usr/bin/shasum -a 512 "$@"\n' > "$WORK/bin/sha512sum"
chmod +x "$WORK/bin/sha512sum"
export VLC_PATH="$WORK/bin"

# macOS (-x), arm64 only: Schnellbild runs on Apple silicon only
./buildMobileVLCKit.sh -vx -a aarch64

FRAMEWORK="$(pwd)/build/VLCKit.xcframework"
BINARY="$(find "$FRAMEWORK" -path '*VLCKit.framework/Versions/A/VLCKit' -type f | head -1)"
[ -f "$BINARY" ] || { echo "!! no VLCKit binary in $FRAMEWORK" >&2; exit 1; }
python3 -I "$ROOT/Scripts/vlckit_licenses.py" "$BINARY" --no-gpl
echo "==> $FRAMEWORK"
