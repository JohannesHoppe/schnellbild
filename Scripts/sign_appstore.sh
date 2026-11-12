#!/bin/bash
# Signs the Mac App Store variant of Schnellbild.app (Scripts/build_app.sh with
# SCHNELLBILD_APPSTORE=1), from the inside out, every part in the App Sandbox:
#   the app                  AppStore/Schnellbild.entitlements
#   the thumbnail extension  AppStore/SchnellbildThumbnails.entitlements
#   the media extension      FormatReader/FormatReader.entitlements
#
# With APPSTORE_SIGN_IDENTITY ("Apple Distribution: …" or "3rd Party Mac
# Developer Application: …") each part gets its App Store provisioning profile
# (APP_PROFILE, THUMBNAILS_PROFILE, FORMATS_PROFILE). Without it the parts are
# signed ad hoc, for tests, without the entitlements only a profile allows (App
# ID, team, the media extension's).
#
#   Scripts/sign_appstore.sh <Schnellbild.app>
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="${1:?usage: sign_appstore.sh <Schnellbild.app>}"
IDENTITY="$(printf '%s' "${APPSTORE_SIGN_IDENTITY:-}" | sed 's/^ *//; s/ *$//')"
APPEX="$APP/Contents/PlugIns/SchnellbildThumbnails.appex"
FORMATS="$APP/Contents/Extensions/SchnellbildFormats.appex"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

APP_ENT="$ROOT/AppStore/Schnellbild.entitlements"
THUMB_ENT="$ROOT/AppStore/SchnellbildThumbnails.entitlements"
FORMATS_ENT="$ROOT/FormatReader/FormatReader.entitlements"

if [ -n "$IDENTITY" ]; then
  echo "==> App Store signing with: $IDENTITY"
  for name in APP_PROFILE THUMBNAILS_PROFILE FORMATS_PROFILE; do
    [ -f "${!name:-}" ] || { echo "!! $name (an App Store provisioning profile) is missing" >&2; exit 1; }
  done
  cp "$APP_PROFILE" "$APP/Contents/embedded.provisionprofile"
  cp "$THUMBNAILS_PROFILE" "$APPEX/Contents/embedded.provisionprofile"
  cp "$FORMATS_PROFILE" "$FORMATS/Contents/embedded.provisionprofile"
  OPTS=(--force --sign "$IDENTITY" --options runtime --timestamp)
else
  echo "==> App Store variant, ad hoc (tests): without the entitlements only a profile allows"
  without_restricted() {
    cp "$1" "$2"
    for key in com.apple.application-identifier com.apple.developer.team-identifier \
               com.apple.developer.mediaextension.formatreader; do
      /usr/libexec/PlistBuddy -c "Delete :$key" "$2" 2>/dev/null || true
    done
  }
  without_restricted "$APP_ENT" "$TMP/app.entitlements"; APP_ENT="$TMP/app.entitlements"
  without_restricted "$THUMB_ENT" "$TMP/thumbnails.entitlements"; THUMB_ENT="$TMP/thumbnails.entitlements"
  without_restricted "$FORMATS_ENT" "$TMP/formats.entitlements"; FORMATS_ENT="$TMP/formats.entitlements"
  OPTS=(--force --sign -)
fi

is_macho() {
  case "$(head -c 4 "$1" | xxd -p)" in
    cffaedfe|cafebabe|cefaedfe|bebafeca) return 0 ;;
    *) return 1 ;;
  esac
}
MAIN="$APP/Contents/MacOS/Schnellbild"
# Every other file with machine code, longest paths first (nested before what holds it)
find "$APP/Contents" -type f ! -path "$MAIN" ! -path "$APPEX/Contents/MacOS/*" ! -path "$FORMATS/Contents/MacOS/*" -print0 \
  | while IFS= read -r -d '' f; do if is_macho "$f"; then printf '%s\n' "$f"; fi; done \
  | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2- \
  | while IFS= read -r f; do codesign "${OPTS[@]}" "$f"; done
codesign "${OPTS[@]}" "$APP/Contents/Frameworks/VLCKit.framework"
codesign "${OPTS[@]}" --entitlements "$THUMB_ENT" "$APPEX"
codesign "${OPTS[@]}" --entitlements "$FORMATS_ENT" "$FORMATS"
codesign "${OPTS[@]}" --entitlements "$APP_ENT" "$APP"
codesign --verify --strict --deep "$APP"

# Every part must be in the App Sandbox
for part in "$APP" "$APPEX" "$FORMATS"; do
  codesign -d --entitlements - --xml "$part" 2>/dev/null | grep -q 'com.apple.security.app-sandbox' \
    || { echo "!! not in the App Sandbox: $part" >&2; exit 1; }
done
echo "==> Signed; app and extensions in the App Sandbox"
