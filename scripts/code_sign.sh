#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${BUILD_CERTIFICATE_BASE64:-}" ]]; then
  echo "BUILD_CERTIFICATE_BASE64 unset; skipping certificate import."
  exit 0
fi

: "${P12_PASSWORD:?P12_PASSWORD not set}"
: "${KEYCHAIN_PASSWORD:?KEYCHAIN_PASSWORD not set}"

CERTIFICATE_PATH="${RUNNER_TEMP:-/tmp}/build_certificate.p12"
KEYCHAIN_PATH="${RUNNER_TEMP:-/tmp}/app-signing.keychain-db"

echo -n "$BUILD_CERTIFICATE_BASE64" | base64 --decode -o "$CERTIFICATE_PATH"

echo "Imported certificate details from PKCS#12:"
openssl pkcs12 -legacy -in "$CERTIFICATE_PATH" -clcerts -nokeys -passin "pass:${P12_PASSWORD}" 2>/dev/null \
  | openssl x509 -noout -subject -enddate -nameopt RFC2253

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

security import "$CERTIFICATE_PATH" -P "$P12_PASSWORD" -A -f pkcs12 -k "$KEYCHAIN_PATH"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security list-keychain -d user -s "$KEYCHAIN_PATH"

echo "Imported identities in temporary keychain:"
security find-identity -v -p codesigning "$KEYCHAIN_PATH"

rm -f "$CERTIFICATE_PATH"
