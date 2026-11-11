import Foundation

/// Export automatique : chaque dictée ou réunion rangée dans un dossier Murmure lié à un dossier du Mac
/// y est copiée en Markdown (« AAAA-MM-JJ - titre.md »), et la copie est tenue à jour à chaque modification
/// (titre, texte, synthèse, interlocuteurs). Un outil ouvert sur le dossier de l'affaire, Claude Code
/// par exemple, voit ainsi les transcriptions sans rien demander. Les copies ne contiennent que du texte.
enum Exporter {
    private static let queue = DispatchQueue(label: "murmure.export")
    private static var pending: Set<UUID> = []
    private static let delay: TimeInterval = 0.8

    /// Regroupe les modifications rapprochées (frappe dans le texte) en une seule écriture.
    static func schedule(_ id: UUID) {
        queue.async {
            guard pending.insert(id).inserted else { return }
            queue.asyncAfter(deadline: .now() + delay) {
                pending.remove(id)
                DispatchQueue.main.async { sync(id) }
            }
        }
    }

    /// Met la copie en accord avec l'état courant : écrit, renomme ou retire le fichier.
    @MainActor
    static func sync(_ id: UUID) {
        let store = RecordingStore.shared
        guard let recording = store.recording(id) else { return }
        guard recording.progress == nil, !recording.text.isEmpty, !recording.isTrashed,
              let directory = store.folder(recording.folderID)?.exportURL else {
            remove(recording)
            store.setExportedPath(id, nil)
            return
        }
        let target = directory.appendingPathComponent(fileName(recording))
        let content = markdown(recording)
        let previous = recording.exportedPath.map { URL(fileURLWithPath: $0) }
        store.setExportedPath(id, target.path)
        queue.async {
            let fm = FileManager.default
            if let previous, previous != target, fm.fileExists(atPath: previous.path) { try? fm.removeItem(at: previous) }
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try? content.data(using: .utf8)?.write(to: target, options: .atomic)
        }
    }

    /// Retire la copie d'un élément (supprimé, ou sorti d'un dossier lié).
    static func remove(_ recording: Recording) {
        guard let path = recording.exportedPath else { return }
        queue.async { try? FileManager.default.removeItem(atPath: path) }
    }

    /// Recopie tout ce qui est rangé dans un dossier lié (ligne de commande `--resync`).
    @MainActor
    static func syncAll() {
        let store = RecordingStore.shared
        let linked = Set(store.folders.filter { $0.exportPath != nil }.map(\.id))
        for recording in store.recordings where recording.exportedPath != nil || linked.contains(recording.folderID ?? UUID()) {
            sync(recording.id)
        }
    }

    /// Attend la fin des écritures en cours.
    static func flush() { queue.sync {} }

    // MARK: - Contenu

    static func fileName(_ recording: Recording) -> String {
        // Jour local (et non UTC) : une réunion de 0 h 30 reste datée du bon jour.
        let day = recording.date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day().dateSeparator(.dash))
        var title = recording.title.replacingOccurrences(of: #"[/\\:*?"<>|]"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = "Sans titre" }
        return "\(day) - \(title.prefix(80)).md"
    }

    static func markdown(_ recording: Recording) -> String {
        let kind = recording.isMeeting ? "réunion" : "dictée"
        var lines = [
            "---",
            "source: Murmure (\(kind), transcription locale, à vérifier)",
            "murmure_id: \(recording.id.uuidString)",
            "date: \(recording.date.formatted(.iso8601))",
            "duree: \(formatDuration(recording.duration))",
            "---",
            "",
            "# \(recording.title)",
            "",
            "\(recording.date.formatted(date: .long, time: .shortened)) · \(formatDuration(recording.duration)) · \(recording.wordCount) mots",
            "",
        ]
        if let summary = recording.summaries?.last {
            lines += ["## \(summary.template)", "", summary.text, ""]
        }
        lines += ["## Transcription", "", recording.transcript, ""]
        return lines.joined(separator: "\n")
    }
}
