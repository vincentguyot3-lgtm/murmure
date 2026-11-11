import AVFoundation
import SwiftUI

/// Accueil du premier lancement, qui personnalise Murmure : prénom, métier et domaines, attentes,
/// autorisations, test du micro, raccourci, services en ligne facultatifs (les clés s'y collent et s'y
/// vérifient), puis une carte qui résume ce qui a été réglé.
/// Les choix ne sont pas décoratifs : voir `Profile.swift` pour ce que chacun change.
struct Onboarding: View {
    let finish: () -> Void

    @ObservedObject private var state = AppState.shared
    @ObservedObject private var installer = LocalLLMInstaller.shared
    @ObservedObject private var store = RecordingStore.shared
    @AppStorage("dictationKey") private var dictationKey = DictationKey.rightOption.rawValue
    @AppStorage("userName") private var userName = Settings.defaultUserName
    @State private var step: Int
    @State private var forward = true
    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    /// Nombre de dictées à l'arrivée sur l'écran « Votre raccourci » : une de plus, et l'essai a réussi.
    @State private var baseline: Int?
    /// Métier choisi ; vide tant que rien n'est touché (Murmure reste alors réglé pour un avocat).
    @State private var profession: Profession?
    @State private var domains: Set<String>
    @State private var goals: Set<Goal>
    /// Ce que la personnalisation a réglé, pour la carte de fin.
    @State private var done: [String]
    /// Écran « En ligne » : clé en cours de saisie et état de chaque service.
    @State private var claudeDraft = ""
    @State private var onlineDraft = ""
    @State private var claudeStatus: KeySetup.Status
    @State private var onlineStatus: KeySetup.Status
    @FocusState private var nameFocused: Bool

    static let steps = 8

    init(finish: @escaping () -> Void) {
        self.finish = finish
        _step = State(initialValue: 0)
        _profession = State(initialValue: UserDefaults.standard.string(forKey: "profession").flatMap(Profession.init))
        _domains = State(initialValue: Set(Settings.domains))
        _goals = State(initialValue: Settings.goals)
        _done = State(initialValue: [])
        // Personnalisation refaite : un service déjà réglé s'affiche comme tel.
        _claudeStatus = State(initialValue: ClaudeAPI.hasKey && Cleaner.chosen == .claude
                              ? .valid("Clé enregistrée : Claude relit vos dictées et rédige vos comptes rendus.") : .idle)
        _onlineStatus = State(initialValue: OnlineTranscription.hasKey && OnlineTranscription.isChosen
                              ? .valid("Clé enregistrée : vos réunions sont transcrites en ligne.") : .idle)
    }

    /// Aperçu d'un écran, avec des choix d'exemple (`--apercu-bienvenue`), sans rien lire ni écrire des réglages.
    init(previewStep step: Int) {
        finish = {}
        _step = State(initialValue: step)
        _profession = State(initialValue: .avocat)
        _domains = State(initialValue: ["Droit pénal", "Contentieux"])
        _goals = State(initialValue: [.write, .meetings, .reports])
        _done = State(initialValue: [
            "5 mots de votre métier ajoutés au dictionnaire",
            "Texte collé là où se trouve votre curseur, accordé à ce qui l'entoure",
            "Appels, visios et rendez-vous repérés : Murmure propose de les enregistrer, participants compris",
            "Chaque réunion se termine par un compte rendu de rendez-vous client",
            "Tout se fait sur ce Mac : rien ne part en ligne",
        ])
        // Les deux cartes avec leur champ : le cas le plus haut de l'écran « En ligne ».
        _claudeStatus = State(initialValue: .idle)
        _onlineStatus = State(initialValue: .idle)
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                ZStack(alignment: .topLeading) {
                    page
                        .id(step)
                        .transition(Motion.level == .full
                                    ? .asymmetric(insertion: .offset(x: forward ? 30 : -30).combined(with: .opacity), removal: .opacity)
                                    : .opacity)
                }
                .frame(width: 560, height: 470, alignment: .topLeading)
                Spacer(minLength: 24)
                footer
                    .frame(width: 560)
                    .padding(.bottom, 40)
            }
        }
        .animation(Motion.page, value: step)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }

    @ViewBuilder private var page: some View {
        switch step {
        case 0: welcome
        case 1: work
        case 2: expectations
        case 3: permissions
        case 4: microphone
        case 5: shortcut
        case 6: online
        default: ready
        }
    }

    /// En-tête d'un écran : étiquette d'étape, grand titre, phrase d'explication.
    private func heading(_ eyebrow: String, _ title: String, _ detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(eyebrow)
                .font(.ui(12, weight: .medium))
                .foregroundStyle(Theme.accent)
                .staggered(0)
            Text(title)
                .font(.ui(32, weight: .semibold))
                .tracking(-0.8)
                .fixedSize(horizontal: false, vertical: true)
                .staggered(1)
            if let detail {
                Text(detail)
                    .font(.ui(14))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .staggered(2)
            }
        }
    }

    // MARK: Écrans

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            LogoMark(height: 38)
                .padding(.bottom, 10)
                .staggered(0)
            Text("Bienvenue dans Murmure")
                .font(.ui(36, weight: .semibold))
                .tracking(-1)
                .staggered(1)
            Text("Dictez dans n'importe quelle application et enregistrez vos réunions. Transcription, mise en forme et comptes rendus se font sur ce Mac. En deux minutes, réglons-le pour vous.")
                .font(.ui(15))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .staggered(2)
            VStack(alignment: .leading, spacing: 8) {
                Text("Comment vous appeler ?")
                    .font(.ui(12, weight: .medium))
                    .foregroundStyle(Theme.muted)
                Group {
                    if StaticPreview.active {
                        Text(userName).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        TextField("Votre prénom", text: $userName)
                            .textFieldStyle(.plain)
                            .focused($nameFocused)
                    }
                }
                .font(.ui(22, weight: .medium))
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(nameFocused ? Theme.fg : Theme.line).frame(height: nameFocused ? 1.5 : 1)
                }
                .frame(width: 320)
                .animation(Motion.quick, value: nameFocused)
            }
            .padding(.top, 18)
            .staggered(3)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    switch state.modelStatus {
                    case .loading:
                        Spinner(size: 12, color: Theme.muted, lineWidth: 1.4)
                        Text("Préparation du modèle de transcription (téléchargé une seule fois, environ 1,6 Go)…")
                    case .ready:
                        Image(systemName: "checkmark.circle.fill")
                        Text("Modèle de transcription prêt")
                    case .failed(let reason):
                        Image(systemName: "exclamationmark.triangle")
                        Text(reason)
                    }
                }
                // Le modèle de rédaction ne concerne que le moteur local (Claude et Apple Intelligence s'en passent).
                if Cleaner.keepsLocalModel || installer.summary != nil {
                    HStack(spacing: 8) {
                        switch state.llmStatus {
                        case .loading:
                            Spinner(size: 12, color: Theme.muted, lineWidth: 1.4)
                            Text(installer.summary.map { "Téléchargement du modèle de rédaction (une seule fois) · \($0)" }
                                 ?? "Chargement du modèle de rédaction…")
                        case .ready:
                            Image(systemName: "checkmark.circle.fill")
                            Text("Modèle de rédaction prêt")
                        case .failed(let reason):
                            Image(systemName: "exclamationmark.triangle")
                            Text(reason)
                        }
                    }
                }
            }
            .font(.ui(12))
            .foregroundStyle(Theme.muted)
        }
    }

    private var work: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("Votre métier", "Pour qui Murmure écrit-il ?",
                    "Les comptes rendus, la relecture des dictées et le dictionnaire s'accordent à votre métier.")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(Array(Profession.allCases.enumerated()), id: \.element) { index, item in
                    ProfessionCard(profession: item, selected: profession == item) {
                        if profession != item { domains = [] }
                        profession = item
                    }
                    .staggered(3 + index / 4)
                }
            }
            if let profession, !profession.domains.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Vos domaines, autant que vous voulez")
                        .font(.ui(12, weight: .medium))
                        .foregroundStyle(Theme.muted)
                    FlowLayout(spacing: 8) {
                        ForEach(profession.domains, id: \.self) { domain in
                            Chip(title: domain, selected: domains.contains(domain)) {
                                if domains.contains(domain) { domains.remove(domain) } else { domains.insert(domain) }
                            }
                        }
                    }
                }
                .id(profession)
                .transition(Motion.slideTransition(from: .bottom))
            }
        }
        .animation(Motion.quick, value: profession)
    }

    private var expectations: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("Vos attentes", "Qu'attendez-vous de Murmure ?",
                    "Plusieurs choix possibles. Murmure se règle en conséquence ; tout reste modifiable.")
            VStack(spacing: 8) {
                ForEach(Array(Goal.allCases.enumerated()), id: \.element) { index, goal in
                    GoalRow(goal: goal, selected: goals.contains(goal)) {
                        if goals.contains(goal) { goals.remove(goal) } else { goals.insert(goal) }
                    }
                    .staggered(3 + index)
                }
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("Autorisations", "Deux autorisations", "macOS ne les demande qu'une fois.")
            VStack(spacing: 10) {
                PermissionRow(symbol: "mic", title: "Micro",
                              detail: "Pour entendre ce que vous dictez. Il ne s'ouvre que pendant une dictée ou une réunion.",
                              granted: micGranted) {
                    if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
                        SystemSettings.open(.microphone)
                    } else {
                        AVCaptureDevice.requestAccess(for: .audio) { granted in
                            DispatchQueue.main.async { micGranted = granted }
                        }
                    }
                }
                .staggered(3)
                PermissionRow(symbol: "keyboard", title: "Accessibilité",
                              detail: "Pour coller le texte là où se trouve votre curseur, dans n'importe quelle application.",
                              granted: state.accessibilityGranted, request: SystemSettings.requestAccessibility)
                    .staggered(4)
            }
        }
    }

    private var microphone: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("Votre micro", "Murmure vous entend-il bien ?",
                    "Un test d'une dizaine de secondes. Vous pourrez le refaire dans Réglages › Général.")
            if micGranted || StaticPreview.active {
                MicTestView(sentence: (profession ?? .avocat).testSentence)
                    .staggered(3)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "mic.slash").font(.ui(16))
                    Text("Le micro n'est pas encore autorisé : revenez à l'écran précédent pour l'accorder.")
                        .font(.ui(13))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.soft))
            }
        }
    }

    private var shortcut: some View {
        let key = DictationKey(rawValue: dictationKey) ?? .rightOption
        return VStack(alignment: .leading, spacing: 22) {
            heading("Votre raccourci", "Maintenez, parlez, relâchez",
                    "Le texte se colle là où se trouve votre curseur. Un appui bref lance une dictée mains libres ; Échap annule.")
            SettingsSection(title: "Touche de dictée") {
                SettingsRow(label: "Touche", last: true) {
                    Dropdown(options: DictationKey.allCases.map { ($0.rawValue, $0.label) }, selection: $dictationKey)
                }
            }
            .staggered(3)
            // L'essai : la carte dit « ça a marché » dès qu'une dictée arrive dans l'historique.
            Group {
                if let first = firstDictation {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").font(.ui(16))
                        Text("Première dictée réussie · \(first.wordCount) mot\(first.wordCount > 1 ? "s" : "")")
                            .font(.ui(13, weight: .medium))
                        Spacer()
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.inverse))
                    .foregroundStyle(Theme.onInverse)
                    .transition(Motion.popTransition())
                } else {
                    HStack(spacing: 14) {
                        Text("Essayez : cliquez dans une autre application, maintenez \(key.label) et dites quelques mots.")
                            .font(.ui(13))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        PillPreview(atTop: false, liveText: false, size: CGSize(width: 150, height: 86), scale: 0.5)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.soft))
                }
            }
            .animation(Motion.pop, value: firstDictation?.id)
            .staggered(4)
        }
        .onAppear { if baseline == nil { baseline = store.recordings.count } }
    }

    private var online: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("En ligne, si vous voulez", "Deux services facultatifs",
                    "Murmure fait déjà tout sur ce Mac. Ces deux services le rendent plus fin. Chacun demande une clé : un mot de passe personnel, qui relie Murmure à votre compte chez le service, et donc à votre facture.")
            ServiceKeyCard(symbol: "text.badge.checkmark", title: "Claude relit et rédige",
                           detail: "Dictées relues avec leur contexte, comptes rendus rédigés par Claude. Seul du texte part, jamais le son. Environ un dixième de centime par dictée.",
                           steps: "Sur la Console Anthropic : créez un compte, ajoutez un crédit, puis créez une clé. Un abonnement Claude ne donne pas de clé.",
                           linkLabel: "Ouvrir la Console", link: KeySetup.claudeSite, placeholder: "sk-ant-…",
                           draft: $claudeDraft, status: claudeStatus, verify: verifyClaude, remove: removeClaude)
                .staggered(3)
            ServiceKeyCard(symbol: "waveform", title: "Réunions transcrites en ligne",
                           detail: "Le son des réunions est transcrit plus précisément par \(OnlineTranscription.serviceName), sur un serveur européen, puis supprimé. Les dictées restent sur ce Mac. Environ 0,30 $ par heure.",
                           steps: "Sur assemblyai.com : créez un compte, puis copiez la clé de la rubrique API Keys.",
                           linkLabel: "Ouvrir le site", link: KeySetup.transcriptionSite, placeholder: "Clé",
                           draft: $onlineDraft, status: onlineStatus, verify: verifyOnline, remove: removeOnline)
                .staggered(4)
            Text("Rien d'obligatoire : « Continuer » garde tout sur ce Mac. À retrouver dans Réglages › Transcription.")
                .font(.ui(12))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .staggered(5)
        }
    }

    private func verifyClaude() {
        let draft = claudeDraft
        claudeStatus = .checking
        Task {
            let result = await KeySetup.tryClaude(draft)
            await MainActor.run {
                if result.ok {
                    claudeDraft = ""
                    Settings.cleanupEngine = Cleaner.Engine.claude.rawValue
                    AppDelegate.startLocalLLM()
                }
                claudeStatus = result.ok ? .valid(result.message) : .failed(result.message)
            }
        }
    }

    private func removeClaude() {
        ClaudeAPI.setKey("")
        Settings.cleanupEngine = Cleaner.Engine.local.rawValue
        AppDelegate.startLocalLLM()
        claudeStatus = .idle
    }

    private func verifyOnline() {
        let draft = onlineDraft
        onlineStatus = .checking
        Task {
            let result = await KeySetup.tryTranscription(draft)
            await MainActor.run {
                if result.ok {
                    onlineDraft = ""
                    Settings.meetingTranscription = "online"
                }
                onlineStatus = result.ok ? .valid(result.message) : .failed(result.message)
            }
        }
    }

    private func removeOnline() {
        OnlineTranscription.setKey("")
        Settings.meetingTranscription = "local"
        onlineStatus = .idle
    }

    private var ready: some View {
        let name = userName.trimmingCharacters(in: .whitespaces)
        let chosen = profession ?? .avocat
        let fields = chosen.domains.filter(domains.contains)
        return VStack(alignment: .leading, spacing: 22) {
            heading("Votre profil", name.isEmpty ? "Votre Murmure est prêt" : "Tout est prêt, \(name)")
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(name.isEmpty ? "Votre profil" : name)
                            .font(.ui(24, weight: .semibold))
                            .tracking(-0.5)
                        Text(([chosen.label] + fields).joined(separator: " · "))
                            .font(.ui(13))
                            .opacity(0.7)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Image(systemName: chosen.symbol).font(.ui(22)).opacity(0.8)
                }
                Rectangle().fill(Theme.onInverse.opacity(0.18)).frame(height: 1)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array((done.isEmpty ? ["Murmure garde ses réglages par défaut"] : done).enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "checkmark").font(.ui(11, weight: .bold)).padding(.top, 2)
                            Text(line).font(.ui(13)).fixedSize(horizontal: false, vertical: true)
                        }
                        .staggered(4 + index)
                    }
                }
            }
            .padding(24)
            .foregroundStyle(Theme.onInverse)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.inverse))
            .staggered(2)
            Text("Tout se change dans Réglages › Général, où « Refaire » vous ramène ici.")
                .font(.ui(12))
                .foregroundStyle(Theme.muted)
                .staggered(3)
        }
    }

    private var firstDictation: Recording? {
        guard let baseline, store.recordings.count > baseline else { return nil }
        return store.recordings.first { !$0.isMeeting }
    }

    // MARK: Pied

    /// Enregistre les choix et règle l'application, au moment de passer à la carte de fin.
    private func saveChoices() {
        if let profession { Settings.profession = profession }
        Settings.domains = (profession ?? .avocat).domains.filter(domains.contains)
        Settings.goals = goals
        done = UserProfile.applyChoices()
        // Où se fait le travail : dit sur la carte de fin, qu'une clé ait été collée ou non.
        let claude = claudeStatus.isValid, transcription = onlineStatus.isValid
        if claude { done.append("Dictées relues et comptes rendus rédigés par Claude, en ligne") }
        if transcription { done.append("Réunions transcrites en ligne, sur un serveur européen") }
        if !claude, !transcription { done.append("Tout se fait sur ce Mac : rien ne part en ligne") }
    }

    /// Sans micro ou sans accessibilité, on prévient avant de fermer l'accueil : la dictée ne marcherait pas, ou copierait seulement.
    private func start() {
        var missing: [String] = []
        if !micGranted { missing.append("sans le micro, Murmure ne peut rien entendre") }
        if !state.accessibilityGranted { missing.append("sans l'accessibilité, le texte est copié mais pas collé") }
        guard !missing.isEmpty else { finish(); return }
        Modals.shared.confirm("Continuer sans autorisation ?",
                              message: missing.joined(separator: " ; ").capitalizedFirst + ". Vous pourrez les accorder plus tard dans Réglages.",
                              confirm: "Continuer quand même", then: finish)
    }

    private var last: Bool { step == Self.steps - 1 }

    private var footer: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(0..<Self.steps, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? Theme.fg : Theme.line)
                        .frame(width: index == step ? 18 : 6, height: 6)
                }
            }
            .animation(Motion.quick, value: step)
            Spacer()
            if step > 0 {
                Button("Retour") {
                    forward = false
                    step -= 1
                }
                .buttonStyle(OutlineButtonStyle())
            }
            Button(last ? "Commencer" : "Continuer") {
                if last {
                    start()
                } else {
                    if step == Self.steps - 2 { saveChoices() }
                    forward = true
                    step += 1
                }
            }
            .buttonStyle(OutlineButtonStyle(prominent: true))
            .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Éléments

/// Entrée échelonnée des éléments d'un écran : chacun glisse de quelques points et apparaît un peu après le précédent.
private struct Staggered: ViewModifier {
    let order: Int
    @State private var shown = StaticPreview.active || Motion.level == .none

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || Motion.level != .full ? 0 : 10)
            .onAppear {
                guard !shown else { return }
                withAnimation(Motion.page?.delay(0.05 + Double(order) * 0.045)) { shown = true }
            }
    }
}

private extension View {
    func staggered(_ order: Int) -> some View { modifier(Staggered(order: order)) }
}

/// Mise en service d'une clé depuis l'accueil : enregistrée, vérifiée auprès du service, et retirée si elle est
/// refusée (la clé d'avant, s'il y en avait une, est remise). Ne touche pas aux réglages : l'écran le fait
/// quand la clé est valide. Essai sans interface : `Murmure --essai-cles claude|transcription clé`.
enum KeySetup {
    enum Status: Equatable {
        case idle, checking
        case valid(String)
        case failed(String)

        var isValid: Bool { if case .valid = self { return true } else { return false } }
    }

    static let claudeSite = URL(string: "https://console.anthropic.com/settings/keys")!
    static let transcriptionSite = URL(string: "https://www.assemblyai.com/dashboard/api-keys")!

    static func tryClaude(_ draft: String) async -> (ok: Bool, message: String) {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return (false, "Collez d'abord la clé.") }
        let previous = ClaudeAPI.key ?? ""
        ClaudeAPI.setKey(key)
        do {
            let model = try await ClaudeAPI.shared.verify()
            return (true, "Clé valide : \(model) a répondu. Claude relira vos dictées et rédigera vos comptes rendus.")
        } catch ClaudeAPI.ClaudeError.badKey {
            ClaudeAPI.setKey(previous)
            return (false, "Clé refusée par Anthropic : vérifiez qu'elle est copiée en entier.")
        } catch {
            ClaudeAPI.setKey(previous)
            return (false, error.localizedDescription.capitalizedFirst)
        }
    }

    static func tryTranscription(_ draft: String) async -> (ok: Bool, message: String) {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return (false, "Collez d'abord la clé.") }
        let previous = OnlineTranscription.key ?? ""
        OnlineTranscription.setKey(key)
        let message = await OnlineTranscription.verify()
        guard message == OnlineTranscription.validMessage else {
            OnlineTranscription.setKey(previous)
            return (false, message)
        }
        return (true, "Clé valide : vos réunions seront transcrites en ligne.")
    }
}

/// Carte d'un service en ligne de l'accueil : ce qu'il apporte, comment obtenir la clé, où la coller.
private struct ServiceKeyCard: View {
    let symbol: String
    let title: String
    let detail: String
    let steps: String
    let linkLabel: String
    let link: URL
    let placeholder: String
    @Binding var draft: String
    let status: KeySetup.Status
    let verify: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.ui(15))
                    .frame(width: 20)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.ui(14, weight: .medium))
                    Text(detail)
                        .font(.ui(12))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if case .valid(let message) = status {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").font(.ui(13))
                    Text(message)
                        .font(.ui(12, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Retirer", action: remove).buttonStyle(OutlineButtonStyle())
                }
                .padding(.leading, 32)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(steps)
                        .font(.ui(12))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button(linkLabel) { NSWorkspace.shared.open(link) }
                            .buttonStyle(OutlineButtonStyle())
                        Group {
                            if StaticPreview.active {
                                Text(placeholder).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                SecureField(placeholder, text: $draft)
                                    .textFieldStyle(.plain)
                                    .onSubmit(verify)
                            }
                        }
                        .font(.ui(12))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.bg))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line))
                        if status == .checking {
                            Spinner(size: 12, color: Theme.muted, lineWidth: 1.4)
                        }
                        Button("Vérifier", action: verify)
                            .buttonStyle(OutlineButtonStyle(prominent: true))
                            .disabled(status == .checking || draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if case .failed(let message) = status {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle").font(.ui(11)).padding(.top, 1)
                            Text(message).font(.ui(12)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 32)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.soft))
    }
}

private struct ProfessionCard: View {
    let profession: Profession
    let selected: Bool
    let pick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: profession.symbol).font(.ui(18))
                Spacer(minLength: 14)
                Text(profession.label)
                    .font(.ui(13, weight: .medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .foregroundStyle(selected ? Theme.onInverse : Theme.fg)
            .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Theme.inverse : (hovering ? Theme.soft : Theme.bg)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Theme.inverse : Theme.line))
            .scaleEffect(selected && Motion.level == .full ? 1.02 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardFocusRing(radius: 14, inset: -3)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: selected)
        .animation(Motion.quick, value: hovering)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct Chip: View {
    let title: String
    let selected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                if selected { Image(systemName: "checkmark").font(.ui(10, weight: .bold)).transition(Motion.popTransition(scale: 0.6)) }
                Text(title).font(.ui(12, weight: selected ? .medium : .regular))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(selected ? Theme.onInverse : Theme.fg)
            .background(Capsule().fill(selected ? Theme.inverse : Theme.bg))
            .overlay(Capsule().strokeBorder(selected ? Theme.inverse : Theme.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardFocusRing(radius: 16, inset: -3)
        .animation(Motion.quick, value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct GoalRow: View {
    let goal: Goal
    let selected: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 14) {
                Image(systemName: goal.symbol)
                    .font(.ui(14))
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.inverse : Theme.soft))
                    .foregroundStyle(selected ? Theme.onInverse : Theme.fg)
                VStack(alignment: .leading, spacing: 2) {
                    Text(goal.title).font(.ui(14, weight: .medium))
                    Text(goal.detail).font(.ui(12)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 12)
                ZStack {
                    Circle().strokeBorder(selected ? Theme.fg : Theme.line, lineWidth: 1.5)
                    if selected {
                        Circle().fill(Theme.fg).padding(0.5)
                        Image(systemName: "checkmark").font(.ui(9, weight: .bold)).foregroundStyle(Theme.onInverse)
                    }
                }
                .frame(width: 20, height: 20)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 12).fill(hovering && !selected ? Theme.soft : Theme.bg))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Theme.fg : Theme.line, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardFocusRing(radius: 14, inset: -3)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let granted: Bool
    let request: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.ui(15))
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.soft))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.ui(14, weight: .medium))
                Text(detail)
                    .font(.ui(12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if granted {
                Label("Autorisé", systemImage: "checkmark")
                    .font(.ui(12, weight: .medium))
                    .transition(Motion.popTransition(scale: 0.8))
            } else {
                Button("Autoriser", action: request)
                    .buttonStyle(OutlineButtonStyle(prominent: true))
            }
        }
        .padding(16)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
        .animation(Motion.quick, value: granted)
    }
}
