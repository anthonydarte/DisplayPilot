#!/bin/bash
# Compile DisplayPilot en arm64 et assemble le bundle .app
#   ./scripts/build.sh              -> build/DisplayPilot.app
#       signé avec "DisplayPilot Local Signing" s'il existe (scripts/create-signing-cert.sh), sinon ad-hoc
#   SIGN_ID="Developer ID Application: ..." ./scripts/build.sh   -> identité explicite
#   ./scripts/build.sh --install    -> copie aussi dans /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

APP=DisplayPilot
# Signature : SIGN_ID explicite > certificat local stable (scripts/create-signing-cert.sh) > ad-hoc
LOCAL_CERT="DisplayPilot Local Signing"
if [ -z "${SIGN_ID:-}" ]; then
  if security find-certificate -c "$LOCAL_CERT" >/dev/null 2>&1; then
    SIGN_ID="$LOCAL_CERT"
  else
    SIGN_ID="-"
    echo "⚠︎ Signature ad-hoc : l'autorisation Accessibilité sera redemandée après chaque build."
    echo "  Lance une fois : bash scripts/create-signing-cert.sh"
  fi
fi

swift build -c release --arch arm64
BIN_DIR=$(swift build -c release --arch arm64 --show-bin-path)

OUT="build/$APP.app"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN_DIR/$APP" "$OUT/Contents/MacOS/$APP"
cp Resources/Info.plist "$OUT/Contents/Info.plist"
printf 'APPL????' > "$OUT/Contents/PkgInfo"
# Icône : régénérée depuis l'iconset si iconutil est disponible, sinon .icns fourni
if command -v iconutil >/dev/null && [ -d Resources/Icon/AppIcon.iconset ]; then
  iconutil -c icns Resources/Icon/AppIcon.iconset -o "$OUT/Contents/Resources/AppIcon.icns"
else
  cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"
fi

if [ "$SIGN_ID" = "-" ]; then
  codesign --force --sign - "$OUT"
else
  codesign --force --sign "$SIGN_ID" "$OUT"
fi
echo "Signé avec : $SIGN_ID"
codesign --verify --strict --verbose=2 "$OUT"
lipo -info "$OUT/Contents/MacOS/$APP"

if [ "${1:-}" = "--install" ]; then
  pkill -x "$APP" 2>/dev/null || true
  rm -rf "/Applications/$APP.app"
  cp -R "$OUT" /Applications/
  echo "Installé dans /Applications/$APP.app"
  open "/Applications/$APP.app"
fi
