#!/bin/bash
# What macOS did with the thumbnail extension: its registration, which
# extension QuickLook picked for videos, the extension's own messages and
# crash reports. Printed by CI when a thumbnail check fails.
pluginkit -m -v -i art.haushoppe.schnellbild.thumbnails || true
echo "--- QuickLook's thumbnail agent"
/usr/bin/log show --last 30m --info --style compact \
  --predicate 'process == "com.apple.quicklook.ThumbnailsAgent" AND (eventMessage CONTAINS "Launching process" OR eventMessage CONTAINS "error" OR eventMessage CONTAINS "Error")' 2>/dev/null \
  | sed -E 's/.*(bundleID: [^ ]+).*/\1/' | cut -c1-300 | tail -40 || true
echo "--- the extension"
/usr/bin/log show --last 30m --info --style compact --predicate 'process == "SchnellbildThumbnails"' 2>/dev/null | cut -c1-300 | tail -60 || true
echo "--- crash reports"
for f in ~/Library/Logs/DiagnosticReports/SchnellbildThumbnails*; do
  [ -f "$f" ] || continue
  echo "$f"; head -c 3000 "$f"; echo
done
