#!/bin/bash
# Sets up (or removes) the signing certificate and the Apple API key on the CI runner.
#
#   macos-signing.sh setup        needs P12 (base64), P12_PASSWORD, P8; writes
#                                 MACOS_SIGN_IDENTITY and NOTARY_KEY to $GITHUB_ENV
#   macos-signing.sh notary-key   only the Apple API key (P8) -> NOTARY_KEY
#   macos-signing.sh cleanup
#
# Never prints secret values, only counts and the certificate's public name.
set -euo pipefail

KC="$RUNNER_TEMP/signing.keychain-db"

case "${1:-}" in
  setup)
    KC_PW=$(openssl rand -hex 24)
    security create-keychain -p "$KC_PW" "$KC"
    security set-keychain-settings -lut 21600 "$KC"
    security unlock-keychain -p "$KC_PW" "$KC"
    printf '%s' "$P12" | base64 --decode > "$RUNNER_TEMP/cert.p12"
    # "security import" can't read a .p12 exported by Keychain Access here ("MAC
    # verification failed"). Read it with OpenSSL (-legacy: Keychain Access encrypts
    # with RC2-40) and repack it with 3DES/SHA-1.
    OPENSSL="$(brew --prefix openssl@3)/bin/openssl"
    PEM="$RUNNER_TEMP/cert.pem"
    (umask 077; "$OPENSSL" pkcs12 -legacy -in "$RUNNER_TEMP/cert.p12" -nodes -passin env:P12_PASSWORD -out "$PEM")
    echo "In the .p12: $(grep -c 'BEGIN CERTIFICATE' "$PEM" || true) certificate(s), $(grep -c 'BEGIN .*PRIVATE KEY' "$PEM" || true) private key(s)"
    grep -q 'BEGIN CERTIFICATE' "$PEM" && "$OPENSSL" x509 -in "$PEM" -noout -subject -enddate
    "$OPENSSL" pkcs12 -export -in "$PEM" -passout env:P12_PASSWORD -out "$RUNNER_TEMP/cert-classic.p12" \
      -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
    rm -f "$PEM"
    security import "$RUNNER_TEMP/cert-classic.p12" -k "$KC" -P "$P12_PASSWORD" -T /usr/bin/codesign
    rm -f "$RUNNER_TEMP/cert.p12" "$RUNNER_TEMP/cert-classic.p12"
    security set-key-partition-list -S apple-tool:,apple: -s -k "$KC_PW" "$KC" >/dev/null
    # Keep the existing keychains (paths without spaces, hence unquoted)
    # shellcheck disable=SC2046
    security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
    ID=$(security find-identity -v -p codesigning "$KC" | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)
    if [ -z "$ID" ]; then echo "No Developer ID certificate found" >&2; exit 1; fi
    echo "Signing with: $ID"
    echo "MACOS_SIGN_IDENTITY=$ID" >> "$GITHUB_ENV"
    "$0" notary-key
    ;;
  notary-key)
    : "${P8:?P8 missing}"
    (umask 077; printf '%s\n' "$P8" > "$RUNNER_TEMP/notary.p8")
    echo "NOTARY_KEY=$RUNNER_TEMP/notary.p8" >> "$GITHUB_ENV"
    ;;
  cleanup)
    security delete-keychain "$KC" 2>/dev/null || true
    rm -f "$RUNNER_TEMP/notary.p8" "$RUNNER_TEMP/cert.p12" "$RUNNER_TEMP/cert-classic.p12" "$RUNNER_TEMP/cert.pem"
    ;;
  *)
    echo "Usage: $0 setup|notary-key|cleanup" >&2
    exit 2
    ;;
esac
