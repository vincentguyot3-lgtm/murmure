#!/bin/zsh
# Fabrique dist/Murmure.zip : l'application toute faite, à joindre à une publication (« Release ») du dépôt
# GitHub. Celui qui la télécharge n'a rien à compiler ni à installer : décompresser, glisser dans Applications.
#
# L'application installée sur ce Mac n'est pas touchée (compilation posée dans dist/). Elle est signée avec le
# certificat local « Murmure Dev » de ce Mac : toutes les publications portant la même signature, macOS garde
# les autorisations (Accessibilité, micro) d'une mise à jour à l'autre chez ceux qui l'ont installée. Sans
# compte de développeur Apple, elle n'est pas notarisée : au premier lancement, macOS demande de confirmer
# l'ouverture dans Réglages Système › Confidentialité et sécurité (voir INSTALLATION.md).
set -euo pipefail
cd "${0:A:h}/.."

CERTIFICAT="${MURMURE_CERTIFICAT:-Murmure Dev}"
# Sorties relues depuis une variable : avec « pipefail », un grep -q qui s'arrête tôt ferait échouer la commande.
IDENTITES="$(security find-identity -p codesigning 2>/dev/null || true)"
if [[ "$IDENTITES" != *"\"$CERTIFICAT\""* ]]; then
  echo "Certificat « $CERTIFICAT » absent : une publication signée à la volée ferait perdre les autorisations" >&2
  echo "à chaque mise à jour chez ceux qui l'installent. Créez-le (tools/certificat-local.sh) puis relancez." >&2
  exit 1
fi

rm -rf dist
mkdir -p dist
MURMURE_APP="$PWD/dist/Murmure.app" MURMURE_CERTIFICAT="$CERTIFICAT" zsh build.sh

SIGNATURE="$(codesign -dvv dist/Murmure.app 2>&1 || true)"
if [[ "$SIGNATURE" != *"Authority=$CERTIFICAT"* ]]; then
  echo "L'application n'a pas été signée avec « $CERTIFICAT » : paquet abandonné." >&2
  exit 1
fi
codesign --verify --deep --strict dist/Murmure.app

# ditto garde les droits, les liens et la signature, comme le fait « Compresser » dans le Finder.
ditto -c -k --keepParent dist/Murmure.app dist/Murmure.zip
rm -rf dist/Murmure.app

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
echo "Paquet : dist/Murmure.zip (version $VERSION, $(du -h dist/Murmure.zip | cut -f1 | tr -d ' '))"
echo "SHA-256 : $(shasum -a 256 dist/Murmure.zip | cut -d' ' -f1)"
