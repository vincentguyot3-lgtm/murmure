#!/bin/zsh
# Corpus du banc « annuaire des noms » : nom.aiff (voix de synthèse), nom.txt (texte dit), nom.noms (noms attendus,
# un par ligne, vide si aucun), et annuaire.txt : un millier de noms fictifs, dont les noms dictés et des pièges
# (homonymes de graphie différente, noms qui sonnent comme des mots courants : « Dumois », « Defoy »).
# Usage : tools/corpus-noms.sh dossier  puis  Murmure --bench-noms dossier
set -e
mkdir -p "$1"
cd "$1"
item() { print -r -- "$3" > "$1.txt"; print -r -- "$4" > "$1.noms"; say -v "$2" -o "$1.aiff" "$3"; }

item 01-baligaux Thomas "Maître Baligaux nous a transmis ses conclusions hier soir." "Baligaux"
item 02-kerdraon Thomas "J'ai eu Monsieur Kerdraon au téléphone ce matin, il accepte la transaction." "Kerdraon"
item 03-lefebvre Thomas "Merci de prévenir Matthieu Lefebvre que l'audience est renvoyée." $'Matthieu\nLefebvre'
item 04-vauquelin Thomas "La société Vauquelin Industries conteste la facture du 3 mars." "Vauquelin Industries"
item 05-szczepanski Amélie "Pouvez-vous envoyer le projet à Madame Szczepanski avant vendredi ?" "Szczepanski"
item 06-quemeneur Thomas "Rendez-vous demain avec Thibault Quéméneur et son expert-comptable." $'Thibault\nQuéméneur'
item 07-desmarais Amélie "Rappelle Anne-Sophie Desmarais pour le dossier Guéguen." $'Anne-Sophie\nDesmarais\nGuéguen'
item 08-nguyen Thomas "Le cabinet Trezzo Delacq représente Madame Nguyen dans cette affaire." $'Trezzo Delacq\nNguyen'
item 09-schaeffer Thomas "Appeler Schaeffer." "Schaeffer"
item 10-combaluzier Thomas "Maître Ghislaine Roux-Combaluzier plaidera pour la partie adverse." $'Ghislaine\nRoux-Combaluzier'
item 11-lefloch Amélie "J'ai transmis le bail à Grégoire Le Floc'h." $'Grégoire\nLe Floc\'h'
item 12-benhaddou Thomas "Le gérant, Monsieur Aït-Benhaddou, n'a pas signé le procès-verbal." "Aït-Benhaddou"
item 13-thiebault Thomas "Stéphane Thiébault viendra au cabinet jeudi." $'Stéphane\nThiébault'
item 14-eriksson Thomas "Envoie le courriel à Cédric et à Baptiste pour le dossier Eriksson." "Eriksson"
item 15-piege-mois Thomas "Le bailleur doit restituer le dépôt de garantie dans un délai de deux mois." ""
item 16-piege-fois Thomas "Le client a réglé la facture en deux fois, par virement." ""
item 17-inconnu Thomas "J'ai rencontré Monsieur Pradalier ce matin pour préparer l'audience." "Pradalier"
item 18-courriel Amélie "Bonjour Mathilde, je vous transmets les pièces que Maître Baligaux m'a adressées pour Monsieur Kerdraon." $'Mathilde\nBaligaux\nKerdraon'
# Dictées de contrôle (21 à 30) : écrites après le réglage du rapprochement, pour le mesurer sur des noms jamais vus.
item 21-vandewalle Thomas "Merci d'adresser la convocation à Maître Pierre-Henri Vandewalle." $'Pierre-Henri\nVandewalle'
item 22-ouazzani Amélie "Le rendez-vous avec Madame Ouazzani est décalé à mardi." "Ouazzani"
item 23-hennebelle Thomas "Nous avons reçu les conclusions de la société Hennebelle Logistique." "Hennebelle Logistique"
item 24-kerjean Thomas "Transmettez le dossier à Jean-Baptiste Kerjean et à Solène Prigent." $'Kerjean\nSolène\nPrigent'
item 25-wojciechowski Thomas "Monsieur Wojciechowski conteste son licenciement pour faute grave." "Wojciechowski"
item 26-lagarrigue Amélie "Je déjeune avec Clotilde Lagarrigue jeudi pour parler de la cession." $'Clotilde\nLagarrigue'
item 27-bouchareb Thomas "Le notaire, Maître Bouchareb, attend l'acte signé avant la fin du mois." "Bouchareb"
item 28-piege-voir Thomas "Il reste à voir si le juge acceptera notre demande de renvoi." ""
item 29-mehdaoui Thomas "Appelle Maître Mehdaoui et dis-lui que Monsieur Tcherkassky ne viendra pas." $'Mehdaoui\nTcherkassky'
item 30-guillou Amélie "La facture de la SCI Ty Guillou reste impayée depuis septembre." "Ty Guillou"

python3 - <<'EOF'
import random
random.seed(7)
prenoms = """Jean Marie Pierre Michel André Philippe Nicolas Christophe François Laurent Julien Frédéric Sébastien
Isabelle Nathalie Sylvie Catherine Christine Sandrine Valérie Céline Sophie Aurélie Camille Léa Manon Chloé Emma
Lucas Hugo Louis Arthur Paul Antoine Thomas Alexandre Maxime Romain Guillaume Olivier Patrick Bernard Alain
Hélène Claire Agnès Martine Brigitte Pascale Élodie Laura Julie Marion Pauline Charlotte Inès Sarah Yasmine
Mehdi Karim Rachid Nadia Leïla Samir Ahmed Fatima Kevin Damien Jérôme Cyril Benoît Vincent Fabrice Thierry""".split()
noms = """Martin Bernard Dubois Thomas Robert Richard Petit Durand Leroy Moreau Simon Laurent Michel Garcia David
Bertrand Roux Vincent Fournier Morel Girard André Mercier Dupont Lambert Bonnet François Martinez Legrand Garnier
Faure Rousseau Blanc Guérin Muller Henry Roussel Nicolas Perrin Morin Mathieu Clément Gauthier Dumont Lopez
Fontaine Chevalier Robin Masson Sanchez Gérard Nguyen Boyer Denis Lemaire Duval Joly Gautier Roger Roche Roy
Noël Meyer Lucas Meunier Jean Perez Marchand Dufour Blanchard Marie Barbier Brun Dumas Brunet Schmitt Leroux
Colin Fernandez Pierre Renard Arnaud Rolland Caron Aubert Giraud Leclerc Vidal Bourgeois Renaud Lemoine Picard
Gaillard Philippe Leclercq Lacroix Fabre Dupuis Olivier Rodriguez Da Silva Hubert Louis Charles Guillot Rivière
Le Gall Guillaume Adam Rey Moulin Gonzalez Berger Lecomte Ménard Fleury Deschamps Carpentier Julien Benoit Paris
Maillard Marchal Aubry Vasseur Le Roux Renault Jacquet Collet Prévost Poirier Charpentier Royer Huet Baron
Dupuy Pons Paul Laine Carré Breton Rémy Schneider Perrot Guyot Barre Marty Cousin Tanguy""".split()
annuaire = set()
while len(annuaire) < 900:
    annuaire.add(f"{random.choice(prenoms)} {random.choice(noms)}")
annuaire |= {
    "Baptiste Baligaux", "Yann Kerdraon", "Matthieu Lefebvre", "Vauquelin Industries", "Agnieszka Szczepanski",
    "Thibault Quéméneur", "Anne-Sophie Desmarais", "Gwenaël Guéguen", "Trezzo Delacq", "Cédric Delacq",
    "Linh Nguyen", "Hans Schaeffer", "Ghislaine Roux-Combaluzier", "Grégoire Le Floc'h", "Karim Aït-Benhaddou",
    "Stéphane Thiébault", "Lars Eriksson", "Mathilde Garnier",
    "Pierre-Henri Vandewalle", "Samira Ouazzani", "Hennebelle Logistique", "Jean-Baptiste Kerjean", "Solène Prigent",
    "Tomasz Wojciechowski", "Clotilde Lagarrigue", "Nadia Bouchareb", "Youssef Mehdaoui", "Igor Tcherkassky",
    "SCI Ty Guillou", "Luc Vandevelde", "Hervé Kerjan", "Arnaud Ravoire",
    # Pièges : même son ou presque, autre personne.
    "Jean Lefèvre", "Paul Dumois", "Claire Defoy", "Henri Pradelle", "Sophie Desmaret", "Marc Thiébaut",
    "Jérôme Kerdreux", "Vauclin Conseil", "Annie Le Goff",
    "Kervoalen Invest", "Lefebvre Distribution", "Novip Services", "Lumière Bâtiment", "Axo E-Car",
}
open("annuaire.txt", "w").write("\n".join(sorted(annuaire)) + "\n")
print(len(annuaire), "noms dans l'annuaire")
EOF
