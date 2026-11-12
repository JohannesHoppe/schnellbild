#!/bin/bash
# Wraps the signed App Store variant (Scripts/build_app.sh with
# SCHNELLBILD_APPSTORE=1 and APPSTORE_SIGN_IDENTITY) in the installer package
# App Store Connect takes, signed with APPSTORE_INSTALLER_IDENTITY ("3rd Party
# Mac Developer Installer: …" / "Mac Installer Distribution: …"); without it
# the package is unsigned (a dry run: App Store Connect refuses it).
#
#   Scripts/package_appstore.sh [<Schnellbild.app>] [<Schnellbild.pkg>]
#
# Upload: Transporter (Mac App Store), or
#   xcrun altool --upload-app -t macos -f build/Schnellbild.pkg --apiKey … --apiIssuer …
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-build/Schnellbild.app}"
PKG="${2:-build/Schnellbild.pkg}"
INSTALLER="$(printf '%s' "${APPSTORE_INSTALLER_IDENTITY:-}" | sed 's/^ *//; s/ *$//')"

codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q 'com.apple.security.app-sandbox' \
  || { echo "!! $APP is not the App Store variant (no App Sandbox)" >&2; exit 1; }
rm -f "$PKG"
if [ -n "$INSTALLER" ]; then
  productbuild --component "$APP" /Applications --sign "$INSTALLER" "$PKG"
else
  echo "   (no APPSTORE_INSTALLER_IDENTITY: an unsigned package, as a dry run)"
  productbuild --component "$APP" /Applications "$PKG"
fi
pkgutil --check-signature "$PKG" || true
echo "==> $PKG"
