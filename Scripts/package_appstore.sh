#!/bin/bash
# Wraps the app signed for the Mac App Store (Scripts/build_app.sh with
# APPSTORE_SIGN_IDENTITY and the App Store profiles) in the installer package
# App Store Connect takes, signed with APPSTORE_INSTALLER_IDENTITY ("3rd Party
# Mac Developer Installer: …" / "Mac Installer Distribution: …"); without it
# the package is unsigned (a dry run: App Store Connect refuses it).
#
#   Scripts/package_appstore.sh [<Schnellbild.app>] [<Schnellbild.pkg>]
#
# Upload: Transporter (Mac App Store), or
#   xcrun altool --upload-package build/Schnellbild.pkg --type macos --apple-id <app.json appleId> \
#     --bundle-id art.haushoppe.schnellbild --bundle-short-version-string <version> --bundle-version <build> \
#     --apiKey … --apiIssuer …   (what .github/workflows/appstore.yml runs)
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
