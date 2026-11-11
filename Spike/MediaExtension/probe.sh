#!/bin/bash
# On a CI runner: installs the spike app, then asks whether macOS lists,
# enables and starts its format reader (from an opted-in app and from
# Quick Look). Prints everything; decides nothing.
set -uo pipefail
cd "$(dirname "$0")"
APP=/Applications/SpikeHost.app
ID=art.haushoppe.schnellbild.spikehost.reader
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
CLIPS=$(mktemp -d)
cp ../../Tests/SchnellbildTests/Videos/clip.avi "$CLIPS/clip.avi"
cp ../../Tests/SchnellbildTests/Videos/clip.avi "$CLIPS/clip.spk"
SINCE=$(date '+%Y-%m-%d %H:%M:%S')

section() { echo; echo "== $*"; }
logs() {
  /usr/bin/log show --info --debug --start "$SINCE" --style compact \
    --predicate 'subsystem == "art.haushoppe.schnellbild.spike" OR eventMessage CONTAINS[c] "spikehost" OR eventMessage CONTAINS[c] "SpikeReader" OR eventMessage CONTAINS[c] "formatreader.spike"' \
    2>/dev/null | grep -v '^Timestamp' | tail -60
  SINCE=$(date '+%Y-%m-%d %H:%M:%S')
}
host() { perl -e 'alarm 60; exec @ARGV' "$APP/Contents/MacOS/SpikeHost" "$CLIPS/clip.avi" "$CLIPS/clip.spk"; echo "host exit $?"; }
plugins() { pluginkit -m -v -A -D -p com.apple.mediaextension.formatreader; pluginkit -m -v -A -D -i "$ID"; }

section system; sw_vers; csrutil status
section install
rm -rf "$APP"; ditto "${1:-build}/SpikeHost.app" "$APP"
"$LSREGISTER" -f -R -trusted "$APP"
sleep 3
codesign -dvv --entitlements - "$APP/Contents/Extensions/SpikeReader.appex" 2>&1 | grep -E 'Identifier|Signature|entitlements|Key|Bool' || true
section types
mdls -name kMDItemContentType -name kMDItemContentTypeTree "$CLIPS/clip.avi" "$CLIPS/clip.spk" 2>&1 || true
section "pluginkit before enabling"; plugins
section "host before enabling"; host; logs
section "enable with pluginkit"; pluginkit -e use -i "$ID"; echo "pluginkit -e exit $?"; sleep 2; plugins
section "host after enabling"; host; logs
section "quick look thumbnails"
mkdir -p "$CLIPS/ql"; perl -e 'alarm 60; exec @ARGV' qlmanage -t -s 256 -o "$CLIPS/ql" "$CLIPS/clip.avi" "$CLIPS/clip.spk" 2>&1 | tail -5; ls -l "$CLIPS/ql"; logs
section "media extension system logs"
/usr/bin/log show --start "$(date -v-10M '+%Y-%m-%d %H:%M:%S')" --style compact \
  --predicate 'process == "MEValidationService" OR subsystem CONTAINS[c] "mediaextension" OR (process == "amfid") OR eventMessage CONTAINS[c] "mediaextension"' \
  2>/dev/null | grep -v '^Timestamp' | tail -80
