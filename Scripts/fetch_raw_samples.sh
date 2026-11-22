#!/bin/bash
# Downloads the camera RAW samples PictureDecoderTests decodes
# (Scripts/raw_samples.env: raw.pixls.us files under CC0 1.0, kept unchanged
# as a pre-release of this repository) into the folder given (default
# Vendor/RawSamples), each file checked against its SHA-256; a file there
# already is kept while its SHA-256 matches. Test data only, never in the app.
#   Scripts/fetch_raw_samples.sh [<folder>]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DEST="${1:-$ROOT/Vendor/RawSamples}"
source "$ROOT/Scripts/fetch_verified.sh"
TAG="$(sed -n 's/^RELEASE_TAG=//p' "$ROOT/Scripts/raw_samples.env")"
mkdir -p "$DEST"
while read -r name sha; do
    case "$name" in ''|'#'*|RELEASE_TAG=*) continue ;; esac
    fetch_pinned "$DEST" "$RELEASES/$TAG" "$name" "$sha"
done < "$ROOT/Scripts/raw_samples.env"
