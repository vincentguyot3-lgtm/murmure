import AVFoundation
import FluidAudio
import Foundation
import Speech
import WhisperKit

/// Banc d'essai de la transcription : `Murmure --bench-asr dossier`.
/// Le dossier contient des paires `nom.aiff` / `nom.txt` (audio et texte de référence).
/// Chaque audio est dégradé (micro lointain, Bluetooth) puis transcrit avec plusieurs réglages ;
/// on mesure le taux d'erreur par mot (WER) et le temps de calcul.
enum BenchASR {
    struct Config {
        let name: String
        var prompt = true
        var timestamps = false
        var vad = false
        var pad = false
        var apple = false
        var parakeet = false
        var firstTokenCheck = true
    }

    static let configs: [Config] = [
        Config(name: "Whisper avant"),
        Config(name: "Whisper app", timestamps: true, vad: true, firstTokenCheck: false), // réglage de Transcriber
        Config(name: "Apple", apple: true),
        Config(name: "Parakeet v3", parakeet: true),
        Config(name: "W sans amorce", prompt: false, timestamps: true, vad: true, firstTokenCheck: false),
    ]

    static var parakeet: AsrManager?

    static func run(directory: String) async throws {
        let dir = URL(fileURLWithPath: directory)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory)
            .filter { $0.hasSuffix(".txt") }.sorted()
        var corpus: [(name: String, audio: [Float], reference: String)] = []
        for file in files {
            let name = String(file.dropLast(4))
            let reference = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            let audio = try loadAudio(dir.appendingPathComponent(name + ".aiff").path)
            corpus.append((name, audio, reference))
        }

        checkStreamingConversion(corpus.map(\.audio).max(by: { $0.count < $1.count }) ?? [])

        let whisper = try await loadEngines()

        let conditions: [(String, ([Float]) -> [Float])] = [
            ("propre", { $0 }),
            ("lointain", distant),
            ("bluetooth", narrowband),
        ]
        var totals: [String: (errors: Int, words: Int, time: Double)] = [:]
        for (condition, degrade) in conditions {
            print("\n##### \(condition)")
            for item in corpus {
                let audio = degrade(item.audio)
                print("\n— \(item.name) (\(String(format: "%.1f", Double(audio.count) / 16_000)) s)")
                for config in configs {
                    let start = Date()
                    let text = try await transcribe(whisper, audio, config)
                    let time = Date().timeIntervalSince(start)
                    let (errors, words) = wordErrors(reference: item.reference, hypothesis: text)
                    let key = "\(condition)|\(config.name)"
                    let t = totals[key] ?? (0, 0, 0)
                    totals[key] = (t.errors + errors, t.words + words, t.time + time)
                    print(String(format: "  %-12@ WER %5.1f %%  %4.2f s  %@", config.name as NSString,
                                 100 * Double(errors) / Double(max(words, 1)), time, text as NSString))
                }
            }
        }
        print("\n##### Synthèse (WER cumulé, temps total)")
        for (condition, _) in conditions {
            for config in configs {
                let t = totals["\(condition)|\(config.name)"]!
                print(String(format: "  %-10@ %-12@ WER %5.1f %%  %5.1f s", condition as NSString, config.name as NSString,
                             100 * Double(t.errors) / Double(max(t.words, 1)), t.time))
            }
        }
    }

    /// Charge Whisper et Parakeet, et fait une première transcription à vide pour ne pas fausser les temps.
    static func loadEngines() async throws -> WhisperKit {
        let whisper = try await WhisperKit(WhisperKitConfig(
            model: ProcessInfo.processInfo.environment["MURMURE_MODEL"] ?? Settings.whisperModel,
            downloadBase: Settings.modelsDir, verbose: false, logLevel: .error, prewarm: false, load: true, download: true
        ))
        _ = try? await whisper.transcribe(audioArray: [Float](repeating: 0, count: 16_000))
        let manager = AsrManager(config: .default)
        try await manager.loadModels(try await AsrModels.downloadAndLoad(version: .v3))
        parakeet = manager
        _ = try? await transcribeParakeet([Float](repeating: 0, count: 16_000))
        return whisper
    }

    /// Banc d'essai sur les vraies dictées : `Murmure --bench-real`.
    /// Prend chaque dictée dont l'audio a été gardé, avec son texte (corrigé dans l'historique) comme référence.
    static func runReal() async throws {
        let recordings = await MainActor.run { RecordingStore.shared.recordings }
        let samples = recordings.compactMap { recording in AudioArchive.url(for: recording.id).map { (recording, $0) } }
        guard !samples.isEmpty else {
            print("Aucune dictée avec audio : activez Réglages › Essais › Garder l'audio des dictées, puis dictez.")
            return
        }
        let whisper = try await loadEngines()
        // Whisper (réglage actuel de l'app), Parakeet, Apple ; MURMURE_ALL=1 ajoute les variantes de Whisper.
        let engines = ProcessInfo.processInfo.environment["MURMURE_ALL"] != nil ? configs : [configs[1], configs[3], configs[2]]
        var totals: [String: (errors: Int, words: Int, time: Double)] = [:]
        for (recording, url) in samples {
            let audio = try loadAudio(url.path)
            print("\n— \(recording.title) (\(String(format: "%.1f", Double(audio.count) / 16_000)) s)")
            print("  référence     \(recording.text)")
            for engine in engines {
                let start = Date()
                let text = Cleaner.applyCommands(try await transcribe(whisper, audio, engine))
                let time = Date().timeIntervalSince(start)
                let (errors, words) = wordErrors(reference: recording.text, hypothesis: text)
                let t = totals[engine.name] ?? (0, 0, 0)
                totals[engine.name] = (t.errors + errors, t.words + words, t.time + time)
                print(String(format: "  %-12@ WER %5.1f %%  %4.2f s  %@", engine.name as NSString,
                             100 * Double(errors) / Double(max(words, 1)), time, text as NSString))
            }
        }
        print("\n##### Synthèse sur \(samples.count) dictée(s)")
        for engine in engines {
            let t = totals[engine.name]!
            print(String(format: "  %-12@ WER %5.1f %%  %5.1f s", engine.name as NSString,
                         100 * Double(t.errors) / Double(max(t.words, 1)), t.time))
        }
    }

    static func transcribe(_ whisper: WhisperKit, _ input: [Float], _ config: Config) async throws -> String {
        if config.apple { return Cleaner.applyReplacements(try await transcribeApple(input)) }
        if config.parakeet { return Cleaner.applyReplacements(try await transcribeParakeet(input)) }
        var audio = input
        if config.pad {
            let peak = audio.map(abs).max() ?? 0
            if peak > 0 { let gain = min(0.7 / peak, 30); audio = audio.map { $0 * gain } }
            let silence = [Float](repeating: 0, count: 16_000 / 2)
            audio = silence + audio + silence
        }
        var options = DecodingOptions(
            task: .transcribe, language: "fr", temperature: 0, usePrefillPrompt: true, detectLanguage: false,
            skipSpecialTokens: true, withoutTimestamps: !config.timestamps,
            chunkingStrategy: config.vad ? .vad : nil
        )
        if !config.firstTokenCheck { options.firstTokenLogProbThreshold = nil }
        let vocab = Settings.vocabulary()
        if config.prompt, let tokenizer = whisper.tokenizer, !vocab.isEmpty {
            options.promptTokens = tokenizer.encode(text: " " + vocab.joined(separator: ", ") + ".")
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        let results = try await whisper.transcribe(audioArray: audio, decodeOptions: options)
        return Cleaner.applyReplacements(results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Parakeet TDT 0.6B v3 (NVIDIA), via FluidAudio sur la puce neuronale. Pas d'amorce de vocabulaire.
    static func transcribeParakeet(_ audio: [Float]) async throws -> String {
        guard let parakeet else { return "" }
        var state = TdtDecoderState.make()
        let result = try await parakeet.transcribe(audio, decoderState: &state, language: .french)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Moteur de dictée de macOS 26 (SpeechAnalyzer), avec le vocabulaire comme contexte.
    static func transcribeApple(_ audio: [Float]) async throws -> String {
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "fr_FR"), preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let context = AnalysisContext()
        context.contextualStrings[.general] = Settings.vocabulary()
        try await analyzer.setContext(context)
        let float = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let int16 = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
        let source = pcmBuffer(audio, format: float)
        let buffer = AVAudioPCMBuffer(pcmFormat: int16, frameCapacity: source.frameLength)!
        try AVAudioConverter(from: float, to: int16)!.convert(to: buffer, from: source)
        let collect = Task { () -> String in
            var text = ""
            for try await result in transcriber.results { text += String(result.text.characters) }
            return text
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()
        if let last = try await analyzer.analyzeSequence(stream) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collect.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Dégradations

    /// Locuteur à 1–2 m d'un micro d'ordinateur : réverbération de pièce, niveau faible, bruit de fond.
    static func distant(_ audio: [Float]) -> [Float] {
        var rng = SplitMix(seed: 42)
        let rate = 16_000
        let length = rate * 4 / 10 // réponse de la pièce : 0,4 s
        var rir = [Float](repeating: 0, count: length)
        rir[0] = 1
        for i in (rate / 200)..<length { // réflexions à partir de 5 ms, décroissance RT60 ≈ 0,5 s
            rir[i] = Float(rng.gaussian()) * 0.25 * expf(-6.9 * Float(i) / Float(rate) / 0.5)
        }
        var wet = [Float](repeating: 0, count: audio.count)
        for (i, x) in audio.enumerated() where x != 0 {
            let end = min(length, audio.count - i)
            for k in stride(from: 0, to: end, by: 1) where rir[k] != 0 { wet[i + k] += x * rir[k] }
        }
        let speech = rms(wet)
        var brown: Float = 0
        let noise = (0..<wet.count).map { _ -> Float in // bruit grave (ventilation, rue)
            brown = 0.98 * brown + Float(rng.gaussian()) * 0.2
            return brown + Float(rng.gaussian()) * 0.3
        }
        let noiseGain = speech / max(rms(noise), 1e-9) / powf(10, 12 / 20) // rapport signal/bruit 12 dB
        return zip(wet, noise).map { ($0 + $1 * noiseGain) * 0.08 }
    }

    /// Casque Bluetooth en mode micro (HFP) : bande passante limitée à 4 kHz.
    static func narrowband(_ audio: [Float]) -> [Float] {
        let wide = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let narrow = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8_000, channels: 1, interleaved: false)!
        return convert(convert(audio, from: wide, to: narrow), from: narrow, to: wide)
    }

    // MARK: Chaîne de capture

    /// Reproduit la conversion morceau par morceau d'`AudioRecorder` (48 kHz → 16 kHz, tampons de 0,1 s)
    /// et la compare à une conversion d'un seul bloc : un écart signalerait une perte à la capture.
    static func checkStreamingConversion(_ audio: [Float]) {
        let rate48 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let rate16 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let source = convert(audio, from: rate16, to: rate48)
        let reference = convert(source, from: rate48, to: rate16)

        let converter = AVAudioConverter(from: rate48, to: rate16)!
        var streamed: [Float] = []
        for start in stride(from: 0, to: source.count, by: 4_800) {
            let chunk = Array(source[start..<min(start + 4_800, source.count)])
            let buffer = pcmBuffer(chunk, format: rate48)
            let out = AVAudioPCMBuffer(pcmFormat: rate16, frameCapacity: AVAudioFrameCount(Double(chunk.count) / 3) + 32)!
            var consumed = false
            converter.convert(to: out, error: nil) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true; status.pointee = .haveData; return buffer
            }
            streamed += Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
        }
        // Le flux peut être décalé de quelques échantillons (latence du filtre) : on cherche le meilleur alignement.
        var best = (lag: 0, snr: -Float.infinity)
        for lag in -64...64 {
            var signal: Float = 0, error: Float = 0
            for i in 16_000..<min(reference.count, streamed.count) - 16_000 {
                let d = streamed[i + lag] - reference[i]
                signal += reference[i] * reference[i]; error += d * d
            }
            let snr = 10 * log10f(signal / max(error, 1e-12))
            if snr > best.snr { best = (lag, snr) }
        }
        print(String(format: "Capture : %d échantillons en continu contre %d d'un bloc, décalage %d, fidélité %.1f dB",
                     streamed.count, reference.count, best.lag, best.snr))
    }

    // MARK: Outils

    static func pcmBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }

    static func convert(_ samples: [Float], from: AVAudioFormat, to: AVAudioFormat) -> [Float] {
        let converter = AVAudioConverter(from: from, to: to)!
        let input = pcmBuffer(samples, format: from)
        let out = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: AVAudioFrameCount(Double(samples.count) * to.sampleRate / from.sampleRate) + 64)!
        var consumed = false
        converter.convert(to: out, error: nil) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true; status.pointee = .haveData; return input
        }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }

    static func rms(_ x: [Float]) -> Float { sqrtf(x.reduce(0) { $0 + $1 * $1 } / Float(max(x.count, 1))) }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Distance d'édition au niveau des mots (substitutions + suppressions + insertions).
    static func wordErrors(reference: String, hypothesis: String) -> (Int, Int) {
        let r = words(reference)
        return (editDistance(r, words(hypothesis)), r.count)
    }

    /// Distance d'édition (substitutions + suppressions + insertions) entre deux suites.
    static func editDistance<T: Equatable>(_ r: [T], _ h: [T]) -> Int {
        var row = Array(0...h.count)
        for i in 1...max(r.count, 1) where !r.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in stride(from: 1, through: h.count, by: 1) {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (r[i - 1] == h[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[h.count]
    }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Double {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
        mutating func gaussian() -> Double {
            sqrt(-2 * log(max(next(), 1e-12))) * cos(2 * .pi * next())
        }
    }
}
