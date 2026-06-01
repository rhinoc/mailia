#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(tr -d '[:space:]' <VERSION)"
PRODUCT="Mailia"
RESOURCE_BUNDLE="Mailia_MailiaApp.bundle"
PLIST_SRC="$ROOT/Sources/MailiaApp/Info.plist"
ICON_SRC="$ROOT/Sources/MailiaApp/Resources/AppIcon.icns"
DMG_BACKGROUND="$ROOT/assets/dmg-background.png"

if [[ ! -f "$DMG_BACKGROUND" ]]; then
  echo "error: missing DMG background at $DMG_BACKGROUND" >&2
  exit 1
fi

npm --prefix Web/Timeline run build:app
swift build -c release --product "$PRODUCT"

BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/$PRODUCT"
SPARKLE_FW="$BIN_DIR/Sparkle.framework"
SPM_RESOURCE_BUNDLE="$BIN_DIR/$RESOURCE_BUNDLE"

if [[ ! -x "$BIN" ]]; then
  echo "error: missing release binary at $BIN" >&2
  exit 1
fi
if [[ ! -d "$SPARKLE_FW" ]]; then
  echo "error: Sparkle.framework not found at $SPARKLE_FW" >&2
  exit 1
fi
if [[ ! -d "$SPM_RESOURCE_BUNDLE" ]]; then
  echo "error: SwiftPM resource bundle not found at $SPM_RESOURCE_BUNDLE" >&2
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

APP="$STAGE/$PRODUCT.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$PLIST_SRC" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/$PRODUCT"
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"
cp -R "$SPM_RESOURCE_BUNDLE" "$APP/Contents/Resources/"
cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"

if ! otool -l "$APP/Contents/MacOS/$PRODUCT" | grep -q '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/$PRODUCT"
fi

find "$APP" -name '._*' -delete
xattr -cr "$APP"
"$ROOT/scripts/sign_built_app.sh" "$APP"

mkdir -p "$ROOT/dist"
DMG="$ROOT/dist/Mailia-${VERSION}-macos.dmg"
rm -f "$DMG"

DMG_BACKGROUND_COPY="$STAGE/dmg-background.png"
DMG_BACKGROUND_RETINA_COPY="$STAGE/dmg-background@2x.png"
sips -z 373 661 "$DMG_BACKGROUND" --out "$DMG_BACKGROUND_COPY" >/dev/null
sips -z 746 1322 "$DMG_BACKGROUND" --out "$DMG_BACKGROUND_RETINA_COPY" >/dev/null
sips -s dpiWidth 72 -s dpiHeight 72 "$DMG_BACKGROUND_COPY" >/dev/null
sips -s dpiWidth 144 -s dpiHeight 144 "$DMG_BACKGROUND_RETINA_COPY" >/dev/null

APPDMG_JSON="$STAGE/appdmg.json"
cat >"$APPDMG_JSON" <<EOF
{
  "title": "Mailia",
  "icon": "$ICON_SRC",
  "background": "$DMG_BACKGROUND_COPY",
  "icon-size": 80,
  "window": {
    "position": { "x": 120, "y": 559 },
    "size": { "width": 661, "height": 379 }
  },
  "format": "UDZO",
  "filesystem": "HFS+",
  "contents": [
    { "x": 180, "y": 197, "type": "file", "path": "$APP" },
    { "x": 480, "y": 197, "type": "link", "path": "/Applications" }
  ]
}
EOF

npx --yes "appdmg@${APPDMG_VERSION:-0.6.6}" "$APPDMG_JSON" "$DMG"

echo "Built $DMG"
