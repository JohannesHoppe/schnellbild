#!/bin/bash
# The entitlements a part is signed with where there is no provisioning
# profile (ad hoc on CI and for the UI tests, the Developer ID build): its
# file in Sandbox/ (or FormatReader/) without what only a profile allows
# (App ID, team, the media extension's entitlement). One source for
# Scripts/sign_app.sh, the Xcode build (project.yml) and the check that the
# app under test is signed with exactly these (Scripts/check_entitlements.sh).
#
#   Scripts/entitlements.sh <entitlements> <out>   one file
#   Scripts/entitlements.sh --all <out dir>        app.entitlements,
#                                                  thumbnails.entitlements,
#                                                  formats.entitlements
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

without_profile() {
  mkdir -p "$(dirname "$2")"
  cp "$1" "$2"
  for key in com.apple.application-identifier com.apple.developer.team-identifier \
             com.apple.developer.mediaextension.formatreader; do
    /usr/libexec/PlistBuddy -c "Delete :$key" "$2" >/dev/null 2>&1 || true
  done
}

if [ "${1:-}" = "--all" ]; then
  OUT="${2:?usage: entitlements.sh --all <out dir>}"
  without_profile "$ROOT/Sandbox/Schnellbild.entitlements" "$OUT/app.entitlements"
  without_profile "$ROOT/Sandbox/SchnellbildThumbnails.entitlements" "$OUT/thumbnails.entitlements"
  without_profile "$ROOT/FormatReader/FormatReader.entitlements" "$OUT/formats.entitlements"
else
  without_profile "${1:?usage: entitlements.sh <entitlements> <out>}" "${2:?usage: entitlements.sh <entitlements> <out>}"
fi
