#!/bin/bash
# Builds SpikeHost.app with the spike format reader in Contents/Extensions,
# ad-hoc signed. $1: "entitled" (the Media Extension entitlement), "plain",
# or "signed" (Developer ID: MACOS_SIGN_IDENTITY, READER_PROFILE).
set -euo pipefail
cd "$(dirname "$0")"
VARIANT=${1:-entitled}
OUT=${2:-build}
APP="$OUT/SpikeHost.app"
EX="$APP/Contents/Extensions/SpikeReader.appex"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$EX/Contents/MacOS"
TARGET=arm64-apple-macos15.0
swiftc -O -target $TARGET -module-name SpikeReader -parse-as-library MKVParser.swift Reader.swift \
  -framework MediaExtension -framework ExtensionFoundation \
  -Xlinker -e -Xlinker _EXExtensionMain -o "$EX/Contents/MacOS/SpikeReader"
swiftc -O -target $TARGET -module-name SpikeHost -parse-as-library Host.swift \
  -framework AVFoundation -framework MediaToolbox -framework VideoToolbox -framework AppKit -o "$APP/Contents/MacOS/SpikeHost"
cp Reader-Info.plist "$EX/Contents/Info.plist"
cp Host-Info.plist "$APP/Contents/Info.plist"
if [ "$VARIANT" = signed ]; then
  # Developer ID with the provisioning profile: the reader under the App ID
  # the profile is for, inside an app whose ID it extends
  : "${MACOS_SIGN_IDENTITY:?no signing identity}" "${READER_PROFILE:?no profile}"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier art.haushoppe.schnellbild" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier art.haushoppe.schnellbild.formatreader" "$EX/Contents/Info.plist"
  cp "$READER_PROFILE" "$EX/Contents/embedded.provisionprofile"
  codesign --force --sign "$MACOS_SIGN_IDENTITY" --options runtime --timestamp --entitlements Reader-signed.entitlements "$EX"
  codesign --force --sign "$MACOS_SIGN_IDENTITY" --options runtime --timestamp "$APP"
  codesign --verify --strict --deep --verbose=2 "$APP"
else
  if [ "$VARIANT" = entitled ]; then ENT=Reader.entitlements; else ENT=Reader-plain.entitlements; fi
  codesign --force --sign - --entitlements "$ENT" "$EX"
  codesign --force --sign - "$APP"
fi
codesign -d --entitlements - "$EX" 2>/dev/null | tail -n +1
echo "built $APP ($VARIANT)"
