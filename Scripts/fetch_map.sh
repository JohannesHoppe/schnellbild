#!/bin/bash
# Fetches the offline map's files (Scripts/map_data.env: the map's PMTiles and
# the place index) from the GitHub release of this repository that holds
# them, into Vendor/Map (gitignored), each checked against its SHA-256 pinned
# in map_data.env; aborts on any mismatch. Files there already are used while
# their SHA-256 matches. build_app.sh and the Xcode project copy Vendor/Map
# into the app's Resources/Map. Making the files: Scripts/build_map_data.py.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
source "$ROOT/Scripts/fetch_verified.sh"
# shellcheck source=map_data.env
source "$ROOT/Scripts/map_data.env"

DEST="$ROOT/Vendor/Map"
BASE="$RELEASES/$RELEASE_TAG"
mkdir -p "$DEST"

fetch_pinned "$DEST" "$BASE" "$MAP_FILE" "$MAP_SHA256"
fetch_pinned "$DEST" "$BASE" "$PLACES_FILE" "$PLACES_SHA256"
prune_except "$DEST" map_data.env "$MAP_FILE" "$PLACES_FILE"
du -sh "$DEST" 2>/dev/null | awk '{print "    Vendor/Map: "$1}'
