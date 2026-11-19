#!/bin/bash
# Downloads the screenshots' world trip (Scripts/world_photos.env) into the
# folder given, each file checked against its SHA-256:
#   Scripts/fetch_world_photos.sh <folder>
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DEST="${1:?usage: fetch_world_photos.sh <folder>}"
source "$ROOT/Scripts/fetch_verified.sh"
TAG="$(sed -n 's/^RELEASE_TAG=//p' "$ROOT/Scripts/world_photos.env")"
BASE="$RELEASES/$TAG"
mkdir -p "$DEST"
while read -r name sha; do
    case "$name" in ''|'#'*|RELEASE_TAG=*) continue ;; esac
    fetch_verified "$name" "$BASE/$name" "$sha" "$DEST/$name"
done < "$ROOT/Scripts/world_photos.env"
