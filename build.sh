#!/bin/zsh
# Compile Murmure et installe Murmure.app dans ~/Applications.
# Sur un Mac qui n'a jamais compilé Murmure, passer plutôt par ./installer.sh, qui vérifie d'abord le Mac.
set -euo pipefail
cd "${0:A:h}"

if ! xcrun --find swift >/dev/null 2>&1; then
  echo "Les outils de développement d'Apple manquent. Lancez : xcode-select --install" >&2
  echo "puis relancez ce script une fois leur installation terminée." >&2
  exit 1
fi

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

# MURMURE_APP : autre emplacement, pour essayer une compilation sans remplacer l'application installée.
APP="${MURMURE_APP:-$HOME/Applications/Murmure.app}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/Murmure" "$APP/Contents/MacOS/Murmure"
cp Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] || swift tools/make-icon.swift Resources
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Ressources des dépendances (tokenizer, etc.) générées par SwiftPM
for bundle in "$BIN_DIR"/*.bundle(N); do
  cp -R "$bundle" "$APP/Contents/Resources/"
done

# Certificat local stable : l'autorisation Accessibilité survit aux recompilations. Sur un Mac qui ne l'a pas
# (ou qui refuse de s'en servir), signature à la volée : l'application marche, mais l'autorisation
# Accessibilité est à redonner après chaque recompilation. tools/certificat-local.sh crée le certificat.
CERTIFICAT="${MURMURE_CERTIFICAT:-Murmure Dev}"
IDENTIFIANT="com.vincentguyot.murmure"
IDENTITES="$(security find-identity -p codesigning 2>/dev/null || true)"
if [[ "$IDENTITES" == *"\"$CERTIFICAT\""* ]] \
   && codesign --force --deep --sign "$CERTIFICAT" --identifier "$IDENTIFIANT" "$APP"; then
  :
else
  codesign --force --deep --sign - --identifier "$IDENTIFIANT" "$APP"
  echo "Signée sans certificat local : l'autorisation Accessibilité sera à redonner après chaque recompilation."
  echo "Pour l'éviter : tools/certificat-local.sh, puis relancer ./build.sh."
fi
echo "Installé : $APP"
