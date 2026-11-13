#!/bin/bash
# Builds Schnellbild.app: renders the icon, assembles the .icns, compiles a
# release binary, and wraps it in a proper macOS app bundle, in the App Sandbox
# (Sandbox/). The same app goes out as the DMG and to the Mac App Store; only
# its signature differs (Scripts/sign_app.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
RES="$ROOT/Resources"
APP="$ROOT/build/Schnellbild.app"

echo "==> Ensuring VLCKit is vendored"
"$ROOT/Scripts/fetch_vlckit.sh"
echo "==> No GPL module in VLCKit"
python3 -I "$ROOT/Scripts/vlckit_licenses.py" \
  "$(find "$ROOT/Vendor/VLCKit.xcframework" -path '*VLCKit.framework/Versions/A/VLCKit' -type f | head -1)" --no-gpl --local-only

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
# Headers and module map are for compiling against it, not for running it
VLCFW="$APP/Contents/Frameworks/VLCKit.framework"
rm -rf "$VLCFW/Headers" "$VLCFW/PrivateHeaders" "$VLCFW/Modules" \
  "$VLCFW/Versions/A/Headers" "$VLCFW/Versions/A/PrivateHeaders" "$VLCFW/Versions/A/Modules"
# VLCKit's own privacy manifest: the reasons behind the system calls in its binary
cp "$ROOT/Sandbox/VLCKit.xcprivacy" "$VLCFW/Versions/A/Resources/PrivacyInfo.xcprivacy"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Schnellbild" 2>/dev/null || true
cp "$RES/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# The UI's translations (en.lproj, de.lproj, …), found through Bundle.main
cp -R "$RES/Localization/"*.lproj "$APP/Contents/Resources/"
# The libraries' license texts (the About window points here), among them
# VLCKit-third-party-licenses.txt: FFmpeg and the other libraries inside VLCKit,
# as published with the VLCKit build (keep it in step with fetch_vlckit.sh)
cp -R "$RES/Licenses" "$APP/Contents/Resources/Licenses"
# A short MKV: Settings plays it through macOS to tell whether the media extension is on
cp "$RES/FormatsCheck.mkv" "$APP/Contents/Resources/FormatsCheck.mkv"
cp "$RES/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# The App Store asks for the reasons behind some system calls (the app's and VLCKit's)
cp "$ROOT/Sandbox/PrivacyInfo.xcprivacy" "$APP/Contents/Resources/PrivacyInfo.xcprivacy"

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
mkdir -p "$APPEX/Contents/Resources"
cp "$ROOT/Sandbox/Thumbnails.xcprivacy" "$APPEX/Contents/Resources/PrivacyInfo.xcprivacy"

echo "==> Media extension (Matroska format reader for macOS's own pipeline)"
FORMATS="$APP/Contents/Extensions/SchnellbildFormats.appex"
mkdir -p "$FORMATS/Contents/MacOS"
# Its entry is ExtensionKit's; it has no main of its own
xcrun swiftc -O -target arm64-apple-macos15.0 -module-name SchnellbildFormats -parse-as-library \
  "$ROOT/FormatReader/MatroskaIndex.swift" "$ROOT/FormatReader/TransportIndex.swift" "$ROOT/FormatReader/FormatReader.swift" \
  -framework MediaExtension -framework ExtensionFoundation -Xlinker -e -Xlinker _NSExtensionMain \
  -o "$FORMATS/Contents/MacOS/SchnellbildFormats"
cp "$ROOT/FormatReader/Info.plist" "$FORMATS/Contents/Info.plist"
for key in CFBundleShortVersionString CFBundleVersion; do
  /usr/libexec/PlistBuddy -c "Set :$key $(/usr/libexec/PlistBuddy -c "Print :$key" "$RES/Info.plist")" "$FORMATS/Contents/Info.plist"
done
mkdir -p "$FORMATS/Contents/Resources"
cp "$ROOT/Sandbox/Formats.xcprivacy" "$FORMATS/Contents/Resources/PrivacyInfo.xcprivacy"

# What Xcode writes into every bundle it builds: App Store Connect reads the
# SDK and Xcode the app was built with from these keys (DTXcode "1620" is
# Xcode 16.2, "2601" Xcode 26.0.1). They need a full Xcode; with only the
# Command Line Tools they are left out, which only the App Store refuses.
echo "==> Toolchain keys (Xcode, SDK, build machine)"
if xcode_version="$(xcodebuild -version 2>/dev/null)"; then
  xcode="$(printf '%s\n' "$xcode_version" | awk '/^Xcode /{print $2}')"
  IFS=. read -r major minor patch <<<"$xcode"
  sdk="$(xcrun --sdk macosx --show-sdk-version)"
  sdk_build="$(xcrun --sdk macosx --show-sdk-build-version)"
  TOOLCHAIN=(
    "DTXcode $(printf '%02d%d%d' "$major" "${minor:-0}" "${patch:-0}")"
    "DTXcodeBuild $(printf '%s\n' "$xcode_version" | awk '/^Build version /{print $3}')"
    "DTSDKName macosx$sdk"
    "DTSDKBuild $sdk_build"
    "DTPlatformName macosx"
    "DTPlatformVersion $(xcrun --sdk macosx --show-sdk-platform-version)"
    "DTPlatformBuild $sdk_build"
    "DTCompiler com.apple.compilers.llvm.clang.1_0"
    "BuildMachineOSBuild $(sw_vers -buildVersion)"
  )
  for plist in "$APP/Contents/Info.plist" "$APPEX/Contents/Info.plist" "$FORMATS/Contents/Info.plist"; do
    for entry in "${TOOLCHAIN[@]}"; do
      read -r key value <<<"$entry"
      [ -n "$value" ] || { echo "!! no value for $key" >&2; exit 1; }
      /usr/libexec/PlistBuddy -c "Delete :$key" "$plist" 2>/dev/null || true
      /usr/libexec/PlistBuddy -c "Add :$key string $value" "$plist"
    done
    /usr/libexec/PlistBuddy -c "Delete :CFBundleSupportedPlatforms" "$plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :CFBundleSupportedPlatforms array" -c "Add :CFBundleSupportedPlatforms:0 string MacOSX" "$plist"
  done
  echo "   Xcode $xcode, macOS SDK $sdk ($sdk_build), on macOS $(sw_vers -buildVersion)"
elif [ -n "${APPSTORE_SIGN_IDENTITY:-}" ]; then
  echo "!! The App Store build needs a full Xcode (xcodebuild -version fails): App Store Connect checks the Xcode and SDK keys" >&2
  exit 1
else
  echo "   (no full Xcode: the Info.plists go without the Xcode and SDK keys, which only the App Store needs)"
fi

# VLCKit exports the libraries VLC carries (libarchive, zlib, FFmpeg …) along
# with its own API, and the linker binds a name to the first library that has
# it. Only VLC's own names may come from VLCKit; anything else would run in
# VLC's copy of a library instead of the system's.
echo "==> Only VLC's own functions taken from VLCKit"
foreign="$(find "$APP/Contents" -path '*/Contents/MacOS/*' -type f -exec nm -m {} \; \
  | grep '(from VLCKit)' | awk '{print $3}' \
  | grep -vE '^_(libvlc_|VLC|kVLC|OBJC_(CLASS|METACLASS)_\$_VLC)' | sort -u || true)"
if [ -n "$foreign" ]; then
  echo "error: taken from VLCKit, not from the library meant:" >&2
  echo "$foreign" >&2
  exit 1
fi

"$ROOT/Scripts/sign_app.sh" "$APP"
echo "==> Done: $APP"
