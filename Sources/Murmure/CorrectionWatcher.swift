import AppKit
import ApplicationServices

/// Apprend des corrections : quelques secondes après le collage, relit l'endroit où le texte a été collé.
/// Un mot que l'utilisateur a remplacé par un mot proche à l'écrit ou à l'oreille (« Lefèvre » → « Lefebvre »)
/// devient une correction du dictionnaire : tout de suite si c'est un nom propre, sinon à la deuxième fois.
final class CorrectionWatcher {
    static let shared = CorrectionWatcher()

    /// Appelé sur le fil principal avec le mot appris, pour l'annoncer.
    var onLearned: ((String) -> Void)?
    /// Appelé sur le fil principal avec la correction apprise que l'utilisateur a défaite deux fois, et qui est oubliée.
    var onForgotten: ((Replacement) -> Void)?

    private struct Watch {
        let field: AXUIElement
        let start: Int
        let pasted: String
        let timer: DispatchWorkItem
    }
    private var current: Watch?
    private static let delay: TimeInterval = 20
    private static let candidatesKey = "correctionCandidates"

    func watch(_ context: FieldContext, pasted: String) {
        flush()
        guard Settings.learnCorrections, let field = context.field, pasted.count >= 3 else { return }
        let timer = DispatchWorkItem { [weak self] in self?.check() }
        current = Watch(field: field, start: context.start, pasted: pasted, timer: timer)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: timer)
    }

    /// Une nouvelle dictée commence : la précédente est relue tout de suite.
    func flush() {
        guard let current else { return }
        current.timer.cancel()
        check()
    }

    private func check() {
        guard let watch = current else { return }
        current = nil
        // Un peu de marge avant et après : l'utilisateur a pu taper autour.
        let length = (watch.pasted as NSString).length
        Task {
            guard let now = await FieldContext.read(watch.field, location: watch.start - 40, length: length + 240) else { return }
            await MainActor.run {
                for correction in Self.corrections(pasted: watch.pasted, now: now) {
                    self.consider(correction)
                }
            }
        }
    }

    /// Une correction du dictionnaire remplace le mot partout, sans égard à la casse : un mot courant
    /// n'y entre jamais. Un nom est appris tout de suite ; un autre mot l'est à la deuxième fois, et
    /// seulement si ce que Whisper avait écrit n'est pas un mot de la langue (« nous » → « vous » est
    /// un changement de sens, « kébis » → « Kbis » une graphie à corriger).
    @MainActor
    private func consider(_ correction: Correction) {
        let heard = correction.heard, corrected = correction.corrected
        // L'utilisateur a remis ce que Murmure avait corrigé : la correction apprise est défaite (oubliée à la
        // deuxième fois), et la retouche n'est pas apprise à son tour.
        let undo = Lexicon.shared.noteUndo(heard: heard, corrected: corrected)
        if let forgotten = undo.forgotten { onForgotten?(forgotten) }
        guard !undo.matched else { return }
        // Même pour un nom : « Durant » → « Durand » ferait réécrire « durant la période » partout
        // (les corrections s'appliquent sans égard à la casse). Une expression de plusieurs mots qui devient un
        // nom (« Jean Pierre Durant » → « Jean-Pierre Durand ») ne se rencontre pas, elle, dans un texte ordinaire.
        let expression = heard.contains(" ")
        guard !Self.isKnownWord(heard.lowercased()) || (correction.isName && expression) else { return }
        let key = heard.lowercased() + "\u{1}" + corrected
        var candidates = UserDefaults.standard.dictionary(forKey: Self.candidatesKey) as? [String: Int] ?? [:]
        let seen = (candidates[key] ?? 0) + 1
        guard correction.isName || seen >= 2 else {
            candidates[key] = seen
            // Les candidats vus une fois ne s'accumulent pas sans fin.
            while candidates.count > 200, let oldest = candidates.keys.first { candidates[oldest] = nil }
            UserDefaults.standard.set(candidates, forKey: Self.candidatesKey)
            return
        }
        candidates[key] = nil
        UserDefaults.standard.set(candidates, forKey: Self.candidatesKey)
        if Lexicon.shared.learn(heard: heard, corrected: corrected, isName: correction.isName) {
            onLearned?(corrected)
        }
    }

    /// Vrai si chaque mot de l'expression figure dans le dictionnaire français du système.
    @MainActor
    private static func isKnownWord(_ text: String) -> Bool {
        text.split(separator: " ").allSatisfy { word in
            NSSpellChecker.shared.checkSpelling(of: String(word), startingAt: 0, language: "fr", wrap: false,
                                                inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
    }

    // MARK: - Comparaison

    struct Correction: Equatable, CustomStringConvertible {
        let heard: String
        let corrected: String
        /// Les deux graphies portent une majuscule hors début de phrase : c'est un nom propre ou un sigle.
        let isName: Bool
        var description: String { "\(heard)→\(corrected)" + (isName ? " (nom)" : "") }
    }

    private struct Word {
        let text: String
        /// Premier mot du texte ou précédé d'une ponctuation de fin de phrase.
        let startsSentence: Bool
    }

    /// Paires « entendu → corrigé » entre le texte collé et ce que le champ contient maintenant.
    /// Rien si le passage a été largement réécrit : ce n'est plus une correction de mots.
    static func corrections(pasted: String, now: String) -> [Correction] {
        let oldWords = words(pasted)
        let old = oldWords.map(\.text), new = words(now).map(\.text)
        guard !old.isEmpty, !new.isEmpty, old.count <= 400, new.count <= 500 else { return [] }
        let a = old.map { $0.lowercased() }, b = new.map { $0.lowercased() }

        // Plus longue sous-suite commune, mot à mot.
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        guard Double(table[0][0]) >= Double(old.count) * 0.6 else { return [] }

        // Parcours : entre deux mots communs, une expression d'au plus quatre mots remplacée par une autre
        // (« Kervoa Len » → « Kervoalen », « Jean Pierre Durant » → « Jean-Pierre Durand »).
        var pairs: [Correction] = []
        var i = 0, j = 0
        var anchored = false
        var removed: [Word] = [], added: [String] = []
        func closeBlock() {
            if anchored, (1...4).contains(removed.count), (1...4).contains(added.count) {
                let heard = removed.map(\.text).joined(separator: " "), corrected = added.joined(separator: " ")
                let isName = !removed[0].startsSentence && removed[0].text.first?.isUppercase == true && corrected.first?.isUppercase == true
                if isPlausible(heard: heard, corrected: corrected) { pairs.append(Correction(heard: heard, corrected: corrected, isName: isName)) }
            }
            removed = []; added = []
        }
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                closeBlock()
                anchored = true
                i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                removed.append(oldWords[i]); i += 1
            } else {
                if anchored { added.append(new[j]) }
                j += 1
            }
        }
        // Un remplacement en toute fin n'est pas encadré : on ne le retient pas.
        return pairs
    }

    private static func words(_ text: String) -> [Word] {
        let letters = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "-'’"))
        var result: [Word] = []
        var current = ""
        var sentenceStart = true
        for character in text {
            if character.unicodeScalars.allSatisfy(letters.contains) {
                current.append(character)
            } else {
                if !current.isEmpty { result.append(Word(text: current, startsSentence: sentenceStart)); current = ""; sentenceStart = false }
                if ".!?:\n".contains(character) { sentenceStart = true }
            }
        }
        if !current.isEmpty { result.append(Word(text: current, startsSentence: sentenceStart)) }
        return result
    }

    /// Une correction de graphie, pas un changement d'idée : même prononciation, ou orthographe proche.
    static func isPlausible(heard: String, corrected: String) -> Bool {
        guard corrected.count >= 3, heard.lowercased() != corrected.lowercased() else { return false }
        if Cleaner.soundKey(heard) == Cleaner.soundKey(corrected) { return true }
        let x = Array(heard.lowercased().folding(options: .diacriticInsensitive, locale: nil).replacingOccurrences(of: " ", with: ""))
        let y = Array(corrected.lowercased().folding(options: .diacriticInsensitive, locale: nil).replacingOccurrences(of: " ", with: ""))
        return distance(x, y) <= max(1, y.count / 4)
    }

    private static func distance(_ x: [Character], _ y: [Character]) -> Int {
        var previous = Array(0...y.count)
        for (i, cx) in x.enumerated() {
            var row = [i + 1]
            for (j, cy) in y.enumerated() {
                row.append(min(previous[j + 1] + 1, row[j] + 1, previous[j] + (cx == cy ? 0 : 1)))
            }
            previous = row
        }
        return previous[y.count]
    }
}
