#!/bin/zsh
# Corpus du banc « contexte » : nom.ctx (texte avant le curseur), nom.txt (phrase dictée), nom.aiff (voix de synthèse).
# Usage : tools/corpus-contexte.sh dossier  puis  Murmure --bench-contexte dossier
set -e
mkdir -p "$1"
cd "$1"
item() { print -r -- "$2" > "$1.ctx"; print -r -- "$3" > "$1.txt"; say -v Thomas -o "$1.aiff" "$3"; }

item 1-bail "Par acte du 3 juin 2026, la société Kervoalen Invest a donné congé à la SCI Les Hauts de Montrevel, représentée par Maître Baligaux. Nous contestons ce congé au visa de l'article L. 145-9 du Code de commerce." \
  "La société Kervoalen Invest ne justifie d'aucun motif grave et légitime, de sorte que la SCI Les Hauts de Montrevel sollicite le paiement d'une indemnité d'éviction."

item 2-conclusions "Maître Anne-Sophie Baligaux, conseil de la société Novip Services, nous a transmis ses conclusions le 14 octobre. Monsieur Damien Ozet y est présenté comme gérant de fait." \
  "Maître Baligaux soutient que Monsieur Ozet avait connaissance de la clause depuis la signature du protocole avec Novip Services."

item 3-audience "Le cabinet Trezzo Delacq intervient pour la société Axo E-Car dans le litige qui l'oppose à l'URSSAF de Bretagne. L'audience est fixée devant le pôle social du tribunal judiciaire de Quimper. Maître Thibault Varna plaidera." \
  "Maître Varna représentera Axo E-Car devant le tribunal judiciaire de Quimper contre l'URSSAF de Bretagne."

item 4-reprise "En conséquence, nous vous demandons de bien vouloir constater la résiliation du bail aux torts exclusifs du preneur, et nous demandons que la société Lefebvre Distribution" \
  "soit condamnée à payer la somme de quinze mille euros au titre de l'article 700 du Code de procédure civile."

item 5-bref "Le délai de réponse expire le 12 novembre. Merci de me confirmer que Madame Lefebvre a bien reçu la mise en demeure envoyée par la société Kervoalen Invest à la SCI Les Hauts de Montrevel." \
  "Oui, c'est bien reçu."
