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
BASE="https://github.com/JohannesHoppe/schnellbild/releases/download/$RELEASE_TAG"
mkdir -p "$DEST"

TMP="$(mktemp -d)"
# bash 3.2 reports an aborted expansion (an unset variable) as success once an
# EXIT trap runs: the trap fails unless the script got to its end.
trap 'rm -rf "$TMP"; [ -n "${finished:-}" ] || exit 1' EXIT

fetch() {
    local file="$1" sha="$2"
    if [ -f "$DEST/$file" ] && [ "$(shasum -a 256 "$DEST/$file" | awk '{print $1}')" = "$sha" ]; then
        echo "==> $file already there — skipping."
        return
    fi
    fetch_verified "$file" "$BASE/$file" "$sha" "$TMP/$file"
    mv "$TMP/$file" "$DEST/$file"
}

fetch "$MAP_FILE" "$MAP_SHA256"
fetch "$PLACES_FILE" "$PLACES_SHA256"

# Files of another map build don't go into the app
for old in "$DEST"/*; do
    [ -e "$old" ] || continue
    case "$(basename "$old")" in
        "$MAP_FILE"|"$PLACES_FILE") ;;
        *) echo "==> Removing $(basename "$old") (not in map_data.env)"; rm -rf "$old" ;;
    esac
done
du -sh "$DEST" 2>/dev/null | awk '{print "    Vendor/Map: "$1}'
finished=1
