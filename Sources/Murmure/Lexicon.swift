import Foundation

struct Replacement: Codable, Identifiable, Hashable {
    var id = UUID()
    var from: String
    var to: String
    /// Apprise en observant une correction de l'utilisateur (et non saisie à la main).
    var learned: Bool?
    /// Nombre de fois où la correction a rectifié ce que Whisper avait écrit. Absent des anciens fichiers.
    var uses: Int?
    /// Date à laquelle elle a été apprise (corrections apprises seulement).
    var learnedAt: Date?
    /// Nombre de fois où l'utilisateur a défait la correction après le collage : à deux, elle est oubliée.
    var undone: Int?
}

/// Dictionnaire personnel : termes rares (amorce Whisper) et corrections automatiques.
final class Lexicon: ObservableObject {
    static let shared = Lexicon()

    struct Data: Codable {
        var terms: [String]
        var replacements: [Replacement]
        /// Extraits : phrase dictée (`from`) remplacée par un texte enregistré (`to`). Absent des anciens fichiers.
        var snippets: [Replacement]?
        /// Passages revenus plusieurs fois dans les dictées, proposés comme raccourcis (voir `RecurringPassages`).
        var suggestions: [String]?
    }

    @Published var terms: [String] = [] { didSet { save() } }
    @Published var replacements: [Replacement] = [] { didSet { save() } }
    @Published var snippets: [Replacement] = [] { didSet { save() } }
    @Published var suggestions: [String] = [] { didSet { save() } }

    private let url = Settings.supportDir.appendingPathComponent("dictionnaire.json")
    private let lock = NSLock()
    private var cached = Data(terms: [], replacements: [], snippets: [], suggestions: [])
    private var loading = false
    private let ioQueue = DispatchQueue(label: "murmure.lexicon")
    private var writeScheduled = false

    private init() {
        loading = true
        let data = Self.load(from: url) ?? Self.migrateOrSeed()
        terms = data.terms
        replacements = data.replacements
        snippets = data.snippets ?? []
        suggestions = data.suggestions ?? []
        loading = false
        save()
    }

    /// « 12 mots · 8 corrections · 3 raccourcis » : Réglages, et le haut de la page Lexique.
    var summary: String {
        func count(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n > 1 ? "s" : "")" }
        return [count(terms.count, "mot"), count(replacements.count, "correction"), count(snippets.count, "raccourci")]
            .joined(separator: " · ")
    }

    /// Copie cohérente, lisible depuis n'importe quel thread.
    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    /// Ajoute une correction apprise (et le terme, si c'est un nom). Faux si elle était déjà connue.
    @MainActor
    func learn(heard: String, corrected: String, isName: Bool) -> Bool {
        let known = replacements.contains {
            $0.from.caseInsensitiveCompare(heard) == .orderedSame && $0.to == corrected
        }
        guard !known else { return false }
        replacements.append(Replacement(from: heard, to: corrected, learned: true, uses: 0, learnedAt: Date()))
        if isName, !terms.contains(where: { $0.caseInsensitiveCompare(corrected) == .orderedSame }) {
            terms.append(corrected)
        }
        return true
    }

    /// Après une dictée : chaque correction qui a rectifié la transcription brute (« Lefèvre » entendu, « Lefebvre »
    /// collé) compte une fois de plus. Compté au collage, et non quand la correction s'applique : la dictée est
    /// retranscrite plusieurs fois pendant qu'on parle.
    @MainActor
    func countUses(raw: String, final: String) {
        var updated = replacements
        var changed = false
        for index in updated.indices {
            let rule = updated[index]
            guard !rule.from.isEmpty, !rule.to.isEmpty else { continue }
            let count = min(Self.occurrences(of: rule.from, in: raw), Self.occurrences(of: rule.to, in: final))
            guard count > 0 else { continue }
            updated[index].uses = (rule.uses ?? 0) + count
            changed = true
        }
        if changed { replacements = updated }
    }

    /// L'utilisateur a remis, après le collage, ce que Murmure avait corrigé (« Lefebvre » → « Lefèvre ») : la
    /// correction apprise est défaite une fois ; à la deuxième, elle est oubliée et renvoyée.
    /// `matched` : la retouche défaisait bien une correction apprise, et ne doit pas être apprise à son tour.
    @MainActor
    func noteUndo(heard: String, corrected: String) -> (matched: Bool, forgotten: Replacement?) {
        guard let index = replacements.firstIndex(where: {
            $0.learned == true && $0.to.caseInsensitiveCompare(heard) == .orderedSame
                && $0.from.caseInsensitiveCompare(corrected) == .orderedSame
        }) else { return (false, nil) }
        let undone = (replacements[index].undone ?? 0) + 1
        guard undone >= 2 else {
            replacements[index].undone = undone
            return (true, nil)
        }
        return (true, replacements.remove(at: index))
    }

    /// Nombre d'occurrences d'une expression, mot entier, sans tenir compte de la casse.
    static func occurrences(of phrase: String, in text: String) -> Int {
        let pattern = "(?i)(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: phrase) + "(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private func save() {
        guard !loading else { return }
        let data = Data(
            terms: terms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            replacements: replacements,
            snippets: snippets,
            suggestions: suggestions
        )
        lock.lock(); cached = data; lock.unlock()
        // Les champs du dictionnaire sont liés directement aux listes : chaque caractère tapé passe ici.
        // L'écriture est regroupée et faite hors du fil principal.
        guard !writeScheduled else { return }
        writeScheduled = true
        ioQueue.asyncAfter(deadline: .now() + 0.5) { [self] in
            writeScheduled = false
            write()
        }
    }

    private func write() {
        if let json = try? JSONEncoder().encode(snapshot()) {
            try? json.write(to: url, options: .atomic)
        }
    }

    /// Écrit tout de suite ce qui est en attente (à la fermeture de l'application).
    func flush() {
        ioQueue.sync { if writeScheduled { writeScheduled = false; write() } }
    }

    private static func load(from url: URL) -> Data? {
        guard let json = try? Foundation.Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Data.self, from: json)
    }

    /// Reprend l'ancien fichier texte s'il existe, sinon part d'une liste de départ.
    private static func migrateOrSeed() -> Data {
        let legacy = Settings.supportDir.appendingPathComponent("vocabulaire.txt")
        if let text = try? String(contentsOf: legacy, encoding: .utf8) {
            var data = Data(terms: [], replacements: [])
            for line in text.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
                guard !line.isEmpty, !line.hasPrefix("#") else { continue }
                let parts = line.components(separatedBy: "=>").map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 {
                    data.replacements.append(Replacement(from: parts[0], to: parts[1]))
                } else {
                    data.terms.append(line)
                }
            }
            try? FileManager.default.removeItem(at: legacy)
            return data
        }
        return Data(
            terms: ["Légifrance", "huitaine", "quinzaine"],
            replacements: [Replacement(from: "GBI", to: "Kbis"), Replacement(from: "K-bis", to: "Kbis")]
        )
    }
}
