#!/bin/bash
# Selects the Xcode the workflows build with on a GitHub-hosted macOS runner:
# one exact version per macOS major version of the runner image, from the
# Xcodes the image carries (/Applications/Xcode_<version>.app). Fails, listing
# what the image has, when that version isn't there: a new image without it
# means choosing a new version here, not building with whatever is the default.
#   Scripts/select_xcode.sh
set -euo pipefail

macos="$(sw_vers -productVersion)"
case "${macos%%.*}" in
    15) version="26.3" ;;
    26) version="26.6" ;;
    *) echo "!! no Xcode chosen for macOS $macos in Scripts/select_xcode.sh" >&2; exit 1 ;;
esac

app=""
for candidate in "/Applications/Xcode_$version.app" "/Applications/Xcode_$version.0.app"; do
    if [ -d "$candidate" ]; then
        app="$candidate"
        break
    fi
done
if [ -z "$app" ]; then
    echo "!! Xcode $version is not on this runner (macOS $macos). The image has:" >&2
    ls -d /Applications/Xcode*.app >&2 || true
    exit 1
fi

sudo xcode-select -s "$app/Contents/Developer"
echo "==> macOS $macos, $app"
xcodebuild -version
