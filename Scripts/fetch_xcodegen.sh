#!/bin/bash
# Fetches XcodeGen (only the UI-test build needs it), verified against the
# SHA-256 GitHub lists for its official release asset; aborts on any mismatch.
# The same zip is kept as an asset of this repository's pre-release
# build-deps, downloaded first; the official release is the fallback. Unpacks to build/xcodegen and prints the folder
# holding the binary (for $GITHUB_PATH).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
source "$ROOT/Scripts/fetch_verified.sh"

VERSION="2.46.0"
URL="https://github.com/JohannesHoppe/schnellbild/releases/download/build-deps/xcodegen-$VERSION.zip"
UPSTREAM_URL="https://github.com/yonaskolb/XcodeGen/releases/download/$VERSION/xcodegen.zip"
SHA256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"
# tree_sha256 (fetch_verified.sh) of the unpacked folder: a copy already there
# (a CI cache, an earlier run) runs only while it matches
TREE_SHA256="fb3491e4c04137cc447b4bbe8d57f884f7caa43fd36629f5b4276258aee6f327"

DEST="$ROOT/build/xcodegen"
if [ ! -x "$DEST/bin/xcodegen" ] || [ "$(cat "$DEST/.version" 2>/dev/null)" != "$VERSION $SHA256" ] \
    || [ "$(tree_sha256 "$DEST")" != "$TREE_SHA256" ]; then
    TMP="$(mktemp -d)"
    # bash 3.2 reports an aborted expansion (an unset variable) as success
    # once an EXIT trap runs: the trap fails unless the script got to its end.
    trap 'rm -rf "$TMP"; [ -n "${finished:-}" ] || exit 1' EXIT
    fetch_verified "XcodeGen $VERSION" "$URL" "$SHA256" "$TMP/xcodegen.zip" "$UPSTREAM_URL"
    unzip -q "$TMP/xcodegen.zip" -d "$TMP/unpacked"
    check_tree "XcodeGen $VERSION" "$TMP/unpacked/xcodegen" "$TREE_SHA256"
    rm -rf "$DEST"
    mkdir -p "$ROOT/build"
    mv "$TMP/unpacked/xcodegen" "$DEST"
    echo "$VERSION $SHA256" > "$DEST/.version"
fi
"$DEST/bin/xcodegen" --version >&2
echo "$DEST/bin"
finished=1
