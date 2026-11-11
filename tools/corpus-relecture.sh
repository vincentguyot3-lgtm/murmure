#!/bin/zsh
# Corpus du banc « relecture anticipée » : nom.ctx (texte avant le curseur), nom.aiff (voix de synthèse).
# Dictées fictives, dont certaines marquent une pause au milieu ([[slnc …]], en millisecondes) puis reprennent :
# la relecture demandée pendant la pause doit être annulée.
# Usage : tools/corpus-relecture.sh dossier  puis  Murmure --bench-relecture dossier
set -e
mkdir -p "$1"
cd "$1"
item() { print -r -- "$2" > "$1.ctx"; say -v Thomas -o "$1.aiff" "$3"; }

item 1-bail "Par acte du 3 juin 2026, la société Kervoalen Invest a donné congé à la SCI Les Hauts de Montrevel, représentée par Maître Baligaux. Nous contestons ce congé au visa de l'article L. 145-9 du Code de commerce." \
  "La société Kervoalen Invest ne justifie d'aucun motif grave et légitime, de sorte que la SCI Les Hauts de Montrevel sollicite le paiement d'une indemnité d'éviction."

item 2-conclusions "Maître Anne-Sophie Baligaux, conseil de la société Novip Services, nous a transmis ses conclusions le 14 octobre. Monsieur Damien Ozet y est présenté comme gérant de fait." \
  "Maître Baligaux soutient que Monsieur Ozet avait connaissance de la clause depuis la signature du protocole avec Novip Services."

item 3-autocorrection "Le cabinet Trezzo Delacq intervient pour la société Axo E-Car dans le litige qui l'oppose à l'URSSAF de Bretagne." \
  "L'audience est fixée devant le tribunal judiciaire de Rennes, de Quimper pardon, le douze mars à quatorze heures."

item 4-courriel "Bonjour Maître, je vous remercie pour votre retour sur le projet de protocole transactionnel." \
  "Je vous confirme que notre client accepte la proposition, sous réserve de la clause de confidentialité. Je reviens vers vous demain."

item 5-pause-reprise "Le délai de réponse expire le 12 novembre. La société Kervoalen Invest a adressé une mise en demeure à la SCI Les Hauts de Montrevel." \
  "Nous accusons réception de la mise en demeure du 3 novembre. [[slnc 1500]] Notre cliente conteste toutefois le montant réclamé, qui ne tient pas compte des versements déjà effectués."

item 6-longue "Monsieur le Président, nous avons l'honneur de vous transmettre nos observations dans l'affaire Lefebvre Distribution contre Kervoalen Invest." \
  "À titre liminaire, nous rappelons que la société Lefebvre Distribution exploite son fonds de commerce dans les lieux depuis plus de quinze ans. [[slnc 900]] Le bailleur ne rapporte la preuve d'aucun manquement grave, et les attestations produites sont postérieures à la délivrance du congé. [[slnc 700]] En conséquence, nous vous demandons de débouter la société Kervoalen Invest de l'ensemble de ses demandes."

item 7-hesitation "Objet : dossier Lefebvre Distribution contre Kervoalen Invest, audience de mise en état du 18 novembre." \
  "Je vous propose de solliciter un renvoi de l'affaire. [[slnc 4000]] Nous pourrions ainsi produire les attestations des anciens salariés avant la clôture."
