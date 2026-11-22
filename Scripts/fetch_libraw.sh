#!/bin/bash
# Fetches the LibRaw source as LibRaw LLC publishes it (libraw.org's
# download page; its GitHub release carries no files) and vendors it into
# Vendor/libraw, where Package.swift and project.yml compile it into the app
# (Native/CRaw/libraw points there). The same file is kept as an asset of
# this repository's pre-release build-deps, downloaded first, so a build
# doesn't depend on libraw.org being up. LibRaw publishes no checksum, so
# the SHA-256 is the one of the download that was reviewed when the version
# was pinned (its sources are those of the tag 0.22.3, commit cf02d66, on
# github.com/LibRaw/LibRaw; the tarball adds autotools' generated files);
# any other content aborts. LibRaw is used under the CDDL 1.0
# (Vendor/libraw/LICENSE.CDDL, see THIRD-PARTY-NOTICES.md), unchanged.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
source "$ROOT/Scripts/fetch_verified.sh"

VERSION="0.22.3"
URL="$RELEASES/build-deps/LibRaw-$VERSION.tar.gz"
UPSTREAM_URL="https://www.libraw.org/data/LibRaw-$VERSION.tar.gz"
SHA256="789f3c33466210a1a0907f747a97c715d21bbf4af712f257fcbbd90111b227e4"
# tree_sha256 (fetch_verified.sh) of Vendor/libraw as unpacked; a vendored
# copy is used only while it matches (a changed CI cache or local copy is
# fetched again)
TREE_SHA256="180bb2b609115502fa490249f012bd427a78b6ee36fd14cf5e6ddd08ba8a1d94"

DEST="$ROOT/Vendor/libraw"
if [ -f "$DEST/.version" ] && [ "$(cat "$DEST/.version")" = "$VERSION" ] \
    && [ "$(tree_sha256 "$DEST")" = "$TREE_SHA256" ]; then
    exit 0
fi

TMP="$(mktemp -d)"
# bash 3.2 reports an aborted expansion (an unset variable) as success once an
# EXIT trap runs: the trap fails unless the script got to its end.
trap 'rm -rf "$TMP"; [ -n "${finished:-}" ] || exit 1' EXIT
fetch_verified "LibRaw $VERSION source" "$URL" "$SHA256" "$TMP/libraw.tar.gz" "$UPSTREAM_URL"
tar -xzf "$TMP/libraw.tar.gz" -C "$TMP"
[ -f "$TMP/LibRaw-$VERSION/libraw/libraw.h" ] || { echo "!! unexpected LibRaw archive layout" >&2; exit 1; }
check_tree "LibRaw $VERSION" "$TMP/LibRaw-$VERSION" "$TREE_SHA256"
rm -rf "$DEST"
mkdir -p "$ROOT/Vendor"
mv "$TMP/LibRaw-$VERSION" "$DEST"
echo "$VERSION" > "$DEST/.version"
echo "==> Vendored: $DEST"
finished=1
