#!/bin/bash
# Builds Schnellbild.app: renders the icon, assembles the .icns, compiles a
# release binary, and wraps it in a proper macOS app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
RES="$ROOT/Resources"
APP="$ROOT/build/Schnellbild.app"

echo "==> Ensuring VLCKit is vendored"
"$ROOT/Scripts/fetch_vlckit.sh"

echo "==> Rendering icon"
swift Scripts/make_icon.swift "$RES/icon_1024.png"

echo "==> Building AppIcon.icns"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
sips -z 16 16   "$RES/icon_1024.png" --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32   "$RES/icon_1024.png" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32   "$RES/icon_1024.png" --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64   "$RES/icon_1024.png" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128 "$RES/icon_1024.png" --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256 "$RES/icon_1024.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$RES/icon_1024.png" --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512 512 "$RES/icon_1024.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$RES/icon_1024.png" --out "$ICONSET/icon_512x512.png"    >/dev/null
cp "$RES/icon_1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"
# Small PNG for the README hero.
sips -z 256 256 "$RES/icon_1024.png" --out "$RES/icon-256.png" >/dev/null

echo "==> swift build -c release"
swift build -c release
BINDIR="$(swift build -c release --show-bin-path)"
BIN="$BINDIR/Schnellbild"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Schnellbild"

echo "==> Embedding VLCKit.framework"
ditto "$BINDIR/VLCKit.framework" "$APP/Contents/Frameworks/VLCKit.framework"
# Apple silicon only, like the app: VideoLAN's build also carries Intel code (45 MB)
VLCBIN="$APP/Contents/Frameworks/VLCKit.framework/Versions/A/VLCKit"
if lipo -archs "$VLCBIN" | grep -q x86_64; then lipo "$VLCBIN" -thin arm64 -output "$VLCBIN.arm64" && mv "$VLCBIN.arm64" "$VLCBIN"; fi
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Schnellbild" 2>/dev/null || true
cp "$RES/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# The UI's translations (en.lproj, de.lproj, …), found through Bundle.main
cp -R "$RES/Localization/"*.lproj "$APP/Contents/Resources/"
# The libraries' license texts (the About window points here)
cp -R "$RES/Licenses" "$APP/Contents/Resources/Licenses"
# A short MKV: Settings plays it through macOS to tell whether the media extension is on
cp "$RES/FormatsCheck.mkv" "$APP/Contents/Resources/FormatsCheck.mkv"
cp "$RES/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Thumbnail extension (QuickLook, for MKV, WebM, AVI …)"
APPEX="$APP/Contents/PlugIns/SchnellbildThumbnails.appex"
mkdir -p "$APPEX/Contents/MacOS"
cp "$BINDIR/SchnellbildThumbnails" "$APPEX/Contents/MacOS/SchnellbildThumbnails"
# VLCKit is the app's, four levels up from the extension's binary
install_name_tool -change @loader_path/../Frameworks/VLCKit.framework/Versions/A/VLCKit \
  @executable_path/../../../../Frameworks/VLCKit.framework/Versions/A/VLCKit "$APPEX/Contents/MacOS/SchnellbildThumbnails"
cp "$ROOT/ThumbnailExtension/Info.plist" "$APPEX/Contents/Info.plist"
for key in CFBundleShortVersionString CFBundleVersion; do
  /usr/libexec/PlistBuddy -c "Set :$key $(/usr/libexec/PlistBuddy -c "Print :$key" "$RES/Info.plist")" "$APPEX/Contents/Info.plist"
done

echo "==> Media extension (Matroska format reader for macOS's own pipeline)"
FORMATS="$APP/Contents/Extensions/SchnellbildFormats.appex"
mkdir -p "$FORMATS/Contents/MacOS"
# Its entry is ExtensionKit's; it has no main of its own
xcrun swiftc -O -target arm64-apple-macos15.0 -module-name SchnellbildFormats -parse-as-library \
  "$ROOT/FormatReader/MatroskaIndex.swift" "$ROOT/FormatReader/FormatReader.swift" \
  -framework MediaExtension -framework ExtensionFoundation -Xlinker -e -Xlinker _EXExtensionMain \
  -o "$FORMATS/Contents/MacOS/SchnellbildFormats"
cp "$ROOT/FormatReader/Info.plist" "$FORMATS/Contents/Info.plist"
for key in CFBundleShortVersionString CFBundleVersion; do
  /usr/libexec/PlistBuddy -c "Set :$key $(/usr/libexec/PlistBuddy -c "Print :$key" "$RES/Info.plist")" "$FORMATS/Contents/Info.plist"
done

# Sign from the inside out: every file with machine code (VLCKit and its
# plugins), then the frameworks, then the app. With MACOS_SIGN_IDENTITY
# ("Developer ID Application: …") for notarization: Hardened Runtime and a
# secure timestamp. Without it: ad hoc, for local and CI builds.
IDENTITY="${MACOS_SIGN_IDENTITY:-}"
IDENTITY="$(printf '%s' "$IDENTITY" | sed 's/^ *//; s/ *$//')"
OPTS=(--force --sign "${IDENTITY:--}")
if [ -n "$IDENTITY" ]; then
  OPTS+=(--options runtime --timestamp)
  echo "==> Signing with: $IDENTITY"
else
  echo "==> Ad-hoc code signing"
fi
is_macho() {
  case "$(head -c 4 "$1" | xxd -p)" in
    cffaedfe|cafebabe|cefaedfe|bebafeca) return 0 ;;
    *) return 1 ;;
  esac
}
MAIN="$APP/Contents/MacOS/Schnellbild"
# Longest paths first: nested code is signed before what contains it.
find "$APP/Contents" -type f ! -path "$MAIN" -print0 \
  | while IFS= read -r -d '' f; do if is_macho "$f"; then printf '%s\n' "$f"; fi; done \
  | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2- \
  | while IFS= read -r f; do codesign "${OPTS[@]}" "$f"; done
codesign "${OPTS[@]}" "$APP/Contents/Frameworks/VLCKit.framework"
# The extension in the App Sandbox (its entitlements), before the app around it
codesign "${OPTS[@]}" --entitlements "$ROOT/ThumbnailExtension/ThumbnailExtension.entitlements" "$APPEX"
# The media extension: macOS starts it only with its entitlement, which
# needs the Developer ID and the provisioning profile for its App ID
# (FORMATS_PROFILE); otherwise it is signed without (and stays unused)
if [ -n "$IDENTITY" ] && [ -n "${FORMATS_PROFILE:-}" ] && [ -f "$FORMATS_PROFILE" ]; then
  cp "$FORMATS_PROFILE" "$FORMATS/Contents/embedded.provisionprofile"
  codesign "${OPTS[@]}" --entitlements "$ROOT/FormatReader/FormatReader.entitlements" "$FORMATS"
else
  echo "   (media extension without its entitlement: no Developer ID or no FORMATS_PROFILE)"
  codesign "${OPTS[@]}" --entitlements "$ROOT/ThumbnailExtension/ThumbnailExtension.entitlements" "$FORMATS"
fi
codesign "${OPTS[@]}" "$APP"
codesign --verify --strict --deep "$APP"

echo "==> Done: $APP"
