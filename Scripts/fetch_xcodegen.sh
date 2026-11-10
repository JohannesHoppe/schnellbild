#!/bin/bash
# Fetches XcodeGen (only the UI-test build needs it) from its official GitHub
# release, verified against the SHA-256 GitHub lists for that release asset;
# aborts on any mismatch. Unpacks to build/xcodegen and prints the folder
# holding the binary (for $GITHUB_PATH).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
source "$ROOT/Scripts/fetch_verified.sh"

VERSION="2.46.0"
URL="https://github.com/yonaskolb/XcodeGen/releases/download/$VERSION/xcodegen.zip"
SHA256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"

DEST="$ROOT/build/xcodegen"
# Fetched already, of this version (a stamp next to it says which)
if [ ! -x "$DEST/bin/xcodegen" ] || [ "$(cat "$DEST/.version" 2>/dev/null)" != "$VERSION $SHA256" ]; then
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    fetch_verified "XcodeGen $VERSION" "$URL" "$SHA256" "$TMP/xcodegen.zip"
    unzip -q "$TMP/xcodegen.zip" -d "$TMP/unpacked"
    rm -rf "$DEST"
    mkdir -p "$ROOT/build"
    mv "$TMP/unpacked/xcodegen" "$DEST"
    echo "$VERSION $SHA256" > "$DEST/.version"
fi
"$DEST/bin/xcodegen" --version >&2
echo "$DEST/bin"
