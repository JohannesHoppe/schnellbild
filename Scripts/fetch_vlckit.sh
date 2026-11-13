#!/bin/bash
# Fetches VLCKit (macOS) and vendors it into Vendor/VLCKit.xcframework: our
# build of VideoLAN's VLCKit without VLC's GPL modules (Scripts/build_vlckit_lgpl.sh,
# workflow vlckit-lgpl.yml), published as a pre-release of this repository. The
# download is verified against the SHA-256 pinned here, and the unpacked
# framework against the tree SHA-256 pinned here (both printed by the
# workflow) — it aborts on any mismatch. A framework vendored already is
# used only while its tree SHA-256 still matches (a changed CI cache or local
# copy is fetched again).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
source "$ROOT/Scripts/fetch_verified.sh"

VERSION="3.7.5-lgpl-11"
URL="https://github.com/JohannesHoppe/schnellbild/releases/download/vlckit-$VERSION/VLCKit-lgpl.xcframework.zip"
SHA256="0c73bc1a20d8e93db8edeb0410193aa56e628ead81d1c8269092d6ba603e159f"
# tree_sha256 (fetch_verified.sh) of the unpacked VLCKit.xcframework
TREE_SHA256="fdfb3a2f725f57c7dee0359414149d3479aacbccfd8642380dd73eb9c4a1f327"

# The UnRAR source is vendored alongside (every build that needs VLCKit
# needs it too).
"$ROOT/Scripts/fetch_unrar.sh"

DEST="$ROOT/Vendor"
FRAMEWORK="$DEST/VLCKit.xcframework"

# A VLCKit of one's own (a modified build, as the LGPL allows): with
# SCHNELLBILD_OWN_VLCKIT=1 whatever Vendor/VLCKit.xcframework holds is used
# as it is.
if [ "${SCHNELLBILD_OWN_VLCKIT:-}" = "1" ]; then
    [ -d "$FRAMEWORK" ] || { echo "!! SCHNELLBILD_OWN_VLCKIT=1, but there is no $FRAMEWORK" >&2; exit 1; }
    echo "==> Using the VLCKit.xcframework in Vendor as it is (SCHNELLBILD_OWN_VLCKIT=1)."
    exit 0
fi

# Vendored already, of this version (a stamp next to it says which; it is
# written only once the framework is complete) and unchanged since
STAMP="$DEST/.vlckit-version"
if [ -d "$FRAMEWORK" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$VERSION $SHA256" ]; then
    if [ "$(tree_sha256 "$FRAMEWORK")" = "$TREE_SHA256" ]; then
        echo "==> VLCKit.xcframework $VERSION already vendored — skipping."
        exit 0
    fi
    echo "==> The vendored VLCKit.xcframework differs from $VERSION — fetching it again."
fi

TMP="$(mktemp -d)"
# bash 3.2 reports an aborted expansion (an unset variable) as success once an
# EXIT trap runs: the trap fails unless the script got to its end.
trap 'rm -rf "$TMP"; [ -n "${finished:-}" ] || exit 1' EXIT

# Our own build (vlckit-lgpl.yml), checked against the SHA-256 pinned above
fetch_verified "VLCKit $VERSION (without GPL modules)" "$URL" "$SHA256" "$TMP/VLCKit.zip"

echo "==> Extracting…"
ditto -x -k "$TMP/VLCKit.zip" "$TMP"
SRC="$(find "$TMP" -maxdepth 3 -name 'VLCKit.xcframework' -type d | head -1)"
[ -d "$SRC" ] || { echo "!! VLCKit.xcframework not found in the archive."; exit 1; }
check_tree "VLCKit $VERSION" "$SRC" "$TREE_SHA256"

mkdir -p "$DEST"
rm -f "$STAMP"
rm -rf "$FRAMEWORK"
ditto "$SRC" "$FRAMEWORK"
echo "$VERSION $SHA256" > "$STAMP"
echo "==> Vendored: $FRAMEWORK"
du -sh "$FRAMEWORK" 2>/dev/null | awk '{print "    size: "$1}'
finished=1
