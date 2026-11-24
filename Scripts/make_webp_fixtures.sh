#!/bin/bash
# Writes the WebP pictures ImageFormatTests decodes into
# Tests/SchnellbildTests/Pictures (ImageIO reads WebP but doesn't write it, so
# a test can't make them): `picture.webp`, the visual checks' reference
# picture, lossless; `animated.webp`, two frames (the reference, then its
# black and white form) shown 250 ms and 500 ms. Needs libwebp's cwebp and
# img2webp and swiftc; the files are committed, so tests don't.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=Tests/SchnellbildTests/Pictures
WORK="$(mktemp -d)"
# bash 3.2 reports an aborted expansion (an unset variable) as success once an
# EXIT trap runs: the trap fails unless the script got to its end.
trap 'rm -rf "$WORK"; [ -n "${finished:-}" ] || exit 1' EXIT
mkdir -p "$OUT"
Scripts/make_decoder_samples.sh "$WORK" > /dev/null
cwebp -quiet -lossless -exact -metadata none "$WORK/reference.png" -o "$OUT/picture.webp"
img2webp -lossless -exact -d 250 "$WORK/reference.png" -d 500 "$WORK/1-bit-expected.png" -o "$OUT/animated.webp"
ls -l "$OUT"
finished=1
