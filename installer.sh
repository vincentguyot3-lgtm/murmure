#!/bin/zsh
# Installe Murmure sur ce Mac à partir de ce dossier : vérifie le Mac, compile, installe, ouvre l'application.
# À relancer tel quel pour une mise à jour (après « git pull »). Le guide complet est dans INSTALLATION.md.
set -euo pipefail
cd "${0:A:h}"

dire()  { print -r -- "$*"; }
titre() { print -r -- ""; print -r -- "— $* —"; }
arret() { print -r -- "" >&2; print -r -- "Installation interrompue : $*" >&2; exit 1; }

titre "Vérification du Mac"

VERSION="$(sw_vers -productVersion)"
if (( ${VERSION%%.*} < 26 )); then
  arret "Murmure demande macOS 26 ou plus récent (ce Mac est en $VERSION). Mettez macOS à jour dans Réglages Système › Général › Mise à jour de logiciels."
fi
dire "macOS $VERSION : bon."

if [[ "$(uname -m)" != "arm64" ]]; then
  dire "Attention : ce Mac a un processeur Intel. Murmure est conçu pour les Mac à puce Apple (M1 et suivantes) ;"
  dire "il n'a jamais été essayé sur Intel et la transcription y sera très lente."
fi

if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swift >/dev/null 2>&1; then
  dire "Les outils de développement d'Apple manquent (gratuits, environ 2 Go)."
  dire "Une fenêtre d'Apple s'ouvre pour les installer : cliquez sur « Installer » et attendez la fin."
  xcode-select --install >/dev/null 2>&1 || true
  arret "relancez ./installer.sh quand l'installation des outils d'Apple est terminée."
fi
dire "Outils de développement d'Apple : présents."

# La compilation (1,5 Go) puis les modèles téléchargés au premier lancement (4 Go environ) ont besoin de place.
LIBRE_GO=$(( $(df -k "$HOME" | awk 'NR==2 {print $4}') / 1048576 ))
if (( LIBRE_GO < 8 )); then
  dire "Attention : il reste $LIBRE_GO Go sur le disque. Murmure a besoin d'environ 8 Go (compilation et modèles)."
fi

# MURMURE_APP (voir build.sh) pose l'application ailleurs pour un essai : on ne ferme ni n'ouvre alors rien.
ESSAI="${MURMURE_APP:-}"

if [[ -z "$ESSAI" ]] && pgrep -xq Murmure; then
  titre "Fermeture de Murmure"
  osascript -e 'tell application "Murmure" to quit' >/dev/null 2>&1 || true
  sleep 2
fi

if [[ "${MURMURE_SANS_CERTIFICAT:-}" != "1" ]]; then
  titre "Certificat local"
  dire "Murmure se signe avec un certificat fabriqué sur ce Mac, pour que macOS le reconnaisse d'une mise à jour"
  dire "à l'autre. Si macOS demande votre mot de passe de session, répondez « Toujours autoriser »."
  zsh tools/certificat-local.sh || dire "Certificat non créé : l'installation continue sans lui."
fi

titre "Compilation (plusieurs minutes la première fois)"
zsh build.sh

if [[ -n "$ESSAI" ]]; then
  dire "Essai terminé : application posée dans $ESSAI, non ouverte."
  exit 0
fi

titre "Ouverture de Murmure"
open "$HOME/Applications/Murmure.app"

cat <<'FIN'

Murmure est installé dans le dossier Applications de votre session (~/Applications/Murmure.app).

À faire maintenant, une seule fois :
  1. Suivre l'accueil de Murmure (prénom, métier, autorisations, test du micro).
  2. Accepter le micro, puis activer Murmure dans
     Réglages Système › Confidentialité et sécurité › Accessibilité.
  3. Laisser le Mac connecté pendant le téléchargement des modèles (4 Go environ, une seule fois).
  4. Pour Claude et la transcription des réunions en ligne : créer vos propres clés et les coller dans
     les Réglages de Murmure. Le pas-à-pas est dans INSTALLATION.md, section « Vos clés ».
FIN
