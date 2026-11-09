#!/bin/bash
# Fetches the OFFICIAL VideoLAN VLCKit (macOS) xcframework and vendors it into
# Vendor/VLCKit.xcframework. The download is verified against VideoLAN's
# published SHA-256 (from the CocoaPods spec) — it aborts on any mismatch.
# No third-party repo is involved; this is the minimal-trust path.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
source "$ROOT/Scripts/fetch_verified.sh"

VERSION="3.6.0"
URL="https://download.videolan.org/pub/cocoapods/prod/VLCKit-3.6.0-c73b779f-dd8bfdba.tar.xz"
SHA256="23f8f7bb0f8e0321393f51ad5da65ea37ecbc1e148ac2d97fd9f05073ec01075"

# The UnRAR source is vendored alongside (every build that needs VLCKit
# needs it too).
"$ROOT/Scripts/fetch_unrar.sh"

DEST="$ROOT/Vendor"
FRAMEWORK="$DEST/VLCKit.xcframework"

if [ -d "$FRAMEWORK" ]; then
    echo "==> VLCKit.xcframework already vendored — skipping (rm -rf Vendor to refetch)."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Checked against VideoLAN's published checksum
fetch_verified "official VLCKit $VERSION (macOS) from videolan.org" "$URL" "$SHA256" "$TMP/VLCKit.tar.xz"

echo "==> Extracting…"
tar -xf "$TMP/VLCKit.tar.xz" -C "$TMP"
SRC="$(find "$TMP" -maxdepth 3 -name 'VLCKit.xcframework' -type d | head -1)"
[ -d "$SRC" ] || { echo "!! VLCKit.xcframework not found in the archive."; exit 1; }

mkdir -p "$DEST"
rm -rf "$FRAMEWORK"
ditto "$SRC" "$FRAMEWORK"
echo "==> Vendored: $FRAMEWORK"
du -sh "$FRAMEWORK" 2>/dev/null | awk '{print "    size: "$1}'
