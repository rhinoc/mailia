#!/usr/bin/env bash
set -euo pipefail

APP="${1:?usage: sign_built_app.sh /path/to/Mailia.app}"

IDENTITY="$(
  security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}'
)"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk -F'"' '/Apple Development/ {print $2; exit}'
  )"
fi

SIGN_ARGS=()
if [[ -n "$IDENTITY" ]]; then
  SIGN_IDENTITY="$IDENTITY"
  if [[ "$IDENTITY" == Developer\ ID* ]]; then
    SIGN_ARGS=(--options runtime --timestamp)
  fi
  echo "Signing with: $IDENTITY"
elif [[ "${MAILIA_ALLOW_ADHOC_SIGNING:-}" == "1" ]]; then
  SIGN_IDENTITY="-"
  echo "Signing ad-hoc because MAILIA_ALLOW_ADHOC_SIGNING=1."
else
  echo "error: no Apple Development or Developer ID signing identity found." >&2
  echo "Set CI signing secrets or use MAILIA_ALLOW_ADHOC_SIGNING=1 for local-only builds." >&2
  exit 1
fi

if [[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]]; then
  codesign --force --deep "${SIGN_ARGS[@]}" --sign "$SIGN_IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
fi

codesign --force "${SIGN_ARGS[@]}" --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/Mailia"
codesign --force "${SIGN_ARGS[@]}" --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --verbose=2 "$APP"
