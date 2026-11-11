import Foundation

/// Dictée transcrite pendant la parole, comme Wispr Flow qui envoie le son au serveur au fil de l'eau :
/// au relâchement de la touche, il ne reste presque rien à faire.
/// - À chaque vraie pause (0,6 s de silence après au moins 8 s de parole), le passage est transcrit et figé.
/// - Entre deux pauses, l'audio pas encore figé est transcrit à titre d'essai, en boucle : c'est l'aperçu de
///   la pastille. Dès que l'on se tait, un essai qui s'arrêtait avant la fin de la parole est relancé : au
///   relâchement, l'essai couvre alors toute la parole et devient le texte final, sans rien refaire.
/// - Sinon, au relâchement, seule la fin non figée est transcrite ; l'essai en cours s'interrompt.
/// Chaque passage est amorcé par le contexte du curseur, puis par la fin du texte déjà figé.
/// Quand on se tait assez longtemps après un essai complet, le texte est annoncé (`onPause`) : la relecture par
/// Claude peut partir avant le relâchement (`ReviewAhead`).
final class ProgressiveDictation {
    private let transcriber: Transcriber
    private let read: (Int) -> [Float]
    private var loop: Task<Void, Never>?
    private let pieces = Pieces()

    private static let rate = 16_000
    /// Silence qui fige un passage, et parole minimale avant lui. Couper plus tôt dégrade le texte
    /// (banc --bench-flux sur une vraie dictée de 26 s coupée à 8 s : « en toute sécurité » devenu
    /// « entre ces questions. La sécurité ») : en deçà de 20 s, l'essai porte sur toute la dictée.
    private static let pause = rate * 6 / 10
    private static let minimumPiece = 20 * rate
    /// Silence après lequel le texte est annoncé pour la relecture anticipée : une respiration au milieu d'une
    /// phrase (0,2 à 0,4 s) n'en est pas une, et chaque annonce coûte une demande à Claude.
    private static let announceSilence = rate / 2

    private actor Pieces {
        var end = 0
        var texts: [String] = []
        /// Dernier essai sur l'audio non figé : jusqu'où il va, et ce qu'il a donné.
        var guess: (end: Int, text: String)?
        /// Fin de l'audio de l'essai en cours de transcription.
        var running: Int?
        func add(_ text: String, until index: Int) {
            if !text.isEmpty { texts.append(text) }
            end = index
            guess = nil
        }
        func setGuess(_ text: String, from start: Int, until index: Int) {
            guard start == end else { return } // un passage a été figé entre-temps
            guess = (index, text)
        }
        func setRunning(_ index: Int?) { running = index }
        func reset() { end = 0; texts = []; guess = nil; running = nil }
        func snapshot() -> (end: Int, text: String, guess: (end: Int, text: String)?, running: Int?) {
            (end, texts.reduce("", ProgressiveDictation.join), guess, running)
        }
    }

    init(transcriber: Transcriber, read: @escaping (Int) -> [Float]) {
        self.transcriber = transcriber
        self.read = read
    }

    /// `onPause` reçoit le texte complet quand on se tait après un essai qui couvre toute la parole, nil quand la
    /// parole reprend ensuite. Appelé depuis la boucle, dans l'ordre.
    func start(context: Task<FieldContext?, Never>?, onPause: ((String?) async -> Void)? = nil) {
        loop?.cancel()
        Task { @MainActor in
            AppState.shared.liveText = ""
            AppState.shared.livePending = ""
        }
        loop = Task.detached(priority: .userInitiated) { [transcriber, read, pieces] in
            await pieces.reset()
            let rate = Self.rate
            var guessedUntil = 0
            var restart = false
            // Texte annoncé pour la relecture anticipée, tant que rien n'a été dit depuis.
            var announced: String?
            while !Task.isCancelled {
                // Un essai périmé se relance sans attendre : chaque dixième de seconde compte au relâchement.
                if !restart { try? await Task.sleep(for: .milliseconds(200)) }
                restart = false
                if Task.isCancelled { return }
                let done = await pieces.snapshot()
                let waiting = read(done.end)
                guard waiting.count >= rate / 2 else { continue }
                let levels = Self.levels(waiting)
                let threshold = Self.threshold(levels)
                // Le dernier essai couvre-t-il toute la parole (rien dit depuis) ? Alors c'est le texte final si l'on
                // relâche maintenant, comme dans `finish` ; de même si tout ce qui a été dit est déjà figé.
                let covering = done.guess.flatMap { Self.hasSpeech(Self.levels(read($0.end)), threshold: threshold) ? nil : $0 }
                let final: String? = if let covering { Self.join(done.text, covering.text) }
                    else if !done.text.isEmpty, !Self.hasSpeech(levels, threshold: threshold) { done.text } else { nil }
                if let final {
                    if final != announced, Self.quietTail(levels, threshold: threshold) * Self.frame >= Self.announceSilence {
                        announced = final
                        await onPause?(final)
                    }
                } else if announced != nil {
                    // La parole a repris : le texte annoncé n'est plus le bon.
                    announced = nil
                    await onPause?(nil)
                }
                // Rien à faire sur du silence : si le dernier essai couvre toute la parole, il reste le texte final
                // (au relâchement, rien à attendre ; le texte annoncé à la relecture anticipée ne change pas).
                guard Self.hasSpeech(levels, threshold: threshold), covering == nil else { continue }
                let hint = await Self.hint(context: context, previous: done.text)

                if let cut = Self.pausePoint(levels: levels, threshold: threshold)
                    ?? (waiting.count >= 25 * rate ? Self.quietestPoint(in: waiting, from: 15 * rate, to: 25 * rate) : nil) {
                    // Passage figé. Tâche à part : l'arrêt de la boucle au relâchement ne l'interrompt pas,
                    // `finish` attend ce morceau plutôt que de le refaire. En cas d'échec, il n'est pas
                    // considéré comme fait : la fin le reprendra.
                    let piece = Array(waiting[..<cut])
                    guard let text = try? await Task(operation: { try await transcriber.transcribe(piece, urgent: false, hint: hint) }).value
                    else { return }
                    await pieces.add(text, until: done.end + cut)
                    let confirmed = await pieces.snapshot().text
                    await MainActor.run {
                        AppState.shared.liveText = confirmed
                        AppState.shared.livePending = ""
                    }
                    guessedUntil = 0
                } else if done.end + waiting.count - guessedUntil >= rate / 4 {
                    // Essai sur tout l'audio non figé, interrompu si la transcription finale demande Whisper,
                    // ou si l'on se tait pendant qu'il tourne : il serait périmé, on le relance aussitôt.
                    let until = done.end + waiting.count
                    await pieces.setRunning(until)
                    let attempt = Task { try await transcriber.transcribe(waiting, urgent: false, hint: hint, preemptible: true) }
                    let watcher = Task {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .milliseconds(50))
                            let after = Self.levels(read(until))
                            if Self.hasSpeech(after, threshold: threshold), Self.endsQuiet(after, threshold: threshold) {
                                transcriber.interrupt()
                                return
                            }
                        }
                    }
                    let text = try? await attempt.value
                    watcher.cancel()
                    await pieces.setRunning(nil)
                    guard let text else { guessedUntil = 0; restart = true; continue }
                    await pieces.setGuess(text, from: done.end, until: until)
                    guessedUntil = until
                    await MainActor.run { AppState.shared.livePending = text }
                }
            }
        }
    }

    func cancel() {
        loop?.cancel()
        loop = nil
        transcriber.interrupt()
        Task { @MainActor in AppState.shared.livePending = "" }
    }

    /// Termine : attend le passage figé en cours, puis reprend l'essai s'il couvre toute la parole,
    /// sinon transcrit la fin. Renvoie le texte complet.
    func finish(_ audio: [Float], context: Task<FieldContext?, Never>?) async throws -> String {
        loop?.cancel()
        let threshold = Self.threshold(Self.levels(audio))
        let state = await pieces.snapshot()
        // L'essai en cours couvre toute la parole (commencé après qu'on s'est tu) : on l'attend.
        // Sinon il est périmé : on l'interrompt pour laisser Whisper à la fin.
        let covered = { (index: Int) in index <= audio.count && !Self.hasSpeech(Self.levels(Array(audio[index...])), threshold: threshold) }
        if !(state.running.map(covered) ?? false) { transcriber.interrupt() }
        await loop?.value
        loop = nil
        let done = await pieces.snapshot()
        await pieces.reset()

        if let guess = done.guess, covered(guess.end) {
            if ProcessInfo.processInfo.environment["MURMURE_DEBUG"] != nil { print("[flux] essai repris tel quel") }
            return Self.join(done.text, guess.text)
        }
        let rest = Array(audio[min(done.end, audio.count)...])
        let tail = rest.count > Self.rate * 4 / 10 && Self.hasSpeech(Self.levels(rest), threshold: threshold)
            ? try await transcriber.transcribe(rest, hint: await Self.hint(context: context, previous: done.text))
            : ""
        return Self.join(done.text, tail)
    }

    /// Recolle deux passages : Whisper clôt chaque passage par un point, même au milieu d'une phrase ;
    /// si le suivant commence par une minuscule, ce point est de trop.
    nonisolated static func join(_ first: String, _ second: String) -> String {
        guard !first.isEmpty else { return second }
        guard !second.isEmpty else { return first }
        var first = first
        if second.first?.isLowercase == true, first.hasSuffix("."), !first.hasSuffix("...") { first.removeLast() }
        return first + " " + second
    }

    /// Amorce : termes du contexte ; pour la suite d'une dictée, la fin de ce qui est déjà transcrit
    /// remplace la fin du texte du document.
    private static func hint(context: Task<FieldContext?, Never>?, previous: String) async -> Transcriber.Hint {
        let field = await context?.value
        let terms = field?.terms ?? []
        guard !previous.isEmpty else {
            return Transcriber.Hint(terms: terms, tail: field?.promptTail(characters: 400) ?? "")
        }
        return Transcriber.Hint(terms: terms, tail: String(previous.suffix(400)))
    }

    // MARK: Silences

    /// Tranches de 30 ms.
    private static let frame = rate * 3 / 100

    /// Niveau (moyenne quadratique) de chaque tranche.
    private static func levels(_ audio: [Float]) -> [Float] { SpeechLevels.levels(audio, frame: frame) }

    /// Seuil de parole, calé sur le fond et la voix de l'enregistrement (voir `SpeechLevels`).
    private static func threshold(_ levels: [Float]) -> Float { SpeechLevels.threshold(levels) }

    /// Parole : au moins 90 ms d'affilée au-dessus du seuil (un clic ou un souffle n'en est pas).
    private static func hasSpeech(_ levels: [Float], threshold: Float) -> Bool {
        SpeechLevels.hasSpeech(levels, threshold: threshold)
    }

    /// Les 0,15 dernières secondes sont silencieuses : on vient de se taire (ou de marquer une pause ;
    /// relancer pour rien ne coûte qu'un essai).
    private static func endsQuiet(_ levels: [Float], threshold: Float) -> Bool {
        levels.count >= 5 && levels.suffix(5).allSatisfy { $0 <= threshold }
    }

    /// Nombre de tranches silencieuses à la fin.
    private static func quietTail(_ levels: [Float], threshold: Float) -> Int {
        levels.reversed().prefix { $0 <= threshold }.count
    }

    /// Milieu de la dernière pause assez longue précédée d'assez de parole, ou nil.
    private static func pausePoint(levels: [Float], threshold: Float) -> Int? {
        let needed = pause / frame
        var quiet = 0, loud = 0
        var spoke = false
        var best: Int?
        for (index, level) in levels.enumerated() {
            if level > threshold { quiet = 0; loud += 1 } else { quiet += 1; loud = 0 }
            if loud >= 3 { spoke = true }
            guard spoke, quiet >= needed else { continue }
            let middle = (index + 1 - quiet / 2) * frame
            if middle >= minimumPiece { best = middle }
        }
        return best
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

    /// Le son se termine-t-il par un silence ? (relâchement après s'être tu : inutile d'écouter plus longtemps)
    static func endsInSilence(_ recent: [Float], reference: [Float]) -> Bool {
        let tail = levels(recent)
        guard tail.count >= 4 else { return false }
        return !hasSpeech(Array(tail.suffix(5)), threshold: threshold(levels(reference)))
    }
}
