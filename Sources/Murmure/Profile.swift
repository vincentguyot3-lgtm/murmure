import Foundation

// Personnalisation choisie à l'accueil : métier, domaines, attentes. Elle n'est pas décorative :
// le métier et les domaines entrent dans les consignes de rédaction, les domaines amorcent le dictionnaire,
// et les attentes règlent l'application (détection des visios, compte rendu par défaut, conservation).

/// Métier de l'utilisateur. Par défaut, avocat : c'est pour lui que Murmure a été écrit.
enum Profession: String, CaseIterable, Identifiable {
    case avocat, juriste, notaire, comptable, medecin, conseil, dirigeant, autre

    var id: String { rawValue }

    var label: String {
        switch self {
        case .avocat: return "Avocat"
        case .juriste: return "Juriste d'entreprise"
        case .notaire: return "Notaire"
        case .comptable: return "Expert-comptable"
        case .medecin: return "Médecin"
        case .conseil: return "Consultant"
        case .dirigeant: return "Dirigeant"
        case .autre: return "Autre métier"
        }
    }

    var symbol: String {
        switch self {
        case .avocat: return "building.columns"
        case .juriste: return "briefcase"
        case .notaire: return "signature"
        case .comptable: return "chart.bar.doc.horizontal"
        case .medecin: return "stethoscope"
        case .conseil: return "lightbulb"
        case .dirigeant: return "person.2"
        case .autre: return "ellipsis"
        }
    }

    /// Celui pour qui le modèle écrit, après « d' » ou « pour » : « un avocat français ».
    var writer: String {
        switch self {
        case .avocat: return "un avocat français"
        case .juriste: return "un juriste d'entreprise français"
        case .notaire: return "un notaire français"
        case .comptable: return "un expert-comptable français"
        case .medecin: return "un médecin français"
        case .conseil: return "un consultant français"
        case .dirigeant: return "un dirigeant d'entreprise français"
        case .autre: return "un professionnel français"
        }
    }

    /// Le même, désigné dans la suite d'une consigne : « l'avocat ».
    var title: String {
        switch self {
        case .avocat: return "l'avocat"
        case .juriste: return "le juriste"
        case .notaire: return "le notaire"
        case .comptable: return "l'expert-comptable"
        case .medecin: return "le médecin"
        case .conseil: return "le consultant"
        case .dirigeant: return "le dirigeant"
        case .autre: return "l'auteur"
        }
    }

    /// « de l'avocat », « du notaire ».
    var ofTitle: String { title.hasPrefix("le ") ? "du " + title.dropFirst(3) : "de " + title }

    /// Exemple de rôle pour nommer l'interlocuteur dans une transcription : « La cliente », « La patiente ».
    var counterpart: String {
        switch self {
        case .medecin: return "La patiente"
        case .juriste, .dirigeant: return "La collègue"
        default: return "La cliente"
        }
    }

    /// Domaines proposés à l'accueil (aucun : l'écran passe directement aux attentes).
    var domains: [String] {
        switch self {
        case .avocat:
            return ["Droit des affaires", "Droit pénal", "Droit social", "Droit de la famille", "Droit immobilier",
                    "Droit fiscal", "Droit public", "Propriété intellectuelle", "Contentieux"]
        case .juriste: return ["Droit des sociétés", "Contrats", "Conformité", "Droit social", "Données personnelles"]
        case .notaire: return ["Immobilier", "Famille et successions", "Droit des sociétés", "Patrimoine"]
        case .comptable: return ["Comptabilité", "Fiscalité", "Social et paie", "Audit", "Conseil aux dirigeants"]
        case .medecin: return ["Médecine générale", "Spécialité", "Hôpital", "Expertise"]
        case .conseil: return ["Stratégie", "Finance", "Ressources humaines", "Informatique"]
        case .dirigeant, .autre: return []
        }
    }

    /// Phrase lue pendant le test du micro : des mots du métier, pour voir s'ils sont bien reconnus.
    var testSentence: String {
        switch self {
        case .avocat: return "Maître Durand représente la société devant le tribunal de commerce de Rennes."
        case .juriste: return "Le contrat de prestation doit être signé avant la fin du trimestre."
        case .notaire: return "L'acte de vente sera signé à l'étude en présence des deux parties."
        case .comptable: return "La liasse fiscale et le bilan seront déposés avant la fin du mois de mai."
        case .medecin: return "Le patient se plaint de douleurs thoraciques depuis plusieurs jours."
        case .conseil, .dirigeant, .autre: return "La réunion de jeudi est reportée à la semaine prochaine, en fin de matinée."
        }
    }
}

/// Mots du métier ajoutés au dictionnaire quand on choisit un domaine : ils amorcent la transcription.
/// Listes courtes : chaque mot du dictionnaire coûte un pas de décodeur à chaque dictée.
enum DomainTerms {
    static let byDomain: [String: [String]] = [
        "Droit des affaires": ["Kbis", "SAS", "pacte d'associés", "fonds de commerce"],
        "Droit pénal": ["CRPC", "JLD", "garde à vue", "comparution immédiate"],
        "Droit social": ["prud'hommes", "rupture conventionnelle", "CSE"],
        "Droit de la famille": ["JAF", "prestation compensatoire"],
        "Droit immobilier": ["VEFA", "bail commercial", "syndic"],
        "Droit fiscal": ["CGI", "BOFiP", "rescrit"],
        "Droit public": ["Conseil d'État", "référé-suspension"],
        "Propriété intellectuelle": ["INPI", "EUIPO", "contrefaçon"],
        "Contentieux": ["RPVA", "mise en état", "assignation"],
        "Droit des sociétés": ["Kbis", "assemblée générale", "SAS"],
        "Conformité": ["Sapin II", "LCB-FT"],
        "Données personnelles": ["RGPD", "CNIL", "DPO"],
        "Immobilier": ["compromis de vente", "VEFA", "servitude"],
        "Famille et successions": ["donation-partage", "PACS", "dévolution successorale"],
        "Patrimoine": ["SCI", "démembrement", "usufruit"],
        "Comptabilité": ["FEC", "liasse fiscale"],
        "Fiscalité": ["CFE", "CVAE", "TVA"],
        "Social et paie": ["DSN", "URSSAF"],
        "Audit": ["CAC"],
    ]

    static func terms(for domains: [String]) -> [String] {
        var seen = Set<String>()
        return domains.flatMap { byDomain[$0] ?? [] }.filter { seen.insert($0.lowercased()).inserted }
    }
}

/// Ce que l'utilisateur attend de Murmure. Chaque attente règle l'application à la fin de l'accueil.
enum Goal: String, CaseIterable, Identifiable {
    case write, meetings, reports, longTexts, recall

    var id: String { rawValue }

    var title: String {
        switch self {
        case .write: return "Écrire plus vite"
        case .meetings: return "Ne plus prendre de notes en réunion"
        case .reports: return "Des comptes rendus de rendez-vous prêts à relire"
        case .longTexts: return "Dicter de longs textes"
        case .recall: return "Retrouver ce qui a été dit"
        }
    }

    var detail: String {
        switch self {
        case .write: return "Mails, messages, notes : dictés là où se trouve votre curseur."
        case .meetings: return "Visio ou réunion sur place, transcrite et résumée sur ce Mac."
        case .reports: return "Contexte, demande, conseils donnés, suites convenues."
        case .longTexts: return "Courriers, conclusions, rapports : mains libres, sans limite de durée."
        case .recall: return "Toutes vos dictées gardées et retrouvées par la recherche."
        }
    }

    var symbol: String {
        switch self {
        case .write: return "text.cursor"
        case .meetings: return "person.3"
        case .reports: return "doc.text"
        case .longTexts: return "text.alignleft"
        case .recall: return "magnifyingglass"
        }
    }
}

extension Settings {
    static var profession: Profession {
        get { Profession(rawValue: UserDefaults.standard.string(forKey: "profession") ?? "") ?? .avocat }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "profession") }
    }

    /// Domaines de travail choisis à l'accueil, dans l'ordre de la liste du métier.
    static var domains: [String] {
        get { UserDefaults.standard.stringArray(forKey: "domains") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "domains") }
    }

    static var goals: Set<Goal> {
        get { Set((UserDefaults.standard.stringArray(forKey: "goals") ?? []).compactMap(Goal.init)) }
        set { UserDefaults.standard.set(Goal.allCases.filter(newValue.contains).map(\.rawValue), forKey: "goals") }
    }

    /// Compte rendu rédigé de lui-même à la fin d'une réunion.
    static var meetingTemplate: SummaryTemplate {
        get { SummaryTemplate(rawValue: UserDefaults.standard.string(forKey: "meetingTemplate") ?? "") ?? .meeting }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "meetingTemplate") }
    }
}

extension UserProfile {
    var profession: Profession { Settings.profession }

    /// Ligne ajoutée aux consignes de rédaction : « Domaines de travail : droit pénal, droit social. »
    var domainLine: String {
        let domains = Settings.domains
        guard !domains.isEmpty else { return "" }
        return "Domaines de travail : " + domains.map { $0.prefix(1).lowercased() + $0.dropFirst() }.joined(separator: ", ") + "."
    }

    /// Applique les choix de l'accueil : dictionnaire amorcé, réglages qui suivent les attentes.
    /// Renvoie ce qui a été fait, pour la carte de fin d'accueil.
    @MainActor
    static func applyChoices() -> [String] {
        var done: [String] = []
        let goals = Settings.goals
        let defaults = UserDefaults.standard

        let lexicon = Lexicon.shared
        let added = DomainTerms.terms(for: Settings.domains).filter { term in
            !lexicon.terms.contains { $0.caseInsensitiveCompare(term) == .orderedSame }
        }
        if !added.isEmpty {
            lexicon.terms.append(contentsOf: added)
            done.append("\(added.count) mot\(added.count > 1 ? "s" : "") de votre métier ajouté\(added.count > 1 ? "s" : "") au dictionnaire")
        }
        if goals.contains(.write) {
            defaults.set(true, forKey: "autoPaste")
            defaults.set(true, forKey: "fieldContext")
            done.append("Texte collé là où se trouve votre curseur, accordé à ce qui l'entoure")
        }
        // Sans réunions parmi les attentes, Murmure ne propose pas d'enregistrer chaque visio.
        defaults.set(goals.contains(.meetings), forKey: "detectMeetings")
        defaults.set(goals.contains(.meetings), forKey: "proposeAtAppointments")
        if goals.contains(.meetings) {
            defaults.set(true, forKey: "meetingSystemAudio")
            done.append("Appels, visios et rendez-vous repérés : Murmure propose de les enregistrer, participants compris")
        }
        Settings.meetingTemplate = goals.contains(.reports) ? .client : .meeting
        if goals.contains(.reports) { done.append("Chaque réunion se termine par un compte rendu de rendez-vous client") }
        if goals.contains(.longTexts) {
            done.append("Appui bref sur \(Settings.dictationKey.label) : dictée mains libres, aussi longue que vous voulez")
        }
        if goals.contains(.recall) {
            Settings.dictationRetention = .always
            done.append("Dictées gardées dans l'historique, sans limite")
        }
        return done
    }
}
