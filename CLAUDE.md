# Murmure — règles pour les agents

Application macOS Swift (SwiftPM, macOS 26) de dictée et de réunions 100 % locales. Le README décrit
ce que fait l'app ; ce fichier décrit comment on travaille dessus. Plusieurs sessions Claude peuvent
être ouvertes en même temps sur ce dossier : ces règles existent pour qu'elles ne s'écrasent pas.

## Git : une livraison = un commit

- Le projet est sous git, branche `main`. Il se partage par un dépôt GitHub **privé** (distant `origin` ; s'il
  n'existe pas encore, c'est à l'utilisateur de le faire créer). N'y pousse que `main`, et seulement quand
  l'utilisateur le demande : pousser, c'est montrer le code aux personnes invitées.
- **L'historique d'avant le 11/11/2026 ne sort jamais de ce Mac.** `main` est reparti ce jour-là d'un commit
  unique (« état initial du dépôt partagé ») ; les 136 livraisons antérieures, dont d'anciens commits citent des
  noms réels, sont dans la branche locale `archive/avant-publication`. Ne pousse ni cette branche ni les
  anciennes branches de travail (un crochet `pre-push` local le refuse), ne les fusionne pas dans `main`
  (`--allow-unrelated-histories` y ferait entrer l'ancien historique). Pour reprendre un travail resté sur une
  ancienne branche : `git rebase --onto main archive/avant-publication <branche>`.
- **Aucun nom réel dans le dépôt** (clients, parties, confrères, cabinet) : exemples, essais, jeux d'essai et
  README n'emploient que des noms inventés.
- **À la fin de chaque livraison** (fonctionnalité, lot, correction qui compile), commiter sans
  qu'on te le demande : `git add -A && git commit`. Message en français, première ligne courte
  (« Export auto : copie Markdown dans le dossier de l'affaire »), puis deux ou trois lignes sur
  le pourquoi si utile. Ne commite jamais un état qui ne compile pas.
- **Avant de toucher un fichier**, regarde `git status` et `git diff -- <fichier>` : s'il porte des
  modifications non commitées que tu n'as pas faites, une autre session y travaille. Ne les écrase
  pas, ne les annule pas (pas de `git checkout --`, pas de `git stash`) ; relis le fichier tel qu'il
  est sur le disque et applique seulement l'intention de ta modification.
- Les fichiers de données de l'utilisateur ne sont pas dans le projet
  (`~/Library/Application Support/Murmure/`) : ne les commite pas, ne les modifie que pour un test,
  et restaure-les après.

## Sessions parallèles : un worktree chacune

- Au début d'une tâche qui **modifie du code**, vérifie si une autre session écrit déjà dans ce
  dossier : `git status --short` non vide, ou fichiers `Sources/Murmure/*.swift` modifiés dans
  les dernières minutes (`find Sources -newer .git/index -name '*.swift'`). Si oui, ou si la tâche
  est longue (plusieurs fichiers), **travaille dans un worktree** (`EnterWorktree`, ou
  `isolation: "worktree"` pour un sous-agent) sur une branche nommée d'après la tâche
  (`direct-transcription`, `palette-commande`). Une session qui ne fait que lire ou mesurer
  (banc d'essai, recherche) reste dans le dossier.
- Un worktree compile et s'installe comme le dossier principal (`./build.sh`), mais `.build/` y
  est reconstruit : la première compilation y prend plusieurs minutes.
- En fin de tâche dans un worktree : commite sur ta branche, puis fusionne dans `main` depuis le
  dossier principal (`git merge --no-ff <branche>`) **seulement si `main` compile encore après**,
  et dis à l'utilisateur ce qui a été fusionné. En cas de conflit, ne devine pas : montre-le.

## Compiler, installer, tester

- `./build.sh` compile en release et installe `~/Applications/Murmure.app` (signature locale
  « Murmure Dev »). Il remplace l'app en place : ferme d'abord l'interface
  (`osascript -e 'tell application "Murmure" to quit'`), **jamais `pkill Murmure`** : d'autres
  sessions lancent le même binaire en ligne de commande (`--bench-asr`, `--test`, `--resync`).
  Relance l'app ensuite (`open ~/Applications/Murmure.app`).
- Vérifie après lancement qu'il n'y a pas de rapport dans `~/Library/Logs/DiagnosticReports`.
- Ce qu'on ne peut pas vérifier sans micro ni capture d'écran (dictée, direct, rendu visuel),
  dis-le explicitement à l'utilisateur plutôt que de le présenter comme testé.
- `historique.json` est gardé en mémoire par l'app : ne l'écris jamais depuis l'extérieur pendant
  qu'elle tourne (ni `--resync`, ni le serveur MCP, qui est en lecture seule pour cette raison).

## Publier une version

- Le destinataire n'installe rien : il télécharge `Murmure.zip` dans les publications (« Releases ») du dépôt
  GitHub et suit `INSTALLATION.md`. `tools/paquet.sh` fabrique `dist/Murmure.zip` sans toucher à l'application
  installée ; il doit être signé « Murmure Dev » (le script refuse sinon), pour que les autorisations données
  par les destinataires survivent aux mises à jour.
- Publier (pousser `main`, créer une publication, y joindre le paquet) ne se fait que sur demande de
  l'utilisateur. Garde `INSTALLATION.md` juste : c'est le seul document que lit le destinataire.

## Style

- Code et commentaires en français, comme le reste du projet ; mêmes idiomes (SwiftUI, `Theme`,
  `Motion`, composants de `DesignSystem.swift`, jamais de contrôles natifs macOS dans la fenêtre).
- Tout texte visible par l'utilisateur est en français, sans anglicisme (« dossier », pas « folder »).
- Une fonctionnalité livrée = la section correspondante du README mise à jour dans le même commit.
