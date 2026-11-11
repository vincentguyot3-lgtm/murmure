# Pistes tirées de Wispr Flow

Étude de Wispr Flow 1.6.1337 (31/10/2026) : archive `app.asar` extraite et lue, helper Swift inspecté,
base locale (`flow.sqlite`) et réglages (`config.json`) lus en copie, interface parcourue par l'accessibilité.
Chaque fiche dit ce que fait Wispr Flow, où on l'a vu, et comment le faire dans Murmure **sans rien envoyer
hors du Mac**. Ordre = priorité proposée pour un usage d'avocat.

Déjà livré dans Murmure à la suite de cette étude : **contexte du curseur** (`FieldContext.swift`) et
**collage accordé** (minuscule, espaces, point final, messageries). Voir le README.

## Comment Wispr Flow est fait (résumé)

- Electron (TypeScript, React, SQLite/Sequelize) + un helper Swift natif sans icône
  (`com.electron.wispr-flow.accessibility-mac-app`) pour l'accessibilité, la touche fn, le collage,
  la coupure du son et la détection des réunions. Messages JSON entre les deux, types générés depuis
  un schéma commun (TypeScript, Swift, C#).
- Audio capté dans le moteur web (`AudioWorklet`, paquets de 640 échantillons), compressé en Opus.
- Aucune transcription locale : flux gRPC bidirectionnel `flow_api.v1.TranscriptionService/TranscribeStream`
  vers `inference.wisprflow.com` (Baseten / Modal), repli HTTP vers Baseten puis vers OpenAI.
  Étapes côté serveur : transcription, alignement, mise en forme, minuscules sauf noms propres.
- Envoyé à chaque dictée : application et URL, mots visibles (accessibilité), texte du champ autour du
  curseur (500 caractères de part et d'autre), prénom et nom, dictionnaires, dictée précédente ;
  en option (désactivée par défaut) une capture d'écran envoyée à `/llm/ocr`.
- Mesuré sur une dictée de 2,2 s : 295 ms entre le relâchement et le collage.
- Le compte du cabinet (du cabinet) y est en essai, avec « zéro rétention » activé côté
  serveur, la lecture du contexte activée et la synchronisation dans le nuage activée.

---

## 1. Vocabulaire de l'écran

**Wispr Flow** : `ax_context` = mots lus dans l'arbre d'accessibilité de la fenêtre active (pas seulement
le champ), envoyés comme vocabulaire ; noms de fichiers et variables ouverts dans VS Code.

**Pour Murmure** : au début de la dictée, en plus du champ, parcourir l'arbre d'accessibilité de la fenêtre
au premier plan (titre de fenêtre, objet et destinataires d'un courriel dans Mail ou Outlook, en-têtes
d'un document Word, liste de conversation Teams) et en extraire les termes notables avec la même règle que
`FieldContext.terms` (sigles, majuscule en milieu de phrase). Les ajouter, après ceux du champ, à
`Transcriber.Hint.terms` et à `Cleaner.applyContextTerms`.

- Fichiers : `FieldContext.swift` (nouvelle fonction `windowTerms(_ app:)`, parcours borné à ~2 000
  éléments et 150 ms, délai d'accessibilité 0,1 s par appel), `AppDelegate.completeRecording`.
- Le titre de la fenêtre Word donne souvent le nom du client (« AXO E-CAR - Réclamation contentieuse ») :
  c'est la source la plus rentable, à lire en premier.
- Mesure : ajouter des triplets au banc `--bench-contexte` où le nom n'est que dans le titre.
- Risque : amorce trop longue, d'où le plafond de 80 jetons ; les termes de la fenêtre passent après
  ceux du champ.

## 2. Apprendre des corrections

**Wispr Flow** : après le collage, le champ est observé (`contentObservationEndReason =
observation_window_elapsed`, `editDistanceToDictated`, table `TranscriptCorrections`) ; un mot corrigé par
l'utilisateur est proposé au dictionnaire (« Dictionary Learning », avec annulation `UndoDictionaryLearn`).
Réglage `shouldAutoLearnWords`, activé par défaut.

**Pour Murmure** : retenir l'élément d'accessibilité et la plage du texte collé ; 20 s plus tard (ou quand
le focus quitte le champ), relire cette plage. Aligner mot à mot le texte collé et le texte relu
(distance d'édition sur les mots) : un mot remplacé par un autre proche à l'écrit ou à l'oreille
(`Cleaner.soundKey` égale, ou distance ≤ 2) donne une paire « entendu → corrigé ». Au bout de deux
occurrences, ou tout de suite si la correction est un nom propre, l'ajouter au dictionnaire
(terme + correction) et l'annoncer dans la pastille : « Ajouté au dictionnaire : Kervoalen · Annuler ».

- Fichiers : nouveau `CorrectionWatcher.swift`, `Paster.swift` (renvoyer la plage collée),
  `Lexicon.swift` (origine « appris », date), `LexiconView.swift` (badge « appris », annulation).
- Garde-fous : ignorer les réécritures importantes (plus de 40 % du texte changé), les champs où
  l'utilisateur continue d'écrire (ne comparer que la plage collée), les mots courants du correcteur macOS.

## 3. Collage fiable et « recoller la dernière dictée »

**Wispr Flow** : `DelayedClipboardProvider` met dans le presse-papiers une **promesse** de données
(`NSPasteboardItemDataProvider`) : si aucune application ne la lit dans le délai, le collage a échoué
(« Failed paste likely »), et le texte est gardé. Raccourcis ⌘⌃V « coller le dernier texte » et
⌘⌃C « copier le dernier texte ».

**Pour Murmure** :
- Dans `Paster.paste`, écrire un `NSPasteboardItem` avec un fournisseur de données ; si
  `pasteboard(_:item:provideDataForType:)` n'est pas appelé dans les 0,6 s, laisser le texte dans le
  presse-papiers (ne pas restaurer) et prévenir : « Collage impossible ici · texte copié, ⌘V ».
- Raccourcis globaux ⌘⌃V et ⌘⌃C dans `HotkeyMonitor` : recollent ou copient la dernière dictée
  (`RecordingStore.shared.recordings.first`).
- Fichiers : `Paster.swift`, `HotkeyMonitor.swift`, `AppDelegate.swift`, README (tableau des gestes).

## 4. Mode commande sur une sélection

**Wispr Flow** : « Transforms » (⌥1 Polish, ⌥2 Prompt Engineer, transformations personnelles,
application automatique après dictée), « Lens » (ctrl+fn) et « instruct » : on sélectionne un texte,
on dicte une consigne, le texte est réécrit sur place.

**Pour Murmure** : si une sélection existe au début de la dictée (`FieldContext.selected` non vide) et
que l'on maintient la touche de dictée **avec Maj**, la dictée est une consigne : `Cleaner.rework(selection,
instruction: dictée)` avec le modèle local, puis collage en remplacement de la sélection. Consignes
enregistrées (« plus formel », « en courriel au client », « style conclusions ») accessibles par
⌥1…⌥4 sans dicter.

- Fichiers : `AppDelegate` (nouvel état « commande »), `HotkeyMonitor` (modificateur), `Cleaner.rework`
  (consignes avec le texte voisin), `Overlay` (« Consigne… »), réglages (consignes enregistrées).
- Garde-fou : montrer les changements avant de coller si la réécriture dépasse 50 % du texte
  (voir fiche 9).

## 5. Extraits (texte inséré sur un mot clé)

**Wispr Flow** : « Snippets » (table `Dictionary`, `isSnippet`) : dire « my email address » insère
l'adresse ; extraits personnels et partagés avec l'équipe.

**Pour Murmure** : étendre le dictionnaire avec une troisième sorte d'entrée, **Extrait** : un déclencheur
dicté (« coordonnées du cabinet », « formule confraternelle », « mention RGPD ») remplacé par un texte de
plusieurs lignes. Appliqué dans `Cleaner.applyReplacements` seulement quand le déclencheur est **toute la
dictée** ou une phrase entière, pour ne pas surprendre.

- Fichiers : `Lexicon.swift` (`snippets: [Replacement]`), `LexiconView.swift` (onglet « Extraits »),
  `Cleaner.swift`, README.

## 6. Détection des réunions et noms des participants

**Wispr Flow** : `autoDetectMeetingsEnabled` ; le helper surveille quels processus tiennent le micro
(`MicrophoneHoldersMonitor`), l'état des visios (`ZoomMeetingAudioChanged`, `TeamsMeetingAudioChanged`,
`GoogleMeetMicrophoneMuteChanged`, `SlackHuddleState`) et l'orateur actif à l'écran
(`MeetingSpeakerChange`, `notetakerAutoDetectParticipantNamesEnabled`). Agenda relié (`CalendarEvents`).

**Pour Murmure** :
- Détection : interroger CoreAudio (`kAudioHardwarePropertyProcessObjectList`,
  `kAudioProcessPropertyIsRunningInput`) toutes les 3 s ; si Teams, Zoom, Webex, Meet (navigateur) ou
  FaceTime tient le micro plus de 20 s, notification « Réunion détectée · Enregistrer ».
- Noms : pendant l'enregistrement, lire par l'accessibilité la tuile de l'orateur actif dans Teams ou
  Zoom (nom affiché) et l'horodater ; à la fin, attribuer à chaque interlocuteur de SpeakerKit le nom le
  plus souvent affiché pendant ses tours de parole. Titre et participants depuis l'agenda local (EventKit).
- Fichiers : nouveau `MeetingDetector.swift`, `MeetingController.swift`, `Transcriber.speakerTurns`
  (noms), `Info.plist` (accès à l'agenda), README (section Réunions).

## 7. Transcrire pendant la parole

**Wispr Flow** : l'audio part en flux pendant la dictée ; le texte est prêt ~300 ms après le relâchement.

**Pour Murmure** : `LiveTranscriber` transcrit déjà pendant la parole pour l'aperçu. Pour une dictée de
plus de 20 s, figer les morceaux déjà terminés (coupés dans un silence, comme `transcribeLong`) et ne
transcrire au relâchement que la fin. Gain attendu : le temps d'attente ne dépend plus de la longueur.

- Fichiers : `LiveTranscriber.swift`, `Transcriber.swift`, `AppDelegate.completeRecording`.
- Mesure : banc `--bench-real` sur les dictées longues gardées (précision identique exigée).

## 8. Couper le son pendant la dictée

**Wispr Flow** : `shouldMuteAudio`, `shouldPauseAudio` (MediaRemote) : la musique ou la vidéo se met en
pause pendant la dictée et reprend ensuite.

**Pour Murmure** : au début de la dictée, si un média joue, envoyer la touche « lecture/pause » système
(événement `NX_KEYTYPE_PLAY`) et la renvoyer à la fin ; à défaut, baisser le volume de sortie par
CoreAudio et le restaurer. Réglage dans Général, désactivé par défaut.

## 9. Voir et annuler la mise en forme

**Wispr Flow** : ⌥O « view diff », `hasRevertedAI`, `formattingDivergenceScore`.

**Pour Murmure** : dans l'historique, afficher les différences entre transcription brute et texte final
(mots retirés barrés, ajoutés soulignés) ; bouton « Revenir au texte brut ». Raccourci global : remplace
la dernière dictée collée par sa version brute si le champ n'a pas bougé (plage retenue par la fiche 2).

## 10. Styles par application

**Wispr Flow** : rubrique « Style » par catégorie (messages personnels, messages professionnels,
courriel, autre ; formel / décontracté / très décontracté) ; formats par application
(`appTranscriptionFormats`).

**Pour Murmure** : profils par application (`bundleID`) : ponctuation des messageries (déjà en partie
livré), « Courriel » qui garde la formule d'appel sur sa propre ligne, « Conclusions » qui écrit les
nombres en lettres et les références d'articles normalisées (« article 700 du Code de procédure civile »).
Réglage dans Transcription.

## Moins prioritaire

- **Mode chuchoté** (`usedWhisperMode`) : dicter à voix basse en open space ; gain automatique plus fort
  et seuil de silence abaissé quand le niveau moyen est faible.
- **Statistiques** (« Insights » : mots par minute, mots dictés, série de jours) : temps gagné estimé
  par rapport à la frappe, dans la page d'accueil.
- **Saisie sécurisée** (`SecureInputStatus`) : quand macOS bloque les raccourcis (mot de passe, Terminal),
  prévenir dans la pastille au lieu de ne rien faire.
- **Bloc-notes** (« Scratchpad ») : Murmure a déjà l'historique, inutile.
