import Foundation

/// Banc de l'annuaire des noms : `Murmure --bench-noms dossier` (tools/corpus-noms.sh : nom.aiff, nom.txt, nom.noms,
/// annuaire.txt). Chaque dictée est transcrite par Whisper sans contexte (un nouveau courriel, un document vide :
/// le cas où les noms manquent), puis relue par Claude sans l'annuaire, puis avec. Compte les noms attendus écrits
/// exactement, les noms de l'annuaire ajoutés à tort, et mesure le temps du rapprochement et de la relecture.
/// `MURMURE_PASSES` : nombre de passes (2 par défaut), sans puis avec l'annuaire en alternance.
enum BenchNames {
    struct Score {
        var found = 0, expected = 0, wrong = 0
        var times: [Double] = []
        mutating func add(_ text: String, expected names: [String], reference: String, annuaire: [String]) {
            expected += names.count
            found += names.filter { text.contains($0) }.count
            wrong += BenchNames.intruders(in: text, reference: reference, annuaire: annuaire).count
        }
    }

    /// Noms de l'annuaire (ou leur nom de famille rare) écrits dans `text` alors que le texte dit ne les contient pas.
    static func intruders(in text: String, reference: String, annuaire: [String]) -> [String] {
        var found: [String] = []
        for name in annuaire {
            let parts = [name] + NameDirectory.words(name).filter { $0.count >= 4 && !Cleaner.isFrenchWord($0.lowercased()) }
            for part in parts where text.contains(part) && !reference.contains(part) && !found.contains(part) {
                found.append(part)
            }
        }
        return found
    }

    static func run(directory: String) async throws {
        Cleaner.override = .claude
        guard ClaudeAPI.hasKey else { print("Claude indisponible : clé absente"); return }
        let dir = URL(fileURLWithPath: directory)
        let annuaire = try String(contentsOf: dir.appendingPathComponent("annuaire.txt"), encoding: .utf8)
            .split(whereSeparator: \.isNewline).map(String.init)
        let items = try FileManager.default.contentsOfDirectory(atPath: directory)
            .filter { $0.hasSuffix(".aiff") }.map { String($0.dropLast(5)) }.sorted()
        let passes = ProcessInfo.processInfo.environment["MURMURE_PASSES"].flatMap(Int.init) ?? 2
        let transcriber = Transcriber()
        try await transcriber.load()
        print("Modèle : \(ClaudeAPI.name(of: Settings.claudeDictationModel)) · \(annuaire.count) noms dans l'annuaire · \(passes) passe(s)")
        NameDirectory.shared.load(annuaire.map { ($0, .contact) })
        _ = await Cleaner.clean("Ceci est un essai de chauffe.", context: nil)

        var raw = Score(), without = Score(), with = Score()
        var matchTimes: [Double] = []
        for name in items {
            let audio = try loadAudio(dir.appendingPathComponent(name + ".aiff").path)
            let reference = (try? String(contentsOf: dir.appendingPathComponent(name + ".txt"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let expected = ((try? String(contentsOf: dir.appendingPathComponent(name + ".noms"), encoding: .utf8)) ?? "")
                .split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
            let heard = try await transcriber.transcribe(audio)
            raw.add(heard, expected: expected, reference: reference, annuaire: annuaire)

            NameDirectory.shared.load(annuaire.map { ($0, .contact) })
            let began = Date()
            let candidates = NameDirectory.shared.candidates(for: heard)
            matchTimes.append(Date().timeIntervalSince(began))

            print("\n\(name)\n  dit      : \(reference)\n  entendu  : \(heard)")
            print("  annuaire : " + (candidates.isEmpty ? "aucun nom" : candidates.map { "« \($0.heard) » → \($0.name)" }.joined(separator: " ; ")))
            for pass in 0..<passes {
                for useDirectory in [false, true] {
                    NameDirectory.shared.load(useDirectory ? annuaire.map { ($0, .contact) } : [])
                    let prepared = await Cleaner.prepare(heard, context: nil)
                    let start = Date()
                    let text = prepared.review ? await Cleaner.clean(prepared.text, context: nil) : prepared.text
                    let time = Date().timeIntervalSince(start)
                    if pass == 0 {
                        let missing = expected.filter { !text.contains($0) }
                        let wrong = intruders(in: text, reference: reference, annuaire: annuaire)
                        print(String(format: "  %@ (%.2f s) : %@", useDirectory ? "avec   " : "sans   ", time, text)
                              + (missing.isEmpty ? "" : "  · MANQUE \(missing.joined(separator: ", "))")
                              + (wrong.isEmpty ? "" : "  · AJOUTÉ À TORT \(wrong.joined(separator: ", "))"))
                        if useDirectory { with.add(text, expected: expected, reference: reference, annuaire: annuaire) }
                        else { without.add(text, expected: expected, reference: reference, annuaire: annuaire) }
                    }
                    if prepared.review {
                        if useDirectory { with.times.append(time) } else { without.times.append(time) }
                    }
                }
            }
        }
        print("\n##### Total (\(items.count) dictées)")
        for (label, score) in [("Whisper seul      ", raw), ("Claude sans annuaire", without), ("Claude avec annuaire", with)] {
            let t = score.times.sorted()
            let time = t.isEmpty ? "" : String(format: " · relecture médiane %.2f s, 90 %% sous %.2f s (%d)", t[t.count / 2], t[min(t.count - 1, t.count * 9 / 10)], t.count)
            print("\(label) : \(score.found)/\(score.expected) noms exacts · \(score.wrong) ajouté(s) à tort\(time)")
        }
        let sorted = matchTimes.sorted()
        print(String(format: "Rapprochement sur le Mac : %.1f ms en moyenne, %.1f ms au plus",
                     sorted.reduce(0, +) / Double(max(sorted.count, 1)) * 1000, (sorted.last ?? 0) * 1000))
    }

    /// `Murmure --noms annuaire.txt "texte"` : noms de l'annuaire rapprochés d'un texte, et clés phonétiques.
    static func show(annuaire path: String, text: String) throws {
        let annuaire = try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
        NameDirectory.shared.load(annuaire.map { ($0, .contact) })
        print("clés : " + NameDirectory.words(text).map { "\($0)=\(String(decoding: NameDirectory.key($0), as: UTF8.self))" }.joined(separator: " "))
        let began = Date()
        let candidates = NameDirectory.shared.candidates(for: text)
        print(String(format: "%.1f ms", Date().timeIntervalSince(began) * 1000))
        for candidate in candidates { print("« \(candidate.heard) » → \(candidate.name) (écart \(candidate.distance))") }
    }
}
