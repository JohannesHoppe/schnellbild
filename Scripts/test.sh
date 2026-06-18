#!/bin/bash
# Runs the SwiftPM unit tests. VLCKit is a binary framework linked into the
# module, but SwiftPM doesn't embed it into the .xctest bundle — and its
# install name is @loader_path/../Frameworks/… — so we copy it in before
# running, then test without rebuilding.
set -euo pipefail
cd "$(dirname "$0")/.."

./Scripts/fetch_vlckit.sh

swift build --build-tests
BIN="$(swift build --show-bin-path)"
XCTEST="$BIN/SchnellbildPackageTests.xctest"
mkdir -p "$XCTEST/Contents/Frameworks"
ditto "$BIN/VLCKit.framework" "$XCTEST/Contents/Frameworks/VLCKit.framework"

swift test --skip-build
