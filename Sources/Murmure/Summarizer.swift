import AppKit
import UniformTypeIdentifiers

/// Modèles de compte rendu proposés pour une réunion.
enum SummaryTemplate: String, CaseIterable, Identifiable {
    case meeting = "Synthèse de réunion"
    case client = "Compte rendu de rendez-vous client"
    case note = "Note interne"

    var id: String { rawValue }

    var sections: String {
        switch self {
        case .meeting:
            return "## Objet\n## Participants\n## Points abordés (trois à six sujets, précisions en sous-points)\n## Décisions\n## Prochaines étapes (qui, quoi, quand)\n## Points de vigilance"
        case .client:
            return "## Contexte\n## Demande du client\n## Faits et pièces évoqués (trois à six sujets, précisions en sous-points)\n## Analyse et conseils donnés\n## Suites convenues et honoraires\n## Pièces à obtenir"
        case .note:
            return "## En bref (trois lignes au plus)\n## Éléments clés (trois à six, précisions en sous-points)\n## Questions juridiques à traiter\n## Actions"
        }
    }
}

/// Rédige les comptes rendus avec le modèle de langage. Avec les moteurs locaux, les longues réunions sont
/// d'abord résumées par tranches, puis le compte rendu est rédigé à partir de ces notes ; Claude lit la
/// réunion entière d'un seul tenant (fenêtre d'un million de jetons : plusieurs heures de réunion).
enum Summarizer {
    /// Tranche de transcription résumée en une fois : 12 000 caractères (~3 500 jetons) pour le modèle local.
    /// Apple Intelligence n'a qu'une fenêtre de ~4 096 jetons, consignes et notes comprises : un quart.
    /// Claude : pas de tranche en pratique (3 millions de caractères, soit plus de 40 h de parole).
    private static var chunkSize: Int {
        switch Cleaner.engine {
        case .claude: return 3_000_000
        case .apple: return 3_000
        default: return 12_000
        }
    }

    /// Longueur de réponse accordée : Claude peut rédiger un compte rendu long et détaillé.
    private static var answerBudget: Int { Cleaner.engine == .claude ? 6_000 : 1_400 }

    /// `notes` : points notés par l'utilisateur pendant la réunion, repris en priorité dans le compte rendu.
    /// `progress` reçoit l'avancement des notes par tranche (« Synthèse 3 / 10 ») pour une longue réunion.
    /// `onPartial` reçoit le compte rendu au fil de la rédaction (pas pendant les notes par tranches).
    static func generate(transcript: String, participants: [String], template: SummaryTemplate, notes: String? = nil,
                         progress: Transcriber.Progress? = nil, onPartial: ((String) -> Void)? = nil) async throws -> String {
        var material = transcript
        var passes = 0
        // Les notes de toutes les tranches doivent tenir avec les consignes et le compte rendu dans la fenêtre
        // du moteur. Si elles la dépassent encore (Apple Intelligence sur une longue réunion), elles sont
        // résumées à leur tour, deux fois au plus.
        while material.count > chunkSize, passes < 3 {
            material = "Notes prises au fil de la réunion :\n" + (try await takeNotes(of: material, progress: progress))
            passes += 1
            guard material.count > maxMaterial else { break }
        }
        if passes > 0 { progress?("Synthèse…") }

        let system = """
        Tu es l'assistant d'\(Settings.profession.writer). À partir de la réunion fournie, rédige une « \(template.rawValue) »
        en français, précise et factuelle. N'invente rien : si une information manque, omets-la.
        \(UserProfile.current.domainLine)
        Respecte exactement ces sections, dans cet ordre :
        \(template.sections)
        Format : Markdown simple, titres de section précédés de « ## », listes avec « - ». Pas de gras, pas de tableau,
        pas de phrase d'introduction ni de conclusion. \(lineFormat)\(notes == nil ? "" : "\n" + notesRule)\(Cleaner.engine == .claude ? "\n" + thoroughRule : "")
        """
        let who = participants.isEmpty ? "" : "Participants identifiés : \(participants.joined(separator: ", ")).\n\n"
        let noted = notes.map { "Points notés par l'utilisateur pendant la réunion :\n\($0)\n\n" } ?? ""
        let draft = clean(try await Cleaner.respond(system: system, user: who + noted + material, maxTokens: answerBudget,
                                                    timeout: longTimeout, effort: .high, onPartial: onPartial))
        let grouped = try await condense(draft)
        return withoutInventedDates(grouped, source: transcript + "\n" + (notes ?? ""))
    }

    /// Nombre de sujets au-delà duquel une section de points est regroupée.
    private static let maxTopics = 6

    /// Un petit modèle recopie volontiers ses notes puce par puce, malgré la consigne (28 points pour une réunion
    /// de 17 min). Une section de points qui dépasse `maxTopics` sujets est regroupée par un second passage, court,
    /// qui ne porte que sur elle ; les décisions et les suites lui sont montrées pour qu'il ne les répète pas.
    private static func condense(_ summary: String) async throws -> String {
        var blocks = sectionBlocks(of: summary)
        var changed = false
        let others = blocks.filter { SummarySection.kind(for: $0.title) == .decisions || SummarySection.kind(for: $0.title) == .actions }
            .map { $0.lines.joined(separator: "\n") }.joined(separator: "\n")
        for index in blocks.indices where SummarySection.kind(for: blocks[index].title) == .points {
            let topics = blocks[index].lines.filter { $0.hasPrefix("- ") }.count
            guard topics > maxTopics else { continue }
            let system = """
            Tu regroupes une liste de points d'un compte rendu de réunion rédigé pour \(Settings.profession.writer).
            Rends de trois à six sujets principaux, chacun en quelques mots sur une ligne « - », avec sous lui ses
            précisions utiles en sous-points (deux espaces puis « - »), quatre au plus par sujet. Tout ce qui se rapporte
            à un même sujet va sous lui. Supprime ce qui figure déjà dans les décisions ou les suites, les redites et
            les détails sans conséquence. N'ajoute rien qui ne soit dans la liste, aucune date, aucun nom.
            Pas de gras, pas de titre, pas de phrase d'introduction : réponds uniquement par la liste.
            """
            let user = "Liste à regrouper :\n" + blocks[index].lines.joined(separator: "\n")
                + (others.isEmpty ? "" : "\n\nDécisions et suites, à ne pas répéter :\n" + others)
            let list = clean(try await Cleaner.respond(system: system, user: user, maxTokens: 900, timeout: longTimeout, effort: .high))
            let lines = list.components(separatedBy: "\n")
                .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }
                .map { $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
            // Un regroupement raté (vide, ou pas plus court) laisse la section telle quelle.
            if (1...maxTopics + 1).contains(lines.filter { $0.hasPrefix("- ") }.count) {
                blocks[index].lines = lines
                changed = true
            }
        }
        guard changed else { return summary }
        return blocks.map { block in ([block.heading].compactMap { $0 } + block.lines).joined(separator: "\n") }
            .joined(separator: "\n\n")
    }

    /// Sections « ## » du Markdown : le titre tel qu'écrit et les lignes non vides qui suivent.
    private static func sectionBlocks(of markdown: String) -> [(heading: String?, title: String, lines: [String])] {
        var blocks: [(heading: String?, title: String, lines: [String])] = []
        for line in markdown.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                let heading = line.trimmingCharacters(in: .whitespaces)
                let title = heading.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                    .replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression)
                blocks.append((heading, title, []))
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                if blocks.isEmpty { blocks.append((nil, "", [])) }
                blocks[blocks.count - 1].lines.append(line.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression))
            }
        }
        return blocks
    }

    /// Retire l'échéance entre parenthèses en fin d'action quand sa date n'a pas été dite : un mois absent de la
    /// transcription, ou un nombre qui n'y figure pas. Le modèle local en inventait (« avant le 12 mars »).
    static func withoutInventedDates(_ summary: String, source: String) -> String {
        let fold: (String) -> String = { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR")) }
        let heard = fold(source)
        let months = ["janvier", "fevrier", "mars", "avril", "mai", "juin", "juillet", "aout", "septembre", "octobre", "novembre", "decembre"]
        func said(_ word: String) -> Bool { heard.range(of: #"\b"# + word + #"\b"#, options: .regularExpression) != nil }
        var kind = SummarySection.Kind.points
        return summary.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                kind = SummarySection.kind(for: trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                    .replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression))
            }
            // Seules les échéances des actions sont vérifiées : ailleurs, une parenthèse (« 2020 à 2023 ») est une information.
            guard kind == .actions, trimmed.hasPrefix("- "),
                  let range = line.range(of: #"\s*\(([^()]*)\)\s*$"#, options: .regularExpression) else { return line }
            let inside = fold(String(line[range]))
            let words = inside.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            let month = words.first { months.contains($0) }
            let numbers = words.filter { $0.allSatisfy(\.isNumber) }
            let invented = month.map { !said($0) } ?? (!numbers.isEmpty && !numbers.allSatisfy(said))
            return invented ? String(line[..<range.lowerBound]) : line
        }.joined(separator: "\n")
    }

    /// Avec la transcription entière sous les yeux, Claude ne laisse passer aucun fait déterminant, mais les range
    /// sous les sujets principaux : une liste de cinquante puces ne se lit pas.
    private static let thoroughRule = """
    Tu as la transcription entière : n'omets aucun fait déterminant (date, montant, nom, demande, avis donné, décision,
    engagement), mais range-le en sous-point sous le sujet qu'il concerne plutôt que d'allonger la liste des sujets.
    Quand un point a été discuté puis tranché, ne garde que ce qui a été retenu, en indiquant ce qui a été écarté
    si cela éclaire la décision.
    """

    /// Notes par tranche, concaténées. Chaque tranche reçoit un budget de jetons tel que l'ensemble tienne
    /// dans `notesBudget` : au-delà de 7 tranches (≈ 1 h 15 avec le modèle local), chacune reçoit un budget
    /// plus court. Sans cela, une réunion de 2 h n'avait ni synthèse ni titre.
    private static func takeNotes(of text: String, progress: Transcriber.Progress?) async throws -> String {
        let parts = chunks(of: text)
        let budget = max(Cleaner.engine == .apple ? 150 : 250, min(700, notesBudget / parts.count))
        var notes: [String] = []
        for (index, chunk) in parts.enumerated() {
            progress?("Synthèse \(index + 1) / \(parts.count)")
            let system = """
            Tu prends des notes pour \(Settings.profession.writer) à partir d'un extrait de transcription de réunion.
            Relève les informations utiles : faits, dates, montants, noms, demandes, avis donnés, décisions,
            engagements (qui fait quoi). Regroupe-les par sujet : une ligne « - » par sujet, en quelques mots,
            puis ses précisions en sous-puces (deux espaces puis « - »). Laisse de côté hésitations, apartés et
            redites. N'invente rien. Pas de phrase d'introduction.
            """
            let part = try await Cleaner.respond(system: system, user: "Extrait \(index + 1) :\n\(chunk)", maxTokens: budget, timeout: longTimeout)
            notes.append(part)
        }
        return notes.joined(separator: "\n")
    }

    /// Jetons de notes au total (toutes tranches), pour rester sous les 8 192 de l'emplacement du modèle local
    /// avec les consignes (~250) et la réponse (1 400) ; sous les ~4 096 d'Apple Intelligence.
    /// Mesuré : ~3,9 caractères par jeton en français avec Qwen3.
    private static var notesBudget: Int { Cleaner.engine == .apple ? 1_600 : 5_200 }
    /// Taille de notes au-delà de laquelle elles sont résumées une nouvelle fois (en caractères).
    private static var maxMaterial: Int { notesBudget * 4 }
    /// Une synthèse n'est pas diffusée en flux : le serveur ne répond qu'à la fin, parfois après plusieurs
    /// minutes pour une longue réunion (et bien plus en économie d'énergie). Le délai de 60 s de la dictée ne convient pas.
    static let longTimeout: TimeInterval = 900

    /// Applique une consigne libre au compte rendu (« ajoute les montants », « plus concis »…).
    static func revise(_ summary: String, instruction: String, transcript: String,
                       onPartial: ((String) -> Void)? = nil) async throws -> String {
        let system = """
        Tu modifies le compte rendu d'une réunion rédigé pour \(Settings.profession.writer), selon sa consigne.
        Garde le même format (Markdown simple, « ## » pour les sections, « - » pour les listes), sans gras.
        \(lineFormat)
        Si la consigne demande une information, cherche-la dans la transcription ; n'invente rien.
        Réponds uniquement par le compte rendu complet modifié.
        """
        let user = "Consigne : \(instruction)\n\nCompte rendu actuel :\n\(summary)\n\nTranscription\(transcript.count > chunkSize ? " (extrait)" : "") :\n\(transcript.prefix(chunkSize))"
        return clean(try await Cleaner.respond(system: system, user: user, maxTokens: max(1_600, answerBudget), timeout: longTimeout,
                                               effort: .high, onPartial: onPartial))
    }

    // MARK: - Proposition d'accompagnement

    /// Trame du mail de proposition d'accompagnement, selon la pratique du cabinet.
    enum ProposalOutline: String, CaseIterable, Identifiable {
        case standard = "Standard", light = "Allégée", study = "Étude approfondie"
        var id: String { rawValue }

        var detail: String {
            switch self {
            case .standard: return "Compréhension · Mission · Honoraires · Liste des éléments à réunir"
            case .light: return "Compréhension · Mission · Honoraires ; les pièces à réunir en une phrase"
            case .study: return "Trame standard, avec les problématiques identifiées et les prochaines étapes"
            }
        }

        /// Sections attendues, pour les consignes.
        fileprivate var sections: String {
            let understanding = "« 1. Notre compréhension » : synthèse de la situation en prose, qui peut se clore par « Si notre compréhension est bonne, … »."
            let mission = "« Notre mission » : diligences concrètes en puces, puis un paragraphe qui décrit le livrable."
            let fees = "« Nos honoraires » : le forfait HT en prose, jamais de tableau, avec le choix du forfait expliqué simplement."
            let documents = "« Liste des éléments » : pièces à réunir en puces, en partant du principe que rien n'a été remis, par blocs : situation personnelle et familiale ; activité et exploitation ; patrimoine, foncier et immobilier ; autres documents utiles."
            switch self {
            case .standard:
                return [understanding, "2. " + mission, "3. " + fees, "4. " + documents].joined(separator: "\n")
            case .light:
                return [understanding, "2. " + mission + " Les pièces à réunir tiennent en une phrase à la fin de la mission.", "3. " + fees].joined(separator: "\n")
            case .study:
                return [understanding,
                        "2. « Problématiques identifiées » : les questions que la situation soulève, en puces, sans les trancher.",
                        "3. " + mission, "4. " + fees, "5. " + documents,
                        "6. « Prochaines étapes » : ce qui se passe après l'accord, en quelques phrases."].joined(separator: "\n")
            }
        }
    }

    struct ProposalOptions {
        var outline: ProposalOutline = .standard
        /// Forfait HT arrêté au rendez-vous (« 3 500 € ») ; vide : « [montant] € HT », à compléter.
        var fee = ""
        /// Destinataire avocat, notaire ou commissaire de justice : registre confraternel.
        var peer = false
    }

    /// Le mail de fin de premier rendez-vous : compréhension de la situation, mission, honoraires, pièces à réunir,
    /// selon la trame et le ton du cabinet. Première ligne « Objet : … », puis le mail, sans signature (la messagerie
    /// l'ajoute). Une longue réunion est d'abord résumée par tranches, comme pour le compte rendu.
    static func proposal(transcript: String, participants: [String], date: Date, notes: String?, summary: String?,
                         options: ProposalOptions, onPartial: ((String) -> Void)? = nil) async throws -> String {
        var material = transcript
        if material.count > chunkSize {
            material = "Notes prises au fil du rendez-vous :\n" + (try await takeNotes(of: material, progress: nil))
        }
        let system = """
        Tu rédiges, pour un avocat français, la proposition d'accompagnement qu'il adresse à un prospect au lendemain
        d'un premier rendez-vous : l'e-mail qui formalise sa compréhension de la situation, le périmètre de la mission
        et le forfait d'honoraires. Document commercial, précis sur le périmètre mais plus léger qu'un mémo juridique :
        on cadre la mission, on ne la traite pas. Écrit à la première personne (« je ») : l'avocat signe seul.
        Les titres de sections restent ceux du cabinet (« Notre compréhension », « Notre mission », « Nos honoraires »).

        Première ligne : « Objet : Monsieur NOM - Proposition d'accompagnement » (ou Madame ; NOM du prospect en
        majuscules ; nom inconnu : « Objet : Proposition d'accompagnement - [objet court] »). Une ligne vide, puis le mail.
        Formule d'appel : « Cher Monsieur, » ou « Chère Madame, » (registre client) ; « Mon cher Maître, » pour un
        confrère, avocat, notaire ou commissaire de justice (registre confraternel). Vouvoiement.
        Introduction : rappel de l'échange (« À la suite de notre entretien du [date], … »), remerciement pour la
        confiance, annonce de la synthèse et de la proposition, définition de l'engagement : la Mission.
        Sections, chacune introduite par son titre numéroté seul sur sa ligne :
        \(options.outline.sections)
        Clôture : « Je vous laisse prendre connaissance de la présente proposition et reste à votre disposition pour en
        échanger. », invitation à confirmer l'accord par retour de mail, puis « Bien à vous, » (client) ou
        « Sentiments dévoués, » (confraternel). Jamais « Bien cordialement ». Aucune signature : la messagerie l'ajoute.

        Ton humain, jamais commercial. Texte brut : pas de Markdown, pas de gras, pas d'émoji ; chaque puce commence
        par « ● » suivi d'une espace, une idée par puce. Espace insécable avant : ; ? ! et », et après «.
        Aucun tiret cadratin ni demi-cadratin : une virgule, des parenthèses, un deux-points ou deux phrases.
        Pas de formules passe-partout (« Il est important de noter que », « N'hésitez pas à », « Dans le cadre de »,
        « En effet » en ouverture, « force est de constater », « En résumé »), pas de triades ni de parallélismes mécaniques.
        N'invente rien : ce qui manque (nom, date, adresse, montant) est écrit « [à compléter] » ; jamais de chiffre
        inventé. Le montant d'honoraires est celui qui t'est donné ; sans montant, écris « [montant] € HT ».
        Réponds uniquement par l'objet et le mail.
        """
        var user = "Date du rendez-vous : \(date.formatted(date: .long, time: .omitted)).\n"
        if !participants.isEmpty { user += "Participants : \(participants.joined(separator: ", ")).\n" }
        user += options.fee.isEmpty ? "Honoraires : aucun montant arrêté.\n" : "Honoraires : forfait de \(options.fee) HT, arrêté au rendez-vous.\n"
        user += options.peer ? "Destinataire : un confrère (registre confraternel).\n" : "Destinataire : le client (registre client).\n"
        if let notes { user += "\nPoints notés par l'avocat pendant le rendez-vous :\n\(notes)\n" }
        if let summary { user += "\nCompte rendu du rendez-vous :\n\(Sharing.plain(summary).prefix(Cleaner.engine == .claude ? 20_000 : 4_000))\n" }
        user += "\nTranscription du rendez-vous :\n\(material)"
        return clean(try await Cleaner.respond(system: system, user: user, maxTokens: Cleaner.engine == .claude ? 4_000 : 1_600,
                                               timeout: longTimeout, effort: .high, onPartial: onPartial))
    }

    /// Sépare l'objet du mail (première ligne « Objet : … ») de son corps.
    static func splitSubject(_ mail: String) -> (subject: String?, body: String) {
        let trimmed = mail.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.prefix { $0 != "\n" }
        guard let range = firstLine.range(of: #"^\s*objet\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) else {
            return (nil, trimmed)
        }
        let subject = String(firstLine[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        let body = String(trimmed[firstLine.endIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (subject.isEmpty ? nil : subject, body)
    }

    /// Réponse à une question sur la réunion, fondée sur la transcription seule, avec le passage qui l'appuie.
    struct Answer {
        var text: String
        /// Extrait de la transcription sur lequel la réponse repose (tel que le modèle l'a cité, ou le tour de
        /// parole complet quand il a été retrouvé), nil si la transcription ne répond pas.
        var excerpt: String?
    }

    /// Transcription lue d'un seul tenant pour une question : la réponse est courte, la fenêtre du modèle local
    /// (8 192 jetons par emplacement) accueille donc plus de texte que pour un compte rendu. Au-delà, la réunion
    /// est d'abord parcourue par tranches.
    static var questionWindow: Int {
        switch Cleaner.engine {
        case .claude: return 3_000_000
        case .apple: return 3_000
        default: return 20_000
        }
    }

    /// Interroge le modèle sur la transcription. Une longue réunion est d'abord parcourue par tranches, dont seuls
    /// les passages utiles à la question sont retenus. `onPartial` reçoit la réponse au fil de la rédaction.
    /// Le modèle recopie d'abord le passage qui fonde sa réponse, puis conclut : un petit modèle qui commence par
    /// « Oui » ou « Non » s'y tient, même quand le passage qu'il cite ensuite dit le contraire.
    /// `summary` : le compte rendu affiché, s'il y en a un ; il donne au modèle une vue d'ensemble déjà rangée
    /// (ce qui a été envoyé, ce qui manque), là où la transcription orale disperse l'information.
    static func answer(_ question: String, transcript: String, summary: String? = nil,
                       onPartial: ((Answer) -> Void)? = nil) async throws -> Answer {
        let overview = summary.map { "Compte rendu :\n\($0)\n\n" } ?? ""
        let material: String
        if overview.count + transcript.count <= questionWindow {
            material = transcript
        } else {
            var found: [String] = []
            let parts = chunks(of: transcript)
            let budget = max(250, min(700, notesBudget / parts.count))
            for (index, chunk) in parts.enumerated() {
                let system = """
                Tu lis un extrait de transcription de réunion pour \(Settings.profession.writer), qui pose une question.
                Recopie mot pour mot, en puces « - », les passages de l'extrait qui aident à répondre
                (avec le nom de qui parle). Si rien ne s'y rapporte, réponds seulement « Rien ». N'invente rien.
                """
                let user = "Extrait \(index + 1) :\n\(chunk)\n\nQuestion : \(question)"
                let part = try await Cleaner.respond(system: system, user: user, maxTokens: budget, timeout: longTimeout)
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".- "))
                if !trimmed.isEmpty, trimmed.lowercased() != "rien" { found.append(part) }
            }
            material = found.isEmpty ? "(aucun passage de la réunion ne se rapporte à la question)" : "Passages de la réunion en rapport avec la question :\n" + found.joined(separator: "\n")
        }

        let system = """
        Tu es l'assistant d'\(Settings.profession.writer). Il pose une question sur une réunion dont tu as \(summary == nil
            ? "la transcription" : "le compte rendu et la transcription").
        Réponds en français, à partir de \(summary == nil ? "la transcription" : "ces deux documents") seulement.
        \(summary == nil ? "" : "Le compte rendu donne une vue d'ensemble ; la transcription fait foi. ")N'invente rien.
        Commence par recopier mot pour mot, depuis la transcription, la phrase qui permet de répondre (seulement cette phrase, trente mots au
        plus, pas toute l'intervention), puis lis-la attentivement et conclus.
        Si la réponse rassemble des éléments dits à plusieurs moments (une liste de pièces, par exemple), recopie les
        deux ou trois phrases les plus complètes, chacune sur sa ligne, et réponds en les réunissant toutes.
        Ta réponse doit dire la même chose que ces passages. Pour une question fermée, commence ta réponse par « Oui. »,
        « Non. » ou « En partie. », puis explique en une à trois phrases ce que dit la réunion, avec les précisions
        utiles (numéros, dates, noms). Si la transcription ne permet pas de répondre, écris « aucun » comme extrait
        et réponds « La réunion ne le dit pas. », suivi de ce qui s'en approche le plus s'il y en a.
        Format exact, sans gras ni titre :
        EXTRAIT : le ou les passages recopiés mot pour mot (ou « aucun »)
        RÉPONSE : ta réponse
        """
        // La réunion avant la question : d'une question à l'autre sur la même réunion, le modèle local garde en
        // cache la lecture du compte rendu et de la transcription, et ne relit que la nouvelle question.
        let user = "\(overview)Transcription :\n\(material)\n\nQuestion : \(question)"
        let partial: ((String) -> Void)? = onPartial.map { report in
            { text in
                let current = parse(clean(text), transcript: transcript, locating: false)
                if current.text != nil { report(current.answer) }
            }
        }
        // 450 jetons suffisent à quelques citations courtes et à la réponse ; un petit modèle qui se met à répéter
        // une liste s'arrête ainsi vite.
        let reply = clean(try await Cleaner.respond(system: system, user: user, maxTokens: Cleaner.engine == .claude ? 2_000 : 450,
                                                    timeout: longTimeout, effort: .high, onPartial: partial))
        return parse(reply, transcript: transcript)
    }

    /// Sépare extrait et réponse ; l'extrait est remplacé par le tour de parole complet de la transcription
    /// quand il y est retrouvé (le modèle cite parfois en raccourcissant).
    static func parse(_ reply: String, transcript: String) -> Answer {
        parse(reply, transcript: transcript, locating: true).answer
    }

    /// `text` vaut nil tant que la réponse n'a pas commencé (le modèle écrit encore l'extrait).
    private static func parse(_ reply: String, transcript: String, locating: Bool) -> (answer: Answer, text: String?) {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let answerMark = reply.range(of: #"R[ÉE]PONSE\s*:"#, options: options.union(.regularExpression))
        let excerptMark = reply.range(of: #"EXTRAIT\s*:"#, options: options.union(.regularExpression))
        var text: String?, excerpt: String?
        switch (excerptMark, answerMark) {
        case let (e?, a?) where e.lowerBound < a.lowerBound:
            excerpt = String(reply[e.upperBound..<a.lowerBound])
            text = String(reply[a.upperBound...])
        case let (e?, a?):
            text = String(reply[a.upperBound..<e.lowerBound])
            excerpt = String(reply[e.upperBound...])
        case let (e?, nil):
            excerpt = String(reply[e.upperBound...])
        case let (nil, a?):
            text = String(reply[a.upperBound...])
        case (nil, nil):
            // Réponse sans le format demandé : on la montre telle quelle, une fois terminée.
            text = locating ? reply : nil
        }
        var shown = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Réponse coupée avant sa conclusion (le modèle s'est attardé sur l'extrait) : on le dit plutôt qu'une carte vide.
        if locating, shown?.isEmpty ?? true { shown = "Murmure n'a pas su conclure. Voici le passage le plus proche de votre question." }
        let quote = excerpt?.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "«»\"“” ")) ?? ""
        let found = quote.isEmpty || ["aucun", "aucune"].contains(quote.lowercased()) ? nil
            : (locating ? locate(quote, in: transcript) ?? quote : quote)
        return (Answer(text: shown ?? "", excerpt: found), shown)
    }

    /// Paragraphes de la transcription qui contiennent la citation (ou son début, le modèle coupant parfois la fin),
    /// un par passage cité sur sa ligne, sans doublon.
    private static func locate(_ quote: String, in transcript: String) -> String? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let paragraphs = transcript.components(separatedBy: "\n")
        var found: [String] = []
        for line in quote.components(separatedBy: "\n") {
            // Puce ou nom de l'interlocuteur recopiés devant la citation : on cherche la parole elle-même.
            var cited = line.trimmingCharacters(in: CharacterSet(charactersIn: "-•«»\"“” ").union(.whitespaces))
            if let colon = cited.range(of: " : "), cited.distance(from: cited.startIndex, to: colon.lowerBound) < 40 {
                cited = String(cited[colon.upperBound...])
            }
            guard cited.count >= 12 else { continue }
            let needle = cited.count > 60 ? String(cited.prefix(60)) : cited
            if let paragraph = paragraphs.first(where: { $0.range(of: needle, options: options) != nil }) {
                let trimmed = paragraph.trimmingCharacters(in: .whitespaces)
                if !found.contains(trimmed) { found.append(trimmed) }
            }
        }
        return found.isEmpty ? nil : found.joined(separator: "\n\n")
    }

    /// Les notes de l'utilisateur (ce qu'il a jugé important sur le moment) passent avant ce que dit la transcription.
    private static let notesRule = """
    L'utilisateur a noté des points pendant la réunion : ce sont les plus importants pour lui. Reprends chacun d'eux
    dans la section qui convient, complété par ce que dit la transcription, avant les autres informations.
    """

    /// Forme des lignes que l'affichage met en page (étiquettes de personnes, responsable et échéance des actions).
    private static var lineFormat: String { """
    La première section tient en une ou deux phrases, sans puce. Une puce = une idée, en une phrase courte.
    Sélectionne : un compte rendu retient l'essentiel, pas tout ce qui a été dit. Points abordés, éléments clés ou
    faits évoqués : les sujets principaux de la réunion seulement, de trois à six puces, même pour une longue réunion.
    Les précisions utiles (dates, montants, pièces, comptes) vont en sous-points sous le sujet qu'elles concernent :
    une ligne « - » précédée de deux espaces, quatre sous-points au plus par sujet. Forme :
    - Sujet principal, en quelques mots
      - précision
      - autre précision
    Regroupe sous un même sujet tout ce qui s'y rattache (par exemple chaque compte ou chaque pièce, sous un seul
    sujet). Décisions, actions et points de
    vigilance : cinq puces au plus chacune, sans sous-points. Une information ne figure que dans une section : une
    décision ou une action n'est pas répétée dans les points abordés. Écarte les détails sans conséquence.
    Participants : seulement les personnes présentes à la réunion, « - Nom : rôle » (pas les sociétés ni les tiers cités).
    Actions et suites : la personne qui s'en charge, deux-points, l'action : « - Nom : transmettre les pièces », suivi
    de l'échéance entre parenthèses seulement si une date a été prononcée dans la réunion (n'en déduis aucune), où Nom
    est un nom entendu dans la réunion ou donné dans la liste des participants, écrit tel quel, sans crochets. Si la personne n'est
    pas nommée, écris son rôle (« \(Settings.profession.title.capitalizedFirst) », « \(Settings.profession.counterpart) ») ou « Interlocuteur 2 ». N'invente aucun nom.
    N'écris jamais le mot « Responsable » à la place du nom.
    """ }

    /// Découpe aux fins de paragraphe pour ne pas couper une réplique en deux. Un paragraphe plus long que
    /// la tranche (réunion à une seule voix : tout le texte est un paragraphe) est lui-même scindé aux fins de phrase.
    static func chunks(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for paragraph in text.components(separatedBy: "\n") {
            for piece in pieces(of: paragraph) {
                if current.count + piece.count > chunkSize, !current.isEmpty {
                    result.append(current)
                    current = ""
                }
                current += piece
            }
            current += "\n"
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(current) }
        return result
    }

    /// Morceaux d'au plus `chunkSize` caractères, coupés après une fin de phrase (ou une espace, à défaut).
    private static func pieces(of paragraph: String) -> [String] {
        guard paragraph.count > chunkSize else { return [paragraph] }
        var pieces: [String] = []
        var rest = Substring(paragraph)
        while rest.count > chunkSize {
            let window = rest.prefix(chunkSize)
            var cut = window.lastIndex(where: { ".!?".contains($0) }).map { window.index(after: $0) }
                ?? window.lastIndex(of: " ")
                ?? window.endIndex
            if cut == rest.startIndex { cut = window.endIndex } // toujours avancer
            pieces.append(String(rest[..<cut]))
            rest = rest[cut...]
        }
        if !rest.isEmpty { pieces.append(String(rest)) }
        return pieces
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "```markdown", with: "")
            .replacingOccurrences(of: "```", with: "")
            // Puces doublées (« - - Maître X : … ») ou en tiret cadratin, que le modèle produit parfois dans les sections d'actions.
            .replacingOccurrences(of: #"(?m)^[ \t]*[-–•][ \t]+[-–•][ \t]+"#, with: "- ", options: .regularExpression)
            // Crochets recopiés de la consigne autour du nom d'une action (« - [Maître] : … »).
            .replacingOccurrences(of: #"(?m)^- \[([^\]\n]+)\]"#, with: "- $1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Export Word (.docx) d'un compte rendu, via le moteur de texte de macOS.
enum DocxExporter {
    static func export(title: String, subtitle: String, markdown: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "docx") ?? .data]
        panel.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-") + ".docx"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let document = attributed(title: title, subtitle: subtitle, markdown: markdown)
            let attributes: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: NSAttributedString.DocumentType.officeOpenXML]
            if let data = try? document.data(from: NSRange(location: 0, length: document.length), documentAttributes: attributes) {
                try? data.write(to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    private static func attributed(title: String, subtitle: String, markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        func add(_ text: String, size: CGFloat, bold: Bool = false, color: NSColor = .black, spaceBefore: CGFloat = 0, indent: CGFloat = 0) {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = spaceBefore
            style.paragraphSpacing = 4
            style.headIndent = indent
            style.firstLineHeadIndent = indent == 0 ? 0 : indent - 12
            result.append(NSAttributedString(string: text + "\n", attributes: [
                .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
                .foregroundColor: color,
                .paragraphStyle: style,
            ]))
        }
        add(title, size: 18, bold: true)
        add(subtitle, size: 10, color: .darkGray)
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") {
                add(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "# ")), size: 13, bold: true, spaceBefore: 12)
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                // Sous-point : puce en retrait (« - » précédé d'espaces dans le Markdown).
                let sub = line.first?.isWhitespace == true
                add((sub ? "·\t" : "–\t") + trimmed.dropFirst(2), size: 11, indent: sub ? 36 : 18)
            } else {
                add(trimmed, size: 11)
            }
        }
        return result
    }
}
