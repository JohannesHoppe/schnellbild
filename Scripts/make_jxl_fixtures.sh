#!/bin/bash
# Writes the JPEG XL pictures ImageFormatTests decodes into
# Tests/SchnellbildTests/Pictures (ImageIO reads JPEG XL but doesn't write
# it, so a test can't make them), both lossless (`-d 0`): `picture.jxl`, the
# visual checks' reference picture; `alpha.jxl`, the reference picture with
# alpha (its lower part fading out, a hole in the bars). The sources are the
# PNGs of Scripts/make_decoder_samples.sh, which the tests make again
# themselves (`DecoderFixtures.reference`). Needs libjxl's cjxl and swiftc;
# the files are committed, so tests don't. cjxl runs only on a GitHub Actions
# runner (.github/workflows/jxl-fixtures.yml), which writes them as an
# artifact.
#   Scripts/make_jxl_fixtures.sh [<folder>]   (default Tests/SchnellbildTests/Pictures)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-Tests/SchnellbildTests/Pictures}"
command -v cjxl > /dev/null || { echo "!! cjxl (libjxl) not found" >&2; exit 1; }
cjxl --version
WORK="$(mktemp -d)"
# bash 3.2 reports an aborted expansion (an unset variable) as success once an
# EXIT trap runs: the trap fails unless the script got to its end.
trap 'rm -rf "$WORK"; [ -n "${finished:-}" ] || exit 1' EXIT
mkdir -p "$OUT"
Scripts/make_decoder_samples.sh "$WORK" > /dev/null
cjxl --quiet -d 0 "$WORK/reference.png" "$OUT/picture.jxl"
cjxl --quiet -d 0 "$WORK/reference-alpha.png" "$OUT/alpha.jxl"
if [ -n "${SOURCES:-}" ]; then
    mkdir -p "$SOURCES"
    cp "$WORK/reference.png" "$WORK/reference-alpha.png" "$SOURCES/"
fi
ls -l "$OUT"
finished=1
