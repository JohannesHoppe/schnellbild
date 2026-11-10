#!/bin/bash
# Checks the built app's QuickLook thumbnail extension the way macOS uses it:
# registered, asked for an MKV's thumbnail from another process, and that
# thumbnail kept by the system (a second process gets it from the cache).
set -euo pipefail
cd "$(dirname "$0")/.."
trap '[ -n "${finished:-}" ] || { ./Scripts/thumbnail_extension_report.sh; exit 1; }' EXIT
APP="${1:-build/Schnellbild.app}"
APPEX="$APP/Contents/PlugIns/SchnellbildThumbnails.appex"
OUT="${2:-build/thumbnail-check}"
mkdir -p "$OUT"
codesign -d --entitlements - "$APPEX" 2>/dev/null | grep -q app-sandbox || { echo "extension not in the App Sandbox"; exit 1; }
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
pluginkit -a "$APPEX"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pluginkit -m -i art.haushoppe.schnellbild.thumbnails | grep -q thumbnails && break
  sleep 1
done
pluginkit -m -v -i art.haushoppe.schnellbild.thumbnails
swiftc -O Scripts/thumbnail_probe.swift -o "$OUT/probe"
FILES=$(mktemp -d)
cp UITests/Fixtures/clip.mkv "$FILES/clip.mkv"
"$OUT/probe" "$FILES/clip.mkv" "$OUT/clip-mkv.png"
"$OUT/probe" "$FILES/clip.mkv"      # a new process: from the system's cache
# A damaged video gets no thumbnail and doesn't hang
"$OUT/probe" UITests/Fixtures/broken.mkv && { echo "broken.mkv got a thumbnail"; exit 1; } || true
finished=1
