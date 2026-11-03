#!/bin/bash
# Packs build/Schnellbild.app into a DMG to drag into Applications.
# Notarization is split into two steps, so a slow Apple doesn't hold up the
# build (the first notarization of a new account can take days):
#
#   package_dmg.sh dmg      Unsigned build: only build dist/Schnellbild.dmg.
#   package_dmg.sh submit   Signed app -> build the DMG, sign it, submit it to Apple
#                           (Apple checks the app inside as well) without waiting.
#                           Result in dist/signed/: the DMG and the submission ID,
#                           which the release workflow keeps as an artifact.
#   package_dmg.sh finish   With dist/signed/: ask Apple for the status. On
#                           "Accepted" staple the ticket -> dist/Schnellbild.dmg.
#                           Writes result=accepted|pending|invalid to $GITHUB_OUTPUT.
#                           Exits 0 on accepted/pending, 1 on invalid.
#   package_dmg.sh history  List all submissions at Apple with their status.
#
# Environment:
#   MACOS_SIGN_IDENTITY  "Developer ID Application: ..." (submit)
#   MACOS_TEAM_ID        expected team ID of the signature (finish)
#   NOTARY_KEY           path to the API key (.p8); NOTARY_KEY_ID, NOTARY_ISSUER
#   NOTARY_WAIT_MINUTES  how long finish waits for Apple (default 0: ask once)
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="Schnellbild"
APP="build/$NAME.app"
DMG="dist/$NAME.dmg"
SIGNED="dist/signed"
SIGNED_DMG="$SIGNED/$NAME.dmg"
NOTARY_ID="$SIGNED/notary-id.txt"

output() { if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1" >> "$GITHUB_OUTPUT"; fi; }

check_notary_env() {
  : "${NOTARY_KEY:?NOTARY_KEY missing}"
  # Strip blanks/newlines from pasted values
  NOTARY_KEY_ID=$(printf '%s' "${NOTARY_KEY_ID:-}" | tr -d '[:space:]')
  NOTARY_ISSUER=$(printf '%s' "${NOTARY_ISSUER:-}" | tr -d '[:space:]')
  if ! [[ "$NOTARY_KEY_ID" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "NOTARY_KEY_ID is not a key ID (10 characters, as in the file name AuthKey_XXXXXXXXXX.p8)" >&2
    exit 1
  fi
  if ! [[ "$NOTARY_ISSUER" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    echo "NOTARY_ISSUER_ID is not an issuer ID (form xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx," >&2
    echo "shown at the top of the Team Keys page in App Store Connect)" >&2
    exit 1
  fi
}

nt() { xcrun notarytool "$@" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER"; }

# Poll until Accepted/Invalid or the wait time is up. Network hiccups count as
# "?" and polling goes on. Prints the last status.
wait_status() {
  local id=$1 minutes=$2 status deadline
  deadline=$(( $(date +%s) + minutes * 60 ))
  while :; do
    status=$(nt info "$id" --output-format json 2>/dev/null \
             | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' 2>/dev/null || echo "?")
    echo "$(date -u +%H:%M) $id: $status" >&2
    case "$status" in
      Accepted|Invalid|Rejected) echo "$status"; return ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then echo "$status"; return; fi
    sleep 60
  done
}

build_dmg() {
  # Opens as "Schnellbild 1.2.3". The file name stays the same, so the
  # download link in the README always points at the newest version.
  local version stage
  version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
  stage=$(mktemp -d)
  ditto "$APP" "$stage/$NAME.app"
  ln -s /Applications "$stage/Applications"
  mkdir -p dist
  rm -f "$DMG"
  hdiutil create -volname "$NAME $version" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
  rm -rf "$stage"
  echo "Built $DMG ($NAME $version)"
}

case "${1:-}" in
  dmg)
    build_dmg
    ;;

  submit)
    check_notary_env
    : "${MACOS_SIGN_IDENTITY:?MACOS_SIGN_IDENTITY missing}"
    build_dmg
    codesign --force -s "$MACOS_SIGN_IDENTITY" --timestamp "$DMG"
    rm -rf "$SIGNED"; mkdir -p "$SIGNED"
    mv "$DMG" "$SIGNED_DMG"
    echo "== Submitting to Apple"
    out=$(nt submit "$SIGNED_DMG" --output-format json)
    echo "$out"
    echo "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' > "$NOTARY_ID"
    echo "Submitted: $(cat "$NOTARY_ID")"
    ;;

  finish)
    check_notary_env
    : "${MACOS_TEAM_ID:?MACOS_TEAM_ID missing}"
    # Only process a DMG with our signature
    codesign -v "$SIGNED_DMG"
    sig=$(codesign -dv "$SIGNED_DMG" 2>&1)
    grep -qx "TeamIdentifier=$MACOS_TEAM_ID" <<< "$sig" \
      || { echo "DMG is not signed by team $MACOS_TEAM_ID" >&2; exit 1; }
    id=$(tr -d '[:space:]' < "$NOTARY_ID")
    [[ "$id" =~ ^[0-9a-f-]{36}$ ]] || { echo "Invalid submission ID" >&2; exit 1; }
    echo "== Status at Apple"
    status=$(wait_status "$id" "${NOTARY_WAIT_MINUTES:-0}")
    case "$status" in
      Accepted) ;;
      Invalid|Rejected)
        nt log "$id" || true
        echo "Apple rejected the DMG ($status), see the log above." >&2
        output result=invalid
        exit 1
        ;;
      *)
        echo "Apple is still checking ($status). The next run asks again."
        output result=pending
        exit 0
        ;;
    esac
    cp "$SIGNED_DMG" "$DMG"
    # Staple the ticket: the DMG then opens without a warning even offline
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    echo "== Checking like Gatekeeper"
    spctl -a -vv -t open --context context:primary-signature "$DMG"
    MNT=$(mktemp -d)
    hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null
    rc=0; spctl -a -vv -t exec "$MNT/$NAME.app" || rc=$?
    hdiutil detach "$MNT" >/dev/null || true
    [ "$rc" -eq 0 ] || exit 1
    output result=accepted
    ;;

  history)
    check_notary_env
    nt history
    ;;

  *)
    echo "Usage: $0 dmg|submit|finish|history" >&2
    exit 2
    ;;
esac
echo "Done ($1)"
