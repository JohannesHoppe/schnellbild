#!/bin/bash
# Fetches the OFFICIAL UnRAR source by RARLAB (the RAR author) and vendors it
# into Vendor/unrar, where Package.swift and project.yml compile it into the
# app (Native/CArchives/unrar points there). RARLAB publishes no checksum, so
# the SHA-256 is the one of the download that was reviewed when the version
# was pinned; any other content aborts. UnRAR's license (Vendor/unrar/
# license.txt) allows extracting RAR archives freely; it may not be used to
# make a RAR-compatible archiver.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
source "$ROOT/Scripts/fetch_verified.sh"

VERSION="7.3.2"
URL="https://www.rarlab.com/rar/unrarsrc-$VERSION.tar.gz"
SHA256="f61a1160d6e2ebbda2ad353c8e82f62ab4312f97fde23c6c2c982d25e0014f99"

DEST="$ROOT/Vendor/unrar"
if [ -f "$DEST/.version" ] && [ "$(cat "$DEST/.version")" = "$VERSION" ]; then
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fetch_verified "UnRAR $VERSION source from rarlab.com" "$URL" "$SHA256" "$TMP/unrar.tar.gz"
tar -xzf "$TMP/unrar.tar.gz" -C "$TMP"
[ -f "$TMP/unrar/dll.hpp" ] || { echo "!! unexpected UnRAR archive layout" >&2; exit 1; }
rm -rf "$DEST"
mkdir -p "$ROOT/Vendor"
mv "$TMP/unrar" "$DEST"
echo "$VERSION" > "$DEST/.version"
echo "==> Vendored: $DEST"
