import SwiftUI
import UniformTypeIdentifiers

// MARK: - Thème noir et blanc

extension Color {
    /// Couleur qui suit le mode clair ou sombre du Mac.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        func ns(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light)
        })
    }
}

enum Theme {
    /// Contraste renforcé : réglage de Murmure, ou « Augmenter le contraste » de macOS.
    static var highContrast: Bool {
        UserDefaults.standard.bool(forKey: "highContrast") || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    static let bg = Color.adaptive(light: 0xFFFFFF, dark: 0x0A0A0A)
    static let side = Color.adaptive(light: 0xFFFFFF, dark: 0x000000)
    static let fg = Color.adaptive(light: 0x0A0A0A, dark: 0xFAFAFA)
    static var muted: Color { highContrast ? mutedStrong : mutedSoft }
    static var line: Color { highContrast ? lineStrong : lineSoft }
    static let soft = Color.adaptive(light: 0xF5F5F5, dark: 0x171717)
    /// Inversé (noir sur blanc en clair, blanc sur noir en sombre). Règle de la direction artistique : le noir plein
    /// est réservé à l'action principale de l'écran (`OutlineButtonStyle(prominent:)` : « Nouvelle réunion »,
    /// « Enregistrer ») et à l'occurrence de recherche en cours ; un élément actif prend `selected`.
    static let inverse = fg
    static let onInverse = bg
    /// Élément actif (panneau, `Choice`, bouton Filtres appliqué) : un gris doux, avec le texte en `fg` (`onSelected`).
    /// En contraste renforcé, retour à l'inversion.
    static var selected: Color { highContrast ? inverse : selectedSoft }
    static var onSelected: Color { highContrast ? onInverse : fg }

    private static let mutedSoft = Color.adaptive(light: 0x737373, dark: 0x8A8A8A)
    private static let mutedStrong = Color.adaptive(light: 0x3D3D3D, dark: 0xC7C7C7)
    private static let lineSoft = Color.adaptive(light: 0xE5E5E5, dark: 0x262626)
    private static let lineStrong = Color.adaptive(light: 0x8F8F8F, dark: 0x6B6B6B)
    private static let selectedSoft = Color.adaptive(light: 0xEBEBEB, dark: 0x262626)

    // Seules touches de couleur dans une interface noir et blanc : l'accent (titre « Aujourd'hui », pictogramme
    // de réunion) et les pastilles des dossiers.
    static let accent = Color.adaptive(light: 0x2F5BD6, dark: 0x7A9BFF)
    static let accentSoft = Color.adaptive(light: 0xE8EEFC, dark: 0x15213F)
    /// Surlignage des occurrences de recherche (sauf celle en cours, inversée) : un bleu doux qui reste visible sur le
    /// gris des bulles (`soft`), avec le texte en `fg` (contraste d'environ 12:1 en clair, 9:1 en sombre).
    static let searchMark = Color.adaptive(light: 0xBFD0F8, dark: 0x2A3F7A)
    /// Six teintes de dossier (bleu, orange, vert, violet, ambre, rose), dans l'ordre de `Folder.tintNames`.
    static let folderTints: [Color] = [
        Color.adaptive(light: 0x2F5BD6, dark: 0x7A9BFF), Color.adaptive(light: 0xC2410C, dark: 0xFB923C),
        Color.adaptive(light: 0x0F766E, dark: 0x2DD4BF), Color.adaptive(light: 0x7C3AED, dark: 0xA78BFA),
        Color.adaptive(light: 0xB45309, dark: 0xFBBF24), Color.adaptive(light: 0xBE185D, dark: 0xF472B6),
    ]
    static func folderTint(_ index: Int) -> Color { folderTints[min(max(index, 0), folderTints.count - 1)] }

    /// Couleur du nom d'un interlocuteur dans une transcription : l'accent pour « moi » (`rank` nil), puis, pour les
    /// autres dans l'ordre d'apparition, violet, vert, orange, rose, ambre (teintes voisines écartées), en boucle.
    /// Seul le nom est coloré : les bulles et le texte restent noir sur gris.
    static func speakerTint(_ rank: Int?) -> Color {
        guard let rank else { return accent }
        let order = [3, 2, 1, 5, 4]
        return folderTints[order[((rank % order.count) + order.count) % order.count]]
    }
}

extension String {
    /// « vendredi 30 octobre » → « Vendredi 30 octobre » (sans majuscule au mois, contrairement à `capitalized`).
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Étiquette fine, éventuellement inversée (élément actif) ou en pointillés (à compléter).
/// Taille `.puce` : la rangée sous le titre d'une page (date, durée, dossier…), plus haute et en 12 pt.
struct Tag: View {
    enum Taille { case etiquette, puce }

    let text: String
    var filled = false
    var dashed = false
    var taille = Taille.etiquette

    var body: some View {
        if taille == .puce {
            Text(text).puce(dashed ? .aFaire : .contour)
        } else {
            Text(text)
                .font(.ui(11))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundStyle(filled ? Theme.onInverse : Theme.fg)
                .background(RoundedRectangle(cornerRadius: 5).fill(filled ? Theme.inverse : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(filled ? Theme.inverse : Theme.line,
                                                                        style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 2] : [])))
        }
    }
}

/// Style d'une puce : contour fin (une information), pointillés (ce qui reste à faire : « Ranger », « 2 voix à
/// nommer »), ou fond gris sans contour (un filtre actif, suivi de sa croix).
enum PuceStyle { case contour, aFaire, filtre }

extension View {
    /// Cadre d'une puce : 12 pt, 24 pt de haut, marges 8/3, rayon 6.
    func puce(_ style: PuceStyle = .contour) -> some View {
        font(.ui(12))
            .lineLimit(1)
            .foregroundStyle(style == .aFaire ? Theme.muted : Theme.fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(minHeight: 24 * Settings.uiScale)
            .background(RoundedRectangle(cornerRadius: 6).fill(style == .filtre ? Theme.soft : Color.clear))
            .overlay {
                if style != .filtre || Theme.highContrast {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: style == .aFaire ? [3, 2] : []))
                }
            }
            .fixedSize()
    }
}

/// Bouton contour ; `prominent` pour l'unique bouton plein d'un écran. Désactivé, il s'estompe : un bouton noir
/// plein ne doit pas avoir l'air actif quand il ne l'est pas.
struct OutlineButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(12, weight: prominent ? .medium : .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(prominent ? Theme.onInverse : Theme.fg)
            .background(RoundedRectangle(cornerRadius: 7).fill(prominent ? Theme.inverse : Theme.bg))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(prominent ? Theme.inverse : Theme.line))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.8 : isEnabled ? 1 : 0.4)
            .animation(Motion.quick, value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

// MARK: - Navigation

enum ListFilter: Hashable {
    case all, today, pinned, meetings, dictations, trash, folder(UUID)
    /// Lexique, entrée du panneau : raccourcis, corrections et vocabulaire (voir `ShortcutsView`), pas une liste.
    case lexicon
}

enum Route: Hashable {
    case list(ListFilter)
    case recording(UUID, from: ListFilter)
    /// Annuaire des noms : sous-page de Réglages › Transcription, gardée comme route pour la palette.
    case names
    case settings
    case live
    /// Chiffres de la semaine, ouverts par le sous-titre de l'accueil.
    case week
}

/// Fenêtre principale : panneau de navigation et dossiers à gauche, contenu à droite.
struct MainView: View {
    @State private var route: Route = .list(.all)
    @State private var showsPalette = false
    /// Un fichier audio est en train d'être glissé sur la fenêtre.
    @State private var dropping = false
    @ObservedObject private var state = AppState.shared
    @AppStorage("highContrast") private var highContrast = false
    @AppStorage("uiScale") private var uiScale = 1.0
    @AppStorage("onboarded") private var onboarded = false
    /// « Augmenter le contraste » de macOS, observé pour recolorer la fenêtre dès qu'il change.
    @State private var systemContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast

    /// Panneau gauche et page courante, sans les calques (palette, dialogues, accueil).
    private var window: some View {
        HStack(spacing: 0) {
            Sidebar(route: $route)
                .frame(width: 220 * uiScale)
            Rectangle().fill(Theme.line).frame(width: 1)
            ZStack {
                content
                    .id(pageKey)
                    .transition(Motion.pageTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .id("\(highContrast)-\(systemContrast)-\(uiScale)") // recolore ou redimensionne la fenêtre, sans perdre la page ouverte
        .animation(Motion.page, value: route)
        .background(Theme.bg)
        .foregroundStyle(Theme.fg)
        .tint(Theme.fg)
    }

    /// Identité de la page affichée : les onglets Tout · Réunions · Dictées de l'accueil sont une seule page (le trait
    /// de l'onglet glisse, la recherche et les filtres restent), le reste change de page à chaque route.
    private var pageKey: AnyHashable {
        if case .list(let filter) = route, HomeView.tabs.contains(filter) { return "accueil" }
        return route
    }

    /// Calques, du plus bas au plus haut : palette, dépôt de fichier, accueil du premier lancement, messages, dialogues.
    private var layered: some View {
        window
            .overlay { TwilightSweep() }
            .overlay {
                if showsPalette {
                    CommandPalette(current: route, navigate: { route = $0 }, close: { showsPalette = false })
                        .transition(.opacity)
                }
            }
            .overlay {
                if dropping {
                    DropHint().transition(.opacity)
                }
            }
            .overlay {
                if !onboarded {
                    Onboarding { onboarded = true }
                        .transition(.opacity)
                }
            }
            .overlay { ToastHost() }
            .overlay { ModalHost() }
    }

    var body: some View {
        layered
            .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                Self.importDropped(providers)
                return true
            }
            .animation(Motion.quick, value: dropping)
            .animation(Motion.pop, value: showsPalette)
            .animation(Motion.page, value: onboarded)
            .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
                systemContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            }
            .ignoresSafeArea()
            .frame(minWidth: 1060, minHeight: 600)
        .onChange(of: state.meetingStartedAt) { _, started in
            if started != nil { route = .live } else if route == .live { route = .list(.meetings) }
        }
        .onChange(of: state.openRecording) { _, id in
            guard let id else { return }
            route = .recording(id, from: .meetings)
            state.openRecording = nil
        }
        .onChange(of: route) { _, newRoute in
            // Le surlignage de recherche ne vaut que pour la fiche ouverte depuis les résultats.
            if case .recording = newRoute {} else { state.highlight = "" }
        }
        .onReceive(state.commands) { command in
            switch command {
            case .go(let filter): route = .list(filter)
            case .settings: route = .settings
            case .palette: showsPalette.toggle()
            case .search:
                if case .recording = route, state.transcriptShown {
                    DispatchQueue.main.async { state.commands.send(.findInTranscript) }
                    return
                }
                if case .list = route {} else { route = .list(.all) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { state.commands.send(.focusSearch) }
            case .focusSearch, .findInTranscript, .showArchives: break
            }
        }
    }

    /// Fichiers audio déposés sur la fenêtre : chacun est importé comme une réunion (voir `AppDelegate.importRecordings`).
    private static func importDropped(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    lock.lock(); urls.append(url); lock.unlock()
                } else if let url = item as? URL {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { AppDelegate.shared?.importRecordings(urls) }
    }

    @ViewBuilder private var content: some View {
        switch route {
        case .list(let filter):
            HomeView(filter: filter, go: { route = $0 }) { id in route = .recording(id, from: filter) }
        case .recording(let id, let from):
            RecordingDetail(id: id) { route = .list(from) }
                .id(id)
        case .names:
            SettingsView(subpage: .names) { route = $0 }
        case .settings:
            SettingsView { route = $0 }
        case .live:
            LiveView()
        case .week:
            Page(title: "Cette semaine") { WeekStats() }
        }
    }
}

/// Aperçu en ligne de commande (`--apercu-accueil`) : le panneau gauche et une page, sans défilement
/// (`ImageRenderer` ne dessine pas l'intérieur d'un `ScrollView`).
struct WindowPreview: View {
    let route: Route
    /// Accueil avec des filtres appliqués (archives, dossier) ou des lignes cochées.
    var archived = false
    var folder: UUID?
    var selection: Set<UUID> = []

    var body: some View {
        // Aligné en haut : sinon le panneau descend quand la page dépasse la hauteur de l'image.
        HStack(alignment: .top, spacing: 0) {
            Sidebar(route: .constant(route), scrolls: false)
                .frame(width: 220)
            Rectangle().fill(Theme.line).frame(width: 1)
            Group {
                switch route {
                case .list(let filter): HomeView(filter: filter, scrolls: false, archived: archived, folder: folder, selection: selection) { _ in }
                case .week: Page(title: "Cette semaine", scrolls: false) { WeekStats() }
                case .settings: SettingsView(scrolls: false)
                case .names: SettingsView(subpage: .names, scrolls: false)
                case .live: LiveView(scrolls: false)
                case .recording: Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.fg)
    }
}

/// Voile affiché pendant qu'un fichier est glissé sur la fenêtre.
private struct DropHint: View {
    var body: some View {
        ZStack {
            Theme.bg.opacity(0.85)
            VStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down").font(.ui(28))
                Text("Déposer pour importer l'enregistrement").font(.ui(15, weight: .medium))
                Text("wav, m4a, mp3 ou aiff · transcrit sur ce Mac et traité comme une réunion").font(.ui(12)).foregroundStyle(Theme.muted)
            }
            .padding(36)
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.fg, style: StrokeStyle(lineWidth: 1, dash: [6, 4])))
        }
        .allowsHitTesting(false)
    }
}

private struct Page<Content: View>: View {
    let title: String
    var subtitle: String?
    /// Faux pour l'aperçu en ligne de commande, où un `ScrollView` resterait vide.
    var scrolls = true
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.titre(30))
                    .tracking(-0.3)
                if let subtitle {
                    Text(subtitle).font(.ui(13)).foregroundStyle(Theme.muted)
                }
            }
            .padding(.top, 48)
            .padding(.bottom, 22)
            .colonne()
            if scrolls {
                ScrollView { inner }
            } else {
                inner
            }
        }
    }

    private var inner: some View {
        content
            .padding(.bottom, 36)
            .colonne()
    }
}

// MARK: - Panneau latéral

/// Panneau gauche, réduit à l'essentiel : trois entrées (les réunions et les dictées sont des onglets de l'accueil),
/// les dossiers avec leur « + », puis Réglages et Corbeille sur une ligne. Les outils (Extraits, Cette semaine) passent
/// par la palette ⌘K, et Cette semaine aussi par le sous-titre de l'accueil.
private struct Sidebar: View {
    @Binding var route: Route
    /// Faux pour l'aperçu en ligne de commande (les dossiers sont alors dans une pile simple).
    var scrolls = true
    @ObservedObject private var store = RecordingStore.shared
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var agenda = Agenda.shared
    @ObservedObject private var installer = LocalLLMInstaller.shared
    @Namespace private var nav

    private var activeFilter: ListFilter? {
        switch route {
        case .list(let filter), .recording(_, let filter): return filter
        default: return nil
        }
    }

    /// Le bas du panneau ne parle que s'il y a quelque chose à faire ou qui dure : accessibilité à autoriser, échec,
    /// téléchargement du modèle de rédaction. Le chargement des modèles n'est qu'un petit anneau à côté du logo.
    private var showsStatus: Bool {
        if !state.accessibilityGranted || installer.summary != nil { return true }
        if case .failed = state.modelStatus { return true }
        return false
    }

    private var loading: Bool {
        if case .loading = state.modelStatus { return true }
        return false
    }

    /// Infobulle de la pastille d'« Aujourd'hui » : « 2 rendez-vous à venir », nil s'il n'en reste aucun.
    private var upcoming: String? {
        let count = agenda.remaining.count
        return count == 0 ? nil : "\(count) rendez-vous à venir"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Wordmark()
                if loading {
                    Spinner(size: 8, color: Theme.muted, lineWidth: 1.2)
                        .help("Chargement des modèles…")
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 42)
            .padding(.bottom, 18)

            // « Cette semaine » s'ouvre depuis le sous-titre de l'accueil : « Vos Murmures » reste allumé.
            NavItem(title: "Vos Murmures", icon: .glyph(.house),
                    active: route == .week || (activeFilter.map(HomeView.tabs.contains) ?? false),
                    unread: unread(), namespace: nav) { route = .list(.all) }
            NavItem(title: "Aujourd'hui", icon: .glyph(.calendar), active: activeFilter == .today, signal: upcoming,
                    namespace: nav) { route = .list(.today) }
            NavItem(title: "Épinglés", icon: .glyph(.star), active: activeFilter == .pinned, namespace: nav) { route = .list(.pinned) }
            NavItem(title: "Lexique", icon: .glyph(.lexicon), active: activeFilter == .lexicon, namespace: nav) { route = .list(.lexicon) }
            if state.meetingStartedAt != nil {
                NavItem(title: "En direct", icon: "waveform", active: route == .live, namespace: nav) { route = .live }
                    .transition(Motion.slideTransition(from: .leading))
            }

            HStack(spacing: 4) {
                Text("Dossiers")
                    .font(.ui(11))
                    .foregroundStyle(Theme.muted)
                Spacer(minLength: 4)
                SideIconButton(symbol: "plus", help: "Nouveau dossier", side: 18, font: 11, action: newFolder)
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.top, 20)
            .padding(.bottom, 4)

            if scrolls {
                ScrollView { folderList }
            } else {
                folderList
            }

            Spacer(minLength: 12)

            SideAgenda { route = .list(.today) }
                .padding(.bottom, 10)

            HStack(spacing: 2) {
                SideIconButton(icon: .glyph(.sliders), help: "Réglages (⌘,)",
                               active: route == .settings || route == .names) {
                    route = .settings
                }
                SideIconButton(symbol: "trash", help: "Corbeille (⌘4)", active: activeFilter == .trash) {
                    route = .list(.trash)
                }
                Spacer(minLength: 0)
                AppearanceSwitch()
            }
            .padding(.horizontal, 4)
            if showsStatus {
                StatusLine()
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .transition(.opacity)
            }
            Color.clear.frame(height: 14)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.side)
        .animation(Motion.page, value: state.meetingStartedAt != nil)
        .animation(Motion.quick, value: showsStatus)
        .animation(Motion.quick, value: loading)
    }

    private func newFolder() {
        Modals.shared.ask("Nouveau dossier", placeholder: "Nom du client ou de l'affaire", confirm: "Créer") { name in
            route = .list(.folder(store.createFolder(name).id))
        }
    }

    private var folderList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(store.folders) { folder in
                // Les compteurs des dossiers sont les seuls gardés dans le panneau.
                NavItem(title: folder.name, icon: .symbol("folder"), dot: folder,
                        active: activeFilter == .folder(folder.id), count: count { $0.folderID == folder.id },
                        unread: unread(in: folder.id), namespace: nav, menu: { folderEntries(folder) },
                        onDrop: { ids in ids.forEach { store.setFolder($0, folder.id) } }) {
                    route = .list(.folder(folder.id))
                }
                .previewSafeRightClick { folderEntries(folder) }
            }
        }
    }

    /// Comptes rendus pas encore ouverts (nil s'il n'y en a aucun) : le nombre bleu du panneau.
    private func unread(in folder: UUID? = nil) -> Int? {
        let n = store.unreadCount(in: folder)
        return n > 0 ? n : nil
    }

    /// Éléments actifs (ni archivés ni à la corbeille) qui répondent au critère : les compteurs du panneau.
    private func count(_ keep: (Recording) -> Bool) -> Int? {
        let n = store.recordings.filter { !$0.isArchived && !$0.isTrashed && keep($0) }.count
        return n > 0 ? n : nil
    }

    private func folderEntries(_ folder: Folder) -> [MenuEntry] {
        var entries: [MenuEntry] = [
            .action("Ouvrir", "folder") { route = .list(.folder(folder.id)) },
            .action("Renommer…", "pencil") {
                Modals.shared.ask("Renommer le dossier", placeholder: "Nom", initial: folder.name, confirm: "Renommer") {
                    store.renameFolder(folder.id, to: $0)
                }
            },
            .divider,
            .header("Couleur"),
        ]
        // Les six teintes, pastille devant le nom, la courante cochée.
        for (index, name) in Folder.tintNames.enumerated() {
            entries.append(.action(name, checked: folder.tintIndex == index, tint: Theme.folderTint(index)) { store.setFolderTint(folder.id, index) })
        }
        entries.append(.divider)
        // Copie automatique en Markdown dans un dossier du Mac (celui de l'affaire).
        if let url = folder.exportURL {
            entries.append(.header("Copié dans « \(url.lastPathComponent) »"))
            entries.append(.action("Afficher dans le Finder", "arrow.up.right.square") { NSWorkspace.shared.open(url) })
            entries.append(.action("Changer le dossier du Mac…", "folder.badge.gearshape") { chooseExportFolder(for: folder) })
            entries.append(.action("Ne plus copier", "folder.badge.minus") { store.setFolderExportPath(folder.id, nil) })
        } else {
            entries.append(.action("Copier dans un dossier du Mac…", "folder.badge.gearshape") { chooseExportFolder(for: folder) })
        }
        // Avec Claude ou la transcription en ligne : garder ce dossier sur le Mac (son, synthèses, questions, réécritures).
        if Cleaner.chosen == .claude || OnlineTranscription.isChosen || folder.isLocalOnly {
            entries.append(.action("Jamais en ligne (tout reste sur ce Mac)", "lock.shield", checked: folder.isLocalOnly) {
                store.setFolderLocalOnly(folder.id, !folder.isLocalOnly)
            })
        }
        entries += [
            .divider,
            .action("Supprimer le dossier…", "trash") {
                Modals.shared.confirm("Supprimer le dossier « \(folder.name) » ?",
                                      message: "Ses dictées et réunions sont conservées, simplement retirées du dossier.",
                                      confirm: "Supprimer") {
                    if activeFilter == .folder(folder.id) { route = .list(.all) }
                    store.deleteFolder(folder.id)
                }
            },
        ]
        return entries
    }

    private func chooseExportFolder(for folder: Folder) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Copier ici"
        panel.message = "Chaque dictée ou réunion rangée dans « \(folder.name) » sera copiée en Markdown dans ce dossier, et tenue à jour."
        if let url = folder.exportURL { panel.directoryURL = url }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            store.setFolderExportPath(folder.id, url.path)
        }
    }
}

/// Logo : un M tracé d'un seul trait, comme une onde de voix (entrée plate, deux crêtes, sortie plate).
struct LogoMark: View {
    var height: CGFloat = 18

    var body: some View {
        let glyph = height * 0.62
        LogoShape()
            .stroke(style: StrokeStyle(lineWidth: glyph * 0.25, lineCap: .round, lineJoin: .round))
            .frame(width: glyph * 2.5, height: glyph)
            .padding(glyph * 0.125)
            .frame(height: height)
    }
}

/// Tracé du logo dans son cadre (rapport 5:2), partagé avec l'icône de la barre des menus.
struct LogoShape: Shape {
    func path(in rect: CGRect) -> Path {
        // Coordonnées normalisées, y vers le haut (0 = ligne de base, 1 = crêtes).
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.maxY - y * rect.height) }
        var path = Path()
        path.move(to: p(0, 0))
        path.addCurve(to: p(0.283, 1), control1: p(0.15, 0), control2: p(0.167, 1))
        path.addCurve(to: p(0.5, 0.25), control1: p(0.4, 1), control2: p(0.417, 0.25))
        path.addCurve(to: p(0.717, 1), control1: p(0.583, 0.25), control2: p(0.6, 1))
        path.addCurve(to: p(1, 0), control1: p(0.833, 1), control2: p(0.85, 0))
        return path
    }
}

private struct Wordmark: View {
    var body: some View {
        HStack(spacing: 9) {
            LogoMark(height: 17)
            Text("Murmure.")
                .font(.ui(17, weight: .semibold))
                .tracking(-0.4)
        }
    }
}

/// Élément de navigation (panneau gauche, rail des Réglages) ; le fond gris de l'élément actif (`Theme.selected`,
/// inversé en contraste renforcé) glisse entre les éléments d'un même espace de noms.
/// `icon` est un symbole SF ou un pictogramme maison ; pour un dossier, `dot` met sa pastille de couleur à la place.
/// `count` s'affiche à droite ; `signal` y pose une pastille d'accent avec son infobulle (rendez-vous à venir) ;
/// `menu` donne un « … » au survol ; `onDrop` reçoit les dictées et réunions glissées depuis la liste.
struct NavItem: View {
    let title: String
    let icon: NavIcon
    var dot: Folder?
    let active: Bool
    var muted = false
    var count: Int?
    /// Comptes rendus pas encore ouverts : nombre en bleu, devant le compteur s'il y en a un (« 1 · 3 »).
    var unread: Int?
    var signal: String?
    let namespace: Namespace.ID
    var menu: (() -> [MenuEntry])?
    var onDrop: (([UUID]) -> Void)?
    let action: () -> Void
    @State private var hover = false
    @State private var targeted = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let dot {
                    FolderDot(folder: dot, showsExport: false).frame(width: 16 * Settings.uiScale)
                } else {
                    // Icônes grises au repos : la colonne d'icônes ne pèse plus plus que les libellés.
                    IconView(icon: icon)
                        .foregroundStyle(active ? Theme.onSelected : Theme.muted)
                }
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
                if let menu, hover {
                    MenuButton(entries: menu) {
                        Image(systemName: "ellipsis")
                            .font(.ui(12, weight: .semibold))
                            .frame(width: 20, height: 18)
                            .contentShape(Rectangle())
                    }
                    .help("Actions du dossier")
                    .transition(.opacity)
                } else if unread != nil || count != nil {
                    counter
                } else if let signal {
                    Circle().fill(active && Theme.highContrast ? Theme.onInverse : Theme.accent)
                        .frame(width: 6 * Settings.uiScale, height: 6 * Settings.uiScale)
                        .padding(.trailing, 2)
                        .help(signal)
                }
            }
            .font(.ui(13, weight: active ? .medium : .regular))
            .foregroundStyle(active ? Theme.onSelected : (muted ? Theme.muted : Theme.fg))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                // Un seul surlignage pour tout le panneau : il glisse d'un élément à l'autre.
                if active {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.selected)
                        .matchedGeometryEffect(id: "navSelection", in: namespace)
                } else if hover || targeted {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.soft)
                }
            }
            .overlay {
                if targeted { RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.fg, lineWidth: 1.5) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardFocusRing(radius: 6, inset: 0)
        .onHover { inside in withAnimation(Motion.quick) { hover = inside } }
        .modifier(DropTarget(onDrop: onDrop, targeted: $targeted))
    }

    /// « 3 », « 1 » en bleu, ou « 1 · 3 » : les non-lus d'abord, en bleu, puis le compteur du dossier.
    private var counter: some View {
        let mutedColor = active && Theme.highContrast ? Theme.onInverse.opacity(0.7) : Theme.muted
        let unreadColor = active && Theme.highContrast ? Theme.onInverse : Theme.accent
        var text = Text("")
        if let unread { text = Text("\(unread)").foregroundStyle(unreadColor) }
        if let count {
            text = Text("\(text)\(Text(unread == nil ? "" : " · ").foregroundStyle(mutedColor))\(Text("\(count)").foregroundStyle(mutedColor))")
        }
        return text
            .font(.ui(11, weight: unread == nil ? .regular : .medium))
            .monospacedDigit()
            .help(unread.map { "\($0) compte\($0 > 1 ? "s" : "") rendu\($0 > 1 ? "s" : "") pas encore ouvert\($0 > 1 ? "s" : "")" } ?? "")
    }
}

/// Sélecteur d'apparence du pied de panneau, trois pictogrammes : clair, sombre, comme le Mac. La pastille de la
/// position choisie glisse de l'une à l'autre, et la fenêtre change de mode en crépuscule ou en aube.
private struct AppearanceSwitch: View {
    @AppStorage("appearance") private var appearance = "system"
    @Namespace private var ring
    @State private var hovered: String?

    private static let options: [(value: String, symbol: String, help: String)] = [
        ("light", "sun.max", "Clair"),
        ("dark", "moon", "Sombre"),
        ("system", "circle.lefthalf.filled", "Comme le Mac"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.options, id: \.value) { option in
                let selected = appearance == option.value
                Button {
                    guard !selected else { return }
                    withAnimation(Motion.quick) { appearance = option.value }
                    Appearance.apply(animated: true)
                } label: {
                    Image(systemName: option.symbol)
                        .font(.ui(11))
                        .foregroundStyle(selected ? Theme.onSelected : (hovered == option.value ? Theme.fg : Theme.muted))
                        .frame(width: 22 * Settings.uiScale, height: 22 * Settings.uiScale)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 5).fill(Theme.selected)
                                    .matchedGeometryEffect(id: "apparence", in: ring)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardFocusRing(radius: 5, inset: 0)
                .help(option.help)
                .accessibilityLabel("Apparence : \(option.help)")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .onHover { hovered = $0 ? option.value : (hovered == option.value ? nil : hovered) }
            }
        }
        .padding(2)
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line))
    }
}

/// Petit bouton carré sans contour du panneau (« + » des dossiers, Réglages, Corbeille) : gris, noir au survol,
/// fond `Theme.selected` quand sa page est ouverte.
private struct SideIconButton: View {
    var icon: NavIcon
    let help: String
    var active = false
    var side: CGFloat = 28
    var font: CGFloat = 13
    let action: () -> Void
    @State private var hover = false

    init(symbol: String, help: String, active: Bool = false, side: CGFloat = 28, font: CGFloat = 13, action: @escaping () -> Void) {
        self.init(icon: .symbol(symbol), help: help, active: active, side: side, font: font, action: action)
    }

    init(icon: NavIcon, help: String, active: Bool = false, side: CGFloat = 28, font: CGFloat = 13, action: @escaping () -> Void) {
        self.icon = icon
        self.help = help
        self.active = active
        self.side = side
        self.font = font
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            IconView(icon: icon, size: font + 1, width: font + 2)
                .font(.ui(font))
                .foregroundStyle(active ? Theme.onSelected : (hover ? Theme.fg : Theme.muted))
                .frame(width: side * Settings.uiScale, height: side * Settings.uiScale)
                .background {
                    if active {
                        RoundedRectangle(cornerRadius: 6).fill(Theme.selected)
                    } else if hover {
                        RoundedRectangle(cornerRadius: 6).fill(Theme.soft)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardFocusRing(radius: 6, inset: 0)
        .onHover { inside in withAnimation(Motion.quick) { hover = inside } }
        .help(help)
    }
}

/// Zone de dépôt des lignes glissées, seulement sur les éléments qui acceptent un dépôt (les dossiers).
private struct DropTarget: ViewModifier {
    let onDrop: (([UUID]) -> Void)?
    @Binding var targeted: Bool

    func body(content: Content) -> some View {
        if let onDrop, !StaticPreview.active {
            content.dropDestination(for: String.self) { payloads, _ in
                let ids = payloads.flatMap { $0.split(separator: ",") }.compactMap { UUID(uuidString: String($0)) }
                guard !ids.isEmpty else { return false }
                onDrop(ids)
                return true
            } isTargeted: { inside in
                withAnimation(Motion.quick) { targeted = inside }
            }
        } else {
            content
        }
    }
}

/// Agenda du jour, en bas du panneau : les trois prochains rendez-vous (heure, titre, « dans 12 min » ou la visio),
/// « et 2 autres » au-delà. Un clic ouvre la page Aujourd'hui ; le rond, au survol, programme l'enregistrement à
/// l'heure (ou enregistre tout de suite un rendez-vous commencé). Rien sans rendez-vous à venir ni accès à l'agenda.
private struct SideAgenda: View {
    let openToday: () -> Void
    @ObservedObject private var agenda = Agenda.shared
    @ObservedObject private var state = AppState.shared

    static let shown = 3

    var body: some View {
        let events = agenda.remaining
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text("Agenda du jour").font(.ui(11)).foregroundStyle(Theme.muted)
                    Spacer(minLength: 4)
                    SideIconButton(symbol: "chevron.right", help: "Ouvrir la page Aujourd'hui", side: 18, font: 10, action: openToday)
                }
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .padding(.bottom, 4)

                ForEach(events.prefix(Self.shown), id: \.id) { event in
                    SideEvent(event: event, openToday: openToday)
                }
                if events.count > Self.shown {
                    let more = events.count - Self.shown
                    Button(action: openToday) {
                        Text("et \(more) autre\(more > 1 ? "s" : "")")
                            .font(.ui(11))
                            .foregroundStyle(Theme.muted)
                            .padding(.leading, 12 + (SideEvent.timeWidth + 8) * Settings.uiScale)
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardFocusRing(radius: 4)
                }
            }
            .transition(.opacity)
            .animation(Motion.quick, value: events.map(\.id))
        }
    }
}

/// Un rendez-vous du panneau : heure, titre, puis « dans 12 min · Teams » (le délai en bleu s'il est imminent).
private struct SideEvent: View {
    let event: CalendarEvent
    let openToday: () -> Void
    @ObservedObject private var agenda = Agenda.shared
    @ObservedObject private var state = AppState.shared
    @State private var hover = false

    /// Colonne de l'heure (« 17:30 »), reprise par « et 2 autres » pour s'aligner sous les titres.
    static let timeWidth: CGFloat = 40

    private var underway: Bool { event.isUnderway(at: agenda.now) }
    private var scheduled: Bool { state.scheduledMeeting?.id == event.id }

    /// « dans 12 min », « dans 2 h », « en cours » ; `soon` : commence dans moins d'un quart d'heure, ou a commencé.
    private var relative: (text: String, soon: Bool)? {
        guard let start = event.start else { return nil }
        let minutes = Int((start.timeIntervalSince(agenda.now) / 60).rounded(.up))
        if minutes <= 0 { return ("en cours", true) }
        if minutes < 60 { return ("dans \(minutes) min", minutes < 15) }
        return nil
    }

    private var detail: Text {
        var parts: [Text] = []
        if let relative { parts.append(Text(relative.text).foregroundStyle(relative.soon ? Theme.accent : Theme.muted)) }
        if scheduled { parts.append(Text("enregistré à l'heure").foregroundStyle(Theme.muted)) }
        let place = event.service ?? event.location
        if let place, !place.isEmpty { parts.append(Text(place).foregroundStyle(Theme.muted)) }
        guard var line = parts.first else { return Text("") }
        for part in parts.dropFirst() { line = Text("\(line)\(Text(" · ").foregroundStyle(Theme.muted))\(part)") }
        return line
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(event.start?.formatted(date: .omitted, time: .shortened) ?? "")
                .font(.ui(12, weight: .medium))
                .monospacedDigit()
                .fixedSize()
                .frame(width: SideEvent.timeWidth * Settings.uiScale, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if let origin = event.origin {
                        Circle().fill(origin.color)
                            .frame(width: 5 * Settings.uiScale, height: 5 * Settings.uiScale)
                            .help("Agenda \(origin.label)")
                    }
                    Text(event.title).font(.ui(12)).lineLimit(1)
                }
                detail.font(.ui(11)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
        .background { if hover { RoundedRectangle(cornerRadius: 6).fill(Theme.soft) } }
        .contentShape(Rectangle())
        .onTapGesture(perform: openToday)
        .onHover { inside in withAnimation(Motion.quick) { hover = inside } }
        .help(event.detail.isEmpty ? event.title : "\(event.title) · \(event.detail)")
        .animation(Motion.quick, value: scheduled)
    }

    /// Le rond d'enregistrement : toujours là (en bleu) quand l'enregistrement est programmé, sinon au survol.
    /// Rien pendant une réunion.
    @ViewBuilder private var action: some View {
        if state.meetingStartedAt != nil {
            EmptyView()
        } else if scheduled {
            SideIconButton(symbol: "record.circle.fill", help: "Enregistrement programmé · cliquer pour annuler", side: 20, font: 11) {
                AppDelegate.shared?.cancelScheduledMeeting()
            }
            .foregroundStyle(Theme.accent)
        } else if hover {
            SideIconButton(symbol: "record.circle",
                           help: underway ? "Enregistrer maintenant, avec le titre et les invités du rendez-vous"
                                          : "Enregistrer à l'heure : la réunion démarrera seule à \(event.start?.formatted(date: .omitted, time: .shortened) ?? "l'heure du rendez-vous")",
                           side: 20, font: 11) {
                if underway { AppDelegate.shared?.startMeeting(event: event) } else { AppDelegate.shared?.scheduleMeeting(event) }
            }
            .transition(.opacity)
        }
    }
}

/// Bas du panneau : seulement ce qui demande une action ou qui dure (accessibilité à autoriser, échec, téléchargement
/// du modèle de rédaction). Une fois tout prêt, rien n'est affiché : le micro ne s'ouvre que pendant la dictée.
private struct StatusLine: View {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var installer = LocalLLMInstaller.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !state.accessibilityGranted {
                Button(action: SystemSettings.requestAccessibility) {
                    Label("Autoriser l'accessibilité", systemImage: "exclamationmark.triangle")
                }
                .buttonStyle(.plain)
                .keyboardFocusRing(radius: 4, inset: -4)
            }
            if let status {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").font(.ui(10))
                    Text(status).lineLimit(2)
                }
                .foregroundStyle(Theme.muted)
            }
            // Premier lancement : le modèle de rédaction (plusieurs gigaoctets) se télécharge pendant que la dictée
            // fonctionne déjà, avec la seule transcription.
            if let download = installer.summary {
                HStack(spacing: 6) {
                    Spinner(size: 8, color: Theme.muted, lineWidth: 1.2)
                    Text("Téléchargement du modèle de rédaction · \(download)").lineLimit(2)
                }
                .foregroundStyle(Theme.muted)
            }
        }
        .font(.ui(11))
    }

    /// Échec du chargement des modèles (le chargement lui-même n'est qu'un anneau à côté du logo).
    private var status: String? {
        if case .failed(let reason) = state.modelStatus { return reason }
        return nil
    }
}

// MARK: - Accueil

/// Accueil et listes (Aujourd'hui, Épinglés, dossiers, corbeille), dans la colonne commune : titre en serif et
/// « Nouvelle réunion », carte du prochain rendez-vous, une barre (onglets Tout · Réunions · Dictées sur l'accueil,
/// recherche, Filtres), puis la liste groupée par jour, sans cadre ni colonnes. Les outils n'apparaissent qu'au
/// survol : case à cocher à la place du pictogramme, « Ranger », « … ».
private struct HomeView: View {
    /// Onglets de l'accueil : trois routes, une seule page (voir `MainView.pageKey`).
    static let tabs: [ListFilter] = [.all, .meetings, .dictations]

    let filter: ListFilter
    /// Faux pour l'aperçu en ligne de commande : la liste est une pile simple.
    var scrolls: Bool
    /// Change de page : onglets de l'accueil, lien « cette semaine » du sous-titre.
    let go: (Route) -> Void
    let open: (UUID) -> Void

    @ObservedObject private var store = RecordingStore.shared
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var agenda = Agenda.shared
    @State private var search = ""
    /// Recherche effectivement appliquée : suit `search` avec 150 ms de retard, pour ne pas filtrer à chaque lettre.
    @State private var query = ""
    @State private var archived: Bool
    @State private var kind: RecordingKind?
    @State private var status: Recording.Status?
    @State private var folderFilter: UUID?
    @State private var sort = SortKey.date
    @State private var ascending = false
    @State private var selection: Set<UUID>
    /// Ligne repérée au clavier (flèches, Entrée, Espace, ⌫).
    @State private var cursor: UUID?
    /// Dernière ligne cochée à la souris : point de départ d'un ⇧-clic.
    @State private var anchor: UUID?
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    /// `archived`, `folder`, `selection` : état de départ, pour les aperçus en ligne de commande.
    init(filter: ListFilter, scrolls: Bool = true, archived: Bool = false, folder: UUID? = nil, selection: Set<UUID> = [],
         go: @escaping (Route) -> Void = { _ in }, open: @escaping (UUID) -> Void) {
        self.filter = filter
        self.scrolls = scrolls
        self.go = go
        self.open = open
        _archived = State(initialValue: archived)
        _folderFilter = State(initialValue: folder)
        _selection = State(initialValue: selection)
    }

    private var isTrash: Bool { filter == .trash }
    /// Lexique : la recherche reste, mais filtre les raccourcis ; ni liste, ni filtres, ni sélection.
    private var isShortcuts: Bool { filter == .lexicon }
    private var isHome: Bool { Self.tabs.contains(filter) }
    private var isFolder: Bool {
        if case .folder = filter { return true }
        return false
    }

    private var title: String {
        switch filter {
        case .all, .meetings, .dictations: return UserProfile.current.greeting
        case .lexicon: return "Lexique"
        case .today: return "Aujourd'hui"
        case .pinned: return "Épinglés"
        case .trash: return "Corbeille"
        case .folder(let id): return store.folder(id)?.name ?? "Dossier"
        }
    }

    /// Le filtre « Type » n'a de sens que là où réunions et dictées sont mêlées sans onglets.
    private var showsKindFilter: Bool { !isHome }

    /// Le filtre « Dossier » n'a pas de sens dans un dossier.
    private var showsFolderFilter: Bool {
        if case .folder = filter { return false }
        return !store.folders.isEmpty
    }

    private var items: [Recording] {
        guard !isShortcuts else { return [] }
        let folded = foldedForSearch(query)
        let kept = store.recordings.filter { recording in
            switch filter {
            case .all, .trash: break
            case .lexicon: return false
            case .today: guard Calendar.current.isDateInToday(recording.date) else { return false }
            case .pinned: guard recording.isPinned else { return false }
            case .meetings: guard recording.isMeeting else { return false }
            case .dictations: guard !recording.isMeeting else { return false }
            case .folder(let id): guard recording.folderID == id else { return false }
            }
            if recording.isTrashed != isTrash { return false }
            if !isTrash, recording.isArchived != archived { return false }
            if showsKindFilter, let kind, (recording.kind ?? .dictation) != kind { return false }
            if let status, recording.status != status { return false }
            if showsFolderFilter, let folderFilter, recording.folderID != folderFilter { return false }
            return folded.isEmpty || store.matches(recording, folded)
        }
        return sorted(kept)
    }

    /// L'historique est déjà du plus récent au plus ancien ; les autres tris se font ici.
    private func sorted(_ items: [Recording]) -> [Recording] {
        switch sort {
        case .date: return ascending ? items.reversed() : items
        case .title: return items.sorted { ascending ? $0.title.localizedStandardCompare($1.title) == .orderedAscending
                                                     : $0.title.localizedStandardCompare($1.title) == .orderedDescending }
        case .status:
            let order = Recording.Status.allCases
            return items.sorted {
                let a = order.firstIndex(of: $0.status) ?? 0, b = order.firstIndex(of: $1.status) ?? 0
                return ascending ? a < b : a > b
            }
        }
    }

    /// « 3 réunions et 12 dictées cette semaine »
    private var weekSummary: String {
        let week = store.recordings.filter {
            !$0.isArchived && !$0.isTrashed && Calendar.current.isDate($0.date, equalTo: Date(), toGranularity: .weekOfYear)
        }
        let meetings = week.filter(\.isMeeting).count
        let dictations = week.count - meetings
        var parts: [String] = []
        if meetings > 0 { parts.append("\(meetings) réunion\(meetings > 1 ? "s" : "")") }
        if dictations > 0 { parts.append("\(dictations) dictée\(dictations > 1 ? "s" : "")") }
        return parts.isEmpty ? "rien cette semaine pour l'instant" : "\(parts.joined(separator: " et ")) cette semaine"
    }

    /// « Vendredi 31 octobre »
    private var todayText: String {
        agenda.now.formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalizedFirst
    }

    private var subtitle: String? {
        switch filter {
        case .all, .meetings, .dictations: return nil // sous-titre avec lien, voir `subtitleView`
        case .lexicon: return "Ce que Murmure sait de vous."
        case .today: return todayText
        case .pinned: return "Dictées et réunions gardées sous la main."
        case .trash: return "Supprimés définitivement 30 jours après leur mise à la corbeille."
        case .folder: return nil
        }
    }

    // MARK: Filtres

    /// Filtres appliqués (archives comprises) : le nombre affiché sur « Filtres ».
    private var activeFilters: Int {
        [archived && !isTrash, showsKindFilter && kind != nil, status != nil, showsFolderFilter && folderFilter != nil]
            .filter { $0 }.count
    }

    /// Le tri n'est plus visible que dans « Filtres » : une puce le rappelle quand il n'est pas celui par défaut.
    private var sortChanged: Bool { sort != .date || ascending }

    private var sortLabel: String {
        switch sort {
        case .date: return "Tri : du plus ancien"
        case .title: return ascending ? "Tri : titre" : "Tri : titre, de Z à A"
        case .status: return ascending ? "Tri : statut, inversé" : "Tri : statut"
        }
    }

    private func clearFilters() {
        withAnimation(Motion.quick) {
            archived = false
            kind = nil
            status = nil
            folderFilter = nil
        }
    }

    /// Un seul menu à rubriques : Afficher (actives ou archivées), Type (hors accueil), Statut, Dossier, Trier par.
    private func filterEntries() -> [MenuEntry] {
        var entries: [MenuEntry] = []
        func section(_ title: String) {
            if !entries.isEmpty { entries.append(.divider) }
            entries.append(.header(title))
        }
        if !isTrash {
            section("Afficher")
            entries.append(.action("Actives", "tray", checked: !archived) { archived = false })
            entries.append(.action("Archivées", "archivebox", checked: archived) { archived = true })
        }
        if showsKindFilter {
            section("Type")
            entries.append(.action("Réunions", "person.2", checked: kind == .meeting) { kind = kind == .meeting ? nil : .meeting })
            entries.append(.action("Dictées", "mic", checked: kind == .dictation) { kind = kind == .dictation ? nil : .dictation })
        }
        section("Statut")
        for option in Recording.Status.allCases {
            entries.append(.action(option.rawValue, checked: status == option) { status = status == option ? nil : option })
        }
        if showsFolderFilter {
            section("Dossier")
            for folder in store.folders {
                entries.append(.action(folder.name, checked: folderFilter == folder.id, tint: Theme.folderTint(folder.tintIndex)) {
                    folderFilter = folderFilter == folder.id ? nil : folder.id
                })
            }
        }
        section("Trier par")
        for (key, label) in [(SortKey.date, "Date"), (.title, "Titre"), (.status, "Statut")] {
            entries.append(.action(label, checked: sort == key) {
                withAnimation(Motion.quick) { sort = key; ascending = key == .title }
            })
        }
        entries.append(.action(ascending ? "Ordre décroissant" : "Ordre croissant", "arrow.up.arrow.down") {
            withAnimation(Motion.quick) { ascending.toggle() }
        })
        if activeFilters > 0 {
            entries.append(.divider)
            entries.append(.action("Tout effacer", "xmark") { clearFilters() })
        }
        return entries
    }

    // MARK: Page

    var body: some View {
        let items = items // calculé une fois par rendu
        return VStack(alignment: .leading, spacing: 0) {
            header(items).colonne()

            // Le prochain rendez-vous n'est plus en tête de l'accueil : l'agenda du jour est en bas du panneau.
            if filter == .today {
                TodayEvents().padding(.top, 22).colonne()
            }

            toolbar(count: items.count).padding(.top, 22).colonne()
            if !isShortcuts, activeFilters > 0 || sortChanged {
                filterChips.padding(.top, 8).colonne().transition(.opacity)
            }

            Group {
                if isShortcuts {
                    if scrolls {
                        ScrollView { ShortcutsView(query: query).padding(.top, 8).padding(.bottom, 36).colonne() }
                    } else {
                        ShortcutsView(query: query).padding(.top, 8).colonne()
                    }
                } else if items.isEmpty {
                    EmptyList(kind: emptyKind).colonne()
                } else {
                    Table(items: items, selection: $selection, cursor: cursor, query: query, trash: isTrash, scrolls: scrolls,
                          sort: sort, grouped: filter != .today, inFolder: isFolder, toggle: toggle, click: { click($0, in: items) }, open: openItem)
                }
            }
            .padding(.top, 14)
        }
        .animation(Motion.quick, value: agenda.next)
        .animation(Motion.quick, value: activeFilters)
        .padding(.bottom, 12)
        // Barre d'actions flottante dès qu'une ligne est cochée.
        .overlay(alignment: .bottom) {
            if !selection.isEmpty {
                SelectionBar(selection: $selection, archivedView: archived, trashView: isTrash)
                    .padding(.bottom, 20)
                    .transition(Motion.slideTransition(from: .bottom))
            }
        }
        .animation(Motion.pop, value: selection.isEmpty)
        // Navigation au clavier dans la liste ; le champ de recherche garde ses touches tant qu'il a le focus.
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { keyboard { moveCursor(1) } }
        .onKeyPress(.upArrow) { keyboard { moveCursor(-1) } }
        .onKeyPress(.return) {
            guard let cursor else { return .ignored }
            return keyboard { openItem(cursor) }
        }
        .onKeyPress(.space) {
            guard let cursor else { return .ignored }
            return keyboard { toggle(cursor) }
        }
        // ⌘A coche toute la liste (Édition › Tout sélectionner, ou la touche si le menu ne la prend pas).
        .onKeyPress(keys: ["a"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            return keyboard { selectAll() }
        }
        .onCommand(#selector(NSText.selectAll(_:))) { if !searchFocused, !isShortcuts { selectAll() } }
        .onKeyPress(.delete) {
            let ids = selection.isEmpty ? Set([cursor].compactMap { $0 }) : selection
            guard !ids.isEmpty else { return .ignored }
            return keyboard {
                if isTrash {
                    Modals.shared.confirm("Supprimer définitivement \(ids.count) élément\(ids.count > 1 ? "s" : "") ?",
                                          message: "Cette action est irréversible.", confirm: "Supprimer") {
                        ids.forEach { store.delete($0) }
                        selection = []
                    }
                } else {
                    RecordingMenu.trash(ids)
                    selection = []
                    cursor = nil
                }
            }
        }
        .onReceive(state.commands) { command in
            switch command {
            case .focusSearch: searchFocused = true
            case .showArchives: withAnimation(Motion.quick) { archived = true }
            default: break
            }
        }
        .onAppear { listFocused = true }
        .onChange(of: archived) { _, _ in selection = []; cursor = nil }
        // Les onglets de l'accueil gardent la page (recherche et filtres compris) : seule la sélection repart à zéro.
        .onChange(of: filter) { _, _ in selection = []; cursor = nil; anchor = nil }
        .onChange(of: search) { _, _ in cursor = nil }
        .task(id: search) {
            // Anti-rebond : la liste se filtre 150 ms après la dernière frappe.
            if search.isEmpty { query = ""; return }
            try? await Task.sleep(for: .milliseconds(150))
            if !Task.isCancelled { query = search }
        }
    }

    /// Titre en serif et sous-titre ; à droite, « Nouvelle réunion » seul (ou « Vider la corbeille… »). Importer
    /// (⌘O, dépôt d'un fichier), la palette (⌘K) et la densité (Réglages › Affichage) restent hors de l'en-tête.
    private func header(_ items: [Recording]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.titre(30))
                    .tracking(-0.3)
                    .lineLimit(2)
                subtitleView
            }
            Spacer(minLength: 12)
            Group {
                if isTrash {
                    Button("Vider la corbeille…") {
                        Modals.shared.confirm("Vider la corbeille ?",
                                              message: "Tous les éléments de la corbeille seront supprimés définitivement.",
                                              confirm: "Vider") {
                            store.purgeTrash(all: true)
                        }
                    }
                    .buttonStyle(OutlineButtonStyle())
                    .keyboardFocusRing()
                    .disabled(items.isEmpty)
                } else {
                    MeetingButton()
                }
            }
            .padding(.top, 4)
        }
        .padding(.top, 48)
    }

    /// Sur l'accueil, « Lundi 2 novembre · 1 réunion et 2 dictées cette semaine », la seconde partie menant aux chiffres
    /// de la semaine (l'ancienne entrée « Cette semaine » du panneau).
    @ViewBuilder private var subtitleView: some View {
        if isHome {
            HStack(spacing: 0) {
                Text("\(todayText) · ").foregroundStyle(Theme.muted)
                TextLink(text: weekSummary, help: "Voir les chiffres de la semaine") { go(.week) }
            }
            .font(.ui(13))
        } else if case .folder(let id) = filter, let url = store.folder(id)?.exportURL {
            // Dossier relié à un dossier du Mac : on le dit, et un clic l'ouvre dans le Finder.
            HStack(spacing: 0) {
                Text("Copié dans ").foregroundStyle(Theme.muted)
                TextLink(text: "« \(url.lastPathComponent) »", help: "Afficher dans le Finder") { NSWorkspace.shared.open(url) }
            }
            .font(.ui(13))
        } else if let subtitle {
            Text(subtitle).font(.ui(13)).foregroundStyle(Theme.muted)
        }
    }

    /// Onglets de l'accueil (sans filet, sur la même ligne), ou le nombre d'éléments ailleurs ; puis la recherche et
    /// « Filtres », calés à droite.
    private func toolbar(count: Int) -> some View {
        HStack(spacing: 8) {
            if isHome {
                TextTabs(options: [(ListFilter.all, "Tout"), (.meetings, "Réunions"), (.dictations, "Dictées")],
                         selection: Binding(get: { filter }, set: { go(.list($0)) }), filet: false, ecart: 6)
                    .padding(.top, 6)
            } else {
                // Sans onglets, un compteur discret occupe la gauche de la ligne.
                Text(isShortcuts ? Lexicon.shared.summary : "\(count) élément\(count > 1 ? "s" : "")")
                    .font(.ui(12)).monospacedDigit().foregroundStyle(Theme.muted)
                    .contentTransition(.numericText())
                Spacer(minLength: 0)
            }
            searchField
            if !isShortcuts {
                FiltersButton(count: activeFilters, entries: filterEntries)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.ui(11)).foregroundStyle(Theme.muted)
            if StaticPreview.active {
                Text("Rechercher").foregroundStyle(Theme.muted).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("Rechercher", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit {
                        cursor = items.first?.id
                        listFocused = true
                    }
                    .onExitCommand {
                        search = ""
                        listFocused = true
                    }
            }
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
                .keyboardFocusRing(radius: 4, inset: -3)
            } else if !searchFocused {
                Text("⌘F").font(.ui(11)).foregroundStyle(Theme.muted)
            }
        }
        .font(.ui(12))
        .padding(.horizontal, 10)
        .frame(width: 210 * Settings.uiScale, height: 30 * Settings.uiScale)
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(searchFocused ? Theme.fg : Theme.line))
    }

    /// Puces des filtres appliqués, sous la barre : un clic retire le filtre.
    private var filterChips: some View {
        FlowLayout(spacing: 6) {
            if archived, !isTrash { FilterChip(label: "Archivées") { archived = false } }
            if showsKindFilter, let kind {
                FilterChip(label: "Type : \(kind == .meeting ? "réunions" : "dictées")") { self.kind = nil }
            }
            if let status { FilterChip(label: "Statut : \(status.rawValue.lowercased())") { self.status = nil } }
            if showsFolderFilter, let folder = store.folder(folderFilter) {
                FilterChip(label: "Dossier : \(folder.name)", folder: folder) { folderFilter = nil }
            }
            if sortChanged {
                FilterChip(label: sortLabel) { sort = .date; ascending = false }
            }
        }
    }

    enum SortKey { case title, date, status }

    private var emptyKind: EmptyList.Kind {
        if !search.isEmpty || (showsKindFilter && kind != nil) || status != nil || (showsFolderFilter && folderFilter != nil) {
            return .results
        }
        if isTrash { return .trash }
        if archived { return .archive }
        switch filter {
        case .folder: return .folder
        case .today: return .today
        case .pinned: return .pinned
        default: return .home
        }
    }

    // MARK: Clavier et souris

    /// Exécute une commande clavier de la liste, sauf quand on tape dans le champ de recherche.
    private func keyboard(_ action: () -> Void) -> KeyPress.Result {
        guard !searchFocused, !isShortcuts else { return .ignored }
        action()
        return .handled
    }

    /// Clic sur une ligne : ⌘-clic coche ou décoche, ⇧-clic coche jusqu'à la dernière ligne cochée, sinon ouvre.
    private func click(_ id: UUID, in items: [Recording]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            toggle(id)
        } else if flags.contains(.shift) {
            let ids = items.map(\.id)
            guard let end = ids.firstIndex(of: id) else { return }
            let start = (anchor ?? cursor).flatMap { ids.firstIndex(of: $0) } ?? end
            withAnimation(Motion.quick) { selection.formUnion(ids[min(start, end)...max(start, end)]) }
            anchor = id
        } else {
            openItem(id)
        }
    }

    private func toggle(_ id: UUID) {
        withAnimation(Motion.quick) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        }
        anchor = id
    }

    private func selectAll() {
        withAnimation(Motion.quick) { selection = Set(items.map(\.id)) }
    }

    private func openItem(_ id: UUID) {
        state.highlight = search.trimmingCharacters(in: .whitespaces)
        open(id)
    }

    private func moveCursor(_ step: Int) {
        let ids = items.map(\.id)
        guard !ids.isEmpty else { return }
        if let cursor, let index = ids.firstIndex(of: cursor) {
            self.cursor = ids[min(max(index + step, 0), ids.count - 1)]
        } else {
            cursor = step > 0 ? ids.first : ids.last
        }
    }
}

/// Lien dans une phrase : texte en `fg` souligné d'un filet gris, souligné en noir au survol.
private struct TextLink: View {
    let text: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .underline(true, color: hover ? Theme.fg : Theme.line)
                .foregroundStyle(Theme.fg)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardFocusRing(radius: 4, inset: -3)
        .onHover { inside in withAnimation(Motion.quick) { hover = inside } }
        .help(help)
    }
}

/// Bouton « Filtres », sans cadre : Afficher (actives ou archivées), Type, Statut, Dossier et tri dans un seul menu.
/// Appliqué, il devient « Filtres · 2 » sur fond `Theme.selected`.
private struct FiltersButton: View {
    let count: Int
    let entries: () -> [MenuEntry]
    @State private var hover = false

    var body: some View {
        PreviewSafeMenuButton(entries: entries) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").font(.ui(11))
                Text(count > 0 ? "Filtres · \(count)" : "Filtres").monospacedDigit()
            }
            .font(.ui(12, weight: count > 0 ? .medium : .regular))
            .foregroundStyle(count > 0 ? Theme.onSelected : Theme.fg)
            .padding(.horizontal, 10)
            .frame(height: 30 * Settings.uiScale)
            .background {
                if count > 0 {
                    RoundedRectangle(cornerRadius: 7).fill(Theme.selected)
                } else if hover {
                    RoundedRectangle(cornerRadius: 7).fill(Theme.soft)
                }
            }
            .contentShape(Rectangle())
            .onHover { inside in withAnimation(Motion.quick) { hover = inside } }
        }
        .help("Archives, type, statut, dossier, tri")
    }
}

/// Puce d'un filtre appliqué : fond gris sans contour, suivi d'une croix ; un clic l'ôte.
private struct FilterChip: View {
    let label: String
    var folder: Folder?
    let remove: () -> Void

    var body: some View {
        Button { withAnimation(Motion.quick) { remove() } } label: {
            HStack(spacing: 6) {
                if let folder { FolderDot(folder: folder, showsExport: false) }
                Text(label)
                Image(systemName: "xmark").font(.ui(9, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            .puce(.filtre)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardFocusRing(radius: 6)
        .help("Retirer ce filtre")
    }
}

/// Le prochain rendez-vous (accueil) ou un rendez-vous du jour (page Aujourd'hui), en carte grise : à gauche
/// « À venir » au-dessus de l'heure ; au centre le titre, puis la pastille de l'agenda d'origine, « Google Meet ·
/// 3 invités » ou le lieu, et le délai (« dans 25 min », en accent à moins d'un quart d'heure) ; à droite, le bouton
/// pour l'enregistrer (tout de suite s'il a commencé, sinon à l'heure).
private struct EventLine: View {
    let event: CalendarEvent
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var agenda = Agenda.shared

    private var over: Bool { event.isOver(at: agenda.now) }
    private var underway: Bool { event.isUnderway(at: agenda.now) }

    private var overline: String { over ? "Terminé" : underway ? "En cours" : "À venir" }

    /// « dans 25 min », « dans 2 h », « depuis 5 min » ; `soon` : commence dans moins d'un quart d'heure, ou a commencé.
    private var relative: (text: String, soon: Bool)? {
        guard !over, let start = event.start else { return nil }
        let minutes = Int((start.timeIntervalSince(agenda.now) / 60).rounded(.up))
        if minutes <= 0 { return ("depuis \(Self.span(max(1, -minutes)))", true) }
        return ("dans \(Self.span(minutes))", minutes < 15)
    }

    private static func span(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 || hours >= 3 ? "\(hours) h" : "\(hours) h \(String(format: "%02d", rest))"
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text(overline).font(.ui(11)).foregroundStyle(Theme.muted)
                Text(event.start?.formatted(date: .omitted, time: .shortened) ?? "")
                    .font(.ui(17, weight: .medium))
                    .monospacedDigit()
            }
            .frame(minWidth: 54 * Settings.uiScale, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.ui(13, weight: .medium)).lineLimit(1)
                HStack(spacing: 6) {
                    if let origin = event.origin {
                        Circle().fill(origin.color)
                            .frame(width: 6 * Settings.uiScale, height: 6 * Settings.uiScale)
                            .help("Agenda \(origin.label)")
                    }
                    detail.font(.ui(12)).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if over {
                EmptyView()
            } else if state.meetingStartedAt != nil {
                Text("Réunion en cours").font(.ui(11)).foregroundStyle(Theme.muted)
            } else if underway {
                Button("Enregistrer") { AppDelegate.shared?.startMeeting(event: event) }
                    .buttonStyle(OutlineButtonStyle(prominent: true))
                    .keyboardFocusRing()
                    .help("Lance la réunion maintenant, avec le titre et les invités du rendez-vous")
            } else if state.scheduledMeeting?.id == event.id {
                Button("Programmé · Annuler") { AppDelegate.shared?.cancelScheduledMeeting() }
                    .buttonStyle(OutlineButtonStyle())
                    .keyboardFocusRing()
                    .help("La réunion démarrera seule à l'heure du rendez-vous ; cliquez pour annuler")
            } else {
                Button("Enregistrer à l'heure") { AppDelegate.shared?.scheduleMeeting(event) }
                    .buttonStyle(OutlineButtonStyle())
                    .keyboardFocusRing()
                    .help("La réunion démarrera seule à \(event.start?.formatted(date: .omitted, time: .shortened) ?? "l'heure du rendez-vous"), avec son titre et ses invités")
            }
        }
        .opacity(over ? 0.6 : 1)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.soft))
        .overlay { if Theme.highContrast { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line) } }
        .animation(Motion.quick, value: state.scheduledMeeting?.id)
    }

    /// « Google Meet · 3 invités · dans 2 h », le délai en accent quand le rendez-vous est imminent.
    private var detail: Text {
        let base = event.detail
        guard let relative else { return Text(base).foregroundStyle(Theme.muted) }
        let lead = base.isEmpty ? "" : base + " · "
        return Text("\(Text(lead).foregroundStyle(Theme.muted))\(Text(relative.text).foregroundStyle(relative.soon ? Theme.accent : Theme.muted))")
    }
}

/// Page Aujourd'hui : les rendez-vous à venir du jour, chacun dans sa carte ; les rendez-vous terminés se résument
/// en une ligne repliée. Sans autorisation d'agenda, la carte le dit et propose de l'accorder.
private struct TodayEvents: View {
    @ObservedObject private var agenda = Agenda.shared
    @State private var authorized = Connectors.calendarAuthorized
    @State private var showsPast = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !authorized, agenda.sample == nil {
                HStack(spacing: 12) {
                    Image(systemName: "calendar.badge.exclamationmark").font(.ui(13))
                    Text("Murmure n'a pas accès à l'agenda du Mac : autorisez-le pour voir vos rendez-vous du jour ici.")
                        .font(.ui(12)).foregroundStyle(Theme.muted)
                    Spacer(minLength: 12)
                    Button("Autoriser…") {
                        Connectors.requestCalendar { granted in
                            authorized = Connectors.calendarAuthorized
                            agenda.refresh()
                            if !granted { SystemSettings.open(.calendars) }
                        }
                    }
                    .buttonStyle(OutlineButtonStyle(prominent: true))
                    .keyboardFocusRing()
                }
                .card()
            } else if agenda.today.isEmpty {
                Text(agenda.sample == nil && Connectors.activeCalendars.isEmpty
                     ? "Aucun agenda n'est coché : choisissez-les dans Réglages › Connecteurs › Agenda."
                     : "Aucun rendez-vous aujourd'hui dans l'agenda.")
                    .font(.ui(12)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
            } else {
                ForEach(agenda.remaining, id: \.id) { event in EventLine(event: event) }
                let past = agenda.today.filter { $0.isOver(at: agenda.now) }
                if !past.isEmpty {
                    Button { withAnimation(Motion.quick) { showsPast.toggle() } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.ui(9, weight: .semibold))
                                .rotationEffect(.degrees(showsPast ? 90 : 0))
                            Text("\(past.count) rendez-vous terminé\(past.count > 1 ? "s" : "") : \(past.map(\.title).joined(separator: ", "))")
                                .lineLimit(1)
                        }
                        .font(.ui(12))
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 4)
                        .padding(.top, agenda.remaining.isEmpty ? 0 : 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardFocusRing(radius: 4)
                    if showsPast {
                        ForEach(past, id: \.id) { event in EventLine(event: event) }
                            .transition(.opacity)
                    }
                }
            }
        }
        .onAppear { authorized = Connectors.calendarAuthorized; agenda.refresh() }
    }
}

private extension View {
    /// Carte grise des messages de la page Aujourd'hui, aux mesures de la carte d'un rendez-vous.
    func card() -> some View {
        padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.soft))
            .overlay { if Theme.highContrast { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line) } }
    }
}

/// Capsule inversée en bas de la liste quand des lignes sont cochées : « 3 sélectionnés · Ranger · Archiver · Corbeille · ✕ ».
private struct SelectionBar: View {
    @Binding var selection: Set<UUID>
    let archivedView: Bool
    var trashView = false
    @ObservedObject private var store = RecordingStore.shared

    var body: some View {
        HStack(spacing: 4) {
            Text("\(selection.count) sélectionné\(selection.count > 1 ? "s" : "")")
                .font(.ui(12, weight: .semibold))
                .padding(.leading, 8)
                .padding(.trailing, 6)
                .monospacedDigit()
            divider
            if trashView {
                action("Restaurer", "arrow.uturn.backward") {
                    let ids = selection
                    withAnimation(Motion.quick) { ids.forEach { store.restore($0) } }
                    selection = []
                }
                action("Supprimer définitivement", "trash") {
                    let ids = selection
                    Modals.shared.confirm("Supprimer définitivement \(ids.count) élément\(ids.count > 1 ? "s" : "") ?",
                                          message: "Cette action est irréversible.", confirm: "Supprimer") {
                        ids.forEach { store.delete($0) }
                        selection = []
                    }
                }
            } else {
                PreviewSafeMenuButton(entries: folderEntries) { label("Ranger", "folder") }
                action(archivedView ? "Désarchiver" : "Archiver", "archivebox") {
                    let ids = selection
                    ids.forEach { store.setArchived($0, !archivedView) }
                    selection = []
                }
                action("Corbeille", "trash") {
                    RecordingMenu.trash(selection)
                    selection = []
                }
            }
            divider
            Button { withAnimation(Motion.quick) { selection = [] } } label: {
                Image(systemName: "xmark")
                    .font(.ui(11, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardFocusRing(radius: 6, inset: 0, color: Theme.onInverse)
            .help("Tout décocher")
        }
        .foregroundStyle(Theme.onInverse)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.inverse))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
    }

    private var divider: some View {
        Rectangle().fill(Theme.onInverse.opacity(0.25)).frame(width: 1, height: 16).padding(.horizontal, 4)
    }

    private func label(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.ui(11))
            Text(title)
        }
        .font(.ui(12, weight: .medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private func action(_ title: String, _ symbol: String, run: @escaping () -> Void) -> some View {
        Button(action: run) { label(title, symbol) }
            .buttonStyle(.plain)
            .keyboardFocusRing(radius: 6, inset: 0, color: Theme.onInverse)
    }

    private func folderEntries() -> [MenuEntry] { RecordingMenu.folderEntries(for: Array(selection)) }
}

struct MeetingButton: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        Group {
            if let started = state.meetingStartedAt {
                HStack(spacing: 8) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        HStack(spacing: 6) {
                            Circle().fill(Theme.fg).frame(width: 7, height: 7)
                                .opacity(!Motion.blinks || Int(context.date.timeIntervalSince(started)) % 2 == 0 ? 1 : 0.3)
                            Text(elapsed(since: started, now: context.date)).monospacedDigit()
                        }
                        .font(.ui(13, weight: .medium))
                    }
                    Button("Arrêter") { AppDelegate.shared?.stopMeeting() }
                        .buttonStyle(OutlineButtonStyle(prominent: true))
                        .keyboardFocusRing()
                    Button { cancel(started) } label: { Image(systemName: "xmark") }
                        .buttonStyle(OutlineButtonStyle())
                        .keyboardFocusRing()
                        .help("Annuler sans rien garder")
                }
            } else {
                Button { AppDelegate.shared?.startMeeting() } label: {
                    Label("Nouvelle réunion", systemImage: "record.circle")
                }
                .buttonStyle(OutlineButtonStyle(prominent: true))
                .keyboardFocusRing()
            }
        }
        .animation(Motion.quick, value: state.meetingStartedAt != nil)
    }

    /// Le ✕ est à deux doigts d'« Arrêter » et jette tout l'audio : au-delà d'une minute, il demande confirmation.
    private func cancel(_ started: Date) {
        guard Date().timeIntervalSince(started) > 60 else { AppDelegate.shared?.cancelMeeting(); return }
        Modals.shared.confirm("Abandonner la réunion en cours ?",
                              message: "L'enregistrement (\(elapsed(since: started, now: Date()))) sera perdu : rien ne sera transcrit ni conservé. "
                                  + "Pour garder la réunion, choisissez plutôt « Arrêter ».",
                              confirm: "Abandonner") { AppDelegate.shared?.cancelMeeting() }
    }

    private func elapsed(since start: Date, now: Date) -> String {
        let s = Int(now.timeIntervalSince(start))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// Liste vide : un message différent selon l'endroit (recherche, corbeille, archives, dossier, accueil).
struct EmptyList: View {
    enum Kind { case results, trash, archive, folder, home, today, pinned }
    let kind: Kind

    private var icon: NavIcon {
        switch kind {
        case .results: return "magnifyingglass"
        case .trash: return "trash"
        case .archive: return "archivebox"
        case .folder: return "folder"
        case .home: return "waveform"
        case .today: return .glyph(.calendar)
        case .pinned: return .glyph(.star)
        }
    }

    private var title: String {
        switch kind {
        case .results: return "Aucun résultat"
        case .trash: return "La corbeille est vide"
        case .archive: return "Aucune archive"
        case .folder: return "Ce dossier est vide"
        case .home: return "Rien ici pour l'instant"
        case .today: return "Rien aujourd'hui pour l'instant"
        case .pinned: return "Aucune fiche épinglée"
        }
    }

    private var detail: String? {
        switch kind {
        case .results: return "Essayez un autre mot, ou retirez un filtre."
        case .trash: return nil
        case .archive: return "Archivez une dictée ou une réunion depuis son menu « … » : elle quittera la liste sans être supprimée."
        case .folder: return "Glissez une ligne de la liste sur ce dossier, ou choisissez-le dans le menu « … » de la ligne."
        case .home, .today: return "Maintenez \(Settings.dictationKey.label) pour dicter, ou lancez une nouvelle réunion."
        case .pinned: return "Épinglez une dictée ou une réunion depuis son menu « … » : elle restera ici, sous la main."
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            IconView(icon: icon, size: 30, width: 36)
                .font(.ui(30, weight: .light))
                .foregroundStyle(Theme.muted)
            Text(title).font(.ui(15, weight: .medium))
            if let detail {
                Text(detail)
                    .font(.ui(12))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Case à cocher noir et blanc.
private struct Checkbox: View {
    let checked: Bool
    var partial = false
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            RoundedRectangle(cornerRadius: 4)
                .fill(checked || partial ? Theme.inverse : Theme.bg)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(checked || partial ? Theme.inverse : Theme.muted, lineWidth: 1))
                .overlay {
                    if checked || partial {
                        Image(systemName: checked ? "checkmark" : "minus")
                            .font(.ui(9, weight: .bold))
                            .foregroundStyle(Theme.onInverse)
                    }
                }
                .frame(width: 15, height: 15)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardFocusRing(radius: 4, inset: -3)
        .activatesOnReturn(toggle)
    }
}

/// Une période de la liste : Aujourd'hui, Hier, chacun des sept derniers jours (« Jeudi 29 octobre »), « Plus tôt en
/// novembre », puis un mois. `byDay` : la colonne de droite montre l'heure plutôt que la date.
private struct DateSection: Identifiable {
    let title: String
    var byDay = false
    var items: [Recording]
    var id: String { title }

    /// Regroupe des éléments déjà triés du plus récent au plus ancien.
    static func group(_ items: [Recording], now: Date = Date()) -> [DateSection] {
        var sections: [DateSection] = []
        for recording in items {
            let (title, byDay) = Self.title(for: recording.date, now: now)
            if sections.last?.title == title {
                sections[sections.count - 1].items.append(recording)
            } else {
                sections.append(DateSection(title: title, byDay: byDay, items: [recording]))
            }
        }
        return sections
    }

    static func title(for date: Date, now: Date = Date()) -> (String, Bool) {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return ("Aujourd'hui", true) }
        if calendar.isDateInYesterday(date) { return ("Hier", true) }
        // Les sept derniers jours gardent leur nom (« Samedi 31 octobre »), même d'une semaine ou d'un mois à l'autre.
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), date >= weekAgo {
            return (date.formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalizedFirst, true)
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .month) {
            return ("Plus tôt en \(date.formatted(.dateTime.month(.wide)))", false)
        }
        let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
        return ((sameYear ? date.formatted(.dateTime.month(.wide)) : date.formatted(.dateTime.month(.wide).year())).capitalizedFirst, false)
    }
}

/// La liste : des lignes posées sur le fond, sans cadre, sans en-têtes de colonnes ni filets, groupées par jour quand
/// elle est triée par date. Le défilement occupe toute la largeur ; les lignes restent dans la colonne commune.
private struct Table: View {
    let items: [Recording]
    @Binding var selection: Set<UUID>
    let cursor: UUID?
    let query: String
    var trash = false
    /// Faux pour l'aperçu en ligne de commande : pile simple à la place du défilement.
    var scrolls = true
    let sort: HomeView.SortKey
    /// Faux sur la page Aujourd'hui, où un seul groupe « Aujourd'hui » redirait le titre de la page.
    var grouped = true
    /// Dans un dossier, les lignes ne répètent pas son nom (il reste au survol, pour changer de dossier).
    var inFolder = false
    let toggle: (UUID) -> Void
    let click: (UUID) -> Void
    let open: (UUID) -> Void

    /// Les périodes (Aujourd'hui, Hier…) n'ont de sens que triées par date.
    private var sections: [DateSection] {
        grouped && sort == .date ? DateSection.group(items) : [DateSection(title: "", items: items)]
    }

    /// Ce qu'une ligne emporte quand on la glisse : elle-même, ou toute la sélection si elle en fait partie.
    private func dragPayload(_ id: UUID) -> String {
        (selection.contains(id) ? selection : [id]).map(\.uuidString).joined(separator: ",")
    }

    var body: some View {
        if scrolls {
            ScrollViewReader { proxy in
                ScrollView {
                    rows.colonne().padding(.bottom, selection.isEmpty ? 24 : 72) // place pour la barre de sélection
                }
                .onChange(of: cursor) { _, id in
                    guard let id else { return }
                    withAnimation(Motion.quick) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        } else {
            rows.colonne()
        }
    }

    private var rows: some View {
        let sections = sections
        // Le titre de la période reste en haut pendant le défilement.
        return LazyVStack(alignment: .leading, spacing: 2, pinnedViews: .sectionHeaders) {
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                Section {
                    ForEach(section.items) { recording in
                        Row(recording: recording,
                            selected: selection.contains(recording.id),
                            selecting: !selection.isEmpty,
                            focused: cursor == recording.id,
                            query: query,
                            trash: trash,
                            byDay: section.byDay,
                            inFolder: inFolder,
                            toggle: { toggle(recording.id) },
                            click: { click(recording.id) }) { open(recording.id) }
                            .draggable(dragPayload(recording.id))
                            .id(recording.id)
                    }
                } header: {
                    if !section.title.isEmpty {
                        SectionHeader(title: section.title, count: section.items.count, first: index == 0)
                    }
                } footer: {
                    if index < sections.count - 1 { Color.clear.frame(height: 12) }
                }
            }
        }
        .animation(Motion.quick, value: items.map(\.id))
    }
}

/// Titre de période, en 13 medium suivi du nombre en gris ; seul « Aujourd'hui » prend la couleur d'accent.
private struct SectionHeader: View {
    let title: String
    let count: Int
    var first = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.ui(13, weight: .medium))
                .foregroundStyle(title == "Aujourd'hui" ? Theme.accent : Theme.fg)
            Text("\(count)").font(.ui(12)).monospacedDigit().foregroundStyle(Theme.muted)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, first ? 0 : 8)
        .padding(.bottom, 4)
        .background(Theme.bg)
    }
}

/// Une ligne : pictogramme (ou case à cocher, au survol et dès qu'une ligne est cochée), titre et sous-titre où se
/// fond le statut quand il dit quelque chose, dossier en pastille, heure ou date, « … » au survol.
private struct Row: View {
    let recording: Recording
    let selected: Bool
    /// Au moins une ligne est cochée : toutes les lignes montrent leur case.
    let selecting: Bool
    let focused: Bool
    let query: String
    var trash = false
    /// Dans un groupe-jour, l'heure ; sinon la date courte (« 31 oct. »).
    var byDay = false
    var inFolder = false
    let toggle: () -> Void
    let click: () -> Void
    let open: () -> Void
    @State private var hover = false
    @AppStorage("compactList") private var compact = false

    private var revealed: Bool { hover || focused }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if selected || selecting || hover {
                    Checkbox(checked: selected, toggle: toggle)
                        .help("Cocher (⌘-clic)")
                        .transition(.opacity)
                } else {
                    Image(systemName: recording.isMeeting ? "person.2.fill" : "mic")
                        .font(.ui(13))
                        .foregroundStyle(recording.isMeeting ? Theme.accent : Theme.muted)
                        .transition(.opacity)
                }
            }
            .frame(width: 26 * Settings.uiScale, height: 26 * Settings.uiScale)
            // Compte rendu prêt, pas encore ouvert : point bleu dans la marge, comme un courriel non lu.
            .overlay(alignment: .leading) {
                if recording.hasUnreadSummary, !trash {
                    Circle().fill(Theme.accent)
                        .frame(width: 7 * Settings.uiScale, height: 7 * Settings.uiScale)
                        .offset(x: -8 * Settings.uiScale)
                        .help("Compte rendu pas encore ouvert")
                        .accessibilityLabel("Non lu")
                        .transition(.opacity)
                }
            }
            .animation(Motion.quick, value: recording.hasUnreadSummary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(highlighted(recording.title, query)).font(.ui(14, weight: .medium)).lineLimit(1)
                    if recording.isPinned {
                        GlyphView(glyph: .star, size: 10, lineWidth: 1.1).foregroundStyle(Theme.muted)
                            .help("Épinglée")
                    }
                }
                subtitleLine.font(.ui(12)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if trash, revealed {
                    // Dans la corbeille, le dossier ne se change pas ; « Restaurer » prend sa place au survol.
                    Button("Restaurer") { withAnimation(Motion.quick) { RecordingStore.shared.restore(recording.id) } }
                        .buttonStyle(OutlineButtonStyle())
                        .keyboardFocusRing()
                } else if !inFolder || revealed {
                    FolderCell(recording: recording, editable: !trash, ligne: true, revealed: revealed)
                }
            }
            .frame(maxWidth: 150 * Settings.uiScale, alignment: .trailing)

            Text(dateText)
                .font(.ui(12))
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .frame(width: 50 * Settings.uiScale, alignment: .trailing)

            // « … » réservé à sa place pour qu'aucune ligne ne bouge, visible seulement au survol ou sous le curseur.
            ActionsButton(recording: recording, open: open)
                .frame(width: 26)
                .opacity(revealed ? 1 : 0)
                .allowsHitTesting(revealed)
                // Invisible, il ne doit pas non plus être un arrêt de tabulation ni être annoncé.
                .focusable(revealed)
                .accessibilityHidden(!revealed)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, compact ? 5 : 9)
        // Trois états distincts : survol (fond), curseur clavier (fond et contour), sélection (case cochée et fond).
        .background(RoundedRectangle(cornerRadius: 9).fill(hover || focused || selected ? Theme.soft : Color.clear))
        .overlay {
            if focused { RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.muted) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: click)
        .onHover { inside in withAnimation(Motion.quick) { hover = inside } }
        .previewSafeRightClick { RecordingMenu.entries(for: recording, open: open) }
    }

    /// « Réunion · 45 min · 2 interlocuteurs », puis le statut seulement s'il apprend quelque chose : « synthèse
    /// prête » (seul segment en noir), « sans contenu », « expire dans 3 h ». En cours : l'anneau et la progression.
    /// Pendant une recherche, l'extrait trouvé remplace le sous-titre quand le mot n'est pas dans le titre.
    @ViewBuilder private var subtitleLine: some View {
        if let snippet {
            Text(highlighted(snippet, query))
        } else if recording.status == .processing {
            HStack(spacing: 6) {
                Spinner(size: 10, color: Theme.muted, lineWidth: 1.3)
                Text(recording.progress?.replacingOccurrences(of: "…", with: "") ?? recording.status.rawValue)
            }
        } else {
            Text("\(Text(subtitle))\(Text(statusNote).foregroundStyle(Theme.fg))\(Text(tail))")
        }
    }

    private var statusNote: String { recording.status == .summarized ? " · synthèse prête" : "" }

    /// Dictée à durée limitée (réglage « Garder les dictées ») : « expire dans 3 h » ; rien pour une dictée gardée.
    private var tail: String {
        var tail = recording.status == .empty ? " · sans contenu" : ""
        if !trash, let expiresIn = recording.expiresIn { tail += " · expire \(expiresIn)" }
        return tail
    }

    private var subtitle: String {
        var parts = [recording.isMeeting ? "Réunion" : "Dictée", formatDuration(recording.duration)]
        if recording.speakerCount >= 2 { parts.append("\(recording.speakerCount) interlocuteurs") }
        if !recording.isMeeting, let app = recording.appName { parts.append("dans \(app)") }
        if let deleted = recording.deletedAt {
            let left = max(0, 30 - Int(Date().timeIntervalSince(deleted) / 86_400))
            parts.append(left == 0 ? "supprimée aujourd'hui" : "encore \(left) jour\(left > 1 ? "s" : "")")
        }
        return parts.joined(separator: " · ")
    }

    /// Extrait autour de la première occurrence recherchée, quand elle n'est pas dans le titre.
    private var snippet: String? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        guard !query.isEmpty, recording.title.range(of: query, options: options) == nil else { return nil }
        let haystack = recording.transcript
        guard let range = haystack.range(of: query, options: options) else { return nil }
        let start = haystack.index(range.lowerBound, offsetBy: -40, limitedBy: haystack.startIndex) ?? haystack.startIndex
        let end = haystack.index(range.upperBound, offsetBy: 60, limitedBy: haystack.endIndex) ?? haystack.endIndex
        let excerpt = haystack[start..<end].replacingOccurrences(of: "\n", with: " ")
        return (start > haystack.startIndex ? "…" : "") + excerpt + (end < haystack.endIndex ? "…" : "")
    }

    private var dateText: String {
        if byDay || Calendar.current.isDateInToday(recording.date) { return recording.date.formatted(date: .omitted, time: .shortened) }
        return recording.date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// Dossier d'une dictée : étiquette, ou « Ranger » pour en choisir un.
struct FolderCell: View {
    let recording: Recording
    var editable = true
    /// En puce, sous le titre de la fiche : le dossier dans une puce, ou « Ranger » en pointillés.
    var puce = false
    /// Dans une ligne de la liste : pastille et nom en gris, sans cadre ; sans dossier, « Ranger » n'apparaît qu'au
    /// survol ou sous le curseur (`revealed`).
    var ligne = false
    var revealed = true
    @ObservedObject private var store = RecordingStore.shared

    var body: some View {
        Group {
            if ligne, recording.folderID == nil, !(editable && revealed) {
                EmptyView()
            } else if editable {
                PreviewSafeMenuButton(entries: { RecordingMenu.folderEntries(for: [recording.id], current: recording.folderID) }) { label }
            } else if recording.folderID != nil {
                label
            }
        }
        .fixedSize(horizontal: !ligne, vertical: true)
    }

    @ViewBuilder private var label: some View {
        if ligne {
            HStack(spacing: 6) {
                if let folder = store.folder(recording.folderID) {
                    FolderDot(folder: folder, showsExport: false)
                    Text(folder.name).lineLimit(1)
                } else {
                    Image(systemName: "folder").font(.ui(10))
                    Text("Ranger")
                }
            }
            .font(.ui(12))
            .foregroundStyle(Theme.muted)
            .contentShape(Rectangle())
        } else if puce {
            if let folder = store.folder(recording.folderID) {
                HStack(spacing: 6) {
                    FolderDot(folder: folder, size: 7)
                    Text(folder.name)
                }
                .puce()
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "folder").font(.ui(10))
                    Text("Ranger")
                }
                .puce(.aFaire)
            }
        } else if let folder = store.folder(recording.folderID) {
            FolderTag(folder: folder)
        } else {
            HStack(spacing: 5) {
                Image(systemName: "folder").font(.ui(11))
                Text("Ranger")
            }
            .font(.ui(12))
            .foregroundStyle(Theme.muted)
        }
    }
}

// MARK: - Cette semaine

/// Chiffres de la semaine, calculés depuis l'historique : un bloc par ligne, le chiffre en grand.
struct WeekStats: View {
    @ObservedObject private var store = RecordingStore.shared
    @ObservedObject private var lexicon = Lexicon.shared

    private struct Block: Identifiable {
        let id: String
        let value: String
        let label: String
        var detail: String?
    }

    private var week: [Recording] {
        store.recordings.filter { !$0.isTrashed && Calendar.current.isDate($0.date, equalTo: Date(), toGranularity: .weekOfYear) }
    }

    private var blocks: [Block] {
        let items = week
        let meetings = items.filter(\.isMeeting)
        let dictations = items.filter { !$0.isMeeting }
        let dictated = dictations.reduce(0) { $0 + $1.duration }
        let words = dictations.reduce(0) { $0 + $1.wordCount }
        let learned = lexicon.replacements.filter { $0.learned == true }.count
        var apps: [String: Int] = [:]
        for dictation in dictations { if let app = dictation.appName { apps[app, default: 0] += 1 } }
        let top = apps.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(3)
        return [
            Block(id: "meetings", value: "\(meetings.count)", label: "réunion\(meetings.count > 1 ? "s" : "")",
                  detail: meetings.isEmpty ? nil : formatDuration(meetings.reduce(0) { $0 + $1.duration }) + " enregistrées"),
            Block(id: "dictations", value: "\(dictations.count)", label: "dictée\(dictations.count > 1 ? "s" : "")"),
            Block(id: "time", value: formatDuration(dictated), label: "de dictée"),
            Block(id: "words", value: words.formatted(), label: "mot\(words > 1 ? "s" : "") dicté\(words > 1 ? "s" : "")",
                  detail: dictated > 0 ? "\(Int(Double(words) * 60 / max(dictated, 1))) mots par minute" : nil),
            Block(id: "learned", value: "\(learned)", label: "correction\(learned > 1 ? "s" : "") apprise\(learned > 1 ? "s" : "")",
                  detail: "dans le dictionnaire, depuis le début"),
            Block(id: "apps", value: top.isEmpty ? "–" : top.map(\.key).joined(separator: ", "),
                  label: top.isEmpty ? "aucune application dictée" : "application\(top.count > 1 ? "s" : "") les plus dictées",
                  detail: top.isEmpty ? nil : top.map { "\($0.key) · \($0.value)" }.joined(separator: "   ")),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                if index > 0 { Rectangle().fill(Theme.line).frame(height: 1) }
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(block.value)
                        .font(.ui(block.id == "apps" ? 20 : 34, weight: .semibold))
                        .tracking(-0.6)
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(minWidth: 120, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(block.label).font(.ui(13))
                        if let detail = block.detail {
                            Text(detail).font(.ui(11)).foregroundStyle(Theme.muted)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
    }
}
