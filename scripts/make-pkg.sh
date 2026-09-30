#!/bin/bash
# Construit dist/DisplayPilot-<version>.pkg (app + LaunchAgent), prêt pour Intune « macOS app (PKG) ».
#   bash scripts/make-pkg.sh
#   INSTALLER_ID="Developer ID Installer: …" bash scripts/make-pkg.sh   # optionnel : pkg signé
set -euo pipefail
cd "$(dirname "$0")/.."

bash scripts/build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Resources/Info.plist)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ROOT="$WORK/root"
mkdir -p "$ROOT/Applications" "$ROOT/Library/LaunchAgents" dist
cp -R build/DisplayPilot.app "$ROOT/Applications/"
cp packaging/LaunchAgents/fr.darte.DisplayPilot.agent.plist "$ROOT/Library/LaunchAgents/"

# Empêche l'installeur de « relocaliser » l'app si une copie existe ailleurs sur le disque
cat > "$WORK/components.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
	<dict>
		<key>BundleHasStrictIdentifier</key><true/>
		<key>BundleIsRelocatable</key><false/>
		<key>BundleIsVersionChecked</key><false/>
		<key>BundleOverwriteAction</key><string>upgrade</string>
		<key>RootRelativeBundlePath</key><string>Applications/DisplayPilot.app</string>
	</dict>
</array>
</plist>
PLIST

pkgbuild --root "$ROOT" \
  --component-plist "$WORK/components.plist" \
  --scripts packaging/scripts \
  --identifier fr.darte.DisplayPilot.pkg \
  --version "$VERSION.$BUILD" \
  --install-location / \
  "$WORK/component.pkg"

OUT="dist/DisplayPilot-$VERSION.pkg"
if [ -n "${INSTALLER_ID:-}" ]; then
  productbuild --package "$WORK/component.pkg" --sign "$INSTALLER_ID" "$OUT"
else
  productbuild --package "$WORK/component.pkg" "$OUT"
fi

echo
echo "Paquet : $OUT"
pkgutil --payload-files "$WORK/component.pkg" | grep -E "DisplayPilot.app$|LaunchAgents/" || true
echo
echo "Intune › Applications › macOS › « macOS app (PKG) »"
echo "  Bundle ID : fr.darte.DisplayPilot   Version : $VERSION"
