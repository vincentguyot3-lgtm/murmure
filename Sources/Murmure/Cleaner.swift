import AppKit
import FoundationModels

/// Met en forme la transcription : règles fixes, puis un modèle de langage (local, Apple Intelligence,
/// ou Claude en ligne). Les moteurs locaux ne sont appelés qu'en cas d'autocorrection ou de bégaiement ;
/// Claude relit chaque dictée avec le contexte du curseur.
enum Cleaner {
    enum Engine: String, CaseIterable, Identifiable {
        case claude, local, apple, none
        var id: String { rawValue }
        var label: String {
            switch self {
            case .claude: return "Claude, en ligne (le plus puissant)"
            case .local: return "Modèle local (llama.cpp)"
            case .apple: return "Apple Intelligence"
            case .none: return "Aucune (transcription brute)"
            }
        }
        /// Le texte quitte le Mac avec ce moteur.
        var isOnline: Bool { self == .claude }
    }

    /// Moteur choisi dans les réglages.
    static var chosen: Engine { override ?? Engine(rawValue: Settings.cleanupEngine) ?? .local }
    /// Moteur imposé par un essai en ligne de commande, sans toucher aux réglages.
    static var override: Engine?

    /// Vrai pendant le traitement d'un élément d'un dossier « jamais en ligne » : Claude est remplacé par le
    /// moteur local le temps de la tâche.
    @TaskLocal static var localOnly = false

    /// Moteur effectivement appelé : le moteur choisi, sauf si Claude est écarté (dossier « jamais en ligne »,
    /// « Rester hors ligne » dans la barre des menus), auquel cas le meilleur moteur local disponible prend le relais.
    static var engine: Engine {
        let chosen = chosen
        guard chosen == .claude, localOnly || Settings.stayOffline else { return chosen }
        return fallbackEngine
    }

    /// Moteur local qui remplace Claude quand il est écarté ou injoignable : le modèle local s'il tourne,
    /// Apple Intelligence sinon, et à défaut aucun.
    static var fallbackEngine: Engine {
        if LocalLLM.shared.isRunning { return .local }
        if appleAvailable { return .apple }
        return .none
    }

    /// Le modèle local doit-il être chargé ? Toujours quand c'est le moteur choisi ; avec Claude, seulement
    /// pour servir de relais sans connexion (réglage « Repli local »).
    static var keepsLocalModel: Bool {
        chosen == .local || (chosen == .claude && Settings.claudeFallback && LocalLLM.isInstalled)
    }

    static var appleAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static var appleUnavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence est désactivé"
        case .unavailable(.modelNotReady): return "modèle Apple Intelligence en cours de téléchargement"
        case .unavailable(.deviceNotEligible): return "Mac non compatible Apple Intelligence"
        case .unavailable: return "Apple Intelligence indisponible"
        }
    }

    /// Le moteur choisi peut-il être appelé maintenant ?
    static var isReady: Bool {
        switch engine {
        case .claude: return ClaudeAPI.hasKey
        case .local: return LocalLLM.shared.isRunning
        case .apple: return appleAvailable
        case .none: return false
        }
    }

    /// Même chose pour un élément d'un dossier « jamais en ligne ».
    static func isReady(localOnly: Bool) -> Bool {
        $localOnly.withValue(localOnly) { isReady }
    }

    /// Pourquoi le moteur n'est pas prêt, pour l'interface.
    static var notReadyReason: String {
        switch engine {
        case .claude: return "Ajoutez votre clé Claude dans Réglages › Transcription."
        case .local: return "Le modèle de langage local n'est pas prêt."
        case .apple: return appleUnavailableReason.map { $0.prefix(1).uppercased() + $0.dropFirst() + "." } ?? "Apple Intelligence n'est pas prêt."
        case .none: return "Aucun modèle de langage n'est choisi dans Réglages › Transcription."
        }
    }

    /// « sur ce Mac » ou « par Claude, en ligne » : où la rédaction se fait.
    static var whereText: String { engine == .claude ? "par Claude, en ligne" : "sur ce Mac" }

    // MARK: - Règles fixes

    /// Règles fixes appliquées avant le modèle : hésitations et commandes de mise en page dictées.
    static func applyCommands(_ text: String) -> String {
        let rules: [(String, String)] = [
            (#"(?i)(^|[\s,.])(euh+|heu+|hum+|hm+|bah|E)(?=[\s,.]|$)[,.]?"#, "$1"),
            (#"(?i)[\s,.]*\bnouveau paragraphe\b[\s,.]*"#, ".\n\n"),
            (#"(?i)[\s,.]*\bpoint [aà] la ligne\b[\s,.]*"#, ".\n"),
            (#"(?i)[\s,]*(\.?)\s*\b[aà] la ligne\b[\s,.]*"#, "$1\n"),
            (#"[ \t]{2,}"#, " "),
            (#"^[\s,.]+"#, ""),
        ]
        var result = applyReplacements(text)
        for (pattern, template) in rules {
            result = result.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        // Majuscule en début de texte et après chaque retour à la ligne.
        let lines = result.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// « Appuie sur entrée » (ou « Entrée. » dit seul) en fin de dictée : retiré du texte, et la touche Entrée
    /// suivra le collage, pour envoyer un message ou une question à un assistant sans toucher le clavier.
    /// « Une entrée », « l'entrée » ne déclenchent rien : il faut la formule, ou le mot seul après un point.
    static func takeEnterCommand(_ text: String) -> (text: String, pressReturn: Bool) {
        let pattern = #"(?i)(?:[\s,.]*\b(?:appuie|appuyez|appuyer) sur (?:la touche )?entrée|[\s,]*\btouche entrée|(?:^|(?<=[.!?…]))\s*entrée)\s*[.!]?\s*$"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return (text, false) }
        var kept = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        while kept.hasSuffix(",") { kept.removeLast() }
        return (kept, true)
    }

    /// Rapproche les mots du texte des termes donnés (participants, objet de la réunion, dictionnaire). Un mot, ou
    /// une suite de mots de même longueur qu'un terme, qui ne diffère du terme que d'une lettre (deux à partir de
    /// huit lettres), même initiale, est remplacé par le terme le plus proche (« Erickson » → « Eriksson »,
    /// « Saint-Jame » → « Saint-James »), à trois conditions : le mot entendu n'est pas lui-même un terme, il n'est
    /// pas un mot du français (« matin » ne devient pas « Martin », « sinon » ne devient pas « Simon »), et il porte
    /// une majuscule si le terme en porte une (un nom propre entendu comme tel). Un terme court (moins de cinq
    /// lettres) n'est rapproché qu'à l'identique, casse à part ; un mot identique au terme à la casse près prend la
    /// graphie du terme (« kbis » → « Kbis »), sauf sa majuscule initiale de début de phrase, gardée. L'élision est
    /// conservée (« d'Erickson » → « d'Eriksson »). Sert à la transcription des réunions, faite sans amorce.
    static func applyTerms(_ text: String, terms: [String]) -> String {
        let candidates = terms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return text }
        func folded(_ s: String) -> String {
            s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
                .replacingOccurrences(of: "’", with: "'")
        }
        struct Term { let text: String; let folded: String; let words: Int; let letters: Int; let capitalized: Bool }
        let prepared = candidates.map { term -> Term in
            let f = folded(term)
            return Term(text: term, folded: f, words: term.split(separator: " ").count, letters: f.filter(\.isLetter).count,
                        capitalized: term.first?.isUppercase ?? false)
        }
        let exact = Set(prepared.map(\.folded))
        // Mots du texte avec, à part, leur ponctuation et leur élision (« d' », « l' », « qu' »).
        let pieces = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        func core(_ piece: String) -> (lead: String, word: String, trail: String) {
            var scalars = Array(piece)
            var lead = "", trail = ""
            while let first = scalars.first, !first.isLetter, !first.isNumber { lead.append(first); scalars.removeFirst() }
            while let last = scalars.last, !last.isLetter, !last.isNumber { trail.insert(last, at: trail.startIndex); scalars.removeLast() }
            if let apostrophe = scalars.firstIndex(where: { $0 == "'" || $0 == "’" }), apostrophe <= 2, apostrophe < scalars.count - 1 {
                lead += String(scalars[...apostrophe])
                scalars.removeFirst(apostrophe + 1)
            }
            return (lead, String(scalars), trail)
        }
        var result: [String] = []
        var i = 0
        while i < pieces.count {
            var best: (term: Term, distance: Int, group: [(lead: String, word: String, trail: String)], candidate: String)?
            for term in prepared where i + term.words <= pieces.count {
                let group = pieces[i..<(i + term.words)].map(core)
                let candidate = group.map(\.word).joined(separator: " ")
                guard !candidate.isEmpty, group.dropLast().allSatisfy({ $0.trail.isEmpty }) else { continue }
                let f = folded(candidate)
                let allowed = term.letters >= 8 ? 2 : term.letters >= 5 ? 1 : 0
                guard f.first == term.folded.first, abs(f.count - term.folded.count) <= allowed else { continue }
                let distance = f == term.folded ? 0 : BenchASR.editDistance(Array(f), Array(term.folded))
                guard distance <= allowed, distance < (best?.distance ?? Int.max) else { continue }
                if distance > 0 {
                    // Un mot entendu qui est déjà un terme, un mot du français, ou un nom commun (minuscule) pour un
                    // nom propre : on ne touche pas.
                    guard !exact.contains(f), !(term.capitalized && !(candidate.first?.isUppercase ?? false)),
                          !isFrenchWord(candidate) else { continue }
                }
                best = (term, distance, group, candidate)
            }
            if let best {
                var replacement = best.term.text
                if best.distance == 0 {
                    // Même mot : la graphie du terme, mais une majuscule de début de phrase entendue est gardée.
                    if best.candidate == best.term.text { result.append(pieces[i]); i += 1; continue }
                    if let first = best.candidate.first, first.isUppercase, let termFirst = replacement.first, termFirst.isLowercase {
                        replacement = String(first) + replacement.dropFirst()
                    }
                }
                result.append(best.group[0].lead + replacement + best.group[best.group.count - 1].trail)
                i += best.term.words
            } else {
                result.append(pieces[i]); i += 1
            }
        }
        return result.joined(separator: " ")
    }

    /// Vrai si chaque mot de l'expression figure dans le dictionnaire français du système (comme pour l'apprentissage
    /// des corrections). Le correcteur est partagé : accès sous verrou.
    private static let spellLock = NSLock()

    /// Mot appris par l'utilisateur dans le correcteur de macOS (« Apprendre l'orthographe ») : un nom qui lui est
    /// familier, que `isFrenchWord` accepte comme s'il était du français.
    static func isLearnedWord(_ word: String) -> Bool {
        spellLock.lock()
        defer { spellLock.unlock() }
        return NSSpellChecker.shared.hasLearnedWord(word) || NSSpellChecker.shared.hasLearnedWord(word.lowercased())
    }

    static func isFrenchWord(_ text: String) -> Bool {
        spellLock.lock()
        defer { spellLock.unlock() }
        return text.split(separator: " ").allSatisfy { word in
            NSSpellChecker.shared.checkSpelling(of: String(word), startingAt: 0, language: "fr", wrap: false,
                                                inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
    }

    /// Corrections personnelles du dictionnaire (mot entier, sans tenir compte de la casse).
    static func applyReplacements(_ text: String) -> String {
        var result = text
        for (from, to) in Settings.replacements() {
            let pattern = "(?i)(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: from) + "(?![\\p{L}\\p{N}])"
            result = result.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: to), options: .regularExpression)
        }
        return result
    }

    // MARK: - Extraits

    /// Remplace chaque phrase dictée qui est exactement le déclencheur d'un extrait (« coordonnées du
    /// cabinet ») par son texte. Une phrase qui ne fait que contenir le déclencheur n'est pas touchée.
    /// Renvoie aussi si un extrait a servi : son texte ne doit plus être retouché ensuite.
    static func applySnippets(_ text: String) -> (text: String, used: Bool) {
        let snippets = Lexicon.shared.snapshot().snippets ?? []
        guard !snippets.isEmpty else { return (text, false) }
        func key(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
                .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        }
        var byKey: [String: String] = [:]
        for snippet in snippets where !key(snippet.from).isEmpty && !snippet.to.isEmpty { byKey[key(snippet.from)] = snippet.to }
        guard let regex = try? NSRegularExpression(pattern: #"[^.!?\n]+[.!?]*"#) else { return (text, false) }
        let ns = text as NSString
        var result = text
        var used = false
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard let snippet = byKey[key(ns.substring(with: match.range))] else { continue }
            let original = ns.substring(with: match.range)
            let lead = original.prefix(while: \.isWhitespace)
            result = (result as NSString).replacingCharacters(in: match.range, with: lead + snippet)
            used = true
        }
        return (result, used)
    }

    // MARK: - Noms du contexte

    /// Rétablit la graphie des noms propres et sigles présents autour du curseur (ou dans le dictionnaire)
    /// quand Whisper les a entendus mais mal écrits : « Lefèvre » pour « Lefebvre », « Baligo » pour « Baligaux »,
    /// « Kervoa Len » pour « Kervoalen ». Deux mots se répondent s'ils se prononcent pareil en français.
    /// Un mot courant correctement écrit et en minuscule (« durant ») n'est jamais remplacé par un nom (« Durand »).
    @MainActor
    static func applyContextTerms(_ text: String, terms: [String]) -> String {
        let words = Set(terms.flatMap { $0.split(separator: " ").map(String.init) })
        var byKey: [String: String] = [:]
        // Deux graphies qui se prononcent pareil dans le même document (« Lefèvre » et « Lefebvre »,
        // demandeur et défendeur) : on ne devine pas laquelle est dite, aucune des deux n'est appliquée.
        var ambiguous: Set<String> = []
        for word in words where word.count >= 4 {
            let key = soundKey(word)
            guard key.count >= 4 else { continue }
            if let existing = byKey[key], existing != word { ambiguous.insert(key) } else { byKey[key] = word }
        }
        for key in ambiguous { byKey[key] = nil }
        guard !byKey.isEmpty, let regex = try? NSRegularExpression(pattern: #"\p{L}[\p{L}\-]*"#) else { return text }
        let ns = text as NSString
        let tokens = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)

        // Un nom écrit avec majuscule par Whisper peut être rectifié ; un mot en minuscule seulement s'il
        // n'existe pas en français. En début de phrase, la majuscule ne dit rien : « Durant l'audience »
        // n'est pas « Durand », on exige alors que le mot n'existe pas en minuscule.
        func startsSentence(_ range: NSRange) -> Bool {
            var index = range.location
            while index > 0 {
                index -= 1
                let char = Character(UnicodeScalar(ns.character(at: index)) ?? " ")
                if char.isWhitespace || char.isNewline { continue }
                return ".!?…".contains(char)
            }
            return true
        }
        func plausible(_ word: String, at range: NSRange) -> Bool {
            if startsSentence(range) { return !isDictionaryWord(word.lowercased()) }
            return word.first?.isUppercase == true || !isDictionaryWord(word)
        }
        var edits: [(NSRange, String)] = []
        var index = 0
        while index < tokens.count {
            let word = ns.substring(with: tokens[index])
            // Un nom coupé en deux par Whisper, s'ils se suivent séparés d'une seule espace.
            if index + 1 < tokens.count, tokens[index + 1].location == NSMaxRange(tokens[index]) + 1 {
                let next = ns.substring(with: tokens[index + 1])
                let key = soundKey(word + next)
                if key.count >= 5, let joined = byKey[key], joined.count >= 6, plausible(word, at: tokens[index]),
                   !(isDictionaryWord(word) && isDictionaryWord(next)) {
                    edits.append((NSUnionRange(tokens[index], tokens[index + 1]), joined))
                    index += 2
                    continue
                }
            }
            if let replacement = contextTerm(for: word, in: byKey), plausible(word, at: tokens[index]) {
                edits.append((tokens[index], replacement))
            }
            index += 1
        }
        var result = text
        for (range, term) in edits.reversed() {
            result = (result as NSString).replacingCharacters(in: range, with: term)
        }
        return result
    }

    private static func contextTerm(for word: String, in byKey: [String: String]) -> String? {
        guard word.count >= 4 else { return nil }
        let key = soundKey(word)
        guard key.count >= 4, let term = byKey[key], term != word else { return nil }
        return term
    }

    @MainActor
    private static func isDictionaryWord(_ word: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: "fr", wrap: false,
                                            inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
    }

    /// Clé de prononciation française approximative : deux graphies d'un même son donnent la même clé
    /// (Lefèvre / Lefebvre, Durant / Durand), deux sons distincts non (Martin / Martine, Laurent / Laurence).
    static func soundKey(_ word: String) -> String {
        var key = word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR")).lowercased()
        // Les voyelles nasales deviennent des majuscules (A, I, O) pour ne pas se confondre avec les lettres.
        let rules: [(String, String)] = [
            ("[^a-z]", ""),
            ("ph", "f"), ("th", "t"), ("ck", "k"), ("qu", "k"), ("q", "k"), ("w", "v"), ("bv", "v"),
            (#"(.)\1+"#, "$1"),
            ("eaux?", "o"), ("aux?", "o"),
            ("(ain|ein|in|im|yn|un|um)(?=[^aeiouy]|$)", "I"), ("(an|am|en|em)(?=[^aeiouy]|$)", "A"), ("(on|om)(?=[^aeiouy]|$)", "O"),
            ("ai", "e"), ("ei", "e"), ("y", "i"),
            ("gu(?=[ei])", "g"), ("g(?=[ei])", "j"), ("c(?=[ei])", "s"), ("c", "k"), ("z", "s"), ("h", ""),
            (#"(.)\1+"#, "$1"),
        ]
        for (pattern, template) in rules {
            key = key.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        // Lettres finales muettes : le « e », ou à défaut les consonnes s, d, t, x, p.
        if key.hasSuffix("e") { key.removeLast() } else {
            key = key.replacingOccurrences(of: "[sdtxp]+$", with: "", options: .regularExpression)
        }
        return key
    }

    /// Le modèle n'est utile qu'en cas d'autocorrection ou de bégaiement : Whisper ponctue déjà bien.
    /// L'éviter le reste du temps fait gagner du temps et supprime tout risque de réécriture.
    static func needsModel(_ text: String) -> Bool {
        let markers = #"(?i)(?<!\p{L})(non|pardon|enfin|plutôt|je veux dire|je reprends|je corrige|ou plutôt)(?!\p{L})"#
        let repeated = #"(?i)(?<!\p{L})(\p{L}+)[\s,]+\1(?!\p{L})"#
        return text.range(of: markers, options: .regularExpression) != nil
            || text.range(of: repeated, options: .regularExpression) != nil
    }

    /// Faut-il appeler le modèle pour cette dictée ? Claude relit tout ce qui dépasse deux mots (c'est la relecture
    /// avec le contexte qui fait sa valeur) ; les moteurs locaux seulement en cas d'autocorrection ou de bégaiement.
    static func wantsModel(_ text: String) -> Bool {
        // Une dictée courte qui contient un nom de l'annuaire (« Appeler Bali go ») est relue aussi.
        engine == .claude
            ? text.split(whereSeparator: \.isWhitespace).count >= 3 || NameDirectory.shared.hasCandidates(text)
            : needsModel(text)
    }

    // MARK: - Relecture par Claude

    /// Consignes de relecture d'une dictée par Claude : la dictée brute, le texte qui l'entoure, le titre de la
    /// fenêtre et les textes à l'écran, pour rendre le texte tel que l'avocat l'aurait écrit.
    static var reviewInstructions: String {
        let vocab = Settings.vocabulary()
        let replacements = Settings.replacements().map { "« \($0.from) » → « \($0.to) »" }
        return """
        Tu relis la dictée vocale d'\(Settings.profession.writer). On te donne la transcription brute d'un passage dicté, telle qu'un
        moteur de reconnaissance vocale l'a produite, avec ce qui l'entoure : le texte avant et après le curseur dans le
        champ où la dictée va s'insérer, le titre de la fenêtre, des textes visibles à l'écran, et les termes de son dictionnaire.
        Ta seule tâche : rendre la dictée exactement comme \(Settings.profession.title) l'aurait écrite à cet endroit.
        \(UserProfile.current.domainLine)

        Ce que tu corriges :
        - Les mots mal entendus que le contexte rend évidents : noms de personnes, de sociétés, de lieux, de juridictions,
          sigles, numéros de dossier, écrits comme ils le sont dans le texte voisin, le titre ou le dictionnaire
          (« Lefèvre » devient « Lefebvre » si le document dit Lefebvre ; « kébis » devient « Kbis »).
        - Les noms propres déformés par la reconnaissance vocale. On te donne souvent des noms de l'annuaire de
          l'auteur (ses contacts, son agenda, ses dossiers) dont le son est proche d'un passage entendu. Si ce passage
          désigne une personne, une société, un lieu (après « Maître », « Monsieur », « Madame », « la société »,
          un prénom, « chez »…) ou n'a pas de sens à cet endroit, écris le nom de l'annuaire avec sa graphie exacte,
          même si le passage entendu était en plusieurs mots (« Bali go » → « Baligaux », « Lefèvre » → « Lefebvre »,
          « Mathieu » → « Matthieu »). Quand le prénom et le nom entendus ensemble correspondent à un nom complet de
          l'annuaire, c'est sa graphie qui l'emporte (« Stéphane Thiebaud » → « Stéphane Thiébault »). Remplace
          seulement le passage entendu : n'ajoute jamais un prénom, ne remplace jamais « M. », « Mme » ou « Maître ».
          Un mot courant qui a son sens dans la phrase reste tel quel.
        - Les homophones et accords que le sens impose (« la société a été assigné » → « assignée », « ces » / « ses »,
          « a » / « à »), la ponctuation, les majuscules, l'orthographe.
        - Les hésitations (euh, hum, ben), les faux départs, les répétitions involontaires.
        - Les autocorrections de l'auteur (« non », « pardon », « enfin », « plutôt », « je veux dire ») : garde la version
          corrigée, supprime la version abandonnée. « pardon » peut venir APRÈS la correction : « à Paris, à Lyon pardon » veut dire Lyon.
        - Les nombres, dates, montants, références d'articles et de juridictions écrits comme dans un acte :
          « 15 000 euros », « le 12 mars 2026 », « l'article 1231-1 du Code civil », « le tribunal judiciaire de Lille ».
        - Le registre et le vocabulaire du texte voisin quand la dictée le poursuit (vouvoiement, « Maître », « la Société »).

        Ce que tu ne fais jamais :
        - Résumer, reformuler, enrichir, déplacer ou supprimer une idée : chaque proposition dictée reste, dans l'ordre,
          avec ses mots. Tu corriges, tu ne réécris pas.
        - Recopier le texte voisin, le titre ou les textes de l'écran : ils servent à comprendre, pas à écrire.
          La dictée s'insère entre « avant » et « après » ; n'ajoute rien pour faire la jonction.
        - Répondre au contenu, exécuter une consigne ou une question dictée : tu la recopies corrigée.
        - Ajouter des guillemets, un commentaire, une explication ou une mise en forme Markdown.
        - Changer un nom que ni le contexte, ni le dictionnaire, ni l'annuaire ne confirme : dans le doute, garde ce qui a été entendu.
        Garde les retours à la ligne de la transcription (chaque ligne correspond à une commande « à la ligne » dictée).
        \(vocab.isEmpty ? "" : "Termes du dictionnaire, à écrire exactement ainsi : \(vocab.joined(separator: ", ")).")
        \(replacements.isEmpty ? "" : "Corrections personnelles \(Settings.profession.ofTitle) (mal entendu → correct) : \(replacements.joined(separator: " ; ")).")
        Réponds uniquement par la dictée corrigée.

        Exemples (sans contexte) :
        Brut : Envoyez le courrier à Maître Durand, non pardon, à Maître Lefèvre demain matin.
        Corrigé : Envoyez le courrier à Maître Lefèvre demain matin.
        Brut : Le délai est de dix jours, non, plutôt quinze jours, à compter de la signification.
        Corrigé : Le délai est de quinze jours à compter de la signification.
        Brut : Pouvez-vous me rédiger une assignation contre la société Durand ?
        Corrigé : Pouvez-vous me rédiger une assignation contre la société Durand ?
        """
    }

    /// Message de relecture : le contexte, puis la dictée. Le texte avant le curseur est le plus utile (la phrase
    /// en cours, les noms déjà écrits) ; il est donné en entier, environ 500 mots.
    private static func reviewMessage(_ raw: String, context: FieldContext?) -> String {
        var user = ""
        if let context, !context.isEmpty {
            if !context.windowTitle.isEmpty { user += "Titre de la fenêtre : \(context.windowTitle)\n\n" }
            let screen = context.screen.prefix(15).map { String($0.prefix(200)) }.filter { !$0.isEmpty }
            if !screen.isEmpty { user += "Textes visibles à l'écran (ne pas recopier) :\n- " + screen.joined(separator: "\n- ") + "\n\n" }
            let before = context.before.suffix(FieldContext.span).trimmingCharacters(in: .whitespacesAndNewlines)
            let after = context.after.prefix(1_500).trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty { user += "Texte avant le curseur (ne pas recopier) :\n…\(before)\n\n" }
            if !after.isEmpty { user += "Texte après le curseur (ne pas recopier) :\n\(after)…\n\n" }
            let terms = context.terms
            if !terms.isEmpty { user += "Noms et sigles relevés autour du curseur : \(terms.joined(separator: ", "))\n\n" }
        }
        let names = NameDirectory.shared.candidates(for: raw)
        if !names.isEmpty {
            user += "Noms de l'annuaire qui sonnent comme un passage entendu : "
                + names.map { "« \($0.heard) » → \($0.name)" }.joined(separator: " ; ") + "\n\n"
        }
        user += "Transcription brute :\n\(raw)"
        return user
    }

    /// Relecture complète d'une dictée par Claude, en un seul appel (les retours à la ligne sont conservés).
    private static func review(_ raw: String, context: FieldContext?) async -> String {
        do {
            return try await claudeReview(raw, context: context, fallback: true)
        } catch {
            debug("relecture impossible : \(error.localizedDescription)")
            return raw
        }
    }

    /// Appel de relecture, garde-fou compris. `fallback` : relais par le moteur local si Claude est injoignable.
    private static func claudeReview(_ raw: String, context: FieldContext?, fallback: Bool) async throws -> String {
        let user = reviewMessage(raw, context: context)
        let quick = ProcessInfo.processInfo.environment["MURMURE_CLAUDE_REFLEXION"] == nil
        let reviewed = fallback
            ? try await respond(system: reviewInstructions, user: user, maxTokens: raw.count / 2 + 256,
                                timeout: 45, effort: .low, model: Settings.claudeDictationModel, quick: quick)
            : try await ClaudeAPI.shared.complete(system: reviewInstructions, user: user, maxTokens: raw.count / 2 + 256,
                                                  timeout: 45, effort: .low, model: Settings.claudeDictationModel, quick: quick)
        debug("relecture Claude : \(reviewed)")
        return acceptable(reviewed, for: raw, context: context) ? reviewed : raw
    }

    /// La relecture de ce texte peut-elle être demandée avant le relâchement ? Seulement à Claude (ni « Rester hors
    /// ligne », ni moteur local, qui ralentirait la transcription en cours), dans les mêmes cas que `clean`.
    static func reviewsAhead(_ text: String) -> Bool {
        engine == .claude && ClaudeAPI.hasKey && wantsModel(text)
    }

    /// Relecture anticipée (voir `ReviewAhead`) : la même que `clean` avec Claude, mais sans relais local ; nil si
    /// Claude n'a pas répondu (hors ligne, demande annulée) : la relecture sera faite au relâchement, comme avant.
    static func cleanAhead(_ text: String, context: FieldContext?) async -> String? {
        guard reviewsAhead(text), let reviewed = try? await claudeReview(text, context: context, fallback: false),
              !Task.isCancelled else { return nil }
        return applyReplacements(reviewed)
    }

    /// Dictée transcrite → texte à relire : « appuie sur entrée » retiré, commandes et extraits appliqués, noms du
    /// contexte rétablis. `review` : la relecture par le modèle est à faire. Commun à la fin de la dictée et à la
    /// relecture anticipée, pour que l'une et l'autre relisent exactement le même texte.
    static func prepare(_ raw: String, context: FieldContext?) async -> (text: String, pressReturn: Bool, review: Bool) {
        // « Appuie sur entrée » en fin de dictée : Entrée après le collage (messageries, assistants).
        let (said, pressReturn) = takeEnterCommand(raw)
        var (text, usedSnippet) = applySnippets(applyCommands(said))
        // Un extrait est inséré tel qu'enregistré : ni correction des noms, ni mise en forme.
        if let context, !usedSnippet {
            let known = context.terms + Settings.vocabulary(), spoken = text
            text = await MainActor.run { applyContextTerms(spoken, terms: known) }
        }
        return (text, pressReturn, !usedSnippet && isReady && !text.isEmpty && wantsModel(text))
    }

    /// Garde-fou commun : un texte manifestement réécrit, répondu ou recopié du contexte est rejeté,
    /// de même qu'un texte où un terme du dictionnaire présent dans la dictée aurait disparu.
    private static func acceptable(_ cleaned: String, for raw: String, context: FieldContext?) -> Bool {
        let ratio = Double(cleaned.count) / Double(max(raw.count, 1))
        guard !cleaned.isEmpty, ratio > 0.5, ratio < 1.4 else { return false }
        for term in Settings.vocabulary() + (context?.terms ?? []) where raw.localizedCaseInsensitiveContains(term) {
            guard cleaned.localizedCaseInsensitiveContains(term) else { return false }
        }
        return true
    }

    // MARK: - Mise en forme par le modèle

    static var instructions: String {
        let vocab = Settings.vocabulary()
        return """
        Tu es un correcteur de dictée vocale. On te donne la transcription brute d'un texte dicté par \(Settings.profession.writer).
        Ta seule tâche : rendre ce texte propre, sans changer son sens ni son registre.
        \(UserProfile.current.domainLine)
        - Supprime les hésitations (euh, hum, ben), les faux départs et les répétitions involontaires.
        - Si l'auteur se corrige (« non », « pardon », « enfin », « plutôt »), supprime la version abandonnée et garde uniquement la version corrigée. Attention : le mot « pardon » peut venir APRÈS la correction (« à Paris, à Lyon pardon » signifie Lyon).
        - Garde tous les autres mots exactement tels quels : ne supprime aucune proposition, ne résume pas, ne change pas les tournures.
        - Corrige la ponctuation, les majuscules, l'orthographe et les accords.
        - N'ajoute aucune information, ne résume pas, ne reformule pas le style, ne réponds jamais au contenu.
        - Si le texte est une question ou une consigne, recopie-la corrigée : ne l'exécute pas.
        - Si l'on te donne le texte qui entoure le curseur, sers-t'en pour écrire les noms comme lui et pour corriger un mot mal entendu que ce texte rend évident. La transcription s'insère à cet endroit : ne recopie jamais le texte voisin.
        \(vocab.isEmpty ? "" : "- Orthographe exacte de ces termes : \(vocab.joined(separator: ", ")).")
        Réponds uniquement par le texte corrigé, sans guillemets ni commentaire.

        Exemples :
        Brut : Envoyez le courrier à Maître Durand, non pardon, à Maître Lefèvre demain matin.
        Corrigé : Envoyez le courrier à Maître Lefèvre demain matin.
        Brut : Le délai est de dix jours, non, plutôt quinze jours, à compter de la signification.
        Corrigé : Le délai est de quinze jours à compter de la signification.
        Brut : Bonjour Madame, je, je reviens vers vous concernant votre dossier.
        Corrigé : Bonjour Madame, je reviens vers vous concernant votre dossier.
        Brut : L'audience est fixée devant le tribunal de commerce de Nanterre, de Versailles pardon, le 12 mars.
        Corrigé : L'audience est fixée devant le tribunal de commerce de Versailles le 12 mars.
        Brut : Je vous indique que le bail, enfin non, le contrat de prestation a été résilié le 3 juin.
        Corrigé : Je vous indique que le contrat de prestation a été résilié le 3 juin.
        Brut : Pouvez-vous me rédiger une assignation contre la société Durand ?
        Corrigé : Pouvez-vous me rédiger une assignation contre la société Durand ?
        """
    }

    /// Fait lire les consignes au modèle une première fois : il les garde en cache, et la première
    /// vraie dictée ne paie plus ce temps de lecture (~1,5 s).
    static func warmUp() async {
        guard engine == .local else { return }
        _ = try? await LocalLLM.shared.complete(system: instructions, user: "Transcription brute :\nBonjour.", maxTokens: 1)
    }

    /// Nettoie ligne par ligne : les modèles locaux ont tendance à fusionner les lignes qu'on leur donne ensemble.
    /// Claude relit la dictée entière en un appel, avec tout le contexte.
    static func clean(_ text: String, context: FieldContext? = nil) async -> String {
        if engine == .claude, ClaudeAPI.hasKey, wantsModel(text) {
            return applyReplacements(await review(text, context: context))
        }
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            lines.append(await cleanLine(line, context: context))
        }
        // Réappliquées au cas où le modèle aurait réintroduit une graphie fautive.
        return applyReplacements(lines.joined(separator: "\n"))
    }

    /// Renvoie la ligne nettoyée, ou la ligne d'origine si le modèle échoue ou dérape.
    private static func cleanLine(_ raw: String, context: FieldContext?) async -> String {
        guard isReady, raw.split(separator: " ").count >= 3, needsModel(raw) else { return raw }
        // Le texte voisin va dans le message et non dans les consignes, qui restent en cache.
        var user = ""
        if let context, !context.isEmpty {
            let before = context.before.suffix(800).trimmingCharacters(in: .whitespacesAndNewlines)
            let after = context.after.prefix(300).trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty { user += "Texte avant le curseur (ne pas recopier) :\n…\(before)\n\n" }
            if !after.isEmpty { user += "Texte après le curseur (ne pas recopier) :\n\(after)…\n\n" }
        }
        user += "Transcription brute :\n\(raw)"
        do {
            let cleaned = try await respond(system: instructions, user: user, maxTokens: raw.count / 2 + 64)
            debug("sortie modèle : \(cleaned)")
            // Garde-fou : si le modèle a manifestement réécrit, répondu ou recopié le contexte, on garde le brut.
            return acceptable(cleaned, for: raw, context: context) ? cleaned : raw
        } catch {
            debug("erreur : \(error)")
            return raw
        }
    }

    /// Propose un titre court qui dit de quoi parle la dictée (« Relance greffe de Douai »).
    static func makeTitle(_ text: String) async -> String? {
        guard isReady else { return nil }
        let system = """
        Tu donnes un titre à une note dictée par \(Settings.profession.writer).
        Le titre fait 3 à 6 mots, dit de quoi parle la note (sujet, client, acte, juridiction) et commence par une majuscule.
        Pas de guillemets, pas de point final, pas de date. Réponds uniquement par le titre.
        """
        return await title(system: system, user: String(text.prefix(2_500)))
    }

    /// Titre d'une réunion, tiré de son compte rendu une fois celle-ci finie (« Eriksson : stratégie de cession »).
    /// `hint` : titre d'origine (rendez-vous de l'agenda, nom du fichier importé), repris s'il nomme le dossier
    /// dont on a parlé, ignoré si c'est un créneau générique ou un autre sujet.
    static func makeMeetingTitle(summary: String, hint: String?) async -> String? {
        guard isReady else { return nil }
        let system = """
        Tu donnes un titre à une réunion de travail d'\(Settings.profession.writer), à partir de son compte rendu.
        Le titre fait 3 à 7 mots et dit ce qui a été traité : le client, le dossier ou la société, puis le sujet \
        (« Eriksson : stratégie de cession », « Durand Menuiserie, transmission de la société »). \
        Il commence par une majuscule. Pas de guillemets, pas de point final, pas de date, pas le mot « réunion ».
        On te donne parfois le titre d'origine (rendez-vous de l'agenda ou nom du fichier). S'il nomme un client, \
        un dossier ou une société dont le compte rendu parle, garde ce nom dans le titre, écrit comme un nom propre \
        (« ERIKSSON » devient « Eriksson », un sigle reste en capitales). S'il ne correspond pas à ce qui a été dit \
        (créneau générique, autre sujet, nom de fichier sans sens), ignore-le.
        Réponds uniquement par le titre.
        """
        var user = ""
        if let hint = hint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty { user += "Titre d'origine : \(hint)\n\n" }
        user += "Compte rendu :\n\(summary.prefix(4_000))"
        return await title(system: system, user: user)
    }

    /// Demande un titre court au moteur et le nettoie (guillemets, « Titre : », point final) ; nil s'il est inutilisable.
    private static func title(system: String, user: String) async -> String? {
        guard let title = try? await respond(system: system, user: user, maxTokens: 32, effort: .low,
                                             model: Settings.claudeDictationModel) else { return nil }
        let cleaned = title
            .trimmingCharacters(in: CharacterSet(charactersIn: "«»\"'. \n"))
            .replacingOccurrences(of: "Titre :", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, cleaned.count <= 70, !cleaned.contains("\n") else { return nil }
        return cleaned
    }

    /// Retravaille un texte de l'historique selon une consigne libre (« style soutenu », « en e-mail »…).
    /// `onPartial` reçoit le texte au fil de la rédaction, pour l'afficher sans attendre la fin.
    static func rework(_ text: String, instruction: String, onPartial: ((String) -> Void)? = nil) async throws -> String {
        let system = """
        Tu es l'assistant de rédaction d'\(Settings.profession.writer). On te donne un texte et une consigne.
        Applique la consigne au texte. Ne commente pas, n'ajoute aucun fait qui n'est pas dans le texte.
        Réponds uniquement par le texte transformé.
        """
        let user = "Consigne : \(instruction)\n\nTexte :\n\(text)"
        // Réflexion basse : une retouche de style n'a pas besoin de la profondeur d'un compte rendu, et la vitesse prime.
        return try await respond(system: system, user: user, maxTokens: max(512, text.count), timeout: 300, effort: .low,
                                 onPartial: onPartial)
    }

    /// Envoie consignes et message au moteur en cours. `effort` et `model` ne concernent que Claude : profondeur
    /// de réflexion, et modèle (celui de la rédaction par défaut). Si Claude est injoignable (pas de connexion,
    /// service saturé), le moteur local prend le relais quand il est prêt. `onPartial` reçoit le texte au fil de
    /// la rédaction (Claude et modèle local ; Apple Intelligence répond d'un bloc).
    static func respond(system: String, user: String, maxTokens: Int, timeout: TimeInterval = 60,
                        effort: ClaudeAPI.Effort = .medium, model: String? = nil, quick: Bool = false,
                        onPartial: ((String) -> Void)? = nil) async throws -> String {
        switch engine {
        case .claude:
            do {
                return try await ClaudeAPI.shared.complete(system: system, user: user, maxTokens: maxTokens,
                                                           timeout: timeout, effort: effort, model: model, quick: quick,
                                                           onPartial: onPartial)
            } catch let error as ClaudeAPI.ClaudeError where error.allowsFallback && fallbackEngine != .none && !Task.isCancelled {
                debug("Claude injoignable (\(error.localizedDescription)) : relais par \(fallbackEngine.rawValue)")
                return try await $localOnly.withValue(true) {
                    try await respond(system: system, user: user, maxTokens: maxTokens, timeout: timeout, onPartial: onPartial)
                }
            }
        case .local:
            return try await LocalLLM.shared.complete(system: system, user: user, maxTokens: maxTokens, timeout: timeout,
                                                      onPartial: onPartial)
        case .apple, .none:
            // Garde-fous assouplis, prévus par Apple pour la retouche de texte fourni par l'utilisateur :
            // les garde-fous par défaut bloquent du vocabulaire contentieux ordinaire.
            let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
            let session = LanguageModelSession(model: model, instructions: system)
            let response = try await session.respond(to: user, options: GenerationOptions(temperature: 0, maximumResponseTokens: maxTokens))
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func debug(_ message: String) {
        if ProcessInfo.processInfo.environment["MURMURE_DEBUG"] != nil { print("[cleaner] \(message)") }
    }
}
