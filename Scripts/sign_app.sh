#!/bin/bash
# Signs Schnellbild.app (Scripts/build_app.sh), from the inside out, every part
# in the App Sandbox:
#   the app                  Sandbox/Schnellbild.entitlements
#   the thumbnail extension  Sandbox/SchnellbildThumbnails.entitlements
#   the media extension      FormatReader/FormatReader.entitlements
#
# One app, three ways to sign it:
#   APPSTORE_SIGN_IDENTITY  the Mac App Store ("Apple Distribution: …"): each
#                           part with its App Store profile (APP_PROFILE,
#                           THUMBNAILS_PROFILE, FORMATS_PROFILE)
#   MACOS_SIGN_IDENTITY     the DMG ("Developer ID Application: …", notarized):
#                           Hardened Runtime; the media extension with its
#                           Developer ID profile (FORMATS_PROFILE), which its
#                           entitlement needs
#   neither                 ad hoc, for local and CI builds
# The entitlements only a profile allows (App ID, team, the media extension's)
# are left out where there is no profile for them; where there is one, it is
# checked against them before anything is signed (check_profile).
#
#   Scripts/sign_app.sh <Schnellbild.app>
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="${1:?usage: sign_app.sh <Schnellbild.app>}"
trim() { printf '%s' "$1" | sed 's/^ *//; s/ *$//'; }
STORE_ID="$(trim "${APPSTORE_SIGN_IDENTITY:-}")"
DEVID="$(trim "${MACOS_SIGN_IDENTITY:-}")"
APPEX="$APP/Contents/PlugIns/SchnellbildThumbnails.appex"
FORMATS="$APP/Contents/Extensions/SchnellbildFormats.appex"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

APP_ENT="$ROOT/Sandbox/Schnellbild.entitlements"
THUMB_ENT="$ROOT/Sandbox/SchnellbildThumbnails.entitlements"
FORMATS_ENT="$ROOT/FormatReader/FormatReader.entitlements"

# without_profile <entitlements> <out>: what only a profile allows, left out
without_profile() {
  cp "$1" "$2"
  for key in com.apple.application-identifier com.apple.developer.team-identifier \
             com.apple.developer.mediaextension.formatreader; do
    /usr/libexec/PlistBuddy -c "Delete :$key" "$2" 2>/dev/null || true
  done
}

# check_profile <profile> <entitlements> <bundle>: the profile allows what the
# bundle is signed with (its App ID is the bundle's, its team and every
# entitlement only a profile grants match), and hasn't run out. macOS would
# refuse to start a part whose profile doesn't, and App Store Connect the upload.
check_profile() {
  local profile="$1" ent="$2" bundle="$3" decoded name bundle_id key want got app_id team expires
  name="$(basename "$bundle")"
  decoded="$TMP/$name.profile.plist"
  security cms -D -i "$profile" > "$decoded" 2>/dev/null \
    || { echo "!! $profile (for $name) is not a provisioning profile" >&2; exit 1; }
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist")"
  app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$decoded" 2>/dev/null || true)"
  team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$decoded" 2>/dev/null || true)"
  [ -n "$team" ] && [ "$app_id" = "$team.$bundle_id" ] \
    || { echo "!! the profile for $name is for the App ID '$app_id', the bundle is $bundle_id (team '$team')" >&2; exit 1; }
  for key in com.apple.application-identifier com.apple.developer.team-identifier \
             com.apple.developer.mediaextension.formatreader; do
    want="$(/usr/libexec/PlistBuddy -c "Print :$key" "$ent" 2>/dev/null)" || continue
    got="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:$key" "$decoded" 2>/dev/null || echo '(not in the profile)')"
    [ "$want" = "$got" ] \
      || { echo "!! $name is signed with $key = $want, its profile allows $got" >&2; exit 1; }
  done
  expires="$(plutil -extract ExpirationDate raw -o - "$decoded")"
  [[ "$expires" > "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ]] \
    || { echo "!! the profile for $name ran out on $expires (docs/SIGNING.md)" >&2; exit 1; }
  echo "   profile for $name: $app_id, until $expires"
}

if [ -n "$STORE_ID" ]; then
  echo "==> Signing for the Mac App Store with: $STORE_ID"
  for name in APP_PROFILE THUMBNAILS_PROFILE FORMATS_PROFILE; do
    [ -f "${!name:-}" ] || { echo "!! $name (an App Store provisioning profile) is missing" >&2; exit 1; }
  done
  check_profile "$APP_PROFILE" "$APP_ENT" "$APP"
  check_profile "$THUMBNAILS_PROFILE" "$THUMB_ENT" "$APPEX"
  check_profile "$FORMATS_PROFILE" "$FORMATS_ENT" "$FORMATS"
  cp "$APP_PROFILE" "$APP/Contents/embedded.provisionprofile"
  cp "$THUMBNAILS_PROFILE" "$APPEX/Contents/embedded.provisionprofile"
  cp "$FORMATS_PROFILE" "$FORMATS/Contents/embedded.provisionprofile"
  OPTS=(--force --sign "$STORE_ID" --options runtime --timestamp)
else
  without_profile "$APP_ENT" "$TMP/app.entitlements"; APP_ENT="$TMP/app.entitlements"
  without_profile "$THUMB_ENT" "$TMP/thumbnails.entitlements"; THUMB_ENT="$TMP/thumbnails.entitlements"
  if [ -n "$DEVID" ]; then
    echo "==> Signing with: $DEVID"
    OPTS=(--force --sign "$DEVID" --options runtime --timestamp)
    if [ -n "${FORMATS_PROFILE:-}" ] && [ -f "$FORMATS_PROFILE" ]; then
      check_profile "$FORMATS_PROFILE" "$FORMATS_ENT" "$FORMATS"
      cp "$FORMATS_PROFILE" "$FORMATS/Contents/embedded.provisionprofile"
    else
      echo "   (media extension without its entitlement: no FORMATS_PROFILE)"
      without_profile "$FORMATS_ENT" "$TMP/formats.entitlements"; FORMATS_ENT="$TMP/formats.entitlements"
    fi
  else
    echo "==> Ad hoc signing (the media extension without its entitlement)"
    OPTS=(--force --sign -)
    without_profile "$FORMATS_ENT" "$TMP/formats.entitlements"; FORMATS_ENT="$TMP/formats.entitlements"
  fi
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
