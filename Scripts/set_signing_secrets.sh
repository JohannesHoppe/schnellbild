#!/bin/bash
# Checks Apple's signing files and puts them into the GitHub secrets of the
# environment "release" (docs/SIGNING.md). Run on the Mac that holds the files,
# with gh logged in. Every file is checked by its content before anything is
# uploaded: the certificate's name in each .p12, the App ID in each profile, and
# that the profile was made for that very certificate.
#
#   set_signing_secrets.sh appstore APP.p12 INSTALLER.p12 APP.provisionprofile \
#       THUMBNAILS.provisionprofile FORMATS.provisionprofile
#       Mac App Store: "Apple Distribution" + "3rd Party Mac Developer Installer"
#       (or "Mac Installer Distribution"), three "Mac App Store Connect" profiles.
#   set_signing_secrets.sh developer-id DEVID.p12 FORMATS.provisionprofile
#       The DMG: "Developer ID Application" + the format reader's Developer ID profile.
#   set_signing_secrets.sh p12 CERT.cer KEY.p12 OUT.p12
#       Makes OUT.p12 from a downloaded certificate and the private key inside
#       KEY.p12 (two certificates made from one signing request share a key,
#       and Keychain Access then exports the same one for both).
#
# The .p12 password is asked once (not echoed, not in the shell history); all
# .p12 files of one call share it.
set -euo pipefail

REPO="${REPO:-JohannesHoppe/schnellbild}"
TEAM="87884AP46G"
OPENSSL=/usr/bin/openssl
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"

fail() { echo "error: $*" >&2; exit 1; }

ask_password() {
  read -r -s -p "Password of the .p12 file(s): " P12_PASSWORD; echo
  export P12_PASSWORD
}

# The certificate inside a .p12, as DER, into $2.
p12_cert() {
  "$OPENSSL" pkcs12 -in "$1" -nokeys -clcerts -passin env:P12_PASSWORD 2>/dev/null \
    | "$OPENSSL" x509 -outform der -out "$2" 2>/dev/null || fail "$1: can't read it (wrong password?)"
  "$OPENSSL" pkcs12 -in "$1" -nocerts -nodes -passin env:P12_PASSWORD 2>/dev/null | grep -q "PRIVATE KEY" \
    || fail "$1: no private key in it (export the certificate line under My Certificates, not the .cer)"
}

common_name() { "$OPENSSL" x509 -inform der -in "$1" -noout -subject | sed -E 's/.*CN ?= ?([^,/]*).*/\1/'; }

# Checks the .p12 holds a certificate whose name starts with one of the
# given prefixes (as a grep -E alternative); prints the name.
check_p12() {
  local p12="$1" der="$TMP/$(basename "$1").der" want="$2" name
  p12_cert "$p12" "$der"
  name="$(common_name "$der")"
  echo "$name" | grep -qE "^($want): .*\($TEAM\)$" \
    || fail "$p12 holds \"$name\", expected $want of team $TEAM"
  local end; end="$("$OPENSSL" x509 -inform der -in "$der" -noout -enddate | cut -d= -f2)"
  echo "  $p12: $name, valid until $end" >&2
}

# Checks a profile is for the App ID and was made for the certificate of the .p12.
check_profile() {
  local profile="$1" app_id="$2" p12_der="$3" plist="$TMP/profile.plist" id end i found=""
  security cms -D -i "$profile" > "$plist" 2>/dev/null || fail "$profile: not a provisioning profile"
  id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$plist")"
  [ "$id" = "$TEAM.$app_id" ] || fail "$profile is for $id, expected $TEAM.$app_id"
  end="$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$plist")"
  for i in 0 1 2 3 4 5 6 7 8 9; do
    plutil -extract "DeveloperCertificates.$i" raw -o - "$plist" 2>/dev/null | base64 -D > "$TMP/c.der" 2>/dev/null || break
    [ -s "$TMP/c.der" ] || break
    if cmp -s "$TMP/c.der" "$p12_der"; then found=1; break; fi
  done
  [ -n "$found" ] || fail "$profile wasn't made for the certificate in the .p12 (make the profile again with that certificate)"
  echo "  $profile: $id, valid until $end" >&2
}

set_secret() { echo "  secret $1"; gh secret set "$1" --env release -R "$REPO" >/dev/null; }
set_file()   { base64 -i "$2" | set_secret "$1"; }

case "${1:-}" in
  appstore)
    [ $# -eq 6 ] || fail "usage: $0 appstore APP.p12 INSTALLER.p12 APP.provisionprofile THUMBNAILS.provisionprofile FORMATS.provisionprofile"
    ask_password
    echo "Checking …"
    check_p12 "$2" "Apple Distribution|3rd Party Mac Developer Application"
    check_p12 "$3" "3rd Party Mac Developer Installer|Mac Installer Distribution"
    APP_DER="$TMP/$(basename "$2").der"
    check_profile "$4" art.haushoppe.schnellbild "$APP_DER"
    check_profile "$5" art.haushoppe.schnellbild.thumbnails "$APP_DER"
    check_profile "$6" art.haushoppe.schnellbild.formatreader "$APP_DER"
    echo "Setting the secrets of $REPO (environment release) …"
    set_file APPSTORE_APP_P12 "$2"
    set_file APPSTORE_INSTALLER_P12 "$3"
    printf '%s' "$P12_PASSWORD" | set_secret APPSTORE_CERT_PASSWORD
    set_file APPSTORE_PROFILE_APP "$4"
    set_file APPSTORE_PROFILE_THUMBNAILS "$5"
    set_file APPSTORE_PROFILE_FORMATREADER "$6"
    echo "Done. Check: gh workflow run appstore.yml (signs only if all is right)."
    ;;
  developer-id)
    [ $# -eq 3 ] || fail "usage: $0 developer-id DEVID.p12 FORMATS.provisionprofile"
    ask_password
    echo "Checking …"
    check_p12 "$2" "Developer ID Application"
    check_profile "$3" art.haushoppe.schnellbild.formatreader "$TMP/$(basename "$2").der"
    echo "Setting the secrets of $REPO (environment release) …"
    set_file MACOS_CERT_P12 "$2"
    printf '%s' "$P12_PASSWORD" | set_secret MACOS_CERT_PASSWORD
    set_file MACOS_PROFILE_FORMATREADER "$3"
    echo "Done. The next release (or release.yml by hand) signs with it."
    ;;
  p12)
    [ $# -eq 4 ] || fail "usage: $0 p12 CERT.cer KEY.p12 OUT.p12"
    [ ! -e "$4" ] || fail "$4 exists; pick a new name"
    ask_password
    "$OPENSSL" x509 -inform der -in "$2" -out "$TMP/cert.pem" 2>/dev/null \
      || "$OPENSSL" x509 -in "$2" -out "$TMP/cert.pem" 2>/dev/null || fail "$2: not a certificate"
    (umask 077; "$OPENSSL" pkcs12 -in "$3" -nocerts -nodes -passin env:P12_PASSWORD -out "$TMP/key.pem" 2>/dev/null) \
      || fail "$3: can't read it (wrong password?)"
    [ "$("$OPENSSL" x509 -in "$TMP/cert.pem" -noout -pubkey)" = "$("$OPENSSL" pkey -in "$TMP/key.pem" -pubout)" ] \
      || fail "the key in $3 doesn't belong to $2 (it came from another signing request)"
    NAME="$("$OPENSSL" x509 -in "$TMP/cert.pem" -noout -subject | sed -E 's/.*CN ?= ?([^,/]*).*/\1/')"
    "$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
      -passout env:P12_PASSWORD -out "$4"
    rm -P "$TMP/key.pem"
    echo "$4: $NAME (same password)"
    ;;
  *)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
