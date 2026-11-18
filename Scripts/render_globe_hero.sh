#!/bin/bash
# Renders the website's hero background from the app's globe (see
# Scripts/render_globe_hero.swift for the arguments). Builds the renderer
# from the OfflineMap module's sources into build/globe-hero/ first; needs
# the globe's and the map's data (Scripts/fetch_globe.sh, Scripts/fetch_map.sh)
# and the world trip's photos (Scripts/fetch_world_photos.sh build/world-photos).
#   Scripts/render_globe_hero.sh --camera=… --date=… --size=1200x500 --out=hero.jpg
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BUILD="$ROOT/build/globe-hero"
mkdir -p "$BUILD"
SOURCES=()
for f in CountryNames Gzip MapLabels MapRenderer MapStyle Mercator PMTiles PlaceIndex VectorTile GlobeMath GlobeData GlobeShaders GlobeRenderer; do
    SOURCES+=("$ROOT/OfflineMap/$f.swift")
done
newest="$(ls -t "${SOURCES[@]}" "$ROOT/Scripts/render_globe_hero.swift" | head -1)"
if [ ! -x "$BUILD/render" ] || [ "$newest" -nt "$BUILD/render" ]; then
    # Top-level code only runs from a file named main.swift among several
    cp "$ROOT/Scripts/render_globe_hero.swift" "$BUILD/main.swift"
    xcrun swiftc -O -target arm64-apple-macos15.0 -swift-version 5 "${SOURCES[@]}" "$BUILD/main.swift" -o "$BUILD/render"
fi
"$BUILD/render" "$ROOT" "$@"
finished=1
