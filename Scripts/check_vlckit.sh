#!/bin/bash
# Checks the VLCKit a build carries (Scripts/vlckit_licenses.py): every module
# states the LGPL, and none of those Schnellbild leaves out is in it. Run by
# build_app.sh before anything is built.
#
# A VLCKit of one's own (SCHNELLBILD_OWN_VLCKIT=1, a modified build as the
# LGPL allows, see THIRD-PARTY-NOTICES.md) is used as it is: what the check
# finds is printed as a warning. A build signed for release (Developer ID or
# Mac App Store) always fails on it.
#   Scripts/check_vlckit.sh [<VLCKit binary>]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="${1:-$(find "$ROOT/Vendor/VLCKit.xcframework" -path '*VLCKit.framework/Versions/A/VLCKit' -type f 2>/dev/null | head -1)}"

echo "==> No GPL module in VLCKit"
if python3 -I "$ROOT/Scripts/vlckit_licenses.py" "$BINARY" --no-gpl --local-only; then
  exit 0
fi
if [ "${SCHNELLBILD_OWN_VLCKIT:-}" = 1 ] && [ -z "${MACOS_SIGN_IDENTITY:-}${APPSTORE_SIGN_IDENTITY:-}" ]; then
  echo "warning: this VLCKit fails the check above; SCHNELLBILD_OWN_VLCKIT=1 uses it as it is" >&2
  exit 0
fi
echo "error: VLCKit fails the check above; a release is built only with a VLCKit that passes it" >&2
exit 1
