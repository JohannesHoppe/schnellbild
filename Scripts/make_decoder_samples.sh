#!/bin/bash
# Writes sample files of QOI, PCX (every kind the app reads), DCX and the
# RAW files the tests give LibRaw (a Casio QV-2000UX raw file, a DNG) into
# <folder> (default build/decoder-samples), from the reference picture of
# Tests/SchnellbildTests/ReferencePicture.swift (encoded by DecoderFixtures.swift):
# the same bytes on every run.
#   Scripts/make_decoder_samples.sh [<folder>]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-build/decoder-samples}"
WORK="$(mktemp -d)"
# bash 3.2 reports an aborted expansion (an unset variable) as success once an
# EXIT trap runs: the trap fails unless the script got to its end.
trap 'rm -rf "$WORK"; [ -n "${finished:-}" ] || exit 1' EXIT
# Top-level code beside another file: the script is the module's main.swift
cp Scripts/make_decoder_samples.swift "$WORK/main.swift"
swiftc -O -o "$WORK/samples" Tests/SchnellbildTests/ReferencePicture.swift Tests/SchnellbildTests/DecoderFixtures.swift "$WORK/main.swift"
"$WORK/samples" "$OUT"
finished=1
