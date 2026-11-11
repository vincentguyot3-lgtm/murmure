import Foundation

/// Banc de la relecture anticipée : `Murmure --bench-relecture dossier` (paires nom.aiff / nom.ctx, texte avant le
/// curseur ; voir tools/corpus-relecture.sh). Chaque dictée est rejouée en temps réel, comme dite au micro, et la
/// touche relâchée après quelques secondes de silence (`MURMURE_RELACHE`, liste, « 0.3,1,2 » par défaut). Deux
/// passes : relecture par Claude après le relâchement (avant), puis relecture anticipée (après). Mesure l'attente
/// entre le relâchement et le texte relu, les demandes envoyées et leur coût. Il faut la clé Claude (coffre de Murmure,
/// `secrets.json`, ou `MURMURE_CLAUDE_KEY`).
enum BenchReview {
    struct Usage {
        var requests = 0, input = 0, cacheRead = 0, cacheWrite = 0, output = 0

        static var now: Usage {
            let api = ClaudeAPI.shared
            return Usage(requests: api.requests, input: api.tokensIn, cacheRead: api.tokensCacheRead,
                         cacheWrite: api.tokensCacheWrite, output: api.tokensOut)
        }
        static func - (a: Usage, b: Usage) -> Usage {
            Usage(requests: a.requests - b.requests, input: a.input - b.input, cacheRead: a.cacheRead - b.cacheRead,
                  cacheWrite: a.cacheWrite - b.cacheWrite, output: a.output - b.output)
        }
        /// En dollars, au tarif de Sonnet 5.5 : 2 $ le million de jetons lus (0,1× en cache, 1,25× mis en cache),
        /// 10 $ le million écrits.
        var cost: Double {
            let plain = input - cacheRead - cacheWrite
            return (Double(plain) * 2 + Double(cacheRead) * 0.2 + Double(cacheWrite) * 2.5 + Double(output) * 10) / 1_000_000
        }
    }

    struct Run {
        let text: String
        /// Attente après le relâchement : jusqu'au texte transcrit, puis jusqu'au texte relu.
        let transcribed: Double
        let total: Double
        let usage: Usage
        let reused: Bool
    }

    static func run(directory: String) async throws {
        Cleaner.override = .claude
        guard Cleaner.reviewsAhead("un deux trois") else {
            print("Claude indisponible : clé absente ou « Rester hors ligne » activé"); return
        }
        let dir = URL(fileURLWithPath: directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory)
            .filter { $0.hasSuffix(".aiff") }.map { String($0.dropLast(5)) }.sorted()
        let releases = (ProcessInfo.processInfo.environment["MURMURE_RELACHE"] ?? "0.3,1,2")
            .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        let transcriber = Transcriber()
        try await transcriber.load()
        print("Modèle : \(ClaudeAPI.name(of: Settings.claudeDictationModel)) · au plus \(ReviewAhead.limit) demandes anticipées par dictée")
        // Chauffe : les consignes entrent dans le cache de Claude, comme après la première dictée de la journée.
        _ = await Cleaner.clean("Ceci est un essai de chauffe.", context: nil)

        // Attente totale, et sa part après le texte transcrit (la relecture) : la transcription varie d'une passe à
        // l'autre avec la charge de la machine, la relecture est ce que l'anticipation change.
        var totals: [Double: (before: Double, after: Double, reviewBefore: Double, reviewAfter: Double, reused: Int, same: Int,
                              count: Int, extra: Int, cost: Double, base: Double)] = [:]
        for name in names {
            let audio = try loadAudio(dir.appendingPathComponent(name + ".aiff").path)
            let before = (try? String(contentsOf: dir.appendingPathComponent(name + ".ctx"), encoding: .utf8)) ?? ""
            let context = FieldContext(bundleID: "com.microsoft.Word", before: before, selected: "", after: "",
                                       windowTitle: "Conclusions.docx")
            for release in releases {
                let padded = audio + [Float](repeating: 0, count: Int(16_000 * release))
                let plain = try await dictate(padded, context: context, transcriber: transcriber, ahead: nil)
                let early = try await dictate(padded, context: context, transcriber: transcriber, ahead: ReviewAhead())
                let same = plain.text == early.text
                print(String(format: "%@ · %.1f s de parole, relâché %.1f s après · avant %.2f s (dont transcription %.2f) · après %.2f s (%.2f) · %d demande(s)%@%@",
                             name, Double(audio.count) / 16_000, release, plain.total, plain.transcribed, early.total,
                             early.transcribed, early.usage.requests, early.reused ? ", relecture anticipée reprise" : "",
                             same ? "" : " · TEXTES DIFFÉRENTS"))
                print("  avant : \(plain.text)")
                if !same { print("  après : \(early.text)") }
                var total = totals[release] ?? (0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
                total.before += plain.total; total.after += early.total
                total.reviewBefore += plain.total - plain.transcribed; total.reviewAfter += early.total - early.transcribed
                total.reused += early.reused ? 1 : 0; total.same += same ? 1 : 0; total.count += 1
                total.extra += early.usage.requests - plain.usage.requests
                total.cost += early.usage.cost; total.base += plain.usage.cost
                totals[release] = total
            }
        }
        print("\n##### Total")
        for release in releases {
            guard let t = totals[release], t.count > 0 else { continue }
            let n = Double(t.count)
            // Une demande annulée peut ne pas avoir renvoyé ses jetons : le surcoût est compté au prix moyen d'une relecture.
            let perRequest = t.base / n
            print(String(format: "relâché %.1f s après : attente moyenne %.2f → %.2f s, dont relecture %.2f → %.2f s · anticipée reprise %d/%d · textes identiques %d/%d · %.2f demande(s) de plus par dictée, soit %.4f $ (relecture seule %.4f $, mesuré après %.4f $)",
                         release, t.before / n, t.after / n, t.reviewBefore / n, t.reviewAfter / n, t.reused, t.count, t.same, t.count,
                         Double(t.extra) / n, Double(t.extra) / n * perRequest, perRequest, t.cost / n))
        }
    }

    /// Une dictée rejouée en temps réel, la touche relâchée à la fin de `audio` ; relecture anticipée si `ahead`.
    static func dictate(_ audio: [Float], context: FieldContext, transcriber: Transcriber, ahead: ReviewAhead?) async throws -> Run {
        let began = Date()
        let flux = ProgressiveDictation(transcriber: transcriber) { index in
            let available = min(audio.count, Int(Date().timeIntervalSince(began) * 16_000))
            return index < available ? Array(audio[index..<available]) : []
        }
        let contextTask = Task<FieldContext?, Never> { context }
        let start = Usage.now
        ahead?.reset()
        flux.start(context: contextTask, onPause: ahead.map { ahead in { await ahead.announce($0, context: contextTask) } })
        try await Task.sleep(for: .seconds(Double(audio.count) / 16_000))
        let released = Date()
        let raw = try await flux.finish(audio, context: contextTask)
        let transcribed = Date().timeIntervalSince(released)
        let prepared = await Cleaner.prepare(raw, context: context)
        var text = prepared.text
        if prepared.review {
            if let ahead { text = await ahead.review(text, context: context) } else { text = await Cleaner.clean(text, context: context) }
        }
        let total = Date().timeIntervalSince(released)
        // Laisse se terminer une demande annulée avant de compter.
        try await Task.sleep(for: .milliseconds(500))
        return Run(text: text, transcribed: transcribed, total: total, usage: Usage.now - start, reused: ahead?.reused ?? false)
    }
}
