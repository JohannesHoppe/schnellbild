#!/bin/bash
# Builds probe.swift into a small app, signs it ad hoc with the given
# entitlements (App Sandbox) and runs it on a folder in ~/Pictures.
set -euo pipefail
cd "$(dirname "$0")"
variant=$1
entitlements=$variant.entitlements
[ "$variant" = uitests ] && entitlements=../../Sandbox/UITests.entitlements
app=build/Probe-$variant.app
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>art.haushoppe.trashprobe.$variant</string>
<key>CFBundleExecutable</key><string>probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
swiftc -O probe.swift -o "$app/Contents/MacOS/probe"
codesign --force --sign - --entitlements "$entitlements" "$app"
codesign -d --entitlements - "$app" | head -30
if [ "$variant" = volume ]; then
  hdiutil create -size 40m -fs APFS -volname ProbeVol build/probe.dmg -ov >/dev/null
  hdiutil attach build/probe.dmg >/dev/null
  mkdir -p /Volumes/ProbeVol/work
  "$app/Contents/MacOS/probe" /Volumes/ProbeVol/work volume || echo "probe exited $?"
  ls -la /Volumes/ProbeVol /Volumes/ProbeVol/work /Volumes/ProbeVol/.Trashes/* 2>&1 || true
  exit 0
fi
work="$HOME/Pictures/trash-probe-$variant"
mkdir -p "$work"
"$app/Contents/MacOS/probe" "$work" || echo "probe exited $?"
echo "== a second process takes back what the first left in the Trash"
"$app/Contents/MacOS/probe" "$work" later || echo "probe exited $?"
echo "== left in $work:"; ls -la "$work" || true
echo "== ~/.Trash:"; ls -la ~/.Trash || true
for item in ~/.Trash/*; do echo "-- xattr $item"; xattr -l "$item" 2>&1 | head -5 || true; done
python3 -I - <<'PY'
import os
p = os.path.expanduser('~/.Trash/.DS_Store')
try:
    data = open(p, 'rb').read()
except Exception as e:
    print('DS_Store:', e); raise SystemExit
print('DS_Store bytes', len(data), 'ptbL', data.count(b'ptbL'), 'ptbN', data.count(b'ptbN'))
for name in ['Folder A', 'file-a.txt', 'Folder B', 'Stay Folder', 'stay-file.txt']:
    print(name, 'in DS_Store:', name.encode('utf-16-be') in data)
PY
