import Foundation

/// Banc d'essai de la reconnaissance des voix : `Murmure --bench-voix fichier…`.
///
/// Chaque fichier est une « réunion » ; un fichier de plus de 4 min compte aussi pour deux réunions (ses deux
/// moitiés), ce qui simule la même personne entendue deux fois. Pour chaque voix de plus de 8 s : sa durée, ses
/// premières paroles (pour savoir qui c'est) et son empreinte. Puis la similarité de chaque paire de voix de deux
/// réunions différentes, la plus proche en tête : les paires d'une même personne doivent passer au-dessus du seuil
/// (`VoiceBook.threshold`), celles de deux personnes différentes en dessous.
///
/// MURMURE_VOIX_NOMS="fichier-moitié:S1=Vincent,…" n'est pas nécessaire : on lit les paroles et on juge.
enum BenchVoices {
    struct Voice {
        let meeting: String
        let label: String
        let print: Voiceprint
        let excerpt: String
    }

    /// Essai de bout en bout : `MURMURE_SUPPORT_DIR=/tmp/essai Murmure --test-voix fichier [nom]`. Les deux moitiés du
    /// fichier deviennent deux réunions ; dans la première, la voix qui parle le plus est nommée (`nom`, « Témoin »
    /// par défaut) ; la seconde doit la reconnaître. Puis : confirmation, correction, oubli. Refuse de tourner sur
    /// les vraies données de l'utilisateur.
    static func selfTest(path: String, name: String) async throws {
        guard ProcessInfo.processInfo.environment["MURMURE_SUPPORT_DIR"] != nil else {
            print("MURMURE_SUPPORT_DIR obligatoire : l'essai écrit un historique.")
            return
        }
        let transcriber = Transcriber()
        try await transcriber.load()
        let audio = try AudioFile.load(URL(fileURLWithPath: path))
        let half = audio.count / 2
        var meetings: [(UUID, [Int: Voiceprint])] = []
        for part in [Array(audio[..<half]), Array(audio[half...])] {
            guard let found = try await transcriber.voices(part) else { print("Distinction des voix indisponible"); return }
            let labels = found.prints.keys.sorted()
            let prints = Dictionary(uniqueKeysWithValues: labels.enumerated().map { ($0.offset + 1, found.prints[$0.element]!) })
            let id = await MainActor.run {
                let id = RecordingStore.shared.add(text: "essai", rawText: "essai", duration: Double(part.count) / 16_000,
                                                   appName: nil, kind: .meeting, title: "Essai voix")
                RecordingStore.shared.setTurns(id, prints.keys.sorted().map { Turn(speaker: $0, text: "…") })
                return id
            }
            meetings.append((id, prints))
        }
        @Sendable func check(_ label: String, _ ok: Bool) { Swift.print("\(ok ? "OK   " : "ÉCHEC") \(label)") }
        let pair = meetings
        await MainActor.run {
            let book = VoiceBook.shared
            book.forgetAll()
            let (first, firstPrints) = pair[0], (second, secondPrints) = pair[1]
            book.remember(first, prints: firstPrints)
            // La voix de la première moitié la plus proche d'une voix de la seconde : une personne présente dans les
            // deux (la distinction des voix peut en fondre une dans une autre). L'essai vérifie le parcours ; la
            // justesse se mesure avec `--bench-voix`.
            func best(_ print: Voiceprint) -> Float { secondPrints.values.map { $0.similarity(print.vector) }.max() ?? -1 }
            let speaker = firstPrints.filter { $0.value.seconds >= VoiceBook.minimumSeconds }.max { best($0.value) < best($1.value) }!.key
            book.name(first, speaker: speaker, name: name)
            check("voix apprise en nommant", book.voices.map(\.name) == [name])

            book.remember(second, prints: secondPrints)
            let expected = secondPrints.max { $0.value.similarity(firstPrints[speaker]!.vector) < $1.value.similarity(firstPrints[speaker]!.vector) }!
            Swift.print(String(format: "      meilleure similarité dans la seconde réunion : %.3f (interlocuteur %d)",
                               expected.value.similarity(firstPrints[speaker]!.vector), expected.key))
            let given = book.recognize(second)
            Swift.print("      reconnus : \(given)")
            let recording = RecordingStore.shared.recording(second)!
            check("reconnue dans la seconde réunion", given[expected.key] == name && recording.speakerName(expected.key) == name)
            check("marquée à confirmer", recording.isRecognized(expected.key))
            check("pas encore apprise (non confirmée)", book.voices.first?.meetings == 1)
            check("aucune autre voix nommée", given.count == 1)

            book.confirm(second, speaker: expected.key)
            check("confirmée : marque retirée", RecordingStore.shared.recording(second)?.isRecognized(expected.key) == false)
            check("confirmée : apprise (2 réunions)", book.voices.first?.meetings == 2)

            book.name(second, speaker: expected.key, name: "Autre")
            check("corrigée : retirée de l'ancien nom", book.voices.first { $0.name == name }?.meetings == 1)
            check("corrigée : rangée sous le nouveau", book.voices.first { $0.name == "Autre" }?.meetings == 1)

            book.setOwn(second, speaker: expected.key)
            check("« C'est moi » : rangée sous Moi", book.voices.first(where: \.isOwn)?.meetings == 1 && book.voices.first { $0.name == "Autre" } == nil)

            RecordingStore.shared.delete(second)
            check("réunion supprimée : empreintes oubliées", !book.hasPrints(second))
            book.forgetAll()
            check("tout oublier", book.voices.isEmpty && !book.hasPrints(first))
        }
    }

    static func run(paths: [String]) async throws {
        let transcriber = Transcriber()
        try await transcriber.load()
        var voices: [Voice] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let audio = try AudioFile.load(url)
            let name = String(url.deletingPathExtension().lastPathComponent.prefix(18))
            var parts: [(String, [Float])] = []
            if audio.count > 16_000 * 240 {
                let half = audio.count / 2
                parts = [("\(name)·1", Array(audio[..<half])), ("\(name)·2", Array(audio[half...]))]
            } else {
                parts = [(name, audio)]
            }
            for (meeting, samples) in parts {
                guard let found = try await transcriber.voices(samples) else { print("Distinction des voix indisponible"); return }
                print(String(format: "\n%@ (%.0f s) : %d voix", meeting, Double(samples.count) / 16_000, found.prints.count))
                for (label, print) in found.prints.sorted(by: { $0.key < $1.key }) {
                    // Premières paroles de la plus longue plage de cette voix, pour savoir de qui il s'agit.
                    let longest = found.spans.filter { $0.voice == label }.max { $0.end - $0.start < $1.end - $1.start }
                    var excerpt = ""
                    if let longest {
                        let from = Int(longest.start * 16_000), to = min(samples.count, Int(min(longest.end, longest.start + 12) * 16_000))
                        if to > from + 8_000 { excerpt = (try? await transcriber.transcribe(Array(samples[from..<to]), urgent: false)) ?? "" }
                    }
                    Swift.print(String(format: "  %@ %5.0f s  « %@ »", label, print.seconds, String(excerpt.prefix(90))))
                    if print.seconds >= VoiceBook.minimumSeconds {
                        voices.append(Voice(meeting: meeting, label: label, print: print, excerpt: excerpt))
                    }
                }
            }
        }
        print(String(format: "\nSimilarités entre réunions différentes (seuil %.2f, invité %.2f) :", VoiceBook.threshold, VoiceBook.invitedThreshold))
        var pairs: [(Voice, Voice, Float)] = []
        for (i, a) in voices.enumerated() {
            for b in voices[(i + 1)...] where a.meeting != b.meeting {
                pairs.append((a, b, a.print.similarity(b.print.vector)))
            }
        }
        for (a, b, score) in pairs.sorted(by: { $0.2 > $1.2 }) {
            print(String(format: "  %.3f  %@ %@  ↔  %@ %@", score, a.meeting, a.label, b.meeting, b.label))
        }
        // MURMURE_VOIX_JSON=fichier : empreintes écrites pour une analyse à part (moyennes de plusieurs réunions…).
        if let path = ProcessInfo.processInfo.environment["MURMURE_VOIX_JSON"] {
            let dump = voices.map { ["voix": "\($0.meeting) \($0.label)", "secondes": $0.print.seconds, "vecteur": $0.print.vector] as [String: Any] }
            try JSONSerialization.data(withJSONObject: dump).write(to: URL(fileURLWithPath: path))
        }
        print("\nSimilarités dans une même réunion (voix que la distinction a séparées) :")
        for (i, a) in voices.enumerated() {
            for b in voices[(i + 1)...] where a.meeting == b.meeting {
                print(String(format: "  %.3f  %@ %@ ↔ %@", a.print.similarity(b.print.vector), a.meeting, a.label, b.label))
            }
        }
    }
}
