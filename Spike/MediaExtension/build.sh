#!/bin/bash
# Builds SpikeHost.app with the spike format reader in Contents/Extensions,
# ad-hoc signed. $1: "entitled" (the Media Extension entitlement) or "plain".
set -euo pipefail
cd "$(dirname "$0")"
VARIANT=${1:-entitled}
OUT=${2:-build}
APP="$OUT/SpikeHost.app"
EX="$APP/Contents/Extensions/SpikeReader.appex"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$EX/Contents/MacOS"
TARGET=arm64-apple-macos15.0
swiftc -O -target $TARGET -module-name SpikeReader -parse-as-library Reader.swift \
  -framework MediaExtension -framework ExtensionFoundation \
  -Xlinker -e -Xlinker _EXExtensionMain -o "$EX/Contents/MacOS/SpikeReader"
swiftc -O -target $TARGET -module-name SpikeHost -parse-as-library Host.swift \
  -framework AVFoundation -framework MediaToolbox -o "$APP/Contents/MacOS/SpikeHost"
cp Reader-Info.plist "$EX/Contents/Info.plist"
cp Host-Info.plist "$APP/Contents/Info.plist"
if [ "$VARIANT" = entitled ]; then ENT=Reader.entitlements; else ENT=Reader-plain.entitlements; fi
codesign --force --sign - --entitlements "$ENT" "$EX"
codesign --force --sign - "$APP"
codesign -d --entitlements - "$EX" 2>/dev/null | tail -n +1
echo "built $APP ($VARIANT)"
