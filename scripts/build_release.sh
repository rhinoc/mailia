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
DMG_DS_STORE="$ROOT/assets/dmg.DS_Store"

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
DMG_ROOT="$STAGE/dmg-root"
mkdir -p "$DMG_ROOT/.background"
cp -R "$APP" "$DMG_ROOT/"
cp "$DMG_BACKGROUND" "$DMG_ROOT/.background/background.png"
ln -s /Applications "$DMG_ROOT/Applications"
if [[ -f "$DMG_DS_STORE" ]]; then
  cp "$DMG_DS_STORE" "$DMG_ROOT/.DS_Store"
fi
find "$DMG_ROOT" -name '._*' -delete
xattr -cr "$DMG_ROOT"
chflags hidden "$DMG_ROOT/.background"

VOLNAME="Mailia"
DMG="$ROOT/dist/Mailia-${VERSION}-macos.dmg"
rm -f "$DMG"
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG" >/dev/null

echo "Built $DMG"
