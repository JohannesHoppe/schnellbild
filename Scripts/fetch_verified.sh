#!/bin/bash
# Sourced by the fetch scripts: downloads a file and accepts it only with the
# pinned SHA-256, else aborts. Messages go to stderr (fetch_xcodegen.sh's
# stdout is the folder it prints for $GITHUB_PATH).
#   fetch_verified <name> <url> <sha256> <output file> [<fallback url> …]
# The URLs are tried in order; the next one only when a download fails (a
# server down), never when a download came with another SHA-256.

# This repository's release assets: $RELEASES/<tag>/<file>
RELEASES="https://github.com/JohannesHoppe/schnellbild/releases/download"

#   sha256_of <file>
sha256_of() {
    shasum -a 256 "$1" | awk '{print $1}'
}

fetch_verified() {
    local name="$1" url="$2" expected="$3" out="$4"
    shift 4
    local urls=("$url" "$@") actual=""
    echo "==> Downloading ${name} …" >&2
    for url in "${urls[@]}"; do
        if curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors -o "$out" "$url"; then
            actual="$(sha256_of "$out")"
            break
        fi
        echo "   not available from $url" >&2
    done
    if [ -z "$actual" ]; then
        echo "!! ${name}: no download worked." >&2
        exit 1
    fi
    if [ "$actual" != "$expected" ]; then
        echo "!! ${name}: SHA-256 mismatch — refusing this download ($url)." >&2
        echo "   expected $expected" >&2
        echo "   got      $actual" >&2
        exit 1
    fi
    echo "   SHA-256 ok: $actual ($url)" >&2
}

# <dest>/<file> from <base>/<file>, checked against <sha256>; a file there
# already is kept while its SHA-256 matches. The download lands next to it
# as <file>.part and takes its name only once checked.
#   fetch_pinned <dest> <base> <file> <sha256>
fetch_pinned() {
    local dest="$1" base="$2" file="$3" sha="$4"
    if [ -f "$dest/$file" ] && [ "$(sha256_of "$dest/$file")" = "$sha" ]; then
        echo "==> $file already there — skipping."
        return
    fi
    ( fetch_verified "$file" "$base/$file" "$sha" "$dest/$file.part" ) || { rm -f "$dest/$file.part"; exit 1; }
    mv "$dest/$file.part" "$dest/$file"
}

# Removes everything in <dest> but the files named, hidden ones and
# symbolic links included: those of another build don't go into the app.
#   prune_except <dest> <pinned in> <name> …
prune_except() {
    local dest="$1" pinned="$2" old name keep
    shift 2
    for old in "$dest"/* "$dest"/.[!.]* "$dest"/..?*; do
        [ -e "$old" ] || [ -L "$old" ] || continue
        name="$(basename "$old")"
        for keep in "$@" ""; do
            [ "$name" = "$keep" ] && break
        done
        [ -n "$keep" ] || { echo "==> Removing $name (not in $pinned)"; rm -rf "$old"; }
    done
}

# The SHA-256 of a vendored folder as it is on disk: every file's path and
# SHA-256, every symbolic link's path and target, in a fixed order (stamps
# and Finder's .DS_Store left out). The fetch scripts pin it next to the
# download's, so a vendored copy that was changed after it was checked (a CI
# cache, a local edit) is fetched and checked again instead of used.
#   tree_sha256 <folder>
tree_sha256() {
    (
        cd "$1" || exit 1
        find . -type f ! -name .version ! -name .DS_Store -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256
        find . -type l -print0 | LC_ALL=C sort -z | while IFS= read -r -d '' link; do
            printf 'link %s -> %s\n' "$link" "$(readlink "$link")"
        done
    ) | shasum -a 256 | awk '{print $1}'
}

# Fails unless <folder>'s tree_sha256 is <sha256>.
#   check_tree <name> <folder> <sha256>
check_tree() {
    local actual
    actual="$(tree_sha256 "$2")"
    if [ "$actual" != "$3" ]; then
        echo "!! $1: the unpacked files are not the ones pinned (tree SHA-256)." >&2
        echo "   expected $3" >&2
        echo "   got      $actual" >&2
        exit 1
    fi
}
