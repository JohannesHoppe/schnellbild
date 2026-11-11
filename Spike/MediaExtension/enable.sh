#!/bin/bash
# On a CI runner: installs the spike app, turns its format reader on in
# System Settings by UI scripting (as a user would), and shows what that
# changed on disk and whether the reader then runs. Prints everything,
# keeps screenshots in $OUT.
set -uo pipefail
cd "$(dirname "$0")"
APP=/Applications/SpikeHost.app
OUT=${2:-$PWD/out}
mkdir -p "$OUT"
READER_ID=${READER_ID:-art.haushoppe.schnellbild.spikehost.reader}
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
CLIPS=$(mktemp -d)
cp ../../Tests/SchnellbildTests/Videos/clip.avi "$CLIPS/clip.spk"
section() { echo; echo "== $*"; }
host() { perl -e 'alarm 30; exec @ARGV' "$APP/Contents/MacOS/SpikeHost" "$CLIPS/clip.spk"; }
shot() { screencapture -x "$OUT/$1.png" 2>&1 || echo "(no screenshot)"; }

section system; sw_vers; csrutil status
rm -rf "$APP"; ditto "${1:-build}/SpikeHost.app" "$APP"
"$LSREGISTER" -f -R -trusted "$APP"; sleep 3
section "host before"; host

MARK=$(mktemp); sleep 1
section "System Settings"
open "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.mediaextension.formatreader"
sleep 10; shot 1-opened
osascript <<'AS' 2>&1 | head -80
tell application "System Events" to tell process "System Settings"
  set frontmost to true
  delay 1
  set out to "windows: " & (count of windows) & linefeed
  repeat with w in windows
    set out to out & "window " & (name of w as text) & ", sheets: " & (count of sheets of w) & linefeed
    repeat with s in sheets of w
      repeat with e in (entire contents of s)
        try
          set out to out & (class of e as text) & " | " & (name of e as text) & " | " & (description of e as text) & " | " & (value of e as text) & linefeed
        on error
          try
            set out to out & (class of e as text) & linefeed
          end try
        end try
      end repeat
    end repeat
  end repeat
  return out
end tell
AS
section "turn the reader's switch on"
osascript <<'AS' 2>&1
tell application "System Events" to tell process "System Settings"
  set n to 0
  repeat with w in windows
    repeat with s in sheets of w
      repeat with e in (entire contents of s)
        try
          if (class of e is checkbox) or (role of e is "AXSwitch") then
            if value of e is 0 then
              click e
              set n to n + 1
            end if
          end if
        end try
      end repeat
    end repeat
  end repeat
  return "clicked by UI scripting: " & n
end tell
AS
sleep 3; shot 2a-after-scripting
section "host after UI scripting"; host
# Where the screenshots show the switch (1024 × 768 screen, the sheet centred)
swift click.swift 675 297 2>&1
sleep 4; shot 2-switched
section "host after"; host
section "the reader's own notes (its container)"
cat "$HOME/Library/Containers/$READER_ID/Data/spike-notes.txt" 2>&1
section "quick look thumbnail of clip.spk, now that it is on (as Finder asks)"
NOTES="$HOME/Library/Containers/$READER_ID/Data/spike-notes.txt"
ASKED=$(grep -c 'asked for' "$NOTES" 2>/dev/null || echo 0)
swiftc -O probe-me.swift -o "$CLIPS/probe" 2>&1 | tail -3
QLSINCE=$(date '+%Y-%m-%d %H:%M:%S')
PROBE_MEDIA_EXTENSIONS=1 perl -e 'alarm 60; exec @ARGV' "$CLIPS/probe" "$CLIPS/clip.spk" "$OUT/3-thumbnail.png" 2>&1
echo "asks before: $ASKED, after: $(grep -c 'asked for' "$NOTES" 2>/dev/null || echo 0)"
section "again after Quick Look is reset and restarted (it may have read the switch before it was on)"
qlmanage -r 2>&1 | tail -1; qlmanage -r cache 2>&1 | tail -1
killall AudiovisualThumbnailExtension 2>/dev/null; killall -kill -m SpikeReader 2>/dev/null; killall -9 com.apple.quicklook.ThumbnailsAgent QuickLookUIService 2>/dev/null; sleep 3
ASKED=$(grep -c 'asked for' "$NOTES" 2>/dev/null || echo 0)
PROBE_MEDIA_EXTENSIONS=1 perl -e 'alarm 60; exec @ARGV' "$CLIPS/probe" "$CLIPS/clip.spk" "$OUT/4-thumbnail-after-reset.png" 2>&1
echo "asks before: $ASKED, after: $(grep -c 'asked for' "$NOTES" 2>/dev/null || echo 0)"
cp ../../Tests/SchnellbildTests/Videos/clip.mkv "$CLIPS/other.spk"
PROBE_MEDIA_EXTENSIONS=1 perl -e 'alarm 60; exec @ARGV' "$CLIPS/probe" "$CLIPS/other.spk" 2>&1
echo "asks after a second, never seen file: $(grep -c 'asked for' "$NOTES" 2>/dev/null || echo 0)"
cat "$NOTES" 2>&1
section "who handled the thumbnail request"
/usr/bin/log show --info --start "$QLSINCE" --style compact \
  --predicate 'process CONTAINS[c] "Thumbnail" OR process CONTAINS[c] "quicklook" OR eventMessage CONTAINS[c] "clip.spk" OR eventMessage CONTAINS[c] "mediaextension"' \
  2>/dev/null | grep -vE 'log run' | tail -40
section "the reader process in the log"
/usr/bin/log show --info --debug --start "$(date -v-4M '+%Y-%m-%d %H:%M:%S')" --style compact --predicate 'process == "SpikeReader"' 2>/dev/null | tail -30
section "settings containers"
for d in "$HOME/Library/Containers/com.apple.MediaExtensions-Settings" "$HOME/Library/Containers/com.apple.ExtensionsSettings.DefaultExtensionEnablement"; do
  echo "--- $d"; find "$d" -type f -newer "$MARK" 2>/dev/null | head; done
section "every plist changed, searched for the reader"
for f in $(find "$HOME/Library" -newer "$MARK" -name '*.plist' -type f 2>/dev/null) $(sudo find /Library /private/var/db -newer "$MARK" -name '*.plist' -type f 2>/dev/null); do
  if sudo plutil -p "$f" 2>/dev/null | grep -qiE 'spike|formatreader|haushoppe'; then echo "--- $f"; sudo plutil -p "$f" | grep -i -B3 -A3 -E 'spike|formatreader|haushoppe' | head -40; fi
done
section "files changed meanwhile (home)"
find "$HOME/Library" -newer "$MARK" -type f 2>/dev/null | grep -vE '/Caches/|/Logs/|\.db-(wal|shm)$|/Saved Application State/|/Biome/|/Metadata/|/Assistants/' | head -60
section "files changed meanwhile (system)"
sudo find /Library /private/var/db /private/var/root/Library -newer "$MARK" -type f 2>/dev/null | grep -vE '/Caches/|/Logs/|/uuidtext/|/diagnostics/|\.db-(wal|shm)$' | head -60
section "plists among them"
for f in $(find "$HOME/Library/Preferences" "$HOME/Library/Group Containers" -newer "$MARK" -name '*.plist' -type f 2>/dev/null | head -20); do
  echo "--- $f"; plutil -p "$f" 2>/dev/null | grep -i -B2 -A2 -E 'spike|mediaextension|formatreader|haushoppe' | head -30
done
section "who logged about it"
/usr/bin/log show --start "$(date -v-3M '+%Y-%m-%d %H:%M:%S')" --style compact \
  --predicate 'eventMessage CONTAINS[c] "spikehost" OR eventMessage CONTAINS[c] "formatreader.spike" OR subsystem == "art.haushoppe.schnellbild.spike"' 2>/dev/null | tail -60
