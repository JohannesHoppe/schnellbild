#!/bin/bash
# On a CI runner: QuickLook Video (Marginal), whose Media Extensions give
# Finder thumbnails on the user's Macs, installed and turned on as a user
# would; then Quick Look is asked for thumbnails of MKV, AVI and WebM clips
# as Finder asks. Answers whether Media Extension thumbnails can work on
# these runners at all. $1: the QuickLook Video DMG.
set -uo pipefail
cd "$(dirname "$0")"
OUT=${2:-$PWD/out}; mkdir -p "$OUT"
section() { echo; echo "== $*"; }
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
CLIPS=$(mktemp -d)
for ext in mkv avi webm; do cp ../../Tests/SchnellbildTests/Videos/clip.$ext "$CLIPS/"; done
swiftc -O ../../Scripts/thumbnail_probe.swift -o "$CLIPS/probe" 2>&1 | tail -2
probe() { for ext in mkv avi webm; do perl -e 'alarm 60; exec @ARGV' "$CLIPS/probe" "$CLIPS/clip.$ext" "$OUT/$1-$ext.png" 2>&1; done; }

section system; sw_vers
section "the app, as signed"
MNT=$(mktemp -d); hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MNT" "$1" >/dev/null
SRC=$(find "$MNT" -maxdepth 1 -name '*.app' | head -1)
codesign -dvv "$SRC" 2>&1 | grep -E 'Authority=Developer ID|TeamIdentifier'
spctl -a -vv "$SRC" 2>&1 | head -3
ditto "$SRC" "/Applications/$(basename "$SRC")"; hdiutil detach "$MNT" >/dev/null
APP="/Applications/$(basename "$SRC")"
"$LSREGISTER" -f -R -trusted "$APP"
section "thumbnails before turning anything on"; probe 0-before
section "launch it once (registers its extensions)"
open "$APP"; sleep 10; osascript -e 'tell application "QuickLook Video" to quit' 2>/dev/null; sleep 2
pluginkit -m -v -p com.apple.mediaextension.formatreader; pluginkit -m -v -p com.apple.mediaextension.videodecoder
section "System Settings: turn its Media Extensions on"
open "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.mediaextension.formatreader"
sleep 10; screencapture -x "$OUT/1-formatreaders.png"
swift ax-enable.swift 2>&1
sleep 3; screencapture -x "$OUT/2-formatreaders-on.png"
osascript -e 'tell application "System Settings" to quit' 2>/dev/null; sleep 2
open "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.mediaextension.videodecoder"
sleep 10; screencapture -x "$OUT/3-decoders.png"
swift ax-enable.swift 2>&1
sleep 3; screencapture -x "$OUT/4-decoders-on.png"
section "Refresh, as its app does (Quick Look cache, the thumbnailer, its extensions)"
qlmanage -r cache 2>&1 | tail -1
killall AudiovisualThumbnailExtension 2>/dev/null; killall -kill -m "QLVideo (Formats|Codecs)" 2>/dev/null; sleep 3
section "thumbnails with its Media Extensions on"; probe 5-after
section "who handled them"
/usr/bin/log show --info --start "$(date -v-2M '+%Y-%m-%d %H:%M:%S')" --style compact \
  --predicate 'process CONTAINS "QLVideo" OR (process == "AudiovisualThumbnailExtension" AND messageType == error)' 2>/dev/null | grep -v 'log run' | tail -30
