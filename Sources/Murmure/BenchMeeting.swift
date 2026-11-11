import AVFoundation
import Foundation

/// Banc d'essai des réunions : `Murmure --bench-reunion dossier`.
/// Le dossier contient `reunion.wav` (16 kHz mono) et `reunion.json` (répliques de référence : voix, texte,
/// début, fin), fabriqués par `tools/corpus-reunion.py`. Chaque méthode est mesurée sur le taux d'erreur par
/// mot (WER), la part des mots de la référence reconnus ET attribués à la bonne voix, le nombre de voix et de
/// tours trouvés, et le temps de calcul. Les transcriptions obtenues sont écrites à côté (`ancien.txt`, `nouveau.txt`).
enum BenchMeeting {
    struct Line: Decodable {
        let speaker: String
        let text: String
        let start: Double
        let end: Double
    }

    struct Corpus: Decodable {
        let lines: [Line]
        /// Termes du contexte (participants, objet), comme le titre et les invités d'une vraie réunion.
        let terms: [String]?
        /// Voix de l'utilisateur, au micro, dans un corpus à deux pistes.
        let local: String?
    }

    /// Interlocuteur trouvé qui porte le plus de mots de la voix de référence `speaker`.
    static func mainSpeaker(of speaker: String, reference: [Line], hypothesis: [Turn]) -> Int? {
        let ref = reference.flatMap { line in BenchASR.words(line.text).map { ($0, line.speaker) } }
        let hyp = hypothesis.flatMap { turn in BenchASR.words(turn.text).map { ($0, turn.speaker) } }
        var counts: [Int: Int] = [:]
        for (i, j) in alignedMatches(ref.map(\.0), hyp.map(\.0)) where ref[i].1 == speaker { counts[hyp[j].1, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key
    }

    struct Score {
        var wer: Double
        var attributed: Double
        var speakers: Int
        var turns: Int
        var time: Double
    }

    static func run(directory: String) async throws {
        let dir = URL(fileURLWithPath: directory)
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: dir.appendingPathComponent("reunion.json")))
        var audio = try loadAudio(dir.appendingPathComponent("reunion.wav").path)
        // Corpus à deux pistes (`--deux-pistes`) : mélangées comme dans l'app, écho des haut-parleurs compris,
        // et part du micro de chaque voix pour reconnaître « Moi ».
        var micShare: ((Int, Int) -> Float)?
        let micURL = dir.appendingPathComponent("micro.wav"), systemURL = dir.appendingPathComponent("ordinateur.wav")
        if FileManager.default.fileExists(atPath: micURL.path), FileManager.default.fileExists(atPath: systemURL.path) {
            let tracks = MeetingAudio(mic: try loadAudio(micURL.path), system: try loadAudio(systemURL.path))
            audio = tracks.mixed
            micShare = tracks.micShareByFrame()
            if let echo = tracks.echo {
                print(String(format: "Écho repéré : %d ms, corrélation %.2f, niveau %.2f, micro retiré sur %.0f %% des passages de l'ordinateur",
                             echo.delayMs, echo.correlation, echo.coupling, 100 * echo.removed))
            } else {
                print("Deux pistes, pas d'écho retiré")
            }
            // Le mélange écouté tel que Whisper l'entend.
            let buffer = BenchASR.pcmBuffer(audio, format: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!)
            try? AVAudioFile(forWriting: dir.appendingPathComponent("melange.wav"), settings: buffer.format.settings).write(from: buffer)
        }
        var own: Int?
        let transcriber = Transcriber()
        try await transcriber.load()
        print(String(format: "Corpus : %d répliques, %d voix, %.1f min, %d mots",
                     corpus.lines.count, Set(corpus.lines.map(\.speaker)).count, Double(audio.count) / 16_000 / 60,
                     corpus.lines.reduce(0) { $0 + BenchASR.words($1.text).count }))

        let methods: [(String, ([Float]) async throws -> [Turn]?)] = [
            ("ancien", { try await legacyTurns(transcriber, $0) }),
            // Une seule voix trouvée (deux voix de synthèse, pour pyannote) : la transcription seule, sans voix,
            // pour mesurer au moins les mots faux (corpus bilingue du 03/11/2026, deux voix de synthèse).
            ("nouveau", { audio in
                if let result = try await transcriber.speakerTurns(audio, micShare: micShare, context: corpus.terms ?? []) {
                    own = result.own
                    return result.turns
                }
                print("  (une seule voix trouvée : transcription sans distinction des voix)")
                let words = try await transcriber.transcribeTimed(audio, context: corpus.terms ?? [])
                return [Turn(speaker: 1, text: Cleaner.applyCommands(words.map(\.text).joined()))]
            }),
            // Service en ligne (clé dans le coffre de Murmure ou MURMURE_TRANSCRIPTION_KEY) : seulement si demandé.
            ("enligne", { try await OnlineTranscription.turns($0, micShare: nil, context: corpus.terms ?? [], progress: nil).turns }),
        ]
        let only = ProcessInfo.processInfo.environment["MURMURE_METHODE"]
        // Le service en ligne envoie le son hors du Mac et coûte : seulement sur demande expresse (MURMURE_METHODE=enligne).
        for (name, method) in methods where only == name || (only == nil && name != "enligne") {
            let start = Date()
            let turns = try await method(audio) ?? []
            let time = Date().timeIntervalSince(start)
            var score = score(reference: corpus.lines, hypothesis: turns)
            score.time = time
            print(String(format: "  %-8@ WER %5.1f %%  bien attribués %5.1f %%  voix %d  tours %d (réf. %d)  %5.1f s",
                         name as NSString, 100 * score.wer, 100 * score.attributed, score.speakers, score.turns,
                         referenceTurns(corpus.lines), time))
            if let local = corpus.local, name == "nouveau", micShare != nil {
                let expected = mainSpeaker(of: local, reference: corpus.lines, hypothesis: turns)
                print("  « Moi » : " + (own == nil ? "non reconnu" : own == expected ? "juste" : "faux (interlocuteur \(own!) au lieu de \(expected.map(String.init) ?? "?"))"))
            }
            let text = turns.map { "\($0.speaker == own && name == "nouveau" ? "Moi" : "Interlocuteur \($0.speaker)") : \($0.text)" }.joined(separator: "\n")
            try text.write(to: dir.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        }
    }

    /// Tours de la référence : répliques consécutives d'une même voix comptées pour un tour.
    static func referenceTurns(_ lines: [Line]) -> Int {
        var count = 0
        var previous: String?
        for line in lines where line.speaker != previous { count += 1; previous = line.speaker }
        return count
    }

    /// Ancienne méthode (jusqu'au 03/11/2026) : chaque plage de parole d'une voix transcrite isolément.
    /// Gardée ici pour la comparaison.
    static func legacyTurns(_ transcriber: Transcriber, _ audio: [Float]) async throws -> [Turn]? {
        guard let spans = try await transcriber.diarize(audio) else { return nil }
        var numbering: [String: Int] = [:]
        var turns: [Turn] = []
        for span in spans where span.end - span.start >= 0.3 {
            let from = max(0, Int((span.start - 0.15) * 16_000))
            let to = min(audio.count, Int((span.end + 0.15) * 16_000))
            guard to > from else { continue }
            let slice = Array(audio[from..<to])
            let spoken = slice.count > 28 * 16_000 ? try await transcriber.transcribeLong(slice) : try await transcriber.transcribe(slice, urgent: false)
            let text = Cleaner.applyCommands(spoken)
            guard !text.isEmpty else { continue }
            if numbering[span.voice] == nil { numbering[span.voice] = numbering.count + 1 }
            let speaker = numbering[span.voice]!
            if turns.last?.speaker == speaker {
                turns[turns.count - 1].text += " " + text
            } else {
                turns.append(Turn(speaker: speaker, text: text))
            }
        }
        return Set(turns.map(\.speaker)).count >= 2 ? turns : nil
    }

    // MARK: Mesure

    /// WER sur le texte entier, et part des mots de la référence retrouvés (alignement mot à mot) chez la
    /// bonne voix, les voix trouvées étant appariées aux voix de référence au mieux (une pour une).
    static func score(reference: [Line], hypothesis: [Turn]) -> Score {
        let ref = reference.flatMap { line in BenchASR.words(line.text).map { ($0, line.speaker) } }
        let hyp = hypothesis.flatMap { turn in BenchASR.words(turn.text).map { ($0, turn.speaker) } }
        let (errors, _) = BenchASR.wordErrors(reference: reference.map(\.text).joined(separator: " "),
                                              hypothesis: hypothesis.map(\.text).joined(separator: " "))
        let matches = alignedMatches(ref.map(\.0), hyp.map(\.0))
        // Comptes par (voix trouvée, voix de référence) sur les mots retrouvés.
        var counts: [Int: [String: Int]] = [:]
        for (i, j) in matches { counts[hyp[j].1, default: [:]][ref[i].1, default: 0] += 1 }
        let hypSpeakers = Array(counts.keys).sorted()
        let refSpeakers = Array(Set(ref.map(\.1))).sorted()
        var best = 0
        func assign(_ index: Int, _ used: Set<String>, _ total: Int) {
            guard index < hypSpeakers.count else { best = max(best, total); return }
            assign(index + 1, used, total) // voix trouvée sans correspondante
            for name in refSpeakers where !used.contains(name) {
                assign(index + 1, used.union([name]), total + (counts[hypSpeakers[index]]?[name] ?? 0))
            }
        }
        assign(0, [], 0)
        return Score(wer: Double(errors) / Double(max(ref.count, 1)), attributed: Double(best) / Double(max(ref.count, 1)),
                     speakers: Set(hypothesis.map(\.speaker)).count, turns: hypothesis.count, time: 0)
    }

    /// Paires (indice référence, indice hypothèse) des mots identiques dans l'alignement d'édition optimal.
    static func alignedMatches(_ r: [String], _ h: [String]) -> [(Int, Int)] {
        let n = r.count, m = h.count
        guard n > 0, m > 0 else { return [] }
        let width = m + 1
        var cost = [Int32](repeating: 0, count: (n + 1) * width)
        for i in 0...n { cost[i * width] = Int32(i) }
        for j in 0...m { cost[j] = Int32(j) }
        for i in 1...n {
            for j in 1...m {
                let same = r[i - 1] == h[j - 1]
                cost[i * width + j] = min(cost[(i - 1) * width + j] + 1, cost[i * width + j - 1] + 1,
                                          cost[(i - 1) * width + j - 1] + (same ? 0 : 1))
            }
        }
        var matches: [(Int, Int)] = []
        var i = n, j = m
        while i > 0, j > 0 {
            let here = cost[i * width + j]
            if r[i - 1] == h[j - 1], here == cost[(i - 1) * width + j - 1] {
                matches.append((i - 1, j - 1)); i -= 1; j -= 1
            } else if here == cost[(i - 1) * width + j - 1] + 1 {
                i -= 1; j -= 1
            } else if here == cost[(i - 1) * width + j] + 1 {
                i -= 1
            } else {
                j -= 1
            }
        }
        return matches.reversed()
    }
}
