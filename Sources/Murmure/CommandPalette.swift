import AppKit
import SwiftUI

/// Palette ⌘K : une barre pour aller n'importe où, lancer une action ou retrouver une dictée ou une réunion.
/// Les résultats sont groupés (fiche ouverte, actions, aller à, dossiers, dictées et réunions) ; le pied rappelle les touches.
struct CommandPalette: View {
    let current: Route
    let navigate: (Route) -> Void
    let close: () -> Void

    private enum Group: String, CaseIterable {
        case context = "Fiche ouverte", actions = "Actions", go = "Aller à", folders = "Dossiers", recordings = "Dictées et réunions"
    }

    private struct Item: Identifiable {
        let id: String
        let group: Group
        let title: String
        var subtitle: String?
        /// Autres mots qui doivent trouver l'élément (« préférences » pour Réglages).
        var keywords = ""
        let icon: NavIcon
        let run: () -> Void
    }

    @ObservedObject private var store = RecordingStore.shared
    @ObservedObject private var state = AppState.shared
    @State private var query = ""
    @State private var cursor = 0
    @State private var monitor: Any?
    @FocusState private var focused: Bool
    @Namespace private var highlight

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    /// Fiche ouverte : ses actions (renommer, ranger, exporter, e-mail, archiver, corbeille).
    private var contextual: [Item] {
        guard case .recording(let id, _) = current, let recording = store.recording(id), !recording.isTrashed else { return [] }
        var items: [Item] = [
            Item(id: "rename", group: .context, title: "Renommer…", keywords: "titre", icon: "pencil") {
                Modals.shared.ask("Renommer", placeholder: "Titre", initial: recording.title, confirm: "Renommer") {
                    store.rename(recording.id, to: $0)
                }
            },
            Item(id: "word", group: .context, title: "Exporter en Word…", keywords: "docx document", icon: "doc.richtext") { Sharing.exportWord(recording) },
            Item(id: "mail", group: .context, title: "Préparer un e-mail dans \(Connectors.mailApp.shortName)", keywords: "courriel partager envoyer",
                 icon: "envelope") { Sharing.mail(recording) },
            Item(id: "pin", group: .context, title: recording.isPinned ? "Désépingler" : "Épingler", keywords: "épingle favori",
                 icon: .glyph(.star)) { store.setPinned(recording.id, !recording.isPinned) },
            Item(id: "archive", group: .context, title: recording.isArchived ? "Désarchiver" : "Archiver", icon: "archivebox") {
                store.setArchived(recording.id, !recording.isArchived)
            },
            Item(id: "trash", group: .context, title: "Placer dans la corbeille", keywords: "supprimer", icon: "trash") {
                RecordingMenu.trash([recording.id])
                navigate(.list(.all))
            },
        ]
        for project in ClaudeCode.recentProjects {
            items.append(Item(id: "claude-\(project.path)", group: .context, title: "Envoyer dans Claude Code › « \(project.lastPathComponent) »",
                              keywords: "projet claude code envoyer", icon: "arrow.up.right.square") { ClaudeCode.send(recording, to: project) })
        }
        items.append(Item(id: "claude-other", group: .context, title: "Envoyer dans Claude Code…", keywords: "projet dossier claude code envoyer",
                          icon: "arrow.up.right.square") { ClaudeCode.choose(for: recording) })
        for entry in Outbound.entries(for: recording) {
            if case .action(let run) = entry.kind {
                items.append(Item(id: "out-\(entry.title)", group: .context, title: entry.title, keywords: "envoyer partager connecteur",
                                  icon: .symbol(entry.symbol ?? "arrow.up.forward.app"), run: run))
            }
        }
        for folder in store.folders where folder.id != recording.folderID {
            items.append(Item(id: "file-\(folder.id)", group: .context, title: "Ranger dans « \(folder.name) »", keywords: "dossier classer",
                              icon: "folder") { store.setFolder(recording.id, folder.id) })
        }
        return items
    }

    private var actions: [Item] {
        [
            state.meetingStartedAt == nil
                ? Item(id: "meeting", group: .actions, title: "Nouvelle réunion", keywords: "enregistrer démarrer", icon: "record.circle") { AppDelegate.shared?.startMeeting() }
                : Item(id: "stop", group: .actions, title: "Arrêter la réunion", icon: "stop.circle") { AppDelegate.shared?.stopMeeting() },
            Item(id: "import", group: .actions, title: "Importer un enregistrement…", keywords: "fichier audio ouvrir", icon: "square.and.arrow.down") {
                AppDelegate.shared?.chooseRecordingToImport()
            },
        ]
    }

    private var destinations: [Item] {
        [
            Item(id: "home", group: .go, title: "Vos Murmures", keywords: "accueil liste tout", icon: .glyph(.house)) { navigate(.list(.all)) },
            Item(id: "today", group: .go, title: "Aujourd'hui", keywords: "agenda rendez-vous jour", icon: .glyph(.calendar)) { navigate(.list(.today)) },
            Item(id: "pinned", group: .go, title: "Épinglés", keywords: "épingle favoris", icon: .glyph(.star)) { navigate(.list(.pinned)) },
            Item(id: "meetings", group: .go, title: "Réunions", icon: "person.2") { navigate(.list(.meetings)) },
            Item(id: "dictations", group: .go, title: "Dictées", icon: "mic") { navigate(.list(.dictations)) },
            Item(id: "archives", group: .go, title: "Archives", keywords: "archivées archiver anciennes", icon: "archivebox") {
                navigate(.list(.all))
                // L'accueil a le temps d'apparaître avant de passer sur les archives.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { state.commands.send(.showArchives) }
            },
            Item(id: "trashlist", group: .go, title: "Corbeille", keywords: "supprimés restaurer", icon: "trash") { navigate(.list(.trash)) },
            Item(id: "lexicon", group: .go, title: "Lexique", keywords: "raccourcis dictionnaire ajouter un mot termes extraits phrases enregistrées textes corrections vocabulaire mots appris", icon: .glyph(.lexicon)) { navigate(.list(.lexicon)) },
            Item(id: "week", group: .go, title: "Cette semaine", keywords: "chiffres statistiques bilan", icon: .glyph(.bars)) { navigate(.week) },
            Item(id: "names", group: .go, title: "Annuaire des noms", keywords: "dictionnaire contacts agenda orthographe noms propres", icon: .glyph(.dictionary)) { navigate(.names) },
            Item(id: "settings", group: .go, title: "Réglages", keywords: "préférences paramètres options raccourci", icon: .glyph(.sliders)) { navigate(.settings) },
        ]
    }

    private var folders: [Item] {
        store.folders.map { folder in
            Item(id: "folder-\(folder.id)", group: .folders, title: folder.name, subtitle: "Dossier", icon: "folder") {
                navigate(.list(.folder(folder.id)))
            }
        }
    }

    /// Dictées et réunions récentes, ou celles qui contiennent la recherche (titre ou contenu) ; 8 au plus.
    private var recordings: [Item] {
        let folded = foldedForSearch(trimmed)
        return store.recordings
            .filter { !$0.isTrashed && (folded.isEmpty || store.matches($0, folded)) }
            .prefix(folded.isEmpty ? 5 : 8)
            .map { recording in
                Item(id: recording.id.uuidString, group: .recordings, title: recording.title,
                     subtitle: (recording.isMeeting ? "Réunion · " : "Dictée · ") + recording.date.formatted(.dateTime.day().month(.abbreviated)),
                     icon: recording.isMeeting ? "person.2.fill" : "mic") {
                    state.highlight = trimmed
                    navigate(.recording(recording.id, from: .all))
                }
            }
    }

    /// Tout, dans l'ordre des groupes ; sans recherche, les actions et destinations plus les cinq fiches récentes.
    private var results: [Item] {
        let folded = foldedForSearch(trimmed)
        let fixed = contextual + actions + destinations + folders
        let kept = folded.isEmpty ? fixed : fixed.filter { foldedForSearch($0.title + " " + $0.keywords + " " + ($0.subtitle ?? "")).contains(folded) }
        return kept + recordings
    }

    var body: some View {
        let results = results
        ZStack(alignment: .top) {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                    TextField("Aller à, lancer, rechercher…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.ui(16))
                        .focused($focused)
                        .onSubmit { run(results) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Rectangle().fill(Theme.line).frame(height: 1)

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Group.allCases, id: \.rawValue) { group in
                                let members = results.enumerated().filter { $0.element.group == group }
                                if !members.isEmpty {
                                    Text(group.rawValue)
                                        .font(.ui(10, weight: .semibold))
                                        .tracking(0.4)
                                        .foregroundStyle(Theme.muted)
                                        .padding(.horizontal, 10)
                                        .padding(.top, group == results.first?.group ? 4 : 10)
                                        .padding(.bottom, 3)
                                    ForEach(members, id: \.element.id) { index, item in
                                        row(item, active: index == cursor)
                                            .id(index)
                                            .onTapGesture {
                                                cursor = index
                                                run(results)
                                            }
                                            .onHover { inside in
                                                if inside { withAnimation(Motion.quick) { cursor = index } }
                                            }
                                    }
                                }
                            }
                            if results.isEmpty {
                                Text("Aucun résultat")
                                    .font(.ui(13))
                                    .foregroundStyle(Theme.muted)
                                    .padding(20)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 420)
                    .onChange(of: cursor) { _, index in withAnimation(Motion.quick) { proxy.scrollTo(index) } }
                }

                Rectangle().fill(Theme.line).frame(height: 1)
                HStack(spacing: 14) {
                    key("↑↓", "parcourir")
                    key("↵", "ouvrir")
                    key("échap", "fermer")
                    Spacer()
                    Text("⌘K").font(.ui(10)).foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .frame(width: 560)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.bg))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.25), radius: 40, y: 16)
            .padding(.top, 110)
        }
        .onAppear {
            focused = true
            installKeys()
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        .onChange(of: query) { _, _ in cursor = 0 }
    }

    private func key(_ symbol: String, _ meaning: String) -> some View {
        HStack(spacing: 5) {
            Text(symbol)
                .font(.ui(10, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line))
            Text(meaning).font(.ui(11))
        }
        .foregroundStyle(Theme.muted)
    }

    private func row(_ item: Item, active: Bool) -> some View {
        HStack(spacing: 10) {
            IconView(icon: item.icon, size: 13, width: 18).font(.ui(13))
            Text(item.title).font(.ui(13)).lineLimit(1)
            Spacer(minLength: 12)
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.ui(11))
                    .foregroundStyle(active ? Theme.onInverse.opacity(0.7) : Theme.muted)
            }
        }
        .foregroundStyle(active ? Theme.onInverse : Theme.fg)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            if active {
                RoundedRectangle(cornerRadius: 8).fill(Theme.inverse)
                    .matchedGeometryEffect(id: "cursor", in: highlight)
            }
        }
        .contentShape(Rectangle())
    }

    /// Flèches et Échap, interceptées avant le champ de saisie (qui garderait sinon les flèches pour lui).
    private func installKeys() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 125: // ↓
                withAnimation(Motion.quick) { cursor = min(cursor + 1, max(results.count - 1, 0)) }
                return nil
            case 126: // ↑
                withAnimation(Motion.quick) { cursor = max(cursor - 1, 0) }
                return nil
            case 53: // Échap
                close()
                return nil
            default:
                return event
            }
        }
    }

    private func run(_ results: [Item]) {
        guard results.indices.contains(cursor) else { return }
        let item = results[cursor]
        close()
        item.run()
    }
}
