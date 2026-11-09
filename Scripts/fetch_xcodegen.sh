#!/bin/bash
# Fetches XcodeGen (only the UI-test build needs it) from its official GitHub
# release, verified against the SHA-256 GitHub lists for that release asset;
# aborts on any mismatch. Unpacks to build/xcodegen and prints the folder
# holding the binary (for $GITHUB_PATH).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

VERSION="2.46.0"
URL="https://github.com/yonaskolb/XcodeGen/releases/download/$VERSION/xcodegen.zip"
SHA256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"

DEST="$ROOT/build/xcodegen"
if [ ! -x "$DEST/bin/xcodegen" ]; then
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    curl -fsSL --retry 3 -o "$TMP/xcodegen.zip" "$URL"
    ACTUAL="$(shasum -a 256 "$TMP/xcodegen.zip" | awk '{print $1}')"
    if [ "$ACTUAL" != "$SHA256" ]; then
        echo "XcodeGen checksum mismatch: expected $SHA256, got $ACTUAL" >&2
        exit 1
    fi
    unzip -q "$TMP/xcodegen.zip" -d "$TMP/unpacked"
    rm -rf "$DEST"
    mkdir -p "$ROOT/build"
    mv "$TMP/unpacked/xcodegen" "$DEST"
fi
"$DEST/bin/xcodegen" --version >&2
echo "$DEST/bin"
