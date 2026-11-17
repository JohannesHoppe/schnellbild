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

fetch "$HEIGHTMAP_FILE" "$HEIGHTMAP_SHA256"
fetch "$SKYMAP_FILE" "$SKYMAP_SHA256"
fetch "$CITYLIGHTS_FILE" "$CITYLIGHTS_SHA256"
fetch "$CLOUDS_FILE" "$CLOUDS_SHA256"
fetch "$SATELLITE_FILE" "$SATELLITE_SHA256"

# Files of another build don't go into the app
for old in "$DEST"/*; do
    [ -e "$old" ] || continue
    case "$(basename "$old")" in
        "$HEIGHTMAP_FILE"|"$SKYMAP_FILE"|"$CITYLIGHTS_FILE"|"$CLOUDS_FILE"|"$SATELLITE_FILE") ;;
        *) echo "==> Removing $(basename "$old") (not in globe_data.env)"; rm -rf "$old" ;;
    esac
done
du -sh "$DEST" 2>/dev/null | awk '{print "    Vendor/Globe: "$1}'
finished=1
