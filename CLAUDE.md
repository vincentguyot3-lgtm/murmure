# Murmure — règles pour les agents

Application macOS Swift (SwiftPM, macOS 26) de dictée et de réunions 100 % locales. Le README décrit
ce que fait l'app ; ce fichier décrit comment on travaille dessus. Plusieurs sessions Claude peuvent
être ouvertes en même temps sur ce dossier : ces règles existent pour qu'elles ne s'écrasent pas.

## Git : une livraison = un commit

- Le projet est sous git (branche `main`, dépôt local, pas de distant). Ne jamais pousser.
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

## Style

- Code et commentaires en français, comme le reste du projet ; mêmes idiomes (SwiftUI, `Theme`,
  `Motion`, composants de `DesignSystem.swift`, jamais de contrôles natifs macOS dans la fenêtre).
- Tout texte visible par l'utilisateur est en français, sans anglicisme (« dossier », pas « folder »).
- Une fonctionnalité livrée = la section correspondante du README mise à jour dans le même commit.
