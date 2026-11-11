import Foundation

/// Aperçu en direct d'un enregistrement (réunion ou dictée). Toutes les 1,5 s, l'audio pas encore figé
/// est re-transcrit et affiché comme provisoire ; passé 20 s, il est coupé dans un silence et figé.
/// Purement indicatif : le texte définitif reste celui du traitement de fin (voix, vocabulaire, mise en forme).
/// Passe après les dictées dans la file de Whisper (urgent: false).
final class LiveTranscriber {
    private let transcriber: Transcriber
    private let read: (Int) -> [Float]
    private var task: Task<Void, Never>?

    init(transcriber: Transcriber, read: @escaping (Int) -> [Float]) {
        self.transcriber = transcriber
        self.read = read
    }

    func start() {
        task?.cancel()
        AppState.shared.liveText = ""
        AppState.shared.livePending = ""
        task = Task.detached(priority: .userInitiated) { [transcriber, read] in
            await Self.run(transcriber: transcriber, read: read)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private static func run(transcriber: Transcriber, read: @escaping (Int) -> [Float]) async {
        let rate = 16_000
        var committed = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1.5))
            if Task.isCancelled { return }
            let chunk = read(committed)
            guard chunk.count >= rate / 2 else { continue }

            if chunk.count >= 20 * rate {
                // Morceau assez long : on le fige, coupé dans un silence entre 12 et 20 s.
                let cut = quietestPoint(in: chunk, from: 12 * rate, to: 20 * rate)
                let text = await transcribe(Array(chunk[..<cut]), with: transcriber)
                if Task.isCancelled { return }
                committed += cut
                await MainActor.run {
                    let state = AppState.shared
                    if !text.isEmpty { state.liveText += (state.liveText.isEmpty ? "" : " ") + text }
                    state.livePending = ""
                }
            } else {
                let text = await transcribe(chunk, with: transcriber)
                if Task.isCancelled { return }
                await MainActor.run { AppState.shared.livePending = text }
            }
        }
    }

    /// Ignore les passages sans parole : Whisper y invente volontiers du texte (« Sous-titrage… »).
    /// Un passage assez fort passe toujours ; plus faible (voix lointaine, sous -48 dBFS), il passe s'il a de la
    /// parole au-dessus de son propre fond.
    private static func transcribe(_ audio: [Float], with transcriber: Transcriber) async -> String {
        let rms = sqrt(audio.reduce(0) { $0 + $1 * $1 } / Float(audio.count))
        let levels = SpeechLevels.levels(audio, frame: 480)
        guard rms > 0.004 || SpeechLevels.hasSpeech(levels, threshold: SpeechLevels.threshold(levels)) else { return "" }
        let text = (try? await transcriber.transcribe(audio, urgent: false)) ?? ""
        return Cleaner.applyCommands(text)
    }

    /// Milieu du passage de 0,2 s le plus calme entre `from` et `to` (indices d'échantillons).
    private static func quietestPoint(in audio: [Float], from: Int, to: Int) -> Int {
        let window = 16_000 / 5
        var best = to
        var quietest = Float.greatestFiniteMagnitude
        var position = from
        while position + window <= min(to, audio.count) {
            var energy: Float = 0
            for i in stride(from: position, to: position + window, by: 4) { energy += audio[i] * audio[i] }
            if energy < quietest { quietest = energy; best = position + window / 2 }
            position += window / 2
        }
        return best
    }
}
