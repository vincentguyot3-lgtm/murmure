import SwiftUI

/// Actions courantes sur une dictée ou une réunion, partagées par le bouton « … » et le clic droit.
enum RecordingMenu {
    /// Menu « Ranger dans » : les dossiers (le dossier actuel coché), « Nouveau dossier… », et « Retirer du dossier »
    /// quand les éléments sont déjà rangés. Partagé par le menu « … », la colonne Dossier et la barre de sélection.
    static func folderEntries(for ids: [UUID], current: UUID? = nil) -> [MenuEntry] {
        let store = RecordingStore.shared
        var entries: [MenuEntry] = [.header("Ranger dans")]
        for folder in store.folders {
            entries.append(.action(folder.name, checked: current == folder.id, tint: Theme.folderTint(folder.tintIndex)) {
                ids.forEach { store.setFolder($0, folder.id) }
            })
        }
        entries.append(.action("Nouveau dossier…", "plus") {
            Modals.shared.ask("Nouveau dossier", placeholder: "Nom du client ou de l'affaire", confirm: "Créer et ranger") { name in
                let folder = store.createFolder(name)
                ids.forEach { store.setFolder($0, folder.id) }
            }
        })
        if current != nil {
            entries.append(.action("Retirer du dossier", "folder.badge.minus") { ids.forEach { store.setFolder($0, nil) } })
        }
        return entries
    }

    /// Place dans la corbeille et propose d'annuler pendant cinq secondes.
    static func trash(_ ids: some Collection<UUID>) {
        let store = RecordingStore.shared
        let ids = Array(ids)
        guard !ids.isEmpty else { return }
        withAnimation(Motion.quick) { ids.forEach { store.trash($0) } }
        let text = ids.count == 1 ? "Déplacé dans la corbeille" : "\(ids.count) éléments déplacés dans la corbeille"
        Toasts.shared.show(text, action: ("Annuler", {
            withAnimation(Motion.quick) { ids.forEach { store.restore($0) } }
        }))
    }

    /// Menu complet (bouton « … » et clic droit de la liste, « … » de la page d'une réunion ou d'une dictée) :
    /// rangement, puis tout ce qui sort de Murmure, puis archive et corbeille. La page garde en plus « Partager »
    /// (`shareEntries`), raccourci vers la partie centrale.
    static func entries(for recording: Recording, open: (() -> Void)? = nil, onDelete: @escaping () -> Void = {}) -> [MenuEntry] {
        if recording.isTrashed { return trashedEntries(for: recording, onDelete: onDelete) }
        return organizeHead(for: recording, open: open) + [.divider] + shareEntries(for: recording)
            + [.divider] + organizeTail(for: recording, onDelete: onDelete)
    }

    /// Ce qui sort de Murmure : copier, Word, e-mail, Claude Code et les connecteurs sortants.
    static func shareEntries(for recording: Recording) -> [MenuEntry] {
        var entries: [MenuEntry] = []
        if let summary = recording.summaries?.last {
            entries.append(.action("Copier la synthèse", "text.alignleft") { copy(Sharing.plain(summary.text)) })
        }
        entries.append(.action("Copier la transcription", "doc.on.doc") { copy(recording.transcript) })
        if let notes = recording.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            entries.append(.action("Copier les notes", "note.text") { copy(notes) })
        }
        if let proposal = recording.proposal?.trimmingCharacters(in: .whitespacesAndNewlines), !proposal.isEmpty {
            entries.append(.action("Copier la proposition", "envelope.open") { copy(proposal) })
        }
        entries.append(.action("Exporter en Word…", "doc.richtext") { Sharing.exportWord(recording) })
        entries.append(.action("Préparer un e-mail dans \(Connectors.mailApp.shortName)", "envelope") { Sharing.mail(recording) })

        entries.append(.divider)
        entries += ClaudeCode.entries(for: recording)
        let outbound = Outbound.entries(for: recording)
        if !outbound.isEmpty {
            entries.append(.divider)
            entries += outbound
        }
        return entries
    }

    private static func trashedEntries(for recording: Recording, onDelete: @escaping () -> Void) -> [MenuEntry] {
        let store = RecordingStore.shared
        return [
            .action("Restaurer", "arrow.uturn.backward") { store.restore(recording.id) },
            .divider,
            .action("Supprimer définitivement…", "trash") {
                Modals.shared.confirm("Supprimer définitivement « \(recording.title) » ?",
                                      message: "Cette action est irréversible.", confirm: "Supprimer") {
                    store.delete(recording.id)
                    onDelete()
                }
            },
        ]
    }

    /// Ouvrir, renommer, épingler, puis les dossiers.
    private static func organizeHead(for recording: Recording, open: (() -> Void)?) -> [MenuEntry] {
        let store = RecordingStore.shared
        var entries: [MenuEntry] = []
        if let open { entries.append(.action("Ouvrir", "arrow.up.right", open)) }
        entries.append(.action("Renommer…", "pencil") {
            Modals.shared.ask("Renommer", placeholder: "Titre", initial: recording.title, confirm: "Renommer") {
                store.rename(recording.id, to: $0)
            }
        })
        entries.append(.action(recording.isPinned ? "Désépingler" : "Épingler", recording.isPinned ? "star.slash" : "star") {
            store.setPinned(recording.id, !recording.isPinned)
        })
        if recording.status == .summarized {
            let unread = recording.hasUnreadSummary
            entries.append(.action(unread ? "Marquer comme lu" : "Marquer comme non lu", unread ? "circle" : "circle.fill") {
                store.setSummaryUnread(recording.id, !unread)
            })
        }
        entries.append(.divider)
        entries += folderEntries(for: [recording.id], current: recording.folderID)
        return entries
    }

    /// Archiver, puis placer dans la corbeille.
    private static func organizeTail(for recording: Recording, onDelete: @escaping () -> Void) -> [MenuEntry] {
        let store = RecordingStore.shared
        return [
            .action(recording.isArchived ? "Désarchiver" : "Archiver", "archivebox") {
                store.setArchived(recording.id, !recording.isArchived)
            },
            .action("Placer dans la corbeille", "trash") {
                trash([recording.id])
                onDelete()
            },
        ]
    }
}

/// Bouton « … » discret qui ouvre le menu d'actions.
struct ActionsButton: View {
    let recording: Recording
    var open: (() -> Void)?
    var onDelete: () -> Void = {}
    /// Dans la barre du haut de la fiche : même menu que dans la liste, mais sans contour, carré de 28 pt grisé au
    /// survol.
    var inTopBar = false
    @State private var hover = false

    var body: some View {
        PreviewSafeMenuButton {
            RecordingMenu.entries(for: recording, open: open, onDelete: onDelete)
        } label: {
            Image(systemName: "ellipsis")
                .font(.ui(13, weight: .semibold))
                .foregroundStyle(Theme.fg)
                .frame(width: 28, height: inTopBar ? 28 : 26)
                .background {
                    if inTopBar { RoundedRectangle(cornerRadius: 7).fill(hover ? Theme.soft : Color.clear) }
                }
                .contentShape(Rectangle())
                .onHover { inside in withAnimation(Motion.quick) { hover = inside } }
        }
        .help(inTopBar ? "Préparer un e-mail, exporter, copier, ranger, archiver…" : "Actions")
    }
}

/// Copie, export Word et brouillon d'e-mail.
enum Sharing {
    /// Markdown simple → texte brut lisible (titres sans « ## »).
    static func plain(_ markdown: String) -> String {
        markdown.components(separatedBy: "\n")
            .map { $0.hasPrefix("#") ? $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) : $0 }
            .joined(separator: "\n")
    }

    /// Exporte le dernier compte rendu, ou à défaut la transcription.
    static func exportWord(_ recording: Recording) {
        let subtitle = "\(recording.date.formatted(date: .long, time: .shortened)) · \(formatDuration(recording.duration)) · rédigé par Murmure, à vérifier"
        let body = recording.summaries?.last?.text ?? recording.transcript
        DocxExporter.export(title: recording.title, subtitle: subtitle, markdown: body)
    }

    /// Ouvre un brouillon dans la messagerie choisie (le compte rendu s'il existe, sinon la transcription),
    /// adressé aux invités du rendez-vous ; rien n'est envoyé.
    static func mail(_ recording: Recording) {
        let body = recording.summaries?.last.map { plain($0.text) } ?? recording.transcript
        Connectors.compose(to: recording.recipients, subject: recording.title, body: body)
    }
}
