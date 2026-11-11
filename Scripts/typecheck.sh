#!/bin/bash
# Typechecks the app, the unit tests and the UI tests with only the Command
# Line Tools installed (no Xcode): SwiftUI's @State macro and XCTest are
# replaced by stand-ins from Scripts/typecheck/. Catches compile errors
# before a push; building and running the tests stays with CI.
set -euo pipefail
cd "$(dirname "$0")/.."
./Scripts/fetch_vlckit.sh >/dev/null
SDK=$(xcrun --show-sdk-path)
VLC=Vendor/VLCKit.xcframework/macos-arm64_x86_64
WORK=$(mktemp -d)
# bash 3.2 reports an aborted expansion (an unset variable) as success once an
# EXIT trap runs: the trap fails unless the script got to its end.
trap 'rm -rf "$WORK"; [ -n "${finished:-}" ] || exit 1' EXIT
FLAGS=(-typecheck -sdk "$SDK" -target arm64-apple-macos15.0 -F "$VLC" -I Native/CArchives/include -swift-version 5)

mkdir -p "$WORK/app" "$WORK/unit" "$WORK/ui" "$WORK/mod"
for f in Schnellbild/*.swift; do perl -pe 's/\@State\b/\@_State/g; s/\bState\(initialValue/_State(initialValue/g' "$f" > "$WORK/app/$(basename "$f")"; done
for f in Tests/SchnellbildTests/*.swift; do
  sed -e 's/^import XCTest$/import Foundation/' -e '/^@testable import Schnellbild$/d' "$f" > "$WORK/unit/$(basename "$f")"
done
for f in UITests/*.swift; do sed 's/^import XCTest$/import Foundation/' "$f" > "$WORK/ui/$(basename "$f")"; done

status=0
echo "== VLCFrames (shared by the app and the thumbnail extension)"
swiftc -emit-module -emit-module-path "$WORK/mod/VLCFrames.swiftmodule" -module-name VLCFrames -parse-as-library \
  "${FLAGS[@]/-typecheck/}" VLCFrames/*.swift || status=1
echo "== VideoContainers (the media extension's parsers, a module for the tests)"
swiftc -emit-module -emit-module-path "$WORK/mod/VideoContainers.swiftmodule" -module-name VideoContainers -parse-as-library -enable-testing \
  "${FLAGS[@]/-typecheck/}" FormatReader/MatroskaIndex.swift FormatReader/TransportIndex.swift || status=1
FLAGS+=(-I "$WORK/mod")
echo "== media extension"
swiftc "${FLAGS[@]}" -parse-as-library FormatReader/MatroskaIndex.swift FormatReader/TransportIndex.swift FormatReader/FormatReader.swift || status=1
echo "== thumbnail extension"
swiftc "${FLAGS[@]}" -parse-as-library ThumbnailExtension/*.swift || status=1
echo "== app"
swiftc "${FLAGS[@]}" Scripts/typecheck/StateShim.swift "$WORK"/app/*.swift || status=1
echo "== unit tests (with the app)"
swiftc "${FLAGS[@]}" Scripts/typecheck/StateShim.swift Scripts/typecheck/XCTestShim.swift \
  "$WORK"/app/*.swift "$WORK"/unit/*.swift -module-name Schnellbild || status=1
echo "== UI tests"
swiftc "${FLAGS[@]}" Scripts/typecheck/XCTestShim.swift "$WORK"/ui/*.swift || status=1
[ $status -eq 0 ] && echo "Typecheck OK"
finished=1
exit $status
