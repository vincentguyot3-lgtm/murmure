# Murmure — état des lieux du 31 octobre 2026

Audit complet de l'application, mené en une session : relecture de tout le code (8 700 lignes, trois relectures indépendantes croisées), tests en ligne de commande sur des réunions synthétiques, sondes sur le modèle local, lecture des rapports de plantage du jour, et comparaison avec Wispr Flow (version installée 1.6.1337, documentation et nouveautés d'avril à octobre 2026), Superwhisper, Granola et Wispr Flow Notetaker.

Trois regards sont tenus ensemble : l'avocat qui veut l'outil le plus fiable pour ses dictées et ses rendez-vous, le développeur qui veut que rien ne casse sur une réunion de deux heures, le designer qui veut une application sobre, moderne et finie.

Ce qui n'a pas pu être vérifié dans cette session, et qu'il faut tester à la main : la dictée au micro, le rendu visuel réel (la capture d'écran est refusée à cette session), l'interface de Wispr Flow (bloquée sur son écran d'accueil, les clics synthétiques sont ignorés par Electron).

---

## 1. En bref

**L'application est solide et déjà au niveau « produit »** : direction artistique tenue de bout en bout, chaîne de dictée bien pensée (contexte du curseur, apprentissage des corrections, dictée en flux), réunions à deux pistes, synthèse par blocs, connecteurs agenda et messagerie, export Markdown vers le dossier de l'affaire, serveur MCP. Aucun plantage trouvé dans l'application installée ; les cinq rapports de plantage du jour viennent tous du binaire lancé à nu en ligne de commande (centre de notifications absent hors paquet), corrigé.

**Mais une réunion de deux heures n'avait ni compte rendu ni titre**, silencieusement : la synthèse dépassait le contexte du modèle local (vérifié par sonde : le serveur répond `exceed_context_size_error`, l'erreur était avalée). Une réunion à une seule voix échouait dès 50 minutes. Un ⌘Q pendant le traitement laissait une réunion « En cours » pour toujours. Ces points sont corrigés et vérifiés (section 3).

**Ce qui reste à faire** se range en trois chantiers : fiabilité résiduelle (sections 4 et 5), fonctions qui manquent face aux concurrents et aux besoins d'un cabinet (section 6), et finition de l'interface, Réglages en tête (section 7). La section 8 propose un ordre.

---

## 2. Tests réalisés

| Test | Résultat |
|---|---|
| Compilation release (`swift build -c release`) | OK, sans avertissement |
| Rapports de plantage (`~/Library/Logs/DiagnosticReports`) | 5 aujourd'hui, tous du binaire `.build/release/Murmure` lancé à nu : 2 erreurs non rattrapées au niveau de `main.swift` (fichier audio illisible passé à `--test`), 3 `UNUserNotificationCenter` hors paquet (`AppDelegate` ligne 39). Aucun de l'application installée. Corrigé. |
| Réunion synthétique de 1 min, deux voix (`--meeting`, dossier de données isolé) | Transcription par interlocuteur juste, synthèse en 6 sections, titre « Clause de résiliation et malfaçon ». 33 s de traitement, pic mémoire du processus 3,9 Go (Whisper, pyannote et audio). |
| Réunion synthétique de 60 min, deux voix, 487 tours de parole | Binaire d'avant les correctifs : transcription juste et complète (291 tours, 10 142 mots, 61 000 caractères) en 8 min 41 s (dont ~6 min de distinction des voix), pic mémoire 3,9 Go ; **mais synthèse vide et titre provisoire « Réunion de test » non remplacé**, sans aucune trace : le délai de 60 s par requête au modèle (six tranches à générer, machine en pression mémoire) a été dépassé et l'erreur avalée. C'est le scénario « réunion d'une heure » de l'utilisateur, et il échouait avant aujourd'hui. Avec les correctifs : synthèse rédigée à partir de la vraie transcription produite (`--synthese`), 6 tranches de notes puis compte rendu, en 6 min 48 s (~58 s par requête : le délai de 60 s était donc bien la cause, avec la machine en pression mémoire). Transcriptions synthétiques de 120 min (19 152 mots, 10 tranches) et 150 min (23 971 mots, 13 tranches) : synthèses rédigées en 8 min 49 s et 10 min 41 s, là où l'ancien découpage dépassait le contexte (vérifié par sonde). Ces durées sont celles d'une machine à 15 % de mémoire libre ; elles s'ajoutent aux 8 à 9 min de transcription par heure d'audio. |
| Sonde du serveur llama.cpp de l'application avec un message de 9 941 jetons | HTTP 400 `exceed_context_size_error` (limite 8 192 par emplacement) en 0,1 s. Avant correction : erreur transformée en « réponse illisible », avalée par `try?`, réunion sans synthèse ni titre, notification « Transcription prête ». Mesure utile : 3,9 caractères par jeton en français. |
| Variante de Qwen3 installée | `Qwen3-4B-Instruct-2507` (lue dans l'en-tête du GGUF) : variante sans « réflexion », aucun jeton de pensée ne consomme `max_tokens`. Rien à faire, mais à noter dans le catalogue : remettre le Qwen3 4B « hybride » sous le même nom viderait titres et mises en forme. |
| Mémoire de la machine (MacBook Air M5, 16 Go) | 15 % libres pendant les tests, 1,5 million de pages sorties sur la session ; l'application et son serveur étaient entièrement paginés (RSS 26 Mo et 6 Mo) après 30 min d'inactivité : la première dictée après une pause doit recharger depuis le disque. |

Le compte rendu de la réunion de 60 min et les deux fichiers de 120 et 150 min servent aussi à vérifier le nouveau découpage de la synthèse (section 3).

---

## 3. Corrigé aujourd'hui

Tout compile, tout est commité (un seul commit), l'application est réinstallée.

### Réunions longues
1. **Synthèse impossible au-delà d'environ 1 h 15 à deux voix, 50 min à une voix** (`Summarizer`). Deux causes : le découpage en tranches ne scindait jamais un paragraphe plus long que 12 000 caractères (une réunion à une voix est un seul paragraphe), et le budget des notes (700 jetons × nombre de tranches) dépassait le contexte final. Désormais les paragraphes trop longs sont coupés aux fins de phrase, et le total des notes est borné à 5 200 jetons (chaque tranche reçoit `max(250, min(700, 5 200 / N))`).
2. **Délai de 60 s sur une génération non diffusée en flux** (`LocalLLM.complete`) : une synthèse de réunion ou une réécriture longue échouait passé 60 s, et toutes en mode économie d'énergie. Délai paramétrable : 900 s pour les synthèses, 300 s pour « Retravailler », 60 s pour la dictée.
3. **Erreur du serveur rendue lisible** : `exceed_context_size_error` et consorts remontent avec leur message au lieu de « réponse illisible ».
4. **Échec de synthèse conservé dans la fiche** (`Recording.processingError`) : l'onglet Synthèse l'affiche avec un pictogramme, « Rédiger un compte rendu » reste proposé. Avant, rien ne distinguait un échec d'un choix.
5. **⌘Q pendant une réunion** : refusé pendant l'enregistrement (message dans la pastille), confirmation pendant le traitement (« Quitter quand même »). Au lancement, une réunion restée « En cours » est débloquée, marquée « (interrompue) » si l'audio était perdu.
6. **Mémoire** : les deux pistes (micro, son de l'ordinateur : 2 × 460 Mo pour 2 h) ne sont plus retenues pendant tout le traitement, seules leurs énergies par tranche de 50 ms le sont pour reconnaître « Moi » (2 × 0,5 Mo). Le mixage ne fait plus de seconde copie pour la normalisation. Place réservée pour 2 h dans chaque tableau au départ : plus de recopie de centaines de Mo sous verrou dans le rappel audio (risque de pertes d'échantillons dans la piste système, donc de désalignement « Moi »).
7. **Page En direct** : seuls les 8 000 derniers caractères sont mis en page toutes les 1,5 s (avant : tout le texte, 120 Ko après 2 h).

### Dictée
8. **Un nom appris ne réécrit plus un mot courant** (`CorrectionWatcher`) : « Durant » corrigé en « Durand » aurait réécrit « durant la période » partout (les corrections s'appliquent sans égard à la casse). Un mot qui existe en français n'est plus appris, même capitalisé.
9. **Noms du contexte plus prudents** (`Cleaner.applyContextTerms`) : en début de phrase, la majuscule ne prouve rien (« Durant l'audience » restait « Durand ») ; et quand le document contient deux graphies homophones (« Lefèvre » et « Lefebvre », demandeur et défendeur), aucune n'est appliquée.
10. **Touche effleurée pendant une longue dictée** : n'annule plus qu'au cours des deux premières secondes (combinaison Option + lettre) ; après, elle est ignorée. Avant, deux minutes de parole étaient jetées sans message.
11. **Texte dicté marqué confidentiel pour les gestionnaires de presse-papiers** (`org.nspasteboard.ConcealedType`) : Maccy, Paste, Alfred ne gardent plus les courriers dictés dans leur historique, et ne consomment plus la promesse de collage à la place du champ (ce qui faisait croire à un collage réussi).

### Hygiène
12. **Historique et dictionnaire réécrits à chaque frappe** : `historique.json` (entier, indenté) était réencodé à chaque caractère tapé dans un titre ou un texte ; `dictionnaire.json` était écrit sur le fil principal à chaque caractère. Écritures regroupées (0,3 s et 0,5 s), vidées à la fermeture.
13. **Serveur llama.cpp avec clé** (`--api-key`, tirée au hasard à chaque lancement) : aucune page web ni aucun autre processus ne peut plus s'en servir.
14. **`killOrphans` ne tue plus les serveurs des autres sessions** (bancs d'essai en cours) : seuls les serveurs dont le parent a disparu sont arrêtés.
15. **Ligne de commande** : plus de plantage hors paquet (`Notifier.isAvailable`), mode inconnu ou incomplet refusé avec la liste des modes, nouveau mode `--synthese transcription.txt`, variable `MURMURE_SUPPORT_DIR` pour tester sans toucher aux données de l'utilisateur pendant que l'application tourne.
16. **Consigne de synthèse** : le modèle écrivait littéralement « Responsable : … » dans les actions (le mot venait de la consigne, pris pour un nom) et listait des sociétés parmi les participants ; la consigne donne maintenant un exemple nominatif et limite les participants aux personnes présentes.
17. **Réglages** (demande de l'utilisateur, non vérifié à l'écran) : les panneaux glissent dans le sens du déplacement au lieu d'un fondu croisé où les deux se superposaient ; les notes longues sont repliées sur leur première ligne, un chevron (qui tourne) les déplie. Les dialogues ont un rappel d'annulation (nécessaire pour « Quitter quand même »).
18. Palette : badge « esc » → « échap ». README : six onglets de Réglages, nouveaux modes, mécanismes ci-dessus.

---

## 4. Ce qui reste à corriger : moteur et réunions

Par gravité. Les lignes citées sont celles d'avant les correctifs du jour, à quelques lignes près.

### Important
- **Diarisation d'un bloc sur 2 h, sans retour** (`Transcriber.speakerTurns`) : un seul appel pyannote sur tout l'audio (6 min pour 60 min sur cette machine, en pression mémoire), puis Whisper tour par tour. Le libellé « Transcription… » reste seul pendant 20 à 40 min. À faire : brancher le `progressCallback` de FluidAudio et le compteur de morceaux sur `progress` (« Voix 42 % », « Transcription 12/60 min ») ; au-delà de 90 min, diariser par tronçons de 30 min recollés par voix.
- **Deux diarisations en parallèle** : une dictée de plus de 3 s pendant le traitement d'une réunion lance `speakerTurns` sur les mêmes modèles Core ML (`OfflineDiarizerManager` n'est pas un acteur). Sérialiser dans `Transcriber`. Non reproduit, risque réel.
- **Changement de périphérique audio pendant une réunion** (`AudioRecorder` ligne 30) : le moteur redémarre sans combler le trou par du silence → piste micro plus courte que la piste système, « Moi » et l'aperçu désalignés pour le reste de la réunion ; si le redémarrage échoue, micro muet sans alerte. Combler par des zéros jusqu'à `elapsed × 16 000`, remonter l'échec dans la pastille, écouter le changement de sortie par défaut pour l'agrégat système.
- **Bouton ✕ « Annuler sans rien garder »** à 24 px d'« Arrêter », sans confirmation, jette deux heures d'audio. `Modals.shared.confirm` dès que la réunion dépasse une minute.
- **Historique illisible = historique perdu** : `load` fait `try?` ; un JSON corrompu donne un tableau vide en mémoire, et la première sauvegarde écrase le fichier. Renommer en `historique.illisible-<date>.json` et refuser d'écrire ; copie `.bak` avant chaque écriture.
- **Apple Intelligence comme moteur** : les tranches de 12 000 caractères dépassent sa fenêtre (~4 096 jetons), la synthèse échouera toujours avec ce moteur. Réduire la tranche à 3 000 caractères quand `engine == .apple`, ou n'offrir ce moteur que pour la dictée.
- **Texte vide après traitement** : statut « Sans contenu », aucune trace de la cause (Whisper en échec ou micro muet). Journaliser l'erreur de `transcribeLong` et le dire dans la fiche.

### Mineur
- Le second emplacement du serveur (`-np 2`) est inutile pour la synthèse : `-c 24576 -np 2` ou un contexte de 12 à 16 k pour les réunions lèverait la contrainte sur les notes sans raccourcir celles-ci.
- Aperçu en direct : Whisper tourne toutes les 1,5 s sur jusqu'à 20 s d'audio pendant toute la réunion (puce neuronale occupée ~50 %, chaleur, batterie). Espacer à 3 s au-delà de 10 s de morceau en cours.
- Notification « Transcription prête » quand la synthèse a échoué : dire « Synthèse impossible : … ».
- Continuation de la file Whisper non annulable (`withCheckedContinuation`) : un passage inutile de 1 à 2 s au plus après l'arrêt de l'aperçu.
- Le transcript est stocké trois fois par réunion (`text`, `rawText`, `turns`) : 400 à 450 Ko pour 2 h, par réunion.

---

## 5. Ce qui reste à corriger : chaîne de dictée

### Important
- **Lecture d'accessibilité non bornée** (`FieldContext` lignes 66 à 158) : le délai de 0,25 s n'est posé que sur l'application et le champ ; le titre de fenêtre et chaque élément du parcours de l'écran gardent le délai par défaut de 6 s. Une application figée (Word en enregistrement automatique, navigateur chargé) peut bloquer la fin de dictée jusqu'à plusieurs secondes sous « Transcription… ». Poser le délai sur l'élément système une fois pour toutes, et ne pas attendre le contexte au-delà de 0,3 s après le relâchement.
- **Détection de collage raté** : fondée sur la consommation de la promesse (corrigé pour les gestionnaires de presse-papiers par la marque « confidentiel »), mais une application lente qui lit après 0,6 s donne un faux « raté » et **le contenu précédent du presse-papiers est perdu** (remplacé sans restauration). Allonger à 1,5 s, et vérifier par relecture AX que le texte est apparu dans le champ.
- **Formule d'appel dans Mail/Outlook** (`FieldContext` ligne 331) : « Madame, Monsieur, je reviens… » est coupé après la première virgule (« Madame, » seule sur sa ligne) ; « Monsieur Durand, en sa qualité de gérant, a… » est pris pour une formule. Accepter une suite de formules, et n'appliquer la règle que si la suite commence par un pronom ou un verbe.
- **Dictée longue et modèle** (`Cleaner.cleanLine`) : une dictée de 5 min sans « nouveau paragraphe » est une seule ligne de 4 000 caractères ; `needsModel` est quasi certain (« enfin », « non seulement », « nous nous »), le modèle regénère ~1 000 jetons (20 à 30 s de « Mise en forme… »), et si le ratio sort de 0,5–1,4 tout est jeté. Découper en groupes de phrases (~600 caractères), n'envoyer que les groupes qui en ont besoin, borner à 3 s par groupe.
- **« nous nous », « vous vous »** déclenchent le modèle comme répétition, et la consigne lui demande de supprimer les répétitions. Exclure les pronoms réfléchis du motif et le dire dans la consigne. À vérifier sur `--bench-llm`.
- **Échap inopérant pendant « Transcription… / Mise en forme… »** : avec les deux points précédents, on peut attendre 30 s sans issue. Accepter Échap en `.processing` (interrompre Whisper, état repos).

### Mineur
- Règle d'hésitation `E` seule : « Annexe E. » devient « Annexe ». « à la ligne » dans la prose (« conforme à la ligne jurisprudentielle ») saute une ligne.
- Après une puce « - » ou un numéro, la dictée est mise en minuscule (« - première remarque »).
- « appuie sur entrée » : une phrase qui parle de la touche (« dites au client d'appuyer sur la touche entrée ») tronque et envoie. Exiger que la formule soit une phrase à part.
- Mode commande verrouillé : la pastille passe en « verrouillée » et l'indication « consigne » disparaît.
- Boucle de dictée en flux qui s'arrête sur un échec de morceau (`ProgressiveDictation` ligne 82) : plus d'aperçu, tout le reste transcrit d'un bloc au relâchement. `continue` au lieu de `return`.
- Changement rapide de moteur puis de modèle : le second `stop()` tue le premier serveur pendant que le premier `start` attend, état « échec » alors qu'un serveur tourne. Numéro de génération.
- Son coupé pendant la dictée non rétabli après un plantage (état en mémoire). Mémoriser le périphérique dans UserDefaults.
- Touche fn : rien n'empêche le choix quand macOS lui attribue le sélecteur d'émojis ; vérifier `AppleFnUsageType` et griser.
- Brouillons de courriel : « + » non encodé (un « +33 6 » devient « 33 6 » dans Gmail), corps coupé à 6 000 caractères sans prévenir, aucun message si aucun client n'est configuré.
- `AXManualAccessibility` posé définitivement sur chaque application Electron activée (Slack, Teams, VS Code ralentis toute la session). Ne l'activer qu'au début d'une dictée dans cette application.
- Candidats de correction (paires de mots tirés des documents) en clair dans UserDefaults : les mettre dans `dictionnaire.json` ou purger à 7 jours.

---

## 6. Face aux concurrents : ce qui manque, ce qui est en avance

### Sources
Wispr Flow (nouveautés avril–octobre 2026 : modèle maison Canto, dictée jusqu'à 20 min, lecture audio de l'historique 14 jours, récupération après fermeture, micro silencieux détecté, sélection automatique du micro, mode mains libres, Transforms, Auto Cleanup à quatre niveaux, Scratchpad, Notetaker avec « Qu'est-ce que j'ai raté ? », import Otter/Granola, MCP, Insights), Superwhisper (modes Voice / Message / Mail / Note / Super / Custom, activation automatique par application, curseur de ton, contexte sélection/presse-papiers/application, transcription de fichiers), Granola (notes de l'utilisateur enrichies par la transcription, modèles de notes par section, chat avec une ou plusieurs réunions, MCP), Wispr Flow Notetaker (pause/reprise, arrêt automatique à 2 h, « Vous / Eux », aide à la rédaction de courriels de suivi). Sources en fin de document.

### Où Murmure est en avance
- **100 % local**, avec les garde-fous réels d'un cabinet : rien ne sort, audio jamais écrit, clé sur le serveur local, presse-papiers confidentiel. Wispr Flow entraîne ses modèles sur les données des forfaits Free et Pro par défaut ; Granola et Wispr envoient l'audio à des fournisseurs cloud aux États-Unis.
- **Contexte du curseur** (titre de fenêtre, textes voisins, accord de la phrase) : Superwhisper (Super Mode) a l'équivalent, Wispr Flow non.
- **Apprentissage des corrections** depuis le document : aucun concurrent ne relit ce que l'utilisateur a corrigé.
- **Réunions à deux pistes avec « Moi »**, dossiers de l'affaire en Markdown, serveur MCP en lecture : Wispr Notetaker n'a lancé son MCP qu'en septembre 2026, sans les dictées.
- **Synthèse par blocs typés** pour l'avocat (décisions, actions avec responsable et échéance, points de vigilance) : Granola fait mieux en souplesse (modèles par section), Wispr Notetaker moins bien (résumé par thèmes).

### Ce qui manque, par ordre d'intérêt pour un avocat

**Fiabilité perçue (Wispr a investi là en 2026)**
1. **Récupération d'une dictée après plantage ou fermeture** : Wispr sauvegarde l'audio d'une dictée interrompue et permet de la traiter depuis l'historique. Murmure perd tout. Proposer un fichier WAV temporaire chiffré ou en mémoire protégée pendant la dictée et la réunion, supprimé à la fin, assumé dans le README (choix à trancher : la promesse « jamais sur le disque » contre la perte de deux heures de rendez-vous).
2. **Micro silencieux et micro débranché** : Wispr prévient dès le début si rien n'est capté, et bascule sur le micro suivant. Murmure n'alerte pas (une dictée muette donne « Aucune parole détectée » à la fin). Détecter l'absence de niveau pendant 2 s au début et le dire dans la pastille ; préférer un micro externe classé.
3. **Lecture de l'audio de l'historique** (Wispr : 14 jours) : utile pour vérifier une transcription contestée. Murmure a l'option « Garder l'audio des dictées » (banc d'essai) mais pas de lecteur. Ajouter un lecteur dans la fiche quand l'audio existe, avec purge automatique à 14 jours.
4. **Pause / reprise d'une réunion**, arrêt automatique après 3 h (Wispr : 2 h) avec notification « Toujours en réunion ? » : évite une réunion oubliée de six heures.

**Dictée**
5. **Styles par application et niveaux de nettoyage** : Wispr (ton par application, Auto Cleanup à quatre niveaux, « Undo AI edit »), Superwhisper (modes avec consigne, activation par application, curseur de ton). Murmure a des règles implicites par application (messagerie sans point final, formule d'appel dans Mail) mais rien de réglable. Proposer un réglage « Mise en forme : brute / légère / soignée » et des profils par application (Mail : courriel soutenu ; Messages : court ; Word : juridique) avec consigne modifiable, dans Réglages › Transcription.
6. **Transforms / consignes enregistrées** : Wispr permet des réécritures nommées (« Polish », « Prompt Engineer ») appliquées à une sélection, ou automatiquement après chaque dictée. Murmure a le mode commande (Maj + touche) libre et les préréglages de « Retravailler » ; il manque des consignes enregistrées, nommées, dictables (« en mise en demeure », « style conclusions ») et un déclencheur pour la fiche ouverte.
7. **Dictée de fichiers audio** (Superwhisper, MacWhisper) : glisser un enregistrement de dictaphone, un mémo vocal iPhone, un fichier d'audience : la chaîne existe (`--test`, `--meeting`), il manque la porte dans l'interface (« Importer un enregistrement… », glisser-déposer sur la fenêtre).
8. **Bloc-notes flottant** (Wispr Scratchpad, Option + S) : dicter une note sans application cible. Murmure a « copier seulement » ; une fenêtre flottante minimale « Note rapide » qui crée une dictée dans l'historique serait cohérente.
9. **Statistiques** (Wispr Insights : mots par minute, mots corrigés, applications) : secondaire, mais une ligne « Cette semaine : 3 h de dictée, 14 000 mots, 32 corrections apprises » dans l'accueil est facile et valorisante.
10. **Mains libres par double appui** et touche d'annulation reconfigurable (Wispr) : Murmure a l'appui bref ; ajouter le choix de la touche d'annulation est trivial.

**Réunions**
11. **Notes de l'utilisateur pendant la réunion, enrichies ensuite** (Granola) : un champ de notes libre sur la page En direct, dont le contenu est donné au modèle (« points que l'utilisateur a notés ») et repris dans la synthèse. C'est la différence la plus visible entre Granola et les autres, et c'est ce qu'un avocat fait déjà sur papier en rendez-vous.
12. **Questions à la réunion** (« Qu'est-ce que j'ai raté ? » pendant, « Quels engagements ai-je pris ? » après, sur une ou plusieurs réunions : Granola, Wispr) : la chaîne `Summarizer.revise` et le modèle local le permettent ; il manque un champ « Poser une question » dans la fiche, et une recherche sémantique simple sur l'historique.
13. **Modèles de compte rendu personnalisables** (Granola : sections libres) : Murmure a trois modèles codés en dur ; les rendre éditables (nom, sections, consignes) dans Réglages ou le Dictionnaire.
14. **Courriel de suivi rédigé** (Wispr Notetaker Windows, Granola) : Murmure ouvre un brouillon de la synthèse brute ; faire rédiger par le modèle un courriel de compte rendu adressé au client, à partir de la synthèse et du modèle « Compte rendu de rendez-vous client ».
15. **Consentement** : Wispr affiche un rappel à l'écran et un réglage administrateur. Pour un avocat, une ligne « Participants informés » à cocher au lancement, et une mention dans l'export, protègent.

**Connecteurs et cabinet**
16. **Pièces du dossier comme contexte** : le dossier de l'affaire lié reçoit déjà les copies Markdown ; dans l'autre sens, donner au modèle les titres des fichiers du dossier (et les noms des parties lus dans un fichier `parties.txt` ou dans les PDF récents) améliorerait les noms propres dans les réunions comme le contexte du curseur le fait pour la dictée.
17. **Rendez-vous à venir** : Wispr et Granola affichent les réunions du jour et proposent d'enregistrer à l'heure. Murmure détecte la visio qui tient le micro ; ajouter la liste des rendez-vous du jour dans l'accueil (EventKit déjà autorisé) avec « Enregistrer » et un rappel à l'heure.
18. **Export** : Word existe pour la synthèse ; ajouter PDF, et l'export de la transcription complète en Word (avec les interlocuteurs), et « Copier pour Claude » (Markdown prêt à coller).
19. **Horodatage des tours de parole** : les segments pyannote ont des temps ; les garder (`Turn.start`) permettrait « 12:34 » dans la transcription, l'écoute à l'endroit si l'audio est gardé, et un meilleur recollement par voix.

---

## 7. Interface : ce qui fait pro, ce qui fait amateur, et quoi faire

Lecture seule du code, pas de rendu observé. Ce qui fonctionne : une grammaire de composants réelle (`SettingsSection/Row`, `Tag`, `Choice`, `MenuButton`, `ModalHost`), des mouvements cohérents (surlignage qui glisse, pages qui coulissent, fenêtre en fondu), des attentions (extraits de recherche, titre épinglé, clavier sur la liste, versions de synthèse). Ce qui tire vers l'amateur : la densité de texte explicatif dans les Réglages, quelques contrôles natifs résiduels, des états intermédiaires non dessinés (erreur, vide, chargement), et l'absence de respiration après une action (pas d'annulation, pas de confirmation visuelle légère).

### Réglages (priorité demandée)
1. **Notes repliables** : chaque section garde une note d'une ligne et un chevron « En savoir plus » qui tourne (0 → 90°) et déplie le paragraphe (`.move(edge: .top)` + opacité, état mémorisé par section). La page devient deux fois plus courte sans perdre un mot. Effort faible, impact fort.
2. **Transition directionnelle entre panneaux** : aujourd'hui fondu croisé dans un `ZStack` (les deux panneaux se superposent, la hauteur saute). Mémoriser l'index précédent et glisser de 18 pt vers la gauche ou la droite selon le sens, hauteur animée. Effort faible.
3. **Sous-pages à tiroir** pour ce qui mérite de l'espace : « Modèle local » (modèles installés, taille, état, dossier, Finder), « Agenda » (comptes détectés, autorisation, « Rendez-vous en cours : … »), « Pastille » (aperçu vivant). Une `SettingsRow` « Modèle local · Qwen3 4B › », la sous-page glisse depuis la droite, « ‹ Transcription » en tête, Échap pour revenir : même grammaire que la page détail. Effort moyen, impact fort.
4. **Aperçus vivants** à la place des phrases : mini-sélecteur dont la pastille glisse pour « Animations », trois carrés pour « Apparence », schéma d'écran 48 × 30 avec la pastille qui se déplace pour sa position.
5. **Retour de modification** : coche qui apparaît 1 s à droite de la ligne modifiée (comme `CopyButton`).
6. **Rail vertical** (Général, Connecteurs, Affichage, Accessibilité, Transcription, Avancé avec symboles) au lieu de six segments qui se touchent, surlignage glissant comme le panneau gauche. Effort moyen.
7. Déplacer l'aide-mémoire du raccourci dans une carte repliée « Comment dicter » ; un seul endroit pour « Réduire les animations » (Accessibilité) avec renvoi.
8. Champ « Rechercher un réglage » filtrant les lignes.

### Accueil et listes
- **Barre d'actions flottante** quand une sélection existe (« 3 sélectionnés · Ranger · Archiver · Corbeille · ✕ », capsule inversée en bas, `.move(edge: .bottom)`), « Action groupée » disparaît de la barre du haut.
- **Toast d'annulation** après mise à la corbeille (« Déplacé dans la corbeille · Annuler », 5 s ; `store.restore` existe).
- Survol, sélection et curseur partagent le même fond : distinguer (sélection = case inversée + filet gauche).
- Colonne « Type » redondante avec le pictogramme ; tri par clic sur Titre / Date / Statut.
- Compteurs à côté de Réunions / Dictées / dossiers dans le panneau gauche ; « … » au survol des dossiers (actions aujourd'hui au clic droit seulement) ; glisser-déposer d'une ligne vers un dossier.
- Archive vide étiquetée « Aucun résultat » ; un dossier vide reçoit le message générique de dictée.
- Corbeille : « encore 27 jours » calculé depuis `deletedAt`, « Restaurer » visible au survol, dossier non modifiable depuis la corbeille, bouton de suppression définitive en contour (pas le même style que toute action principale).

### Fiches
- **Réunion** : double cadre (le panneau encadre, chaque section encadre) à supprimer ; sélecteur de versions en texte gris quasi invisible → puces 1 · 2 · 3 ; barre de consigne collante en bas de page ; apparition des blocs un à un après la rédaction (`delay(index × 0,04)`) ; Échap / ⌘[ pour revenir ; carte d'erreur commune avec « Réessayer ».
- **Dictée** : l'éditeur n'a ni cadre ni focus visible ; les quatre préréglages n'ont pas de titre (le README dit « Retravailler ») ; échec silencieux de la retouche (`try?`) ; préréglages actifs sans modèle ; après retouche, montrer le diff (`changes()` existe) avec « Garder / Annuler » ; compteur « 312 mots · 1 min 40 ».
- « Partager » dans l'en-tête fait « Préparer un e-mail » : un seul libellé ; trancher « e-mail » / « courriel » une fois pour toutes (dix chaînes).
- Titre : champ inline qui renomme à chaque frappe et « Renommer… » modal ; si le titre généré arrive pendant la saisie, il écrase ce que l'utilisateur tape.

### Dictionnaire
- Aucun état de focus sur les cellules ; « Ajouter une correction » crée une ligne vide sans focus, sauvegardée vide ; pas de compteur ni de filtre (les corrections apprises s'accumulent) ; croix de 8 pt ; suppression sans animation.

### Pastille
- Seules couleurs de l'application (rouge, orange, bleu) ; erreurs et astuces partagent le même pictogramme ; roue native blanche pendant « Transcription… » sans progression ; tailles fixes qui ignorent « Taille de l'interface ». Proposé : vumètre monochrome, glyphe de mode à gauche (cadenas, étincelles, micro), erreurs distinguées, fine ligne qui balaie la capsule pendant la transcription.

### Accueil du premier lancement
- Écran 3 « Essayez… » ne dit jamais « ça a marché » : écouter l'historique et transformer la carte en « Première dictée réussie · 12 mots » ; mini-pastille factice qui joue « À l'écoute → Transcription → Collé » ; avertir si l'on continue sans micro ni accessibilité.

### Palette ⌘K
- Pas de titres de groupe, Corbeille et Dictionnaire n'apparaissent qu'en tapant, pas de pied avec les raccourcis, correspondance sur le titre seul, aucune action contextuelle sur la fiche ouverte (renommer, exporter, ranger).

### Accessibilité et dette
- **Zéro `accessibilityLabel`** dans le projet ; interrupteurs maison invisibles pour VoiceOver et le clavier (capsule + `onTapGesture`, `Toggle("")`) ; menus maison sans clavier (seule la palette gère ↑ ↓ Entrée) ; lignes de l'accueil non focusables individuellement ; « … » au repos à 2,4:1 de contraste.
- Contrôles natifs restants : `ProgressView` (six endroits), panneau « À propos » standard. Un indicateur maison et une vue « À propos » dans `ModalHost` fermeraient la boucle de la DA.
- Doublons : `Choice` / `SegmentedTabs`, `CopyButton` copié-collé, menu « Ranger dans » écrit trois fois, ouverture des Réglages Système d'accessibilité écrite trois fois, `onboarded` déclaré trois fois avec deux valeurs par défaut.
- Performance de l'accueil sur une grosse base : filtre recalculé deux à trois fois par rendu, `Recording.matches` reconstruit le transcript de chaque réunion à chaque caractère tapé, `@Published recordings` global redessine tout. Mémoriser `items`, précalculer un champ de recherche plié par enregistrement, débounce 150 ms.
- Animations hors `Motion` : vumètre, défilement En direct, point clignotant de la réunion ; contraste renforcé de macOS lu mais non observé (pas de notification).

---

## 8. Ordre proposé

**Lot 1 — fiabilité (une session, moteur)** : progression visible du traitement (voix, transcription, synthèse) ; confirmation du ✕ ; sérialiser la diarisation ; changement de périphérique comblé ; sauvegarde `.bak` de l'historique et refus d'écraser un fichier illisible ; délai AX borné et contexte non bloquant ; Échap pendant le traitement ; collage raté vérifié par relecture ; formule d'appel multiple.

**Lot 2 — Réglages et finition (une session, interface)** : notes repliables, transition directionnelle, sous-pages à tiroir (Modèle local, Agenda, Pastille), aperçus vivants, retour de modification, rail vertical ; `ProgressView` maison ; carte d'erreur commune ; toast d'annulation ; barre d'actions flottante.

**Lot 3 — ce que les concurrents ont et qu'un avocat veut (deux sessions)** : notes pendant la réunion reprises dans la synthèse ; question à la réunion ; micro silencieux détecté ; importer un enregistrement ; lecteur audio et purge ; styles de mise en forme par application avec consigne ; consignes enregistrées ; rendez-vous du jour dans l'accueil ; courriel de suivi rédigé ; modèles de compte rendu éditables.

**Lot 4 — accessibilité et dette** : libellés VoiceOver, interrupteurs et menus au clavier, doublons, performance de l'accueil, animations sous `Motion`.

Décision prise par l'utilisateur le 31 octobre 2026 : un fichier audio temporaire est conservé pendant une réunion et son traitement, puis supprimé (reprise possible après un plantage ; rien ne quitte le Mac). Confiée au lot 1.

---

## Sources (concurrents)
- Wispr Flow, nouveautés : https://wisprflow.ai/whats-new ; produit : https://wisprflow.ai/
- Superwhisper, modes : https://superwhisper.com/docs/modes ; comparatif éditeur : https://superwhisper.com/vs/wispr-flow
- Wispr Flow Notetaker, essai par tl;dv (concurrent, à lire avec recul) : https://tldv.io/fr/blog/wispr-flow-notetaker-review/
- Granola, retour d'un an d'usage : https://zackproser.com/granola
- Comparatifs 2026 : https://spokenly.app/blog/wispr-flow-vs-superwhisper-vs-macwhisper ; https://www.getvoibe.com/resources/compare/
