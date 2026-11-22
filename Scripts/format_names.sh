#!/bin/bash
# Writes site/formats-macos.json: the names macOS gives the formats of
# site/formats.json, in each of the website's languages (Scripts/format_names.swift).
# Built with an Info.plist that allows every localization, since a command-line
# tool without one gets macOS's type descriptions in English only.
set -euo pipefail
cd "$(dirname "$0")/.."

out="build/format-names"
mkdir -p "$out"
cat > "$out/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>art.haushoppe.schnellbild.format-names</string>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleAllowMixedLocalizations</key><true/>
</dict>
</plist>
PLIST
swiftc -O -suppress-warnings Scripts/format_names.swift -o "$out/format_names" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$out/Info.plist"
"$out/format_names" "$PWD"
