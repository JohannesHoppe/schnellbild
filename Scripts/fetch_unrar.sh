#!/bin/bash
# Fetches the OFFICIAL UnRAR source by RARLAB (the RAR author) and vendors it
# into Vendor/unrar, where Package.swift and project.yml compile it into the
# app (Native/CArchives/unrar points there). RARLAB publishes no checksum, so
# the SHA-256 is the one of the download that was reviewed when the version
# was pinned; any other content aborts. UnRAR's license (Vendor/unrar/
# license.txt) allows extracting RAR archives freely; it may not be used to
# make a RAR-compatible archiver.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
source "$ROOT/Scripts/fetch_verified.sh"

# A release, not a beta (version.hpp: RARVER_BETA 0); 7.2.7 is RAR 7.23
VERSION="7.2.7"
# Bumped when the patch below changes, so a vendored copy is made again
PATCHLEVEL="tls1"
URL="https://www.rarlab.com/rar/unrarsrc-$VERSION.tar.gz"
SHA256="01d903a7dcf413cb2925696d7796e48e38d471f79bfe7ef3ad2aebf6c12dbefd"
# tree_sha256 (fetch_verified.sh) of Vendor/unrar, unpacked and patched; a
# vendored copy is used only while it matches (a changed CI cache or local
# copy is fetched again)
TREE_SHA256="38fa45dcbd7959f8fe7ea637b0238b6d32d1817a20c1a8260cd1b58e6e31c814"

DEST="$ROOT/Vendor/unrar"
if [ -f "$DEST/.version" ] && [ "$(cat "$DEST/.version")" = "$VERSION+$PATCHLEVEL" ] \
    && [ "$(tree_sha256 "$DEST")" = "$TREE_SHA256" ]; then
    exit 0
fi

TMP="$(mktemp -d)"
# bash 3.2 reports an aborted expansion (an unset variable) as success once an
# EXIT trap runs: the trap fails unless the script got to its end.
trap 'rm -rf "$TMP"; [ -n "${finished:-}" ] || exit 1' EXIT
fetch_verified "UnRAR $VERSION source from rarlab.com" "$URL" "$SHA256" "$TMP/unrar.tar.gz"
tar -xzf "$TMP/unrar.tar.gz" -C "$TMP"
[ -f "$TMP/unrar/dll.hpp" ] || { echo "!! unexpected UnRAR archive layout" >&2; exit 1; }
# One error state per thread: UnRAR keeps one for the process (ErrHandler),
# and the app reads several archives at once — another thread's error (a
# wrong password tried elsewhere, a stopped stream) must not fail this read.
grep -q '^EXTVAR ErrorHandler ErrHandler;$' "$TMP/unrar/global.hpp" || { echo "!! UnRAR's ErrHandler declaration changed" >&2; exit 1; }
sed -i.orig 's/^EXTVAR ErrorHandler ErrHandler;$/EXTVAR thread_local ErrorHandler ErrHandler;/' "$TMP/unrar/global.hpp"
rm "$TMP/unrar/global.hpp.orig"
check_tree "UnRAR $VERSION+$PATCHLEVEL" "$TMP/unrar" "$TREE_SHA256"
rm -rf "$DEST"
mkdir -p "$ROOT/Vendor"
mv "$TMP/unrar" "$DEST"
echo "$VERSION+$PATCHLEVEL" > "$DEST/.version"
echo "==> Vendored: $DEST"
finished=1
