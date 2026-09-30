#!/bin/bash
# Crée (une seule fois) un certificat de signature de code local et auto-signé.
# Avec une signature STABLE, macOS reconnaît l'app d'un build à l'autre :
# l'autorisation Accessibilité accordée une fois reste valable.
set -euo pipefail

NAME="DisplayPilot Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Le certificat « $NAME » existe déjà."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cfg" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout pass:displaypilot -name "$NAME"

# Import de la clé + certificat ; codesign est autorisé à utiliser la clé sans demander.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P displaypilot -T /usr/bin/codesign
# Confiance « signature de code » pour ce certificat (demande ton mot de passe de session).
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo
echo "Certificat « $NAME » créé."
security find-identity -v -p codesigning | grep "$NAME" || true
