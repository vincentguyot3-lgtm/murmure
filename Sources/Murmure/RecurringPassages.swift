import CryptoKit
import Foundation

/// Repère les passages qu'on dicte encore et encore (adresse du cabinet, formule de politesse, signature) pour les
/// proposer comme raccourcis. Une phrase d'au moins huit mots, ou une dictée entière de plusieurs phrases, compte une
/// fois par dictée. Jusqu'à la troisième fois, seule une empreinte du texte est gardée (jamais le texte) ; à la
/// troisième, le passage est proposé dans le Lexique. Rien n'est compté si les dictées ne sont pas gardées.
enum RecurringPassages {
    private static let countsKey = "recurringPassages"
    private static let dismissedKey = "recurringPassagesDismissed"
    /// Nombre de dictées où le passage doit revenir avant d'être proposé.
    static let threshold = 3

    @MainActor
    static func note(_ text: String) {
        guard Settings.dictationRetention != .never else { return }
        let lexicon = Lexicon.shared
        var counts = UserDefaults.standard.dictionary(forKey: countsKey) as? [String: Int] ?? [:]
        let dismissed = Set(UserDefaults.standard.stringArray(forKey: dismissedKey) ?? [])
        let saved = Set(lexicon.snippets.map { key($0.to) } + lexicon.suggestions.map(key))
        var proposed: [String] = []
        for passage in passages(in: text) {
            let k = key(passage)
            guard !k.isEmpty, !saved.contains(k) else { continue }
            let hash = digest(k)
            guard !dismissed.contains(hash) else { continue }
            let seen = (counts[hash] ?? 0) + 1
            if seen >= threshold {
                counts[hash] = nil
                proposed.append(passage)
            } else {
                counts[hash] = seen
            }
        }
        // Les empreintes vues une ou deux fois ne s'accumulent pas sans fin.
        while counts.count > 500, let any = counts.keys.first { counts[any] = nil }
        UserDefaults.standard.set(counts, forKey: countsKey)
        if !proposed.isEmpty { lexicon.suggestions.append(contentsOf: proposed) }
    }

    /// « Écarter » : le passage n'est plus proposé, même s'il revient.
    @MainActor
    static func dismiss(_ passage: String) {
        var dismissed = UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []
        dismissed.append(digest(key(passage)))
        UserDefaults.standard.set(Array(dismissed.suffix(500)), forKey: dismissedKey)
        Lexicon.shared.suggestions.removeAll { $0 == passage }
    }

    /// Phrases d'au moins huit mots, et la dictée entière si elle en compte plusieurs et reste courte (un bloc
    /// d'adresse ou une signature dictés d'un trait).
    static func passages(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var sentences: [String] = []
        trimmed.enumerateSubstrings(in: trimmed.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty {
                sentences.append(sentence)
            }
        }
        var result = sentences.filter { wordCount($0) >= 8 }
        if sentences.count > 1, trimmed.count <= 600, wordCount(trimmed) >= 8 { result.append(trimmed) }
        return result
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// Clé indifférente à la casse, aux accents et à la ponctuation : la même formule dictée deux fois peut sortir
    /// avec une virgule de plus.
    static func key(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func digest(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
