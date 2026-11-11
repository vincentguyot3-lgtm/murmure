#!/bin/zsh
# Crée, une fois, le certificat local « Murmure Dev » qui sert à signer l'application compilée sur ce Mac.
#
# Pourquoi : sans certificat, l'application est signée « à la volée » et macOS la prend pour une autre
# application à chaque recompilation ; il faut alors redonner l'autorisation Accessibilité après chaque mise
# à jour. Avec ce certificat, l'autorisation est donnée une fois pour toutes.
#
# Le certificat est fabriqué sur ce Mac, n'en sort pas et ne sert qu'à Murmure. Il est rangé dans le trousseau
# de session. À la première signature, macOS demande le mot de passe de session : répondre « Toujours autoriser ».
#
# Essais : MURMURE_CERTIFICAT (nom) et MURMURE_TROUSSEAU (fichier de trousseau) remplacent les valeurs d'usage.
set -euo pipefail

NOM="${MURMURE_CERTIFICAT:-Murmure Dev}"
TROUSSEAU="${MURMURE_TROUSSEAU:-$HOME/Library/Keychains/login.keychain-db}"

present() { [[ "$(security find-identity -p codesigning "$TROUSSEAU" 2>/dev/null || true)" == *"\"$NOM\""* ]]; }

if present; then
  echo "Certificat « $NOM » déjà présent."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NOM
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

# Le mot de passe ne protège que le fichier d'échange, effacé à la fin du script.
PASSE="$(uuidgen)"
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/conf" \
  -keyout "$TMP/cle.pem" -out "$TMP/certificat.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/cle.pem" -in "$TMP/certificat.pem" \
  -name "$NOM" -out "$TMP/identite.p12" -passout "pass:$PASSE" 2>/dev/null
security import "$TMP/identite.p12" -k "$TROUSSEAU" -P "$PASSE" -T /usr/bin/codesign >/dev/null

if present; then
  echo "Certificat « $NOM » créé dans le trousseau de session."
else
  echo "Le certificat « $NOM » n'a pas pu être créé." >&2
  exit 1
fi
