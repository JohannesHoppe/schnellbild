#!/bin/bash
# Sourced by the fetch scripts: downloads a file and accepts it only with the
# pinned SHA-256, else aborts. Messages go to stderr (fetch_xcodegen.sh's
# stdout is the folder it prints for $GITHUB_PATH).
#   fetch_verified <name> <url> <sha256> <output file>
fetch_verified() {
    local name="$1" url="$2" expected="$3" out="$4"
    echo "==> Downloading $name…" >&2
    curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors -o "$out" "$url"
    local actual
    actual="$(shasum -a 256 "$out" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        echo "!! $name: SHA-256 mismatch — refusing this download." >&2
        echo "   expected $expected" >&2
        echo "   got      $actual" >&2
        exit 1
    fi
    echo "   SHA-256 ok: $actual" >&2
}
