# Installer Murmure sur votre Mac

Murmure est une application de dictée et de comptes rendus de réunion. Vous parlez, elle écrit ; elle
enregistre une réunion, distingue les voix et rédige le compte rendu. Par défaut, tout se passe sur votre
Mac. Ce guide vous mène de la page GitHub à une application qui marche, sans rien connaître à la programmation.

Il n'y a rien à installer d'autre que Murmure lui-même : vous téléchargez l'application, vous l'ouvrez, et
elle télécharge seule ses modèles au premier lancement. Comptez un quart d'heure, dont l'essentiel à attendre.

## 1. Ce qu'il vous faut

| | |
|---|---|
| **Un Mac à puce Apple** | M1, M2, M3, M4, M5… (menu Pomme › À propos de ce Mac › « Puce »). Un Mac Intel n'est pas pris en charge. |
| **macOS 26 ou plus récent** | Menu Pomme › À propos de ce Mac. Sinon : Réglages Système › Général › Mise à jour de logiciels. |
| **6 Go libres sur le disque** | 4 Go pour les modèles de transcription et de rédaction, et de la marge. |
| **Une connexion Internet** | Pour l'installation et le premier lancement. Ensuite, Murmure fonctionne hors ligne. |

Murmure n'existe que pour Mac : il n'y a pas de version Windows, Linux, iPhone ni Android.


## 2. Installer

1. **Télécharger.** Sur la page GitHub de Murmure, colonne de droite, cliquez sur **Releases**, puis sur le
   fichier **Murmure.zip** de la publication la plus récente.
2. **Ranger.** Dans Téléchargements, double-cliquez sur `Murmure.zip` : l'application **Murmure** apparaît.
   Faites-la glisser dans le dossier **Applications**. (Ne la lancez pas depuis Téléchargements.)
3. **Ouvrir, la première fois.** Double-cliquez sur Murmure. macOS affiche qu'il ne peut pas vérifier
   l'application et refuse de l'ouvrir : cliquez sur **Terminé**. Ouvrez ensuite **Réglages Système ›
   Confidentialité et sécurité**, descendez jusqu'à la ligne qui cite Murmure, cliquez sur **Ouvrir quand
   même**, confirmez avec votre mot de passe ou votre empreinte. C'est à faire une seule fois.

C'est tout. Aucun autre logiciel n'est nécessaire.

Pourquoi cet avertissement : macOS n'ouvre sans question que les applications vérifiées par Apple, ce qui
demande un compte de développeur payant que Murmure n'a pas. L'avertissement ne dit rien de l'application
elle-même ; il dit seulement qu'Apple ne l'a pas examinée.

Si vous comptez modifier Murmure, voyez plutôt « Installer à partir du code », en fin de guide.

## 3. Premier lancement

Murmure vous accueille et se règle avec vous : prénom, métier, ce que vous en attendez, test du micro, touche
de dictée. Il demande alors quelques autorisations à macOS. Chacune est demandée une seule fois.

| Autorisation | À quoi elle sert | Indispensable ? |
|---|---|---|
| **Micro** | Vous entendre. | Oui |
| **Accessibilité** | Écouter la touche de dictée et coller le texte là où est votre curseur. À activer dans Réglages Système › Confidentialité et sécurité › Accessibilité. | Oui |
| **Enregistrement du son de l'ordinateur** | En réunion, entendre aussi vos interlocuteurs en visio. | Pour les réunions en visio |
| **Calendriers** | Montrer vos rendez-vous du jour, nommer une réunion d'après l'agenda. | Non |
| **Contacts** | Écrire correctement les noms propres que vous dictez. | Non |

Pendant ce temps, Murmure télécharge ses modèles, une fois pour toutes : le modèle de transcription (1,6 Go),
puis le modèle de rédaction (2,5 Go). L'avancement s'affiche dans la fenêtre. La dictée fonctionne dès que le
premier est arrivé. Laissez le Mac branché et connecté jusqu'au bout.

**Pour dicter** : placez le curseur là où vous voulez écrire, maintenez la touche **Option de droite**, parlez,
relâchez. Le texte est collé.

## 4. Vos clés (Claude et transcription en ligne)

Sans aucune clé, Murmure fonctionne entièrement : dictée, réunions, comptes rendus, tout se fait sur votre
Mac, gratuitement. Deux services en ligne, en option, le rendent plus fin. Chacun demande une **clé**.

**Une clé est un mot de passe personnel** qui relie un service à votre compte, et donc à votre facture. Celle
de la personne qui vous a transmis Murmure n'est pas dans ce que vous avez téléchargé : elle n'a jamais été
dans le code. La vôtre ne quitte pas votre Mac (elle est rangée dans le dossier de données de Murmure, lisible
par votre seule session) et n'est envoyée qu'au service qu'elle ouvre. Ne la donnez à personne.

### Claude : relecture des dictées, comptes rendus, questions

Avec Claude, chaque dictée est relue avec le contexte du document, et les comptes rendus de réunion sont
rédigés par le modèle le plus puissant. Seul du **texte** part chez Anthropic, jamais le son.

1. Allez sur [console.anthropic.com](https://console.anthropic.com) et créez un compte. Ce compte est distinct
   d'un abonnement Claude (Pro, Max, Team) : un abonnement ne donne pas de clé.
2. Dans la rubrique de facturation (« Billing »), ajoutez un moyen de paiement et quelques euros de crédit.
3. Dans « API Keys », créez une clé. Elle commence par `sk-ant-`. Copiez-la tout de suite : elle n'est montrée
   qu'une fois.
4. Dans Murmure : **Réglages › Transcription › Mise en forme**, choisissez « Claude, en ligne (le plus
   puissant) », ouvrez la sous-page **Claude**, collez la clé, cliquez sur **Vérifier**.

Coût, facturé à l'usage par Anthropic : de l'ordre d'un dixième de centime par dictée relue, quelques
centimes à quelques dizaines de centimes par compte rendu de réunion selon sa longueur.

### AssemblyAI : transcription plus précise des réunions

Avec AssemblyAI, le **son des réunions** (pas celui des dictées) est transcrit sur un serveur européen, plus
précisément que sur le Mac, puis supprimé chez le service dès la transcription reçue.

1. Allez sur [assemblyai.com](https://www.assemblyai.com) et créez un compte.
2. Dans « API Keys », copiez votre clé.
3. Dans Murmure : **Réglages › Transcription › Réunions › Transcription des réunions**, choisissez « En ligne,
   plus précise », collez la clé, cliquez sur **Vérifier**.

Coût, facturé à l'usage par AssemblyAI : environ 0,30 $ par heure de réunion.

### Garder la main

- Barre des menus › **Rester hors ligne** coupe d'un clic tout envoi en ligne.
- Clic droit sur un dossier › **Jamais en ligne** : rien de ce dossier ne part.
- Le **cadenas** de la page En direct garde une réunion sur le Mac.
- Sans réseau, ou si un service ne répond pas, Murmure fait le travail sur le Mac.

## 5. Connecteurs (en option)

**Réglages › Connecteurs** relie Murmure à vos outils : agenda (Outlook, Google, iCloud, par l'application
Calendrier du Mac), messagerie, Notion, Slack, Todoist, Rappels, Notes, dossier de l'affaire (OneDrive, Google
Drive, Dropbox…), Claude et Claude Code. Chaque connecteur se relie à **votre** compte, depuis sa ligne ; rien
n'est préréglé.

## 6. Mettre à jour

Quittez Murmure, téléchargez le nouveau `Murmure.zip` sur la page **Releases**, et remplacez l'application dans
le dossier Applications. Vos dictées, réunions, réglages et clés sont conservés : ils ne sont pas dans
l'application, mais dans `~/Library/Application Support/Murmure/`. Les autorisations déjà données restent
valables ; macOS redemande seulement « Ouvrir quand même », comme la première fois.

## 7. Désinstaller

1. Quittez Murmure, puis mettez l'application Murmure (dossier Applications) à la corbeille.
2. Pour effacer aussi vos données (dictées, réunions, modèles, clés) : dans le Finder, menu Aller › Aller au
   dossier, tapez `~/Library/Application Support/Murmure` et mettez ce dossier à la corbeille.

## Questions

**La touche de dictée ne fait rien.**
Vérifiez que Murmure est activé dans Réglages Système › Confidentialité et sécurité › Accessibilité. Après une
mise à jour, si la touche ne répond plus, retirez Murmure de cette liste (bouton –), puis rajoutez-le.

**Le téléchargement des modèles s'est arrêté.**
Il reprend là où il en était au lancement suivant. Dans Réglages › Transcription › Modèle local, chaque modèle
a un bouton « Télécharger » ou « Réessayer ».

**Tout est lent.**
Le mode Économie d'énergie de macOS divise la vitesse des modèles par cinq à dix. Désactivez-le (Réglages
Système › Batterie) ou branchez le Mac.

**Où sont mes données ?**
Sur votre Mac, dans `~/Library/Application Support/Murmure/`. Rien n'est envoyé à l'auteur de Murmure, ni à
GitHub. Seuls les services en ligne que vous avez vous-même activés (Claude, AssemblyAI, vos connecteurs)
reçoivent ce que la section 4 décrit.

**Enregistrer une réunion : ai-je le droit ?**
Prévenez toujours vos interlocuteurs avant d'enregistrer, et recueillez leur accord quand la loi l'exige.

## Installer à partir du code (pour modifier Murmure)

Murmure est écrit en Swift. Pour le compiler, il faut seulement les outils de développement en ligne de
commande d'Apple (gratuits ; Xcode n'est pas nécessaire) : le script les demande s'ils manquent.

1. Récupérez le code : `git clone` du dépôt, ou bouton vert **Code › Download ZIP** sur la page GitHub.
2. Dans le Terminal, depuis le dossier du code : `zsh installer.sh`.

Le script vérifie le Mac, fabrique un certificat local nommé « Murmure Dev » (rangé dans votre trousseau, il
signe l'application pour que macOS la reconnaisse d'une compilation à l'autre et garde l'autorisation
Accessibilité ; si macOS demande votre mot de passe de session pour « codesign », répondez « Toujours
autoriser »), compile (plusieurs minutes la première fois), installe `~/Applications/Murmure.app` et l'ouvre.
Une application compilée sur place s'ouvre sans l'avertissement de macOS. Relancer `zsh installer.sh` après
une modification, ou après `git pull`, la met à jour ; `MURMURE_SANS_CERTIFICAT=1 zsh installer.sh` se passe
du certificat (l'autorisation Accessibilité est alors à redonner après chaque compilation).

Le fonctionnement de l'application est décrit dans [README.md](README.md), les règles de travail sur le code
dans [CLAUDE.md](CLAUDE.md). `tools/paquet.sh` fabrique le `Murmure.zip` d'une publication.
