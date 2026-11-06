#!/bin/bash
# Opens a DMG in Finder and photographs its window in light and dark mode:
#   dmg_preview.sh <dmg> <out-dir>   -> <out-dir>/dmg-light.png, dmg-dark.png
# Needs screen recording and Automation (System Events) permission, which the
# GitHub macOS runners have; runs in .github/workflows/dmg-preview.yml.
# Leaves the appearance as it found it.
set -euo pipefail
DMG=$1 OUT=$2
mkdir -p "$OUT"
VOL=""
HELPER="$(mktemp -d)/winbounds.swift"

appearance() {
  osascript -e "tell application \"System Events\" to tell appearance preferences to set dark mode to $1"
}
was_dark=$(osascript -e 'tell application "System Events" to tell appearance preferences to get dark mode')
cleanup() {
  appearance "$was_dark"
  if [ -n "$VOL" ]; then hdiutil detach "$VOL" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

# Prints the bounds of the Finder window showing the volume as x,y,w,h
cat > "$HELPER" <<'SWIFT'
import AppKit
let name = CommandLine.arguments[1]
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerName as String] as? String) == "Finder"
    && (w[kCGWindowLayer as String] as? Int) == 0 {
    // The name needs screen recording permission; without it take the first normal window
    if let n = w[kCGWindowName as String] as? String, n != name { continue }
    let b = w[kCGWindowBounds as String] as! [String: CGFloat]
    print("\(Int(b["X"]!)),\(Int(b["Y"]!)),\(Int(b["Width"]!)),\(Int(b["Height"]!))")
    break
}
SWIFT

VOL=$(hdiutil attach -nobrowse "$DMG" | awk -F'\t' '/\/Volumes\//{print $NF}')
echo "Mounted $VOL"
open "$VOL"

RECT=""
for _ in $(seq 1 30); do
  RECT=$(swift "$HELPER" "$(basename "$VOL")")
  [ -n "$RECT" ] && break
  sleep 1
done
[ -n "$RECT" ] || { echo "No Finder window for $VOL" >&2; exit 1; }
echo "Window at $RECT"

for mode in light dark; do
  appearance "$([ "$mode" = dark ] && echo true || echo false)"
  sleep 3   # let Finder redraw
  screencapture -x -R "$RECT" "$OUT/dmg-$mode.png"
  echo "Wrote $OUT/dmg-$mode.png"
done
