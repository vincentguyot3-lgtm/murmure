import Foundation

/// Relecture anticipée d'une dictée par Claude. La transcription se fait déjà pendant la parole
/// (`ProgressiveDictation`) ; restait, après le relâchement, la relecture par Claude (1,6 s avec Sonnet 5.5).
/// Dès que l'on se tait et que l'essai couvre toute la parole, le texte transcrit part à la relecture ; si l'on
/// relâche sans avoir reparlé et que le texte final est le même, cette relecture (déjà reçue ou en cours) est
/// reprise au lieu d'en demander une nouvelle. Seul du texte part, jamais le son.
/// - Une seule demande en vol par dictée : une nouvelle annule la précédente, la reprise de la parole aussi.
/// - Au plus `limit` demandes par dictée ; au-delà, la relecture se fait au relâchement, comme avant.
/// - Mêmes règles que la relecture ordinaire (`Cleaner.cleanAhead`) : Claude seulement, pas en « Rester hors
///   ligne », même garde-fou ; si Claude ne répond pas, la relecture ordinaire (avec relais local) est refaite.
final class ReviewAhead {
    static let limit = 3

    private let lock = NSLock()
    private var key: String?
    private var task: Task<String?, Never>?
    /// Demandes envoyées depuis le début de la dictée, et si l'une a servi (pour le banc d'essai).
    private(set) var sent = 0
    private(set) var reused = false

    /// Nouvelle dictée : rien en vol, compteur à zéro.
    func reset() {
        lock.withLock {
            task?.cancel()
            task = nil
            key = nil
            sent = 0
            reused = false
        }
    }

    /// Texte annoncé par la dictée (`ProgressiveDictation`, `onPause`) : préparé comme il le sera à la fin, puis
    /// envoyé à la relecture ; nil (la parole reprend) annule la demande en cours.
    func announce(_ raw: String?, context: Task<FieldContext?, Never>?) async {
        guard let raw else { cancel(); return }
        let field = await context?.value.flatMap { $0.isEmpty ? nil : $0 }
        let prepared = await Cleaner.prepare(raw, context: field)
        if prepared.review { propose(prepared.text, context: field) } else { cancel() }
    }

    /// Demande la relecture de ce texte, déjà préparé (`Cleaner.prepare`), sauf si c'est déjà fait.
    func propose(_ text: String, context: FieldContext?) {
        lock.withLock {
            guard text != key else { return }
            task?.cancel()
            task = nil
            key = nil
            guard sent < Self.limit, Cleaner.reviewsAhead(text) else { return }
            sent += 1
            key = text
            task = Task(priority: .userInitiated) { await Cleaner.cleanAhead(text, context: context) }
            Self.debug("relecture demandée (\(sent)/\(Self.limit)) : \(text)")
        }
    }

    /// La parole reprend, ou la dictée est abandonnée : la demande en cours est annulée.
    func cancel() {
        lock.withLock {
            if task != nil { Self.debug("relecture annulée") }
            task?.cancel()
            task = nil
            key = nil
        }
    }

    /// Relecture de la dictée terminée : celle déjà demandée pour exactement ce texte si elle aboutit, sinon la
    /// relecture ordinaire (la demande anticipée, inutile, est annulée avant : jamais deux en vol).
    func review(_ text: String, context: FieldContext?) async -> String {
        let pending: Task<String?, Never>? = lock.withLock {
            defer { task = nil; key = nil }
            guard text == key, let task else { task?.cancel(); return nil }
            return task
        }
        if let pending, let reviewed = await pending.value {
            lock.withLock { reused = true }
            Self.debug("relecture anticipée reprise")
            return reviewed
        }
        return await Cleaner.clean(text, context: context)
    }

    private static func debug(_ message: String) {
        if ProcessInfo.processInfo.environment["MURMURE_DEBUG"] != nil { print("[anticipée] \(message)") }
    }
}
