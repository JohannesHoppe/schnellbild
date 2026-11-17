#!/bin/bash
# The app under test is the app that ships: it and its extensions are signed
# with exactly the entitlements of Sandbox/ (FormatReader/ for the media
# extension) without what only a profile allows (Scripts/entitlements.sh),
# nothing more and nothing less, so the UI tests meet the App Sandbox a user
# meets. Fails on any difference, a missing App Sandbox or a temporary
# exception. Looser rights belong to the test runner only, never to the app.
#
#   Scripts/check_entitlements.sh <Schnellbild.app>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?usage: check_entitlements.sh <Schnellbild.app>}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; [ -n "${finished:-}" ] || exit 1' EXIT

"$ROOT/Scripts/entitlements.sh" --all "$TMP/want"

# check <bundle> <expected entitlements>
failed=0
check() {
  local bundle="$1" want="$2" got="$TMP/got-$(basename "$1").plist"
  if ! codesign -d --entitlements - --xml "$bundle" > "$got" 2>/dev/null || [ ! -s "$got" ]; then
    echo "!! $bundle: no entitlements in its signature" >&2; failed=1; return
  fi
  if ! python3 -I - "$want" "$got" "$bundle" <<'EOF'
import plistlib, sys
want_path, got_path, bundle = sys.argv[1:4]
with open(want_path, "rb") as f: want = plistlib.load(f)
with open(got_path, "rb") as f: got = plistlib.load(f)
problems = []
if got.get("com.apple.security.app-sandbox") is not True:
    problems.append("not in the App Sandbox")
problems += [f"temporary exception {k}" for k in got if "temporary-exception" in k]
problems += [f"more than shipped: {k} = {got[k]!r}" for k in sorted(set(got) - set(want))]
problems += [f"less than shipped: {k}" for k in sorted(set(want) - set(got))]
problems += [f"{k}: {got[k]!r}, shipped {want[k]!r}" for k in sorted(set(want) & set(got)) if want[k] != got[k]]
if problems:
    print(f"!! {bundle}:", file=sys.stderr)
    for p in problems: print(f"   {p}", file=sys.stderr)
    sys.exit(1)
print(f"   {bundle}: {len(got)} entitlements, as shipped: " + ", ".join(sorted(got)))
EOF
  then failed=1; fi
}

echo "==> The entitlements of $APP"
check "$APP" "$TMP/want/app.entitlements"
check "$APP/Contents/PlugIns/SchnellbildThumbnails.appex" "$TMP/want/thumbnails.entitlements"
# The media extension: in the bundle build_app.sh makes, not in the Xcode build
FORMATS="$APP/Contents/Extensions/SchnellbildFormats.appex"
if [ -d "$FORMATS" ]; then check "$FORMATS" "$TMP/want/formats.entitlements"; fi
[ "$failed" = 0 ] || { echo "!! the app under test isn't signed as it ships" >&2; exit 1; }
echo "==> Signed as it ships, in the App Sandbox"
finished=1
