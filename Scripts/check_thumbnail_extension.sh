#!/bin/bash
# Checks the built app's QuickLook thumbnail extension the way macOS uses it:
# registered, then asked from another process for a thumbnail of each format
# it claims (which extension answered is printed: on newer macOS, Apple's own
# reads some of them itself), an MKV's thumbnail kept by the system (a second
# process gets it from the cache), and no thumbnail for a damaged file.
# AVI and AVCHD are printed, not checked: macOS gives those to its own
# extension, which has no picture for them.
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
sw_vers -productVersion
swiftc -O Scripts/thumbnail_probe.swift -o "$OUT/probe"
FILES=$(mktemp -d)
cp Tests/SchnellbildTests/Videos/clip.* "$FILES/"

# Which extension made the picture: ours logs every player it starts
answered_by() {
  local since=$1
  if /usr/bin/log show --start "$since" --info --style compact \
       --predicate 'process == "SchnellbildThumbnails" AND eventMessage CONTAINS "creating player instance"' 2>/dev/null \
       | grep -q "creating player"; then echo "Schnellbild"; else echo "macOS"; fi
}
probe() {   # probe <ext> <must get a thumbnail: yes/no>
  local since; since=$(date "+%Y-%m-%d %H:%M:%S")
  if "$OUT/probe" "$FILES/clip.$1" "$OUT/clip-$1.png"; then
    sleep 1; echo "   .$1 answered by $(answered_by "$since")"
  else
    [ "$2" = yes ] && { echo ".$1 got no thumbnail"; exit 1; }
    echo "   .$1: none (macOS keeps it for its own extension)"
  fi
}
for ext in mkv webm wmv asf flv ogv vob; do probe "$ext" yes; done
for ext in avi m2ts mts; do probe "$ext" no; done
"$OUT/probe" "$FILES/clip.mkv"      # a new process: from the system's cache
# A damaged video gets no thumbnail and doesn't hang
"$OUT/probe" UITests/Fixtures/broken.mkv && { echo "broken.mkv got a thumbnail"; exit 1; } || true
finished=1
