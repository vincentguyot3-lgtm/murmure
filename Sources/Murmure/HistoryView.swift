import SwiftUI

/// Met le texte dans le presse-papiers (raccourci de `Paster.copy`, pour les vues).
func copy(_ text: String) { Paster.copy(text) }

func formatDuration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    if s < 60 { return "\(s) s" }
    if s < 3600 { return "\(s / 60) min" }
    return "\(s / 3600) h \(String(format: "%02d", s / 60 % 60))"
}

/// Texte où chaque occurrence de `query` est surlignée (recherche), sans tenir compte des accents : fond bleu doux
/// (`Theme.searchMark`), sauf l'occurrence `current` (rang dans ce texte), inversée. En contraste renforcé, toutes
/// sont inversées, et celle en cours passe sur l'accent, soulignée, pour qu'on la retrouve.
func highlighted(_ text: String, _ query: String, current: Int? = nil) -> AttributedString {
    highlighted(AttributedString(text), query, current: current)
}

/// Même surlignage sur un texte déjà mis en forme (différences du texte brut d'une dictée, par exemple).
func highlighted(_ text: AttributedString, _ query: String, current: Int? = nil) -> AttributedString {
    var result = text
    guard !query.isEmpty else { return result }
    var start = result.startIndex
    var index = 0
    while start < result.endIndex,
          let range = result[start...].range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
        if Theme.highContrast && index == current {
            result[range].backgroundColor = Theme.accent
            result[range].foregroundColor = Theme.onInverse
            result[range].underlineStyle = Text.LineStyle(pattern: .solid, color: Theme.onInverse)
        } else if index == current || Theme.highContrast {
            result[range].backgroundColor = Theme.inverse
            result[range].foregroundColor = Theme.onInverse
        } else {
            result[range].backgroundColor = Theme.searchMark
            result[range].foregroundColor = Theme.fg
        }
        start = range.upperBound
        index += 1
    }
    return result
}

/// Nombre d'occurrences de `query` dans `text`, comptées comme `highlighted` les surligne.
func occurrences(of query: String, in text: String) -> Int {
    guard !query.isEmpty else { return 0 }
    var count = 0
    var start = text.startIndex
    while start < text.endIndex,
          let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex) {
        count += 1
        start = range.upperBound
    }
    return count
}

/// Page d'une réunion ou d'une dictée : barre du haut (Retour, Partager, « … »), puis, dans la colonne commune, le
/// titre, une rangée de puces, les onglets et leur contenu ; pour une réunion, la barre « Demander à Murmure » en bas.
struct RecordingDetail: View {
    let id: UUID
    let onBack: () -> Void

    enum Tab: String {
        case summary = "Synthèse", text = "Texte", transcript = "Transcription", notes = "Notes", proposal = "Proposition"
    }

    @ObservedObject private var store = RecordingStore.shared
    @ObservedObject private var state = AppState.shared
    @State private var tab: Tab?
    @State private var title: String
    @FocusState private var editingTitle: Bool
    /// Versions et rédaction des comptes rendus, partagées entre l'onglet Synthèse et la barre du bas.
    @StateObject private var summaryWork = SummaryWork()
    /// Question posée dans la barre du bas et sa réponse, gardées tant que la fiche est ouverte, jamais au-delà.
    @StateObject private var ask: AskWork
    /// Dictée : « Voir le texte brut » est ouvert. Tenu ici pour qu'Échap le referme avant de revenir à la liste.
    @State private var showsRaw = false
    /// Compte rendu arrivé pendant que Murmure n'était pas au premier plan : marqué lu au retour dans la fenêtre.
    @State private var readOnActivation = false

    /// `tab` : onglet ouvert d'emblée ; `answer` : réponse déjà affichée ; `editsSummary` : barre du bas en mode
    /// « Modifier la synthèse » (aperçus en ligne de commande).
    init(id: UUID, onBack: @escaping () -> Void, tab: Tab? = nil, answer: (question: String, answer: Summarizer.Answer)? = nil,
         editsSummary: Bool = false) {
        self.id = id
        self.onBack = onBack
        _tab = State(initialValue: tab)
        _title = State(initialValue: RecordingStore.shared.recording(id)?.title ?? "")
        let work = AskWork()
        if let answer {
            work.asked = answer.question
            work.answer = answer.answer
        }
        work.editsSummary = editsSummary
        _ask = StateObject(wrappedValue: work)
    }

    var body: some View {
        if let recording = store.recording(id) {
            content(recording)
        } else {
            Color.clear.onAppear(perform: onBack)
        }
    }

    private func tabs(for recording: Recording) -> [Tab] {
        var tabs: [Tab] = recording.isMeeting ? [.summary] : [.text]
        // Une réunion a toujours sa transcription, même à une seule voix (bulles sans nom) : c'est ce qui permet de
        // retirer son onglet Brut, dont le texte est le même. Une dictée n'a la sienne que si plusieurs voix y ont été
        // distinguées ; son texte brut s'ouvre depuis l'onglet Texte (« Voir le texte brut »).
        if recording.isMeeting || recording.turns != nil { tabs.append(.transcript) }
        if recording.isMeeting { tabs.append(.notes) }
        if recording.isMeeting, !recording.text.isEmpty { tabs.append(.proposal) }
        return tabs
    }

    /// La barre « Demander à Murmure » : réunions avec une transcription, hors corbeille (comme « Partager »).
    private func asks(_ recording: Recording) -> Bool { recording.isMeeting && !recording.text.isEmpty && !recording.isTrashed }

    private func content(_ recording: Recording) -> some View {
        let tabs = tabs(for: recording)
        let current = tab.flatMap { tabs.contains($0) ? $0 : nil } ?? tabs[0]
        let asks = asks(recording)
        return VStack(alignment: .leading, spacing: 0) {
            topBar(recording)
                .padding(.horizontal, 20)
                .padding(.top, 20)

            VStack(alignment: .leading, spacing: 0) {
                titleField(recording)
                chips(recording, current: current).padding(.top, 10)
                TextTabs(options: tabs.map { ($0, $0.rawValue) },
                         selection: Binding(get: { current }, set: { tab = $0 }))
                    .padding(.top, 28)
                ZStack(alignment: .topLeading) {
                    Group {
                        switch current {
                        case .summary: SummaryPane(recording: recording, work: summaryWork)
                        case .text: DictationPane(recording: recording, showsRaw: $showsRaw)
                        case .transcript: TranscriptPane(recording: recording)
                        case .notes: NotesPane(recording: recording)
                        case .proposal: ProposalPane(recording: recording)
                        }
                    }
                    .id(current)
                    .transition(.opacity)
                }
                .padding(.top, tabs.count > 1 ? 20 : 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.top, 20)
            .padding(.bottom, asks ? 0 : 24)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .colonne()
            // La réponse flotte au-dessus de la barre, sur le contenu ; elle reste ouverte d'un onglet à l'autre.
            .overlay(alignment: .bottom) {
                if asks, ask.isOpen {
                    AnswerCard(recording: recording, ask: ask)
                        .colonne()
                        .padding(.bottom, 6)
                        .transition(Motion.slideTransition(from: .bottom))
                }
            }
            .animation(Motion.quick, value: ask.isOpen)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if asks {
                AskBar(recording: recording, onSummary: current == .summary && summaryWork.current(recording) != nil,
                       ask: ask, summary: summaryWork)
            }
        }
        // Échap ferme d'abord la réponse, puis revient à la liste, depuis la page comme depuis un champ de la page.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.escape) { escape(); return .handled }
        .onExitCommand(perform: escape)
        .onAppear {
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } // titre non présélectionné
            store.setSummaryUnread(id, false)
        }
        // Compte rendu rédigé pendant que la fiche est ouverte : lu si la fenêtre est sous les yeux, sinon au retour.
        // (Sur l'arrivée du compte rendu, pas sur l'état : « Marquer comme non lu » depuis la fiche doit tenir.)
        .onChange(of: recording.summaries?.count) { _, _ in
            guard recording.hasUnreadSummary, !StaticPreview.active else { return }
            if NSApp.isActive { store.setSummaryUnread(id, false) } else { readOnActivation = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard readOnActivation else { return }
            readOnActivation = false
            store.setSummaryUnread(id, false)
        }
        // Un titre généré en arrière-plan n'écrase pas ce que l'utilisateur est en train de taper.
        .onChange(of: recording.title) { _, newValue in if !editingTitle { title = newValue } }
        .onChange(of: editingTitle) { _, focused in if !focused { commitTitle(recording) } }
        // Le texte brut appartient à l'onglet Texte : il se referme quand on en sort.
        .onChange(of: tab) { _, _ in showsRaw = false }
    }

    /// Échap referme ce qui est ouvert (réponse, texte brut d'une dictée), puis revient à la liste.
    private func escape() {
        if ask.isOpen {
            withAnimation(Motion.quick) { ask.close() }
        } else if showsRaw {
            withAnimation(Motion.quick) { showsRaw = false }
        } else {
            onBack()
        }
    }

    // MARK: Barre du haut

    /// Retour carré à gauche ; à droite, « Partager » (tout ce qui sort de Murmure) et « … » (le même menu que dans
    /// la liste de l'accueil : rangement et partage).
    private func topBar(_ recording: Recording) -> some View {
        HStack(spacing: 4) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.ui(12, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                    .frame(width: 28, height: 28)
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardFocusRing()
            .keyboardShortcut("[", modifiers: .command)
            .help("Revenir à la liste (Échap ou ⌘[)")
            Spacer(minLength: 12)
            // Dans la corbeille, rien ne sort de Murmure : « … » propose Restaurer et Supprimer.
            if !recording.isTrashed { ShareButton(recording: recording) }
            ActionsButton(recording: recording, onDelete: onBack, inTopBar: true)
        }
    }

    // MARK: En-tête

    /// Titre de page, en serif, modifiable en place ; renommé à la validation (Entrée) ou en quittant le champ.
    private func titleField(_ recording: Recording) -> some View {
        Group {
            if StaticPreview.active {
                Text(title).fixedSize(horizontal: false, vertical: true)
            } else {
                TextField("Titre", text: $title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
                    .focused($editingTitle)
                    .onSubmit { commitTitle(recording); editingTitle = false }
            }
        }
        .font(.titre(30))
        .tracking(-0.3)
    }

    /// Puces sous le titre : date et heure, durée, application, dossier (ou « Ranger »), état, voix à nommer, terme
    /// surligné. Elles passent à la ligne quand la colonne ne suffit pas (dossier au nom long, taille agrandie).
    private func chips(_ recording: Recording, current: Tab) -> some View {
        FlowLayout(spacing: 6) {
            Tag(text: recording.date.formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalizedFirst
                    + ", " + recording.date.formatted(date: .omitted, time: .shortened), taille: .puce)
            Tag(text: formatDuration(recording.duration), taille: .puce)
            if let app = recording.appName { Tag(text: "dans \(app)", taille: .puce) }
            FolderCell(recording: recording, editable: !recording.isTrashed, puce: true)
                .help(recording.folderID == nil ? "Ranger dans un dossier" : "Changer de dossier")
            if recording.isArchived { Tag(text: "Archivée", taille: .puce) }
            if recording.isTrashed { Tag(text: "Dans la corbeille", taille: .puce) }
            if let progress = recording.progress {
                HStack(spacing: 6) {
                    Spinner(size: 10, color: Theme.muted, lineWidth: 1.3)
                    Text(progress).foregroundStyle(Theme.muted)
                }
                .puce()
            }
            // Les voix se nomment dans la transcription : la puce y mène.
            let unnamed = recording.unnamedSpeakers.count
            if unnamed > 0 {
                Button { withAnimation(Motion.quick) { tab = .transcript } } label: {
                    Tag(text: "\(unnamed) voix à nommer", dashed: true, taille: .puce)
                }
                .buttonStyle(.plain)
                .keyboardFocusRing(radius: 6)
                .help("Ouvrir la transcription pour nommer les voix")
            }
            if !state.highlight.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").font(.ui(10))
                    Text(state.highlight)
                    Button { withAnimation(Motion.quick) { state.highlight = "" } } label: {
                        Image(systemName: "xmark").font(.ui(9, weight: .semibold)).foregroundStyle(Theme.muted)
                            .frame(width: 14, height: 14).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Retirer le surlignage")
                }
                .puce(.filtre)
                .help("Terme surligné dans la fiche")
                .transition(.opacity)
            }
        }
        .animation(Motion.quick, value: state.highlight.isEmpty)
    }

    private func commitTitle(_ recording: Recording) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { title = recording.title } else if trimmed != recording.title { store.rename(recording.id, to: trimmed) }
    }
}

/// « Partager ▾ » de la barre du haut : copier, Word, e-mail, Claude Code et connecteurs sortants.
private struct ShareButton: View {
    let recording: Recording
    @State private var hover = false

    var body: some View {
        PreviewSafeMenuButton(entries: { RecordingMenu.shareEntries(for: recording) }) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up").font(.ui(12))
                Text("Partager")
                Image(systemName: "chevron.down").font(.ui(9, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            .font(.ui(12, weight: .medium))
            .foregroundStyle(Theme.fg)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Theme.soft : Color.clear))
            .contentShape(Rectangle())
            .onHover { inside in withAnimation(Motion.quick) { hover = inside } }
        }
        .help("Copier, exporter en Word, préparer un e-mail, envoyer dans Claude Code")
    }
}

// MARK: - Synthèse

/// Comptes rendus d'une fiche en cours de travail : version affichée, rédaction au fil des mots, erreur. Partagé
/// entre l'onglet Synthèse et la barre du bas en mode « Modifier la synthèse ».
@MainActor
final class SummaryWork: ObservableObject {
    @Published var version: UUID?
    @Published var working = false
    /// Compte rendu en cours de rédaction, affiché au fil des mots ; nil au repos.
    @Published var draft: String?
    @Published var error: String?
    /// Relance la dernière rédaction ou modification qui a échoué.
    var retry: (() -> Void)?

    func current(_ recording: Recording) -> Summary? {
        let summaries = recording.summaries ?? []
        return summaries.first { $0.id == version } ?? summaries.last
    }

    func generate(_ template: SummaryTemplate, for recording: Recording) {
        let localOnly = RecordingStore.shared.isLocalOnly(recording)
        working = true
        error = nil
        draft = ""
        Task {
            do {
                let text = try await Cleaner.$localOnly.withValue(localOnly) {
                    try await Summarizer.generate(transcript: recording.transcript, participants: recording.participantNames,
                                                  template: template, notes: recording.userNotes,
                                                  onPartial: { partial in Task { @MainActor in if self.draft != nil { self.draft = partial } } })
                }
                let summary = Summary(template: template.rawValue, text: text, date: Date())
                RecordingStore.shared.addSummary(recording.id, summary)
                version = summary.id
            } catch {
                self.error = "Rédaction impossible : \(error.localizedDescription)"
                retry = { [weak self] in self?.generate(template, for: recording) }
            }
            working = false
            draft = nil
        }
    }

    /// Nouvelle version de `current` selon la consigne ; `done` est appelé quand elle est enregistrée.
    func revise(_ current: Summary, order: String, for recording: Recording, done: @escaping () -> Void = {}) {
        let order = order.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !order.isEmpty, !working else { return }
        let localOnly = RecordingStore.shared.isLocalOnly(recording)
        working = true
        error = nil
        draft = ""
        Task {
            do {
                let text = try await Cleaner.$localOnly.withValue(localOnly) {
                    try await Summarizer.revise(current.text, instruction: order, transcript: recording.transcript,
                                                onPartial: { partial in Task { @MainActor in if self.draft != nil { self.draft = partial } } })
                }
                let summary = Summary(template: current.template, text: text, date: Date())
                RecordingStore.shared.addSummary(recording.id, summary)
                version = summary.id
                done()
            } catch {
                self.error = "Modification impossible : \(error.localizedDescription)"
                retry = { [weak self] in self?.revise(current, order: order, for: recording, done: done) }
            }
            working = false
            draft = nil
        }
    }
}

private struct SummaryPane: View {
    let recording: Recording
    @ObservedObject var work: SummaryWork

    private var summaries: [Summary] { recording.summaries ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let current = work.current(recording) {
                VStack(alignment: .leading, spacing: 0) {
                    header(current)
                    if StaticPreview.active {
                        // `ImageRenderer` ne dessine pas l'intérieur d'un `ScrollView`.
                        text(current)
                        Spacer(minLength: 0)
                    } else {
                        ScrollView { text(current) }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            } else if recording.progress != nil {
                Waiting(text: recording.progress ?? "")
            } else {
                VStack(spacing: 12) {
                    Text("Pas encore de compte rendu").font(.ui(15, weight: .medium))
                    if let failure = recording.processingError {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(.ui(12)).foregroundStyle(Theme.muted)
                            .frame(maxWidth: 520)
                            .multilineTextAlignment(.center)
                    }
                    Text(ready ? "Choisissez un modèle : il sera rédigé \(localOnly ? "sur ce Mac" : Cleaner.whereText)." : Cleaner.notReadyReason)
                        .font(.ui(12)).foregroundStyle(Theme.muted)
                    templateMenu(label: "Rédiger un compte rendu", prominent: true)
                        .disabled(!ready || work.working)
                        .opacity(ready && !work.working ? 1 : 0.4) // estompé comme `OutlineButtonStyle` désactivé
                    if let draft = work.draft, !draft.isEmpty {
                        ScrollView {
                            Text(Sharing.plain(draft))
                                .readingFont()
                                .lineSpacing(4)
                                .foregroundStyle(Theme.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: 640)
                        .padding(.top, 8)
                    } else if work.working {
                        Spinner(size: 14, color: Theme.muted)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = work.error {
                ErrorCard(message: error, retry: work.retry).transition(.opacity)
            }
        }
        .animation(Motion.quick, value: work.error)
    }

    @ViewBuilder private func text(_ current: Summary) -> some View {
        if let draft = work.draft {
            // Le nouveau compte rendu s'écrit sous les yeux ; la mise en page par blocs vient à la fin.
            Text(draft.isEmpty ? "…" : Sharing.plain(draft))
                .readingFont()
                .lineSpacing(4)
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 16)
                .padding(.bottom, 24)
        } else {
            SummaryView(markdown: current.text,
                        names: Dictionary(uniqueKeysWithValues: (recording.speakerNames ?? [:]).compactMap { key, name in
                            Int(key).map { ($0, name) } }),
                        date: recording.date, animated: !StaticPreview.active)
                .id(current.id) // une nouvelle version fait réapparaître les blocs un à un
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 16)
                .padding(.bottom, 24)
        }
    }

    /// Une seule ligne discrète : modèle, versions 1 · 2 · 3 et « + », mention de vérification ; copier et Word à droite.
    private func header(_ current: Summary) -> some View {
        HStack(spacing: 8) {
            Text(current.template).font(.ui(12, weight: .medium)).lineLimit(1)
            versionPills(current)
            Text("rédigé automatiquement, à vérifier")
                .font(.ui(11)).foregroundStyle(Theme.muted).lineLimit(1)
                .padding(.leading, 2)
            Spacer(minLength: 8)
            CopyIcon(text: Sharing.plain(current.text), help: "Copier la synthèse")
            BarIcon(symbol: "doc.richtext", help: "Exporter en Word") {
                DocxExporter.export(title: recording.title, subtitle: subtitle, markdown: current.text)
            }
        }
        .frame(height: 24)
    }

    private var subtitle: String {
        "\(recording.date.formatted(date: .long, time: .shortened)) · \(formatDuration(recording.duration)) · rédigé par Murmure, à vérifier"
    }

    /// Versions en pastilles 1 · 2 · 3 (l'active cerclée de noir, inversée en contraste renforcé), puis « + » pour un
    /// nouveau compte rendu.
    private func versionPills(_ current: Summary) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(summaries.enumerated()), id: \.element.id) { index, summary in
                let active = summary.id == current.id
                Button { withAnimation(Motion.quick) { work.version = summary.id } } label: {
                    let inverted = active && Theme.highContrast
                    Text("\(index + 1)")
                        .font(.ui(10, weight: active ? .semibold : .medium))
                        .foregroundStyle(inverted ? Theme.onInverse : active ? Theme.fg : Theme.muted)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(inverted ? Theme.inverse : Color.clear))
                        .overlay { if active && !inverted { Circle().strokeBorder(Theme.fg, lineWidth: 1) } }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Version \(index + 1) · \(summary.template) · \(summary.date.formatted(date: .omitted, time: .shortened))")
            }
            PreviewSafeMenuButton(entries: { [.header("Nouveau compte rendu")] + templateEntries() }) {
                Image(systemName: "plus")
                    .font(.ui(11, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .help("Rédiger un nouveau compte rendu")
        }
        .disabled(work.working)
    }

    private func templateEntries() -> [MenuEntry] {
        SummaryTemplate.allCases.map { template in
            .action(template.rawValue, "doc.text") { work.generate(template, for: recording) }
        }
    }

    private func templateMenu(label: String, prominent: Bool) -> some View {
        PreviewSafeMenuButton(entries: templateEntries) {
            HStack(spacing: 6) {
                Text(label)
                Image(systemName: "chevron.down").font(.ui(9, weight: .semibold))
            }
            .font(.ui(12, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(prominent ? Theme.onInverse : Theme.fg)
            .background(RoundedRectangle(cornerRadius: 7).fill(prominent ? Theme.inverse : Color.clear))
            .contentShape(Rectangle())
        }
    }

    /// Dossier « jamais en ligne » : la rédaction reste sur le Mac même avec Claude.
    private var localOnly: Bool { RecordingStore.shared.isLocalOnly(recording) }
    private var ready: Bool { Cleaner.isReady(localOnly: localOnly) }
}

/// Icône « copier » sans contour, qui devient une coche une seconde et demie.
private struct CopyIcon: View {
    let text: String
    let help: String
    @State private var copied = false

    var body: some View {
        BarIcon(symbol: copied ? "checkmark" : "doc.on.doc", help: help) {
            copy(text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        }
    }
}

// MARK: - Demander à Murmure

/// Question posée sur la réunion depuis la barre du bas : le modèle répond à partir de la transcription et montre le
/// passage qui fonde sa réponse. Rien n'est conservé : la réponse disparaît en la fermant ou en quittant la fiche.
@MainActor
final class AskWork: ObservableObject {
    /// Dernière question envoyée (le texte en cours de saisie reste dans `AskBar`, pour qu'une frappe ne redessine pas
    /// toute la fiche).
    @Published var asked = ""
    @Published var answer: Summarizer.Answer?
    /// Réponse en cours de rédaction, affichée au fil des mots ; nil tant que le modèle recopie encore l'extrait.
    @Published var draft: Summarizer.Answer?
    @Published var working = false
    @Published var error: String?
    /// Sur l'onglet Synthèse : la barre modifie la synthèse au lieu de poser une question.
    @Published var editsSummary = false
    private var task: Task<Void, Never>?

    /// La carte de réponse est affichée.
    var isOpen: Bool { working || answer != nil || error != nil }

    func ask(_ question: String, _ recording: Recording) {
        let query = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let localOnly = RecordingStore.shared.isLocalOnly(recording)
        guard !query.isEmpty, !working, Cleaner.isReady(localOnly: localOnly) else { return }
        let transcript = recording.transcript
        let summary = recording.summaries?.last?.text
        asked = query
        answer = nil
        draft = nil
        error = nil
        working = true
        task = Task {
            do {
                let result = try await Cleaner.$localOnly.withValue(localOnly) {
                    try await Summarizer.answer(query, transcript: transcript, summary: summary, onPartial: { partial in
                        Task { @MainActor in if self.working, self.asked == query { self.draft = partial } }
                    })
                }
                guard !Task.isCancelled else { return }
                draft = nil
                answer = result
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "Réponse impossible : \(error.localizedDescription)"
            }
            working = false
        }
    }

    /// Repose la dernière question (après une erreur).
    func retry(_ recording: Recording) {
        working = false
        ask(asked, recording)
    }

    func close() {
        task?.cancel()
        task = nil
        working = false
        answer = nil
        draft = nil
        error = nil
        asked = ""
    }
}

/// Barre épinglée en bas de la fiche d'une réunion : une capsule « Demander à Murmure… », valable sur tous les
/// onglets. Sur la Synthèse, une pastille à gauche bascule entre « Demander » et « Modifier la synthèse ».
private struct AskBar: View {
    let recording: Recording
    /// Onglet Synthèse avec un compte rendu à modifier.
    let onSummary: Bool
    @ObservedObject var ask: AskWork
    @ObservedObject var summary: SummaryWork
    /// Texte du champ (question, ou consigne de modification de la synthèse), local à la barre.
    @State private var question = ""
    @FocusState private var focused: Bool

    private var localOnly: Bool { RecordingStore.shared.isLocalOnly(recording) }
    private var ready: Bool { Cleaner.isReady(localOnly: localOnly) || StaticPreview.modelePret }
    private var modifies: Bool { onSummary && ask.editsSummary }
    private var working: Bool { modifies ? summary.working : ask.working }
    private var whereText: String { localOnly ? "sur ce Mac" : Cleaner.whereText }

    /// Le texte d'invite ne change pas quand le modèle n'est pas prêt : la raison est dans l'infobulle, et souvent déjà
    /// sur la page (sous « Rédiger… »), pour ne pas la lire deux fois.
    private var placeholder: String {
        modifies ? "Que voulez-vous modifier dans la synthèse ?" : "Demander à Murmure…"
    }

    var body: some View {
        HStack(spacing: 8) {
            if onSummary { modeToggle }
            field
            sendButton
        }
        .padding(.leading, onSummary ? 6 : 16)
        .padding(.trailing, 8)
        .frame(height: 44)
        .background(Capsule().fill(Theme.bg))
        .overlay(Capsule().strokeBorder(focused ? Theme.fg : Theme.line))
        .opacity(ready ? 1 : 0.55)
        .disabled(!ready)
        .help(!ready ? Cleaner.notReadyReason
              : modifies ? "Nouvelle version de la synthèse, rédigée \(whereText) selon votre consigne"
              : "Réponse rédigée \(whereText) à partir de la transcription, non conservée")
        .animation(Motion.quick, value: focused)
        .animation(Motion.quick, value: onSummary)
        .colonne()
        .padding(.top, 14)
        .padding(.bottom, 20)
        // Fond en dégradé, transparent en haut (maquette : `.ask`) : l'ombre de la carte de réponse n'est pas tranchée.
        .background(LinearGradient(stops: [.init(color: Theme.bg.opacity(0), location: 0), .init(color: Theme.bg, location: 0.4)],
                                   startPoint: .top, endPoint: .bottom))
        // Le contenu s'efface sous la barre au lieu d'être coupé net (pas la carte de réponse, posée juste au-dessus).
        .background(alignment: .top) {
            if !ask.isOpen {
                LinearGradient(colors: [Theme.bg.opacity(0), Theme.bg], startPoint: .top, endPoint: .bottom)
                    .frame(height: 24)
                    .offset(y: -24)
                    .allowsHitTesting(false)
            }
        }
    }

    private var modeToggle: some View {
        Button { withAnimation(Motion.quick) { ask.editsSummary.toggle() } } label: {
            HStack(spacing: 5) {
                Text(ask.editsSummary ? "Modifier la synthèse" : "Demander")
                Image(systemName: "chevron.up.chevron.down").font(.ui(8, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            .font(.ui(12, weight: .medium))
            .foregroundStyle(Theme.fg)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Capsule().fill(Theme.soft))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardFocusRing(radius: 16)
        .help(ask.editsSummary ? "Revenir aux questions sur la réunion" : "Modifier la synthèse par une consigne")
    }

    @ViewBuilder private var field: some View {
        if StaticPreview.active {
            Text(question.isEmpty ? placeholder : question)
                .font(.ui(13))
                .foregroundStyle(question.isEmpty ? Theme.muted : Theme.fg)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField(placeholder, text: $question)
                .textFieldStyle(.plain)
                .font(.ui(13))
                .focused($focused)
                .onSubmit(send)
        }
    }

    private var sendButton: some View {
        Button(action: send) {
            Group {
                if working { Spinner(size: 12, color: Theme.onInverse, lineWidth: 1.5) } else { Image(systemName: "arrow.up") }
            }
            .font(.ui(12, weight: .semibold))
            .foregroundStyle(Theme.onInverse)
            .frame(width: 28, height: 28)
            .background(Circle().fill(Theme.inverse))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardFocusRing(radius: 14)
        .disabled(working || question.trimmingCharacters(in: .whitespaces).isEmpty)
        .help(modifies ? "Modifier la synthèse (↩)" : "Demander (↩)")
    }

    /// La consigne reste dans le champ jusqu'à la nouvelle version (à corriger si elle échoue) ; la question, elle,
    /// passe dans la carte de réponse dès l'envoi (« Réessayer » la repose après une erreur).
    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ready, !text.isEmpty, !working else { return }
        if modifies, let current = summary.current(recording) {
            summary.revise(current, order: text, for: recording) { question = "" }
        } else {
            question = ""
            withAnimation(Motion.quick) { ask.ask(text, recording) }
        }
    }
}

/// Réponse de « Demander à Murmure », au-dessus de la barre : la question, la réponse, l'extrait qui la fonde et la
/// mention « non conservé ». Se ferme par sa croix ou Échap.
private struct AnswerCard: View {
    let recording: Recording
    @ObservedObject var ask: AskWork

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text(ask.asked)
                    .font(.ui(13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 5)
                BarIcon(symbol: "xmark", help: "Fermer la réponse (Échap)") {
                    withAnimation(Motion.quick) { ask.close() }
                }
            }
            if ask.working {
                if let draft = ask.draft, !draft.text.isEmpty {
                    body(draft, final: false)
                } else {
                    HStack(spacing: 8) {
                        Spinner(size: 12, color: Theme.muted, lineWidth: 1.4)
                        Text(recording.transcript.count > Summarizer.questionWindow ? "Lecture de la réunion par tranches…"
                             : "Recherche du passage qui répond…")
                            .font(.ui(12)).foregroundStyle(Theme.muted)
                    }
                }
            } else if let error = ask.error {
                ErrorCard(message: error) { ask.retry(recording) }
            } else if let answer = ask.answer {
                if StaticPreview.active {
                    body(answer)
                } else {
                    // À sa taille tant qu'elle tient (carte de 360 pt au plus), puis en défilement.
                    ScrollView { body(answer) }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(maxHeight: 290)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.soft))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.highContrast ? Theme.line : Theme.fg.opacity(0.06))
        }
        .shadow(color: .black.opacity(0.08), radius: 14, y: 4)
    }

    /// `final` : réponse terminée (sinon en cours de rédaction : ni mentions ni avertissement d'extrait manquant).
    private func body(_ answer: Summarizer.Answer, final: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(answer.text)
                .readingFont()
                .lineSpacing(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let excerpt = answer.excerpt {
                HStack(alignment: .top, spacing: 12) {
                    Rectangle().fill(Theme.line).frame(width: 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Extrait de la transcription")
                            .font(.ui(11, weight: .medium))
                            .foregroundStyle(Theme.muted)
                        Text(excerpt)
                            .font(.ui(13))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            } else if final {
                Text("Aucun passage de la transcription ne fonde cette réponse : à vérifier.")
                    .font(.ui(11)).foregroundStyle(Theme.muted)
            }
            if final {
                Text("Rédigé par Murmure à partir de la transcription, à vérifier. Non conservé.")
                    .font(.ui(11)).foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Barre de consigne d'une dictée (« Que voulez-vous modifier ? »).
private struct PromptBar: View {
    @Binding var text: String
    let working: Bool
    let placeholder: String
    let send: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            if StaticPreview.active {
                Text(text.isEmpty ? placeholder : text).font(.ui(13)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(placeholder, text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.ui(13))
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit(send)
            }
            Button(action: send) {
                Group {
                    if working { Spinner(size: 13, color: Theme.onInverse, lineWidth: 1.5) } else { Image(systemName: "arrow.up") }
                }
                .font(.ui(13, weight: .semibold))
                .foregroundStyle(Theme.onInverse)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.inverse))
            }
            .buttonStyle(.plain)
            .disabled(working || text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focused ? Theme.fg : Theme.line, lineWidth: 1))
        .animation(Motion.quick, value: focused)
    }
}

private struct Waiting: View {
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Spinner(size: 16, color: Theme.muted)
            Text(text).font(.ui(13)).foregroundStyle(Theme.muted)
            Text("La transcription se fait sur ce Mac ; vous pouvez continuer à travailler.")
                .font(.ui(11)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Transcription, texte, brut

/// Transcription en bulles : un nom coloré par prise de parole, puis ses bulles grises. Une réunion à une seule voix
/// (sans tours de parole) montre son texte en bulles sans nom. En tête, un bandeau fixe : nombre de voix et durée,
/// puis chercher, copier et nommer.
private struct TranscriptPane: View {
    let recording: Recording
    @ObservedObject private var app = AppState.shared
    /// Champ de recherche ouvert (il l'est aussi d'emblée quand un terme vient de la recherche de l'accueil).
    @State private var searching = false
    /// Occurrence en cours, comptée sur toute la transcription.
    @State private var current = 0

    @State private var cache = TranscriptCache()

    var body: some View {
        let layout = cache.layout(recording)
        let counts = cache.counts(app.highlight)
        let total = counts.reduce(0, +)
        let place = Self.locate(min(current, max(total - 1, 0)), in: counts)
        VStack(alignment: .leading, spacing: 0) {
            TranscriptBar(recording: recording, searching: $searching, current: $current, total: total,
                          ranks: layout.ranks)
            if recording.text.isEmpty {
                if let progress = recording.progress {
                    Waiting(text: progress)
                } else {
                    Text("Aucune parole reconnue.")
                        .font(.ui(13)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if StaticPreview.active {
                // `ImageRenderer` ne dessine pas l'intérieur d'un `ScrollView`.
                rows(layout, place: place)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) { rows(layout, place: place) }
                            .padding(.bottom, 24)
                    }
                    .onChange(of: app.highlight) { _, _ in
                        current = 0
                        reveal(Self.locate(0, in: cache.counts(app.highlight)), proxy)
                    }
                    .onChange(of: current) { _, newValue in reveal(Self.locate(newValue, in: counts), proxy) }
                    .onAppear { reveal(place, proxy) }
                }
            }
        }
        // ⌘F (Fichier › Rechercher) cherche dans la transcription tant qu'elle est affichée (voir `MainView`).
        .onAppear { app.transcriptShown = true }
        .onDisappear { app.transcriptShown = false }
    }

    @ViewBuilder private func rows(_ layout: TranscriptLayout, place: (bubble: Int, local: Int)?) -> some View {
        ForEach(layout.rows) { row in
            switch row.kind {
            case .name(let speaker):
                SpeakerName(recording: recording, speaker: speaker, tint: Theme.speakerTint(layout.ranks[speaker] ?? nil))
                    .padding(.top, 16)
                    .padding(.bottom, 2)
            case .bubble(let index):
                let bubble = layout.bubbles[index]
                let passage = layout.passages[bubble.passage]
                TranscriptBubble(text: highlighted(bubble.text, app.highlight, current: place?.bubble == index ? place?.local : nil))
                    .padding(.top, row.id == layout.rows.first?.id ? 16 : (bubble.first && passage.speaker == nil ? 8 : 4))
                    .previewSafeRightClick {
                        // Le clic droit est intercepté : « Copier la sélection » remplace celui du texte sélectionnable.
                        [.action("Copier la sélection", "text.cursor") { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) },
                         .action("Copier tout le passage", "doc.on.doc") { copy(passage.text) }]
                    }
            }
        }
    }

    /// Bulle et rang dans la bulle de l'occurrence `index` (rang sur toute la transcription).
    static func locate(_ index: Int, in counts: [Int]) -> (bubble: Int, local: Int)? {
        var remaining = index
        for (bubble, count) in counts.enumerated() {
            if remaining < count { return (bubble, remaining) }
            remaining -= count
        }
        return nil
    }

    private func reveal(_ place: (bubble: Int, local: Int)?, _ proxy: ScrollViewProxy) {
        guard let place else { return }
        withAnimation(Motion.quick) { proxy.scrollTo(place.bubble, anchor: .center) }
    }
}

/// Découpage gardé d'une évaluation à l'autre : le corps de la transcription est réévalué à chaque publication
/// d'`AppState` (texte en direct, synthèse qui s'écrit), alors que le découpage ne change qu'avec le texte, les tours
/// de parole ou la voix « moi », et les comptes d'occurrences qu'avec le terme cherché.
private final class TranscriptCache {
    private struct Key: Equatable {
        let id: UUID
        let text: String
        let turns: [Turn]?
        let own: Int?
    }
    private var key: Key?
    private var cached = TranscriptLayout()
    private var query: String?
    private var cachedCounts: [Int] = []

    func layout(_ recording: Recording) -> TranscriptLayout {
        let key = Key(id: recording.id, text: recording.text, turns: recording.turns, own: recording.ownVoice)
        if key != self.key {
            self.key = key
            cached = TranscriptLayout(recording)
            query = nil
        }
        return cached
    }

    /// Occurrences de `query` dans chaque bulle du dernier découpage.
    func counts(_ query: String) -> [Int] {
        if query != self.query {
            self.query = query
            cachedCounts = cached.bubbles.map { occurrences(of: query, in: $0.text) }
        }
        return cachedCounts
    }
}

/// Découpage d'une transcription pour l'affichage : passages (prises de parole consécutives d'une même voix), bulles
/// (une par prise, coupée en fin de phrase au-delà de 600 signes), et lignes à empiler (nom, puis bulles). Rien n'est
/// modifié dans la fiche : les anciennes réunions, aux prises fusionnées, sont découpées de la même façon.
struct TranscriptLayout {
    struct Passage {
        /// nil pour une réunion à une seule voix : pas de nom au-dessus.
        let speaker: Int?
        var text: String
    }
    struct Bubble {
        let passage: Int
        let text: String
        /// Première bulle de son passage.
        let first: Bool
    }
    struct Row: Identifiable {
        enum Kind { case name(Int), bubble(Int) }
        /// Rang de la bulle (identifiant de défilement de la recherche), ou négatif pour un nom.
        let id: Int
        let kind: Kind
    }

    var passages: [Passage] = []
    var bubbles: [Bubble] = []
    var rows: [Row] = []
    /// Rang de couleur de chaque voix (`Theme.speakerTint`), nil pour « moi ».
    var ranks: [Int: Int?] = [:]

    /// Au-delà, une prise de parole est coupée en plusieurs bulles.
    static let limit = 600

    init() {}

    init(_ recording: Recording) {
        var pieces: [(speaker: Int?, texts: [String])] = []
        if let turns = recording.turns, !turns.isEmpty {
            for turn in turns {
                let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                if let last = pieces.last, last.speaker == turn.speaker {
                    pieces[pieces.count - 1].texts.append(text)
                } else {
                    pieces.append((turn.speaker, [text]))
                }
            }
            for speaker in recording.speakersInOrder { ranks[speaker] = recording.speakerRank(speaker) }
        } else {
            // Une seule voix : un passage par paragraphe du texte.
            pieces = recording.text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { (nil, [$0]) }
        }
        for (index, piece) in pieces.enumerated() {
            passages.append(Passage(speaker: piece.speaker, text: piece.texts.joined(separator: "\n\n")))
            if let speaker = piece.speaker { rows.append(Row(id: -(index + 1), kind: .name(speaker))) }
            var first = true
            for text in piece.texts {
                for chunk in Self.chunks(text) {
                    rows.append(Row(id: bubbles.count, kind: .bubble(bubbles.count)))
                    bubbles.append(Bubble(passage: index, text: chunk, first: first))
                    first = false
                }
            }
        }
    }

    /// Coupe un texte de plus de `limit` signes en morceaux à peu près égaux, toujours en fin de phrase (point,
    /// point d'interrogation ou d'exclamation, points de suspension, suivis d'une majuscule). Une phrase plus longue
    /// que la limite reste entière.
    static func chunks(_ text: String) -> [String] {
        guard text.count > limit else { return [text] }
        var sentences: [String] = []
        var sentence = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            sentence.append(character)
            guard ".?!…".contains(character), index + 2 < characters.count, characters[index + 1].isWhitespace else { continue }
            let next = characters[index + 2]
            guard next.isUppercase || next == "«" || next == "\"" else { continue }
            // « M. Dupont », « J.-P. » : une initiale suivie d'un point ne termine pas la phrase.
            let word = sentence.split(separator: " ").last ?? ""
            if character == ".", word.count <= 2, word.first?.isUppercase == true { continue }
            sentences.append(sentence.trimmingCharacters(in: .whitespaces))
            sentence = ""
        }
        if !sentence.trimmingCharacters(in: .whitespaces).isEmpty { sentences.append(sentence.trimmingCharacters(in: .whitespaces)) }
        let parts = Int((Double(text.count) / Double(limit)).rounded(.up))
        let target = text.count / max(parts, 1)
        var result: [String] = []
        var chunk = ""
        for sentence in sentences {
            if !chunk.isEmpty, chunk.count >= target || chunk.count + 1 + sentence.count > limit {
                result.append(chunk)
                chunk = ""
            }
            chunk += chunk.isEmpty ? sentence : " " + sentence
        }
        if !chunk.isEmpty { result.append(chunk) }
        return result
    }
}

/// Bulle d'une prise de parole : gris doux, coins arrondis, qui épouse son texte jusqu'à 600 pt.
private struct TranscriptBubble: View {
    let text: AttributedString

    var body: some View {
        Text(text).bulle()
    }
}

extension View {
    /// Mise en forme d'une bulle de transcription (fiche, page En direct) : taille de lecture, fond gris doux, rayon 10,
    /// au plus 600 pt de large, calée à gauche.
    func bulle() -> some View {
        readingFont()
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.soft))
            .overlay {
                // En contraste renforcé, le gris doux ne se détache plus du fond : un contour le remplace.
                if Theme.highContrast {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line)
                }
            }
            .frame(maxWidth: Gabarit.bulle, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Nom d'une voix au-dessus de ses bulles, dans sa couleur ; un clic ouvre « Renommer… » et « C'est moi ».
private struct SpeakerName: View {
    let recording: Recording
    let speaker: Int
    let tint: Color
    @State private var hover = false

    private var named: Bool { recording.speakerNames?[String(speaker)] != nil || recording.isOwn(speaker) }

    var body: some View {
        PreviewSafeMenuButton(entries: { SpeakerMenu.entries(recording, speaker) }) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(recording.speakerName(speaker))
                    .font(.ui(15, weight: Theme.highContrast ? .semibold : .medium))
                    .foregroundStyle(tint)
                    .underline(hover, color: tint.opacity(0.5))
                if !named {
                    Text("cliquer pour nommer").font(.ui(11)).foregroundStyle(Theme.muted)
                } else if recording.isRecognized(speaker) {
                    // Nom donné d'office d'après une réunion précédente : à confirmer ou corriger d'un clic.
                    HStack(spacing: 3) {
                        Image(systemName: "waveform").font(.ui(9))
                        Text("voix reconnue, à confirmer")
                    }
                    .font(.ui(11))
                    .foregroundStyle(Theme.muted)
                } else {
                    Image(systemName: "pencil")
                        .font(.ui(10))
                        .foregroundStyle(Theme.muted)
                        .opacity(hover ? 1 : 0)
                }
            }
            .padding(.leading, 2)
            .contentShape(Rectangle())
        }
        .onHover { inside in withAnimation(Motion.quick) { hover = inside } }
        .help(recording.isRecognized(speaker)
              ? "Voix reconnue d'après une réunion précédente : confirmer ou corriger"
              : "Renommer cette voix, ou indiquer que c'est vous")
    }
}

/// Menus de nommage des voix (nom au-dessus des bulles, bandeau de la transcription).
enum SpeakerMenu {
    static func entries(_ recording: Recording, _ speaker: Int) -> [MenuEntry] {
        let own = recording.isOwn(speaker)
        var entries: [MenuEntry] = []
        // Nom proposé parce que la voix a été reconnue : le confirmer l'apprend, le corriger aussi.
        if recording.isRecognized(speaker) {
            let who = own ? "moi" : recording.speakerName(speaker)
            entries.append(.action("Oui, c'est bien \(who)", "checkmark") { VoiceBook.shared.confirm(recording.id, speaker: speaker) })
        }
        entries += [
            .action(recording.isRecognized(speaker) ? "Non, c'est quelqu'un d'autre…" : "Renommer…", "pencil") { rename(recording, speaker) },
            .action("C'est moi", "person", checked: own) {
                VoiceBook.shared.setOwn(recording.id, speaker: own ? nil : speaker)
            },
        ]
        return entries
    }

    static func rename(_ recording: Recording, _ speaker: Int) {
        Modals.shared.ask("Nommer l'interlocuteur \(speaker)",
                          message: "Ce nom remplacera « \(recording.speakerName(speaker)) » dans la transcription et les comptes rendus."
                              + (Settings.recognizeVoices ? " Murmure reconnaîtra cette voix aux prochaines réunions." : ""),
                          placeholder: "Me Delorme",
                          initial: recording.isRecognized(speaker) ? "" : recording.speakerNames?[String(speaker)] ?? "",
                          confirm: "Enregistrer") {
            VoiceBook.shared.name(recording.id, speaker: speaker, name: $0)
        }
    }
}

/// Bandeau fixe de la transcription : « 3 INTERLOCUTEURS · 45 MIN », puis chercher (⌘F), copier, nommer. En recherche,
/// le champ prend la place du libellé, avec « 3 sur 12 », ↩ pour l'occurrence suivante et Échap pour fermer.
private struct TranscriptBar: View {
    let recording: Recording
    @Binding var searching: Bool
    @Binding var current: Int
    let total: Int
    let ranks: [Int: Int?]
    @ObservedObject private var app = AppState.shared
    @FocusState private var fieldFocused: Bool
    @State private var copied = false

    private var open: Bool { searching || !app.highlight.isEmpty }

    var body: some View {
        HStack(spacing: 2) {
            if open { searchField } else { summary }
        }
        .frame(height: 34)
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.soft))
        .overlay { if Theme.highContrast { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line) } }
        .padding(.top, 2)
        .animation(Motion.quick, value: open)
        // ⌘F passe par Fichier › Rechercher, que `MainView` aiguille ici tant que la transcription est affichée :
        // un raccourci posé sur la loupe disparaîtrait avec elle quand la recherche est ouverte.
        .onReceive(app.commands) { command in
            if case .findInTranscript = command { openSearch() }
        }
    }

    /// Ouvre le champ et lui donne le curseur, une fois qu'il existe (au même passage, le focus serait ignoré).
    private func openSearch() {
        searching = true
        DispatchQueue.main.async { fieldFocused = true }
    }

    private var label: String {
        let voices = recording.speakerCount
        let who = recording.turns == nil ? "une seule voix" : "\(voices) interlocuteur\(voices > 1 ? "s" : "")"
        return "\(who) · \(formatDuration(recording.duration))"
    }

    @ViewBuilder private var summary: some View {
        Text(label.uppercased())
            .font(.ui(11, weight: .medium))
            .tracking(0.6)
            .monospacedDigit()
            .foregroundStyle(Theme.muted)
            .lineLimit(1)
        Spacer(minLength: 8)
        // Où la réunion a été transcrite, quand la transcription en ligne entre en jeu.
        if recording.transcribedBy == "online" {
            BarIconLabel(symbol: "cloud")
                .help(PendingDeletions.isPending(recording: recording.id)
                      ? "Transcrite en ligne, sur un serveur européen. La suppression chez le service n'a pas encore pu se faire : elle sera retentée."
                      : "Transcrite en ligne, sur un serveur européen ; la transcription et le son y ont été supprimés.")
        } else if let failure = recording.onlineFailure {
            BarIconLabel(symbol: "exclamationmark.icloud")
                .help("Transcrite sur ce Mac : la transcription en ligne n'a pas pu se faire (\(failure)).")
        }
        // Réunion gardée sur ce Mac (cadenas, ou reprise après un arrêt brutal) : un clic lève l'interdiction pour la
        // suite (synthèse et questions par Claude, envois) ; la transcription, elle, est déjà faite.
        if recording.keepLocal == true {
            BarIcon(symbol: "lock.fill", help: "Réunion gardée sur ce Mac : rien n'en part en ligne. Cliquer pour l'autoriser désormais.") {
                RecordingStore.shared.update(recording.id) { $0.keepLocal = nil }
            }
        }
        BarIcon(symbol: "magnifyingglass", help: "Chercher dans la transcription (⌘F)") { openSearch() }
        BarIcon(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copier la transcription") {
            copy(recording.transcript)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        }
        if recording.turns != nil {
            PreviewSafeMenuButton(entries: { nameEntries }) {
                BarIconLabel(symbol: "person.badge.plus")
            }
            .help("Nommer les interlocuteurs")
        }
    }

    private var nameEntries: [MenuEntry] {
        [.header("Nommer les voix")] + recording.speakersInOrder.map { speaker in
            .action(recording.speakerName(speaker), tint: Theme.speakerTint(ranks[speaker] ?? nil)) {
                SpeakerMenu.rename(recording, speaker)
            }
        }
    }

    @ViewBuilder private var searchField: some View {
        Image(systemName: "magnifyingglass").font(.ui(11)).foregroundStyle(Theme.muted).padding(.trailing, 4)
        Group {
            if StaticPreview.active {
                Text(app.highlight).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("Chercher dans la transcription", text: $app.highlight)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit { step(1) }
                    // Échap ferme la recherche avant de ramener à la liste.
                    .onKeyPress(.escape) { close(); return .handled }
                    .onExitCommand(perform: close)
            }
        }
        .font(.ui(12))
        if !app.highlight.isEmpty {
            Text(total == 0 ? "aucun résultat" : "\(min(current, total - 1) + 1) sur \(total)")
                .font(.ui(11))
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 6)
                .fixedSize()
            BarIcon(symbol: "chevron.up", help: "Occurrence précédente") { step(-1) }.disabled(total == 0)
            BarIcon(symbol: "chevron.down", help: "Occurrence suivante (↩)") { step(1) }.disabled(total == 0)
        }
        BarIcon(symbol: "xmark", help: "Fermer la recherche (Échap)") { close() }
    }

    private func step(_ delta: Int) {
        guard total > 0 else { return }
        current = ((min(current, total - 1) + delta) % total + total) % total
    }

    private func close() {
        withAnimation(Motion.quick) {
            searching = false
            app.highlight = ""
            current = 0
        }
    }
}

/// Icône du bandeau de transcription (et de celui de la page En direct) : 26 × 26, grise, noire au survol.
struct BarIcon: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { BarIconLabel(symbol: symbol) }
            .buttonStyle(.plain)
            .keyboardFocusRing()
            .help(help)
    }
}

struct BarIconLabel: View {
    let symbol: String
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Image(systemName: symbol)
            .font(.ui(12))
            .foregroundStyle(hover && enabled ? Theme.fg : Theme.muted)
            .opacity(enabled ? 1 : 0.4)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
            .onHover { inside in withAnimation(Motion.quick) { hover = inside } }
    }
}

private struct DictationPane: View {
    let recording: Recording
    /// Texte brut affiché à la place de l'éditeur, en différences avec le texte actuel (« Voir le texte brut ») ; tenu
    /// par la fiche, dont Échap le referme.
    @Binding var showsRaw: Bool
    @ObservedObject private var app = AppState.shared
    @State private var text = ""
    @State private var working = false
    @State private var previous: String?
    @State private var instruction = ""
    @State private var error: String?
    @State private var retry: (() -> Void)?
    /// Texte retravaillé en attente : montré en différences, gardé ou abandonné par l'utilisateur.
    @State private var proposal: String?
    /// Texte en cours de rédaction par le modèle, affiché au fil des mots ; nil au repos.
    @State private var draft: String?
    @State private var task: Task<Void, Never>?

    init(recording: Recording, showsRaw: Binding<Bool>) {
        self.recording = recording
        _showsRaw = showsRaw
        _text = State(initialValue: recording.text)
    }

    /// La mise en forme a changé quelque chose : le texte brut de Murmure se consulte et se rétablit.
    private var hasChanges: Bool { !recording.rawText.isEmpty && recording.rawText != text }

    private static var presets: [(label: String, instruction: String)] { [
        ("Corriger et ponctuer", "Corrige l'orthographe, la grammaire et la ponctuation, sans rien reformuler."),
        ("Style soutenu", "Réécris dans un style soutenu et précis, adapté à \(Settings.profession == .avocat ? "un courrier d'avocat" : "un courrier professionnel")."),
        // Le ton du cabinet pour un mail : formules d'appel et de clôture, pas de tiret cadratin ni de formule passe-partout.
        ("En e-mail", "Transforme en e-mail professionnel complet, à la première personne : formule d'appel (« Cher Monsieur, », « Chère Madame, », ou « Mon cher Maître, » pour un confrère), corps en paragraphes courts, clôture « Bien à vous, » (« Sentiments dévoués, » pour un confrère), jamais « Bien cordialement ». Pas d'objet, pas de signature. Sans tiret cadratin ni demi-cadratin, sans formule passe-partout (« N'hésitez pas à », « Il est important de noter que », « Dans le cadre de »)."),
        ("Points clés", "Résume en une liste de points clés, une ligne par point, commençant par un tiret."),
    ] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let proposal {
                review(proposal)
            } else if showsRaw {
                raw
            } else if let draft {
                drafting(draft)
            } else {
                editor
            }
            HStack(spacing: 6) {
                Hint("\(text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count) mots · \(Self.spoken(recording.duration))")
                // Dictée à durée limitée : « expire dans 3 h » et « Garder », qui retire l'expiration.
                if let expiresIn = recording.expiresIn {
                    Text("· expire \(expiresIn)").font(.ui(11)).foregroundStyle(Theme.muted).lineLimit(1)
                    Button("Garder") { withAnimation(Motion.quick) { RecordingStore.shared.keep(recording.id) } }
                        .buttonStyle(.plain)
                        .font(.ui(11, weight: .medium))
                        .underline()
                        .help("Garder cette dictée dans l'historique sans limite de durée")
                }
                Spacer()
                if hasChanges, !showsRaw, proposal == nil {
                    Button("Voir le texte brut") { withAnimation(Motion.quick) { showsRaw = true } }
                        .buttonStyle(.plain)
                        .font(.ui(11, weight: .medium))
                        .underline()
                        .foregroundStyle(Theme.muted)
                        .keyboardFocusRing(radius: 4)
                        .help("La transcription de Murmure avant mise en forme, en différences avec le texte actuel")
                }
                if !showsRaw, proposal == nil, draft == nil {
                    CopyIcon(text: text, help: "Copier le texte")
                }
            }
            .frame(minHeight: 26)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Retravailler").font(.ui(12, weight: .medium)).foregroundStyle(Theme.muted)
                    if !Cleaner.isReady {
                        Hint(Cleaner.notReadyReason.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")))
                    }
                }
                HStack(spacing: 6) {
                    ForEach(Self.presets, id: \.label) { preset in
                        Button(preset.label) { rework(preset.instruction) }
                            .buttonStyle(OutlineButtonStyle())
                            .disabled(working || !Cleaner.isReady)
                    }
                    if let previous {
                        Button { text = previous; self.previous = nil } label: { Label("Revenir au texte précédent", systemImage: "arrow.uturn.backward") }
                            .buttonStyle(OutlineButtonStyle())
                            .transition(.opacity)
                    }
                }
                .animation(Motion.quick, value: previous != nil)
            }
            .disabled(proposal != nil)
            PromptBar(text: $instruction, working: working, placeholder: "Que voulez-vous modifier ?") {
                rework(instruction)
            }
            .disabled(!Cleaner.isReady || proposal != nil)
            if let error {
                ErrorCard(message: error, retry: retry).transition(.opacity)
            }
        }
        .animation(Motion.quick, value: error)
        .animation(Motion.quick, value: proposal != nil)
        .animation(Motion.quick, value: draft != nil)
        .animation(Motion.quick, value: showsRaw)
        // Un terme cherché depuis l'accueil qui ne se trouve que dans le texte brut : celui-ci s'ouvre d'emblée.
        .onAppear {
            let query = app.highlight
            if !query.isEmpty, hasChanges, occurrences(of: query, in: text) == 0, occurrences(of: query, in: recording.rawText) > 0 {
                showsRaw = true
            }
        }
    }

    /// L'éditeur, sans cadre, comme une page (à la manière des Notes) ; Copier est sur la ligne « N mots ».
    private var editor: some View {
        Group {
            if StaticPreview.active {
                // `ImageRenderer` ne dessine pas les vues AppKit (éditeur de texte).
                Text(text)
                    .lineSpacing(5)
                    .padding(.leading, 5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                TextEditor(text: $text)
                    .lineSpacing(5)
                    .scrollContentBackground(.hidden)
                    .onChange(of: text) { _, newValue in
                        if newValue != recording.text { RecordingStore.shared.updateText(recording.id, to: newValue) }
                    }
            }
        }
        .readingFont(delta: 1)
        .padding(.leading, -5) // le texte de l'éditeur s'aligne sur la colonne
        .transition(.opacity)
    }

    /// Le texte retravaillé, en différences avec l'actuel : mots retirés barrés, ajoutés soulignés ; Garder ou Annuler.
    private func review(_ proposal: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                Text(changes(from: text, to: proposal))
                    .readingFont(delta: 1)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.fg))
            HStack(spacing: 8) {
                Button("Garder") {
                    previous = text
                    text = proposal
                    self.proposal = nil
                }
                .buttonStyle(OutlineButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                Button("Annuler") { self.proposal = nil }
                    .buttonStyle(OutlineButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Hint("retiré barré · ajouté souligné")
            }
        }
        .transition(.opacity)
    }

    /// Le texte brut de Murmure, sans cadre comme l'éditeur, en différences avec le texte actuel (retiré barré, ajouté
    /// souligné, terme cherché surligné) ; on peut y revenir (« Revenir au texte précédent » annule), le copier, ou fermer.
    private var raw: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if StaticPreview.active {
                    rawText.frame(maxHeight: .infinity, alignment: .top)
                } else {
                    ScrollView { rawText }
                }
            }
            HStack(spacing: 8) {
                Button("Revenir au texte brut") {
                    previous = text
                    text = recording.rawText
                    withAnimation(Motion.quick) { showsRaw = false }
                }
                .buttonStyle(OutlineButtonStyle())
                .help("Remplace le texte de la dictée par la transcription brute de Murmure, sans mise en forme")
                Button("Copier le texte brut") { copy(recording.rawText) }
                    .buttonStyle(OutlineButtonStyle())
                Button("Fermer") { withAnimation(Motion.quick) { showsRaw = false } }
                    .buttonStyle(OutlineButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Hint("brut : retiré barré · ajouté souligné")
            }
        }
        .transition(.opacity)
    }

    private var rawText: some View {
        Text(highlighted(changes(from: recording.rawText, to: text), app.highlight))
            .readingFont(delta: 1)
            .lineSpacing(5)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Le texte en cours de rédaction, qui s'écrit sous les yeux ; « Arrêter » abandonne et garde le texte actuel.
    private func drafting(_ draft: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                Text(draft.isEmpty ? "…" : draft)
                    .readingFont(delta: 1)
                    .lineSpacing(5)
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Spinner(size: 12, color: Theme.muted, lineWidth: 1.4)
                Text("Rédaction \(RecordingStore.shared.isLocalOnly(recording) ? "sur ce Mac" : Cleaner.whereText)…")
                    .font(.ui(12)).foregroundStyle(Theme.muted)
                Button("Arrêter") { task?.cancel() }
                    .buttonStyle(OutlineButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .help("Abandonne la retouche en cours ; le texte reste tel quel")
            }
        }
        .transition(.opacity)
    }

    /// « 1 min 40 » : durée parlée, avec les secondes sous l'heure.
    private static func spoken(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(String(format: "%02d", s % 60))" }
        return formatDuration(seconds)
    }

    private func rework(_ order: String) {
        let order = order.trimmingCharacters(in: .whitespaces)
        guard !order.isEmpty, !text.isEmpty else { return }
        working = true
        error = nil
        draft = ""
        let original = text
        let localOnly = RecordingStore.shared.isLocalOnly(recording)
        task = Task {
            do {
                let result = try await Cleaner.$localOnly.withValue(localOnly) {
                    try await Cleaner.rework(original, instruction: order,
                                             onPartial: { partial in Task { @MainActor in if draft != nil { draft = partial } } })
                }
                await MainActor.run {
                    if result.trimmingCharacters(in: .whitespacesAndNewlines) == original.trimmingCharacters(in: .whitespacesAndNewlines) {
                        error = "Le modèle n'a rien changé."
                        retry = nil
                    } else {
                        proposal = result
                        instruction = ""
                    }
                }
            } catch {
                // Arrêté par l'utilisateur : le texte reste tel quel, sans message.
                if !Task.isCancelled {
                    await MainActor.run {
                        self.error = "Retouche impossible : \(error.localizedDescription)"
                        retry = { rework(order) }
                    }
                }
            }
            await MainActor.run { working = false; draft = nil }
        }
    }
}

/// Notes de l'utilisateur : prises pendant la réunion sur la page En direct, complétables ici ; le prochain
/// compte rendu les reprend en priorité. Une page sans cadre, l'explication dans le texte d'invite.
private struct NotesPane: View {
    let recording: Recording
    @State private var text: String

    init(recording: Recording) {
        self.recording = recording
        _text = State(initialValue: recording.notes ?? "")
    }

    var body: some View {
        NotesEditor(text: $text,
                    placeholder: "Vos notes : points importants, questions, engagements pris… Le prochain compte rendu les reprend en priorité.",
                    delta: 1, spacing: 6)
            .padding(.leading, -5) // le texte de l'éditeur s'aligne sur la colonne
            .padding(.bottom, 24)
            .onChange(of: text) { _, newValue in
                if newValue != (recording.notes ?? "") { RecordingStore.shared.setNotes(recording.id, newValue) }
            }
    }
}

// MARK: - Proposition d'accompagnement

/// Le mail de fin de premier rendez-vous (compréhension de la situation, mission, honoraires, pièces à réunir),
/// rédigé à partir de la réunion selon la trame du cabinet, relu et corrigé ici, puis ouvert en brouillon dans la
/// messagerie. Le texte reste dans la fiche.
private struct ProposalPane: View {
    let recording: Recording
    @State private var outline: Summarizer.ProposalOutline = .standard
    @State private var fee = ""
    @State private var peer = false
    @State private var text: String
    /// Texte en cours de rédaction, affiché au fil des mots ; nil au repos.
    @State private var draft: String?
    @State private var working = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    init(recording: Recording) {
        self.recording = recording
        _text = State(initialValue: recording.proposal ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let draft {
                drafting(draft)
            } else if text.isEmpty {
                Text("Le mail de fin de premier rendez-vous, rédigé selon la trame du cabinet.")
                    .font(.ui(13))
                    .fixedSize(horizontal: false, vertical: true)
                options
                VStack(alignment: .leading, spacing: 8) {
                    Button("Rédiger la proposition") { write() }
                        .buttonStyle(OutlineButtonStyle(prominent: true))
                        .disabled(!ready || working)
                    Hint(ready
                         ? "Rédigée \(localOnly ? "sur ce Mac" : Cleaner.whereText) à partir de la transcription\(recording.summaries?.last == nil ? "" : " et du compte rendu"), puis ouverte en brouillon dans \(Connectors.mailApp.shortName) : rien n'est envoyé sans vous."
                         : Cleaner.notReadyReason)
                }
            } else {
                editor
                HStack(spacing: 8) {
                    Button { open() } label: { Label("Ouvrir dans \(Connectors.mailApp.shortName)", systemImage: "envelope") }
                        .buttonStyle(OutlineButtonStyle(prominent: true))
                        .help("Ouvre ce texte en brouillon, adressé aux invités du rendez-vous ; vous le relisez et l'envoyez vous-même")
                    Button("Rédiger à nouveau") {
                        withAnimation(Motion.quick) {
                            text = ""
                            RecordingStore.shared.setProposal(recording.id, nil)
                        }
                    }
                    .buttonStyle(OutlineButtonStyle())
                    .help("Efface cette proposition pour en rédiger une autre, avec d'autres choix")
                    Spacer()
                    Hint("rédigée par Murmure, à relire avant envoi")
                }
                .padding(.bottom, 24)
            }
            if let error {
                ErrorCard(message: error) { write() }.transition(.opacity)
            }
        }
        .animation(Motion.quick, value: error)
        .animation(Motion.quick, value: draft != nil)
    }

    /// Trame, honoraires, destinataire (ce que la transcription ne dit pas toujours), dans une carte grise,
    /// chaque étiquette au-dessus de son contrôle.
    private var options: some View {
        VStack(alignment: .leading, spacing: 18) {
            field("Trame") {
                Choice(options: Summarizer.ProposalOutline.allCases.map { ($0, $0.rawValue) }, selection: $outline)
                Text(outline.detail).font(.ui(11)).foregroundStyle(Theme.muted)
            }
            field("Honoraires") {
                Group {
                    if StaticPreview.active {
                        Text(fee.isEmpty ? Self.feePlaceholder : fee)
                            .foregroundStyle(fee.isEmpty ? Theme.muted : Theme.fg)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        TextField(Self.feePlaceholder, text: $fee).textFieldStyle(.plain)
                    }
                }
                .font(.ui(12))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.bg))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line))
            }
            field("Destinataire") {
                Choice(options: [(false, "Client"), (true, "Confrère")], selection: $peer)
                Text(peer ? "Avocat, notaire ou commissaire de justice : « Mon cher Maître, » et « Sentiments dévoués, »."
                          : "« Cher Monsieur, » ou « Chère Madame, », et « Bien à vous, ».")
                    .font(.ui(11)).foregroundStyle(Theme.muted)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.soft))
        .overlay {
            if Theme.highContrast { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line) }
        }
    }

    private static let feePlaceholder = "Forfait HT arrêté au rendez-vous, par exemple « 3 500 € » ; vide : « [montant] € HT », à compléter"

    private func field<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.ui(12))
                .foregroundStyle(Theme.muted)
            control()
        }
    }

    /// Le mail, modifiable comme une page, sans cadre ; chaque changement est gardé dans la fiche.
    private var editor: some View {
        Group {
            if StaticPreview.active {
                Text(text)
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                TextEditor(text: $text)
                    .lineSpacing(6)
                    .scrollContentBackground(.hidden)
                    .padding(.leading, -5) // le texte de l'éditeur s'aligne sur la colonne
                    .onChange(of: text) { _, newValue in
                        if newValue != (recording.proposal ?? "") { RecordingStore.shared.setProposal(recording.id, newValue) }
                    }
            }
        }
        .readingFont(delta: 1)
        .transition(.opacity)
    }

    private func drafting(_ draft: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                Text(draft.isEmpty ? "…" : draft)
                    .readingFont(delta: 1)
                    .lineSpacing(6)
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Spinner(size: 12, color: Theme.muted, lineWidth: 1.4)
                Text(draft.isEmpty && recording.transcript.count > 12_000 ? "Lecture de la réunion par tranches…"
                     : "Rédaction \(localOnly ? "sur ce Mac" : Cleaner.whereText)…")
                    .font(.ui(12)).foregroundStyle(Theme.muted)
                Button("Arrêter") { task?.cancel() }
                    .buttonStyle(OutlineButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.bottom, 24)
        }
        .transition(.opacity)
    }

    private var localOnly: Bool { RecordingStore.shared.isLocalOnly(recording) }
    private var ready: Bool { Cleaner.isReady(localOnly: localOnly) }

    private func write() {
        guard ready, !working else { return }
        working = true
        error = nil
        draft = ""
        let recording = recording
        let localOnly = localOnly
        let options = Summarizer.ProposalOptions(outline: outline, fee: fee.trimmingCharacters(in: .whitespaces), peer: peer)
        task = Task {
            do {
                let result = try await Cleaner.$localOnly.withValue(localOnly) {
                    try await Summarizer.proposal(transcript: recording.transcript, participants: recording.participantNames,
                                                  date: recording.date, notes: recording.userNotes,
                                                  summary: recording.summaries?.last?.text, options: options,
                                                  onPartial: { partial in Task { @MainActor in if draft != nil { draft = partial } } })
                }
                await MainActor.run {
                    text = result
                    RecordingStore.shared.setProposal(recording.id, result)
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run { self.error = "Rédaction impossible : \(error.localizedDescription)" }
                }
            }
            await MainActor.run { working = false; draft = nil }
        }
    }

    /// Ouvre le texte en brouillon : l'objet est la première ligne « Objet : … », le reste est le corps.
    private func open() {
        let (subject, body) = Summarizer.splitSubject(text)
        Connectors.compose(to: recording.recipients, subject: subject ?? "Proposition d'accompagnement", body: body)
    }
}

/// Différences mot à mot entre la transcription brute et le texte final :
/// mots retirés barrés et estompés, mots ajoutés soulignés.
func changes(from raw: String, to final: String) -> AttributedString {
    func tokens(_ text: String) -> [String] {
        var result: [String] = [], current = ""
        for character in text {
            if character.isWhitespace { if !current.isEmpty { result.append(current); current = "" } } else { current.append(character) }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
    let a = tokens(raw), b = tokens(final)
    guard a.count * b.count <= 400_000 else { return AttributedString(final) }
    var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
    for i in stride(from: a.count - 1, through: 0, by: -1) {
        for j in stride(from: b.count - 1, through: 0, by: -1) {
            table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
        }
    }
    var result = AttributedString()
    func append(_ word: String, _ style: (inout AttributedString) -> Void = { _ in }) {
        if !result.characters.isEmpty { result += AttributedString(" ") }
        var piece = AttributedString(word)
        style(&piece)
        result += piece
    }
    var i = 0, j = 0
    while i < a.count || j < b.count {
        if i < a.count, j < b.count, a[i] == b[j] {
            append(a[i]); i += 1; j += 1
        } else if j < b.count, i == a.count || table[i][j + 1] >= table[i + 1][j] {
            append(b[j]) { $0.underlineStyle = .single }
            j += 1
        } else {
            append(a[i]) { $0.strikethroughStyle = .single; $0.foregroundColor = Theme.muted }
            i += 1
        }
    }
    return result
}
