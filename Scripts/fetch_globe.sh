#!/bin/bash
# Fetches the globe's files (Scripts/globe_data.env: the heightmap, the night
# sky, the city lights, the clouds, the satellite picture's tiles) from the GitHub release of this repository that holds
# them, into Vendor/Globe (gitignored), each checked against its SHA-256
# pinned in globe_data.env; aborts on any mismatch. Files there already are
# used while their SHA-256 matches. build_app.sh and the Xcode project copy
# Vendor/Globe into the app's Resources/Globe. Making the files:
# Scripts/build_globe_data.py.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
source "$ROOT/Scripts/fetch_verified.sh"
# shellcheck source=globe_data.env
source "$ROOT/Scripts/globe_data.env"

DEST="$ROOT/Vendor/Globe"
BASE="$RELEASES/$RELEASE_TAG"
mkdir -p "$DEST"

fetch_pinned "$DEST" "$BASE" "$HEIGHTMAP_FILE" "$HEIGHTMAP_SHA256"
fetch_pinned "$DEST" "$BASE" "$SKYMAP_FILE" "$SKYMAP_SHA256"
fetch_pinned "$DEST" "$BASE" "$CITYLIGHTS_FILE" "$CITYLIGHTS_SHA256"
fetch_pinned "$DEST" "$BASE" "$CLOUDS_FILE" "$CLOUDS_SHA256"
fetch_pinned "$DEST" "$BASE" "$SATELLITE_FILE" "$SATELLITE_SHA256"
prune_except "$DEST" globe_data.env "$HEIGHTMAP_FILE" "$SKYMAP_FILE" "$CITYLIGHTS_FILE" "$CLOUDS_FILE" "$SATELLITE_FILE"
du -sh "$DEST" 2>/dev/null | awk '{print "    Vendor/Globe: "$1}'
