#!/bin/bash
# Fetches the OFFICIAL VideoLAN VLCKit (macOS) xcframework and vendors it into
# Vendor/VLCKit.xcframework. The download is verified against VideoLAN's
# published SHA-256 (from the CocoaPods spec) — it aborts on any mismatch.
# No third-party repo is involved; this is the minimal-trust path.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

VERSION="3.6.0"
URL="https://download.videolan.org/pub/cocoapods/prod/VLCKit-3.6.0-c73b779f-dd8bfdba.tar.xz"
SHA256="23f8f7bb0f8e0321393f51ad5da65ea37ecbc1e148ac2d97fd9f05073ec01075"

DEST="$ROOT/Vendor"
FRAMEWORK="$DEST/VLCKit.xcframework"

if [ -d "$FRAMEWORK" ]; then
    echo "==> VLCKit.xcframework already vendored — skipping (rm -rf Vendor to refetch)."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Downloading official VLCKit $VERSION (macOS) from videolan.org…"
curl -fL --retry 3 -o "$TMP/VLCKit.tar.xz" "$URL"

echo "==> Verifying SHA-256 against VideoLAN's published checksum…"
ACTUAL="$(shasum -a 256 "$TMP/VLCKit.tar.xz" | awk '{print $1}')"
if [ "$ACTUAL" != "$SHA256" ]; then
    echo "!! SHA-256 mismatch — refusing this download."
    echo "   expected $SHA256"
    echo "   got      $ACTUAL"
    exit 1
fi
echo "   ok: $ACTUAL"

echo "==> Extracting…"
tar -xf "$TMP/VLCKit.tar.xz" -C "$TMP"
SRC="$(find "$TMP" -maxdepth 3 -name 'VLCKit.xcframework' -type d | head -1)"
[ -d "$SRC" ] || { echo "!! VLCKit.xcframework not found in the archive."; exit 1; }

mkdir -p "$DEST"
rm -rf "$FRAMEWORK"
ditto "$SRC" "$FRAMEWORK"
echo "==> Vendored: $FRAMEWORK"
du -sh "$FRAMEWORK" 2>/dev/null | awk '{print "    size: "$1}'
