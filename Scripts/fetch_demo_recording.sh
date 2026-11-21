#!/bin/bash
# Downloads the demo video's recording (Scripts/demo_video.env) into the
# folder given, each file checked against its SHA-256; then
#   python3 -I Scripts/make_demo_video.py <folder> <out folder>
# makes the website's demo videos and the App Store's app preview from it:
#   Scripts/fetch_demo_recording.sh <folder>
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DEST="${1:?usage: fetch_demo_recording.sh <folder>}"
source "$ROOT/Scripts/fetch_verified.sh"
TAG="$(sed -n 's/^RELEASE_TAG=//p' "$ROOT/Scripts/demo_video.env")"
BASE="$RELEASES/$TAG"
mkdir -p "$DEST"
while read -r name sha; do
    case "$name" in ''|'#'*|RELEASE_TAG=*) continue ;; esac
    fetch_verified "$name" "$BASE/$name" "$sha" "$DEST/$name"
done < "$ROOT/Scripts/demo_video.env"
finished=1
