import SwiftUI

/// Compte rendu mis en page : chaque section « ## » du Markdown devient un bloc avec son pictogramme
/// et une présentation adaptée (objet en chapeau, participants en étiquettes, points numérotés,
/// décisions cochées, actions avec responsable et échéance, points de vigilance mis en avant).
/// Le plan reste celui du modèle ; seule la présentation change. Un texte inattendu s'affiche tel quel.
struct SummaryView: View {
    let markdown: String
    /// Noms donnés aux voix (numéro → nom) : un « Interlocuteur 2 » nommé depuis la rédaction prend son nom à l'écran.
    let names: [Int: String]
    /// Date de la réunion : les dates du compte rendu antérieures à elle ne sont pas des échéances.
    let date: Date?
    @ObservedObject private var app = AppState.shared
    /// Les blocs apparaissent un à un à la première présentation (fondu et léger glissement, 40 ms d'écart).
    @State private var appeared: Bool

    init(markdown: String, names: [Int: String] = [:], date: Date? = nil, animated: Bool = true) {
        self.markdown = markdown
        self.names = names
        self.date = date
        _appeared = State(initialValue: !animated)
    }

    var body: some View {
        let sections = SummarySection.parse(Self.renamed(markdown, names))
        let tiles = SummaryGlance.tiles(sections, after: date)
        VStack(alignment: .leading, spacing: 14) {
            if tiles.count >= 2 {
                glance(tiles)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared || Motion.level != .full ? 0 : 8)
                    .animation(Motion.page, value: appeared)
            }
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                Group {
                    if section.kind == .lead {
                        lead(section)
                    } else {
                        card(section)
                    }
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared || Motion.level != .full ? 0 : 8)
                .animation(Motion.page.map { $0.delay(Double(index) * 0.04) }, value: appeared)
            }
        }
        .textSelection(.enabled)
        .onAppear { appeared = true }
    }

    // MARK: Blocs

    /// « En un coup d'œil » : combien de décisions, d'actions, de pièces…, et la prochaine date citée. Des tuiles
    /// grises sans cadre, en noir et blanc comme le reste ; le chiffre en grand, le libellé au-dessus.
    private func glance(_ tiles: [SummaryGlance.Tile]) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                VStack(alignment: .leading, spacing: 2) {
                    Text(tile.label).font(.ui(11)).foregroundStyle(Theme.muted).lineLimit(1)
                    Text(tile.value)
                        .font(.ui(tile.isDate ? 15 : 20, weight: .medium))
                        .foregroundStyle(Theme.fg)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(height: 24, alignment: tile.isDate ? .bottom : .center)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.soft))
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.bottom, 4)
    }

    /// Objet / En bref / Contexte : texte d'ouverture, plus grand, souligné d'un filet à gauche.
    private func lead(_ section: SummarySection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header(section)
            ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                Text(highlighted(line.text, app.highlight))
                    .readingFont(.medium, delta: 1)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 14)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.fg).frame(width: 3) }
        .padding(.bottom, 4)
    }

    private func card(_ section: SummarySection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(section)
            switch section.kind {
            case .people: people(section)
            case .decisions: rows(section) { _ in mark("checkmark", filled: true) }
            case .actions: actions(section)
            case .watch: rows(section) { _ in Image(systemName: "exclamationmark").font(.ui(11, weight: .bold)).frame(width: 18) }
            default: rows(section) { index in mark("\(index + 1)", filled: false) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(section.kind == .watch ? Theme.soft : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(section.kind == .watch ? Theme.fg : Theme.line,
                                                                 lineWidth: 1))
    }

    private func header(_ section: SummarySection) -> some View {
        HStack(spacing: 7) {
            Image(systemName: section.kind.symbol).font(.ui(11, weight: .semibold))
            Text(section.title.uppercased())
                .font(.ui(11, weight: .semibold))
                .tracking(0.6)
            if section.items > 1 {
                Text("\(section.items)").font(.ui(11)).foregroundStyle(Theme.muted)
            }
        }
        .foregroundStyle(section.kind == .lead || section.kind == .watch ? Theme.fg : Theme.muted)
    }

    /// Une ligne par puce, précédée d'un repère (numéro, coche…) ; les paragraphes restent pleine largeur. Chaque texte
    /// garde toute sa hauteur (`fixedSize` vertical) : un point de plusieurs lignes n'est jamais tronqué.
    private func rows(_ section: SummarySection, @ViewBuilder marker: @escaping (Int) -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(section.lines.enumerated()), id: \.offset) { position, line in
                // Un point suivi de précisions est un sujet : en gras, détaché du sujet précédent.
                let topic = line.bullet != nil && section.lines.indices.contains(position + 1) && section.lines[position + 1].sub
                if line.sub {
                    // Sous-point : sous le texte du point principal (repère de 18 + espacement de 10), sans numéro.
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("–").font(.ui(11)).foregroundStyle(Theme.muted)
                        Text(highlighted(line.text, app.highlight)).readingFont().lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 28)
                    .padding(.top, -4)
                } else if let index = line.bullet {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        marker(index)
                        Text(highlighted(line.text, app.highlight)).readingFont(topic ? .semibold : .regular).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, topic && index > 0 ? 6 : 0)
                } else {
                    Text(highlighted(line.text, app.highlight)).readingFont().lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Repère rond : plein pour une décision, au trait pour un numéro.
    private func mark(_ text: String, filled: Bool) -> some View {
        Group {
            if filled { Image(systemName: text).font(.ui(9, weight: .bold)) } else { Text(text).font(.ui(10, weight: .semibold)) }
        }
        .foregroundStyle(filled ? Theme.onInverse : Theme.fg)
        .frame(width: 18, height: 18)
        .background(Circle().fill(filled ? Theme.inverse : Color.clear))
        .overlay(Circle().strokeBorder(Theme.fg, lineWidth: 1))
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 5 }
    }

    private func people(_ section: SummarySection) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                let person = Self.split(line.text)
                HStack(spacing: 5) {
                    Image(systemName: "person").font(.ui(10))
                    Text(person.who ?? person.what).font(.ui(12, weight: .medium))
                    if person.who != nil { Text(person.what).font(.ui(12)).foregroundStyle(Theme.muted) }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line, style: StrokeStyle(
                    lineWidth: 1, dash: Self.unnamed(person.who ?? person.what) ? [3, 2] : [])))
            }
        }
    }

    /// « - Responsable : action (échéance) » → case à cocher, action, puis responsable et échéance en étiquettes.
    private func actions(_ section: SummarySection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                let action = Self.split(line.text)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.fg, lineWidth: 1.2)
                        .frame(width: 13, height: 13)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(highlighted(action.what, app.highlight)).readingFont().lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                        if action.who != nil || action.when != nil {
                            HStack(spacing: 6) {
                                // Responsable en étiquette au trait : le noir plein reste à l'action principale.
                                // « Interlocuteur 2 » en pointillés : une voix encore à nommer.
                                if let who = action.who { Tag(text: who, dashed: Self.unnamed(who)) }
                                if let when = action.when {
                                    Label(when, systemImage: "calendar").font(.ui(11)).foregroundStyle(Theme.muted)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Voix sans nom, telle que le modèle l'écrit faute de mieux.
    static func unnamed(_ who: String) -> Bool {
        who.range(of: #"^Interlocuteur \d+$"#, options: .regularExpression) != nil
    }

    /// « Interlocuteur 2 » → le nom donné depuis à cette voix ; « Moi » devient le titre de la profession (« Avocat »),
    /// comme le modèle l'écrit lui-même.
    static func renamed(_ markdown: String, _ names: [Int: String]) -> String {
        guard !names.isEmpty, let regex = try? NSRegularExpression(pattern: #"\bInterlocuteur (\d+)\b"#) else { return markdown }
        var result = ""
        var cursor = markdown.startIndex
        for match in regex.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)) {
            guard let whole = Range(match.range, in: markdown), let digits = Range(match.range(at: 1), in: markdown),
                  let number = Int(markdown[digits]), let name = names[number] else { continue }
            let own = name.compare("Moi", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            result += markdown[cursor..<whole.lowerBound]
            result += own ? Settings.profession.title.capitalizedFirst : name
            cursor = whole.upperBound
        }
        return result + markdown[cursor...]
    }

    /// Sépare « Qui : quoi (quand) ». Le responsable n'est retenu que s'il est court (un nom, pas une phrase).
    static func split(_ text: String) -> (who: String?, what: String, when: String?) {
        var what = text
        var when: String?
        if what.hasSuffix(")"), let open = what.lastIndex(of: "(") {
            let inside = what[what.index(after: open)..<what.index(before: what.endIndex)].trimmingCharacters(in: .whitespaces)
            if !inside.isEmpty, inside.count <= 40 {
                when = inside.replacingOccurrences(of: #"^(échéance|avant le|pour le)\s*:?\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
                    .capitalizedFirst
                what = what[..<open].trimmingCharacters(in: .whitespaces)
            }
        }
        if let colon = what.range(of: " : ") ?? what.range(of: ": "), what.distance(from: what.startIndex, to: colon.lowerBound) <= 32 {
            let who = what[..<colon.lowerBound].trimmingCharacters(in: .whitespaces)
            // « M. Bernard » ou « Maître Guyot », pas un début de phrase (quatre mots au plus).
            if !who.isEmpty, who.split(separator: " ").count <= 4 {
                return (who, String(what[colon.upperBound...]).trimmingCharacters(in: .whitespaces).capitalizedFirst, when)
            }
        }
        return (nil, what, when)
    }
}

/// Une section du compte rendu : titre, nature (déduite du titre) et lignes.
struct SummarySection {
    enum Kind {
        case lead, people, points, decisions, actions, watch

        var symbol: String {
            switch self {
            case .lead: return "text.alignleft"
            case .people: return "person.2"
            case .points: return "list.number"
            case .decisions: return "checkmark.seal"
            case .actions: return "arrow.right.circle"
            case .watch: return "exclamationmark.triangle"
            }
        }
    }

    struct Line {
        var text: String
        /// Rang parmi les puces de la section (nil pour un paragraphe ou un sous-point).
        var bullet: Int?
        /// Sous-point du point qui précède (puce en retrait dans le Markdown).
        var sub = false
    }

    var title: String
    var kind: Kind
    var lines: [Line] = []
    var items: Int { lines.filter { $0.bullet != nil }.count }

    static func kind(for title: String) -> Kind {
        let key = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
        func has(_ words: String...) -> Bool { words.contains { key.contains($0) } }
        if has("objet", "en bref", "contexte", "resume") { return .lead }
        if has("participant", "presents") { return .people }
        if has("decision") { return .decisions }
        if has("prochaine", "action", "suites", "a obtenir", "a faire") { return .actions }
        if has("vigilance", "risque", "questions juridiques", "attention") { return .watch }
        return .points
    }

    static func parse(_ markdown: String) -> [SummarySection] {
        var sections: [SummarySection] = []
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                let title = line.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                    .replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression)
                sections.append(SummarySection(title: title, kind: kind(for: title)))
                continue
            }
            if sections.isEmpty { sections.append(SummarySection(title: "Synthèse", kind: .points)) }
            var section = sections.removeLast()
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                // Une puce en retrait sous un point est un sous-point ; sans point au-dessus, elle en devient un.
                if raw.first?.isWhitespace == true, section.items > 0, section.kind != .people, section.kind != .actions {
                    section.lines.append(Line(text: String(line.dropFirst(2)), sub: true))
                } else {
                    section.lines.append(Line(text: String(line.dropFirst(2)), bullet: section.items))
                }
            } else {
                section.lines.append(Line(text: line))
            }
            sections.append(section)
        }
        // Une section vide (« Décisions » sans décision) n'apporte rien à l'écran.
        return sections.filter { !$0.lines.isEmpty }
    }
}

/// Rangée « en un coup d'œil » en tête du compte rendu : le nombre de puces des sections qui appellent une suite
/// (décisions, conseils, actions, pièces, vigilance), puis la prochaine date citée. Calculée sur le Markdown affiché :
/// rien n'est demandé de plus au modèle.
enum SummaryGlance {
    struct Tile: Equatable {
        var label: String
        var value: String
        var isDate = false
    }

    static func tiles(_ sections: [SummarySection], after date: Date?) -> [Tile] {
        var tiles: [Tile] = []
        for section in sections where section.items > 0 {
            guard let label = label(for: section), !tiles.contains(where: { $0.label == label }) else { continue }
            tiles.append(Tile(label: label, value: "\(section.items)"))
        }
        tiles = Array(tiles.prefix(3))
        let texts = sections.filter { $0.kind != .lead }.flatMap { $0.lines.map(\.text) }
        if let next = nextDate(in: texts, after: date ?? Date()) {
            tiles.append(Tile(label: "Prochaine date", value: next, isDate: true))
        }
        return tiles
    }

    /// Libellé court de la tuile, ou nil pour une section qui n'en mérite pas (objet, participants, points abordés).
    static func label(for section: SummarySection) -> String? {
        let key = section.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
        // « Pièces à obtenir », pas « Faits et pièces évoqués » (des points abordés).
        if key.contains("piece"), ["obtenir", "fournir", "reunir", "demander"].contains(where: key.contains) { return "Pièces à obtenir" }
        if key.contains("conseil") || key.contains("analyse") { return "Conseils" }
        switch section.kind {
        case .decisions: return "Décisions"
        case .actions: return key.contains("suite") ? "Suites" : key.contains("prochaine") ? "Prochaines étapes" : "Actions"
        case .watch: return key.contains("question") ? "Questions" : "Vigilance"
        default: return nil
        }
    }

    private static let months = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre",
                                 "octobre", "novembre", "décembre"]

    /// La date la plus proche à partir du jour de la réunion, parmi « 1er décembre », « 15 janvier 2027 » et
    /// « 12/12 » ou « 12/12/2026 ». Sans année, la date est prise dans l'année de la réunion, ou la suivante si elle
    /// est déjà passée. Rendue comme on l'écrit : « 1er décembre », avec l'année seulement si ce n'est pas la même.
    static func nextDate(in texts: [String], after reference: Date) -> String? {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(for: reference)
        let year = calendar.component(.year, from: reference)
        let monthNames = (months + ["fevrier", "aout", "decembre"]).joined(separator: "|")
        let written = try? NSRegularExpression(pattern: #"\b(1er|[0-3]?\d)\s+("# + monthNames + #")(?:\s+(\d{4}))?\b"#,
                                               options: .caseInsensitive)
        let numeric = try? NSRegularExpression(pattern: #"(?<![\d/])([0-3]?\d)/([01]?\d)(?:/(\d{4}|\d{2}))?(?![\d/])"#)
        var best: (date: Date, explicitYear: Bool)?

        func consider(day: Int, month: Int, explicitYear: Int?) {
            guard (1...31).contains(day), (1...12).contains(month) else { return }
            var components = DateComponents(year: explicitYear ?? year, month: month, day: day)
            guard var date = calendar.date(from: components), calendar.component(.day, from: date) == day else { return }
            if explicitYear == nil, date < start {
                components.year = year + 1
                guard let next = calendar.date(from: components) else { return }
                date = next
            }
            guard date >= start else { return }
            if best == nil || date < best!.date { best = (date, explicitYear != nil && explicitYear != year) }
        }

        for text in texts {
            let range = NSRange(text.startIndex..., in: text)
            func group(_ match: NSTextCheckingResult, _ index: Int) -> String? {
                Range(match.range(at: index), in: text).map { String(text[$0]) }
            }
            for match in written?.matches(in: text, range: range) ?? [] {
                guard let dayText = group(match, 1), let monthText = group(match, 2) else { continue }
                let folded = monthText.lowercased().replacingOccurrences(of: "fevrier", with: "février")
                    .replacingOccurrences(of: "aout", with: "août").replacingOccurrences(of: "decembre", with: "décembre")
                guard let month = months.firstIndex(of: folded) else { continue }
                consider(day: dayText == "1er" ? 1 : Int(dayText) ?? 0, month: month + 1,
                         explicitYear: group(match, 3).flatMap { Int($0) })
            }
            for match in numeric?.matches(in: text, range: range) ?? [] {
                guard let day = group(match, 1).flatMap({ Int($0) }), let month = group(match, 2).flatMap({ Int($0) }) else { continue }
                let explicit = group(match, 3).flatMap { Int($0) }.map { $0 < 100 ? 2000 + $0 : $0 }
                consider(day: day, month: month, explicitYear: explicit)
            }
        }
        guard let best else { return nil }
        let day = calendar.component(.day, from: best.date)
        let text = "\(day == 1 ? "1er" : "\(day)") \(months[calendar.component(.month, from: best.date) - 1])"
        return best.explicitYear ? "\(text) \(calendar.component(.year, from: best.date))" : text
    }
}
