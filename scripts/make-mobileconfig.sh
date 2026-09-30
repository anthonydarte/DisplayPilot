#!/bin/bash
# Génère dist/DisplayPilot.mobileconfig à partir de la signature RÉELLE de l'app construite :
#  - PPPC : Accessibilité autorisée (touches luminosité/volume)
#  - Éléments d'ouverture gérés : l'agent de démarrage ne peut pas être désactivé et n'affiche pas d'alerte
# À relancer si le certificat de signature change (pas à chaque version).
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/DisplayPilot.app
[ -d "$APP" ] || bash scripts/build.sh

REQ=$(codesign -dr - "$APP" 2>&1 | sed -n 's/^designated => //p')
if [ -z "$REQ" ]; then echo "Impossible de lire la signature de $APP"; exit 1; fi
if echo "$REQ" | grep -q "cdhash"; then
  echo "⚠︎ App signée ad-hoc : l'exigence de code change à chaque build et le profil deviendrait invalide."
  echo "  Lance d'abord : bash scripts/create-signing-cert.sh, puis reconstruis."
  exit 1
fi
esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
REQ_XML=$(printf '%s' "$REQ" | esc)
U() { uuidgen; }
mkdir -p dist
OUT=dist/DisplayPilot.mobileconfig

cat > "$OUT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>PayloadDisplayName</key>
	<string>DisplayPilot — autorisations</string>
	<key>PayloadDescription</key>
	<string>Accessibilité (touches luminosité/volume) et élément d'ouverture géré pour DisplayPilot.</string>
	<key>PayloadIdentifier</key>
	<string>fr.darte.DisplayPilot.profile</string>
	<key>PayloadOrganization</key>
	<string>DisplayPilot</string>
	<key>PayloadScope</key>
	<string>System</string>
	<key>PayloadType</key>
	<string>Configuration</string>
	<key>PayloadUUID</key>
	<string>$(U)</string>
	<key>PayloadVersion</key>
	<integer>1</integer>
	<key>PayloadContent</key>
	<array>
		<dict>
			<key>PayloadDisplayName</key>
			<string>PPPC — DisplayPilot</string>
			<key>PayloadIdentifier</key>
			<string>fr.darte.DisplayPilot.profile.pppc</string>
			<key>PayloadType</key>
			<string>com.apple.TCC.configuration-profile-policy</string>
			<key>PayloadUUID</key>
			<string>$(U)</string>
			<key>PayloadVersion</key>
			<integer>1</integer>
			<key>Services</key>
			<dict>
				<key>Accessibility</key>
				<array>
					<dict>
						<key>Identifier</key>
						<string>fr.darte.DisplayPilot</string>
						<key>IdentifierType</key>
						<string>bundleID</string>
						<key>CodeRequirement</key>
						<string>$REQ_XML</string>
						<key>StaticCode</key>
						<false/>
						<key>Authorization</key>
						<string>Allow</string>
						<key>Comment</key>
						<string>Touches luminosité / volume des écrans externes</string>
					</dict>
				</array>
			</dict>
		</dict>
		<dict>
			<key>PayloadDisplayName</key>
			<string>Éléments d'ouverture gérés — DisplayPilot</string>
			<key>PayloadIdentifier</key>
			<string>fr.darte.DisplayPilot.profile.loginitems</string>
			<key>PayloadType</key>
			<string>com.apple.servicemanagement</string>
			<key>PayloadUUID</key>
			<string>$(U)</string>
			<key>PayloadVersion</key>
			<integer>1</integer>
			<key>Rules</key>
			<array>
				<dict>
					<key>RuleType</key>
					<string>Label</string>
					<key>RuleValue</key>
					<string>fr.darte.DisplayPilot.agent</string>
					<key>Comment</key>
					<string>Agent de démarrage DisplayPilot</string>
				</dict>
				<dict>
					<key>RuleType</key>
					<string>BundleIdentifier</string>
					<key>RuleValue</key>
					<string>fr.darte.DisplayPilot</string>
					<key>Comment</key>
					<string>DisplayPilot</string>
				</dict>
			</array>
		</dict>
	</array>
</dict>
</plist>
PLIST

plutil -lint "$OUT"
echo "Profil : $OUT"
echo "Exigence de code : $REQ"
