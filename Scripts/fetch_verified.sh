#!/bin/bash
# Sourced by the fetch scripts: downloads a file and accepts it only with the
# pinned SHA-256, else aborts. Messages go to stderr (fetch_xcodegen.sh's
# stdout is the folder it prints for $GITHUB_PATH).
#   fetch_verified <name> <url> <sha256> <output file>
fetch_verified() {
    local name="$1" url="$2" expected="$3" out="$4"
    echo "==> Downloading ${name} …" >&2
    curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors -o "$out" "$url"
    local actual
    actual="$(shasum -a 256 "$out" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        echo "!! ${name}: SHA-256 mismatch — refusing this download." >&2
        echo "   expected $expected" >&2
        echo "   got      $actual" >&2
        exit 1
    fi
    echo "   SHA-256 ok: $actual" >&2
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
