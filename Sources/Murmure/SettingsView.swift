import EventKit
import ServiceManagement
import SwiftUI

/// Réglages : un rail vertical de six panneaux à gauche, le panneau à droite ; certaines lignes « › »
/// ouvrent une sous-page à tiroir (modèle local, agenda, pastille) qui glisse depuis la droite.
struct SettingsView: View {
    enum Pane: String, CaseIterable {
        case general = "Général", connectors = "Connecteurs", display = "Affichage", accessibility = "Accessibilité",
             transcription = "Transcription", advanced = "Avancé"

        /// Général reprend le pictogramme maison des Réglages (deux curseurs) ; les autres restent des symboles SF.
        var icon: NavIcon {
            switch self {
            case .general: return .glyph(.sliders)
            case .connectors: return "link"
            case .display: return "macwindow"
            case .accessibility: return "accessibility"
            case .transcription: return "text.quote"
            case .advanced: return "wrench.and.screwdriver"
            }
        }
    }

    /// Sous-pages ouvertes depuis une ligne d'un panneau ; chacune revient à son panneau parent.
    enum Subpage: String {
        case model, claude, meetingTranscription, voices, calendar, pill, names, claudeCode, notion, slack, webhook, obsidian, todoist

        var parent: Pane {
            switch self {
            case .model, .claude, .meetingTranscription, .voices, .names: return .transcription
            case .calendar, .claudeCode, .notion, .slack, .webhook, .obsidian, .todoist: return .connectors
            case .pill: return .display
            }
        }
    }

    @ObservedObject private var state = AppState.shared
    @ObservedObject private var installer = LocalLLMInstaller.shared
    @AppStorage("settingsPane") private var pane = Pane.general.rawValue
    @State private var subpage: Subpage?
    /// « Rechercher un réglage » : quand il est rempli, les six panneaux s'empilent, filtrés ligne à ligne.
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    /// Sens du dernier déplacement : le nouveau panneau glisse depuis la droite si l'on avance, depuis la gauche sinon.
    @State private var forward = true
    @FocusState private var focused: Bool
    @FocusState private var nameFocused: Bool
    @Namespace private var rail
    // Général
    @AppStorage("userName") private var userName = Settings.defaultUserName
    @AppStorage("profession") private var profession = Profession.avocat.rawValue
    @AppStorage("meetingSystemAudio") private var meetingSystemAudio = true
    @AppStorage("detectMeetings") private var detectMeetings = true
    @AppStorage("proposeAtAppointments") private var proposeAtAppointments = true
    @AppStorage("remindAppointments") private var remindAppointments = true
    @AppStorage("offerToEndQuietMeetings") private var offerToEndQuietMeetings = true
    @ObservedObject private var startup = OuvertureAuDemarrage.shared
    // Connecteurs
    @AppStorage("useCalendar") private var useCalendar = true
    @AppStorage("mailApp") private var mailApp = Connectors.MailApp.preferred.rawValue
    @State private var calendarAuthorized = Connectors.calendarAuthorized
    @State private var calendarAccounts = Connectors.calendarAccounts
    @State private var currentEvent: CalendarEvent?
    @State private var subscriptionLink = ""
    @State private var subscriptionError = false
    @FocusState private var subscriptionFocused: Bool
    // Affichage
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("motion") private var motion = Motion.Level.full.rawValue
    @AppStorage("compactList") private var compactList = false
    @AppStorage("overlayPosition") private var overlayPosition = "bottom"
    @AppStorage("overlayLiveText") private var overlayLiveText = true
    @AppStorage("floatingButton") private var floatingButton = true
    // Accessibilité
    @AppStorage("readingSize") private var readingSize = 14.0
    @AppStorage("highContrast") private var highContrast = false
    @AppStorage("dictationSounds") private var dictationSounds = false
    // Transcription
    @AppStorage("cleanupEngine") private var cleanupEngine = "local"
    @AppStorage("localModel") private var localModel = "qwen3-4b.gguf"
    // Claude
    @AppStorage("claudeDictationModel") private var claudeDictationModel = ClaudeAPI.defaultDictationModel
    @AppStorage("claudeWritingModel") private var claudeWritingModel = ClaudeAPI.defaultModel
    @AppStorage("claudeFallback") private var claudeFallback = true
    @AppStorage("meetingTranscription") private var meetingTranscription = "local"
    @AppStorage("onlineSendsDictionary") private var onlineSendsDictionary = true
    @AppStorage("onlineImports") private var onlineImports = false
    @AppStorage("stayOffline") private var stayOffline = false
    @State private var onlineKeyDraft = ""
    @State private var onlineKeyPresent = OnlineTranscription.hasKey
    @State private var onlineChecking = false
    @State private var onlineCheck: String?
    @State private var claudeKeyDraft = ""
    @State private var claudeKeyPresent = ClaudeAPI.hasKey
    @State private var claudeChecking = false
    /// Résultat de « Vérifier » (modèle qui a répondu, ou erreur).
    @State private var claudeCheck: String?
    @AppStorage("language") private var language = "fr"
    @AppStorage("fieldContext") private var fieldContext = true
    @AppStorage("learnCorrections") private var learnCorrections = true
    // Avancé
    @AppStorage("keepAudio") private var keepAudio = false
    @AppStorage("avoidBluetoothMic") private var avoidBluetoothMic = true
    @AppStorage("dictationKey") private var dictationKey = DictationKey.rightOption.rawValue
    @AppStorage("autoPaste") private var autoPaste = true
    @AppStorage("dictationRetention") private var dictationRetention = Settings.DictationRetention.day.rawValue
    @AppStorage("muteWhileDictating") private var muteWhileDictating = false
    @AppStorage("notifyWhenReady") private var notifyWhenReady = true
    @AppStorage("uiScale") private var uiScale = 1.0
    @AppStorage("useNameDirectory") private var useNameDirectory = true

    private var current: Pane { Pane(rawValue: pane) ?? .general }

    /// Aperçu en ligne de commande : `ImageRenderer` ne dessine pas l'intérieur d'un `ScrollView`.
    private var scrolls = true
    /// Quitte les Réglages pour une page de la fenêtre (le Lexique).
    private var go: (Route) -> Void

    /// `subpage` : sous-page ouverte d'emblée (route Annuaire des noms, aperçu en ligne de commande) ; le rail se
    /// place alors sur son panneau parent.
    init(subpage: Subpage? = nil, scrolls: Bool = true, search: String = "", go: @escaping (Route) -> Void = { _ in }) {
        _subpage = State(initialValue: subpage)
        self.go = go
        _search = State(initialValue: search)
        self.scrolls = scrolls
        if let subpage { UserDefaults.standard.set(subpage.parent.rawValue, forKey: "settingsPane") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Réglages")
                .font(.ui(26, weight: .semibold))
                .tracking(-0.4)
                .padding(.horizontal, 36)
                .padding(.top, 40)
                .padding(.bottom, 20)
            HStack(alignment: .top, spacing: 0) {
                railView
                    .frame(width: 176 * uiScale)
                    .padding(.leading, 26)
                    .padding(.top, 4)
                if scrolls {
                    ScrollView { panelStack }
                } else {
                    panelStack
                }
            }
        }
        // Échap referme la sous-page ouverte ; la vue doit avoir le focus pour recevoir la touche.
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.escape) {
            if !search.isEmpty { search = ""; return .handled }
            guard subpage != nil else { return .ignored }
            closeSubpage()
            return .handled
        }
        .onExitCommand {
            if !search.isEmpty { search = "" } else if subpage != nil { closeSubpage() }
        }
        .onAppear { focused = true; startup.actualiser() }
        .onChange(of: cleanupEngine) { _, _ in AppDelegate.startLocalLLM() }
        .onChange(of: localModel) { _, _ in AppDelegate.startLocalLLM() }
        .onChange(of: claudeFallback) { _, _ in AppDelegate.startLocalLLM() }
        .onChange(of: appearance) { _, _ in Appearance.apply(animated: true) }
    }

    private var filter: String { foldedForSearch(search.trimmingCharacters(in: .whitespaces)) }
    /// Entre les blocs d'un panneau ; nul pendant une recherche, où chaque bloc visible ajoute le sien.
    private var sectionSpacing: CGFloat { filter.isEmpty ? 28 : 0 }

    private var panelStack: some View {
        ZStack(alignment: .topLeading) {
            if filter.isEmpty {
                panel
                    .id(subpage?.rawValue ?? pane)
                    .transition(transition)
            } else {
                searchResults
                    .id("recherche")
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
        .padding(.horizontal, 36)
        .padding(.bottom, 36)
        .environment(\.settingsFilter, filter)
        .animation(Motion.quick, value: filter.isEmpty)
    }

    /// Les six panneaux à la suite, chacun sous son nom ; les blocs et lignes qui ne correspondent pas se cachent.
    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Pane.allCases, id: \.rawValue) { item in
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 8) {
                        IconView(icon: item.icon, size: 12).font(.ui(12))
                        Text(item.rawValue).font(.ui(13, weight: .semibold))
                    }
                    content(of: item)
                }
                .modifier(HidesWhenFiltered(title: item.rawValue, spacing: 12))
            }
            SearchSummary(query: search)
        }
    }

    @ViewBuilder private func content(of item: Pane) -> some View {
        switch item {
        case .general: general
        case .connectors: connectors
        case .display: display
        case .accessibility: accessibility
        case .transcription: transcription
        case .advanced: advanced
        }
    }

    // MARK: Navigation

    private var railView: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                if StaticPreview.active {
                    Text("Rechercher un réglage").foregroundStyle(Theme.muted).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("Rechercher un réglage", text: $search)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onExitCommand { search = "" }
                }
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted)
                    }
                    .buttonStyle(.plain)
                    .keyboardFocusRing(radius: 4, inset: -3)
                    .help("Effacer")
                }
            }
            .font(.ui(12))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(searchFocused ? Theme.fg : Theme.line))
            .padding(.bottom, 10)
            ForEach(Pane.allCases, id: \.rawValue) { item in
                NavItem(title: item.rawValue, icon: item.icon, active: filter.isEmpty && current == item, namespace: rail) {
                    search = ""
                    select(item)
                }
            }
        }
        .padding(.trailing, 20)
    }

    private func select(_ item: Pane) {
        let order = Pane.allCases
        forward = subpage == nil && (order.firstIndex(of: item) ?? 0) >= (order.firstIndex(of: current) ?? 0)
        withAnimation(Motion.page) {
            subpage = nil
            pane = item.rawValue
        }
    }

    private func open(_ page: Subpage) {
        forward = true
        withAnimation(Motion.page) { subpage = page }
    }

    private func closeSubpage() {
        forward = false
        withAnimation(Motion.page) { subpage = nil }
    }

    /// Sous-page : tiroir qui glisse depuis le bord droit (et y repart). Panneau : décalage de 24 pt dans le sens du déplacement.
    private var transition: AnyTransition {
        guard Motion.level == .full else { return .opacity }
        if subpage != nil { return .move(edge: .trailing).combined(with: .opacity) }
        return .asymmetric(insertion: .offset(x: forward ? 24 : -24).combined(with: .opacity), removal: .opacity)
    }

    @ViewBuilder private var panel: some View {
        if let subpage {
            switch subpage {
            case .model: modelPage
            case .claude: claudePage
            case .meetingTranscription: meetingTranscriptionPage
            case .voices: VoicesPage(header: AnyView(subpageHeader(.voices, title: "Voix connues")), spacing: sectionSpacing)
            case .calendar: calendarPage
            case .pill: pillPage
            case .names: namesPage
            case .claudeCode: connectorPage(.claudeCode, "Claude Code") { ClaudeCodePage() }
            case .notion: connectorPage(.notion, "Notion") { NotionPage() }
            case .slack: connectorPage(.slack, "Slack") { SlackPage() }
            case .webhook: connectorPage(.webhook, "Webhook") { WebhookPage() }
            case .obsidian: connectorPage(.obsidian, "Obsidian") { ObsidianPage() }
            case .todoist: connectorPage(.todoist, "Todoist") { TodoistPage() }
            }
        } else {
            switch current {
            case .general: general
            case .connectors: connectors
            case .display: display
            case .accessibility: accessibility
            case .transcription: transcription
            case .advanced: advanced
            }
        }
    }

    /// « ‹ Transcription » puis le titre de la sous-page.
    private func subpageHeader(_ page: Subpage, title: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: closeSubpage) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.ui(11, weight: .semibold))
                    Text(page.parent.rawValue)
                }
                .font(.ui(12))
                .foregroundStyle(Theme.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardFocusRing(radius: 4, inset: -3)
            .help("Revenir (Échap)")
            Text(title).font(.ui(18, weight: .semibold)).tracking(-0.3)
        }
        .padding(.bottom, -6)
    }

    /// Interrupteur d'une ligne, avec la coche de modification.
    private func toggle(_ value: Binding<Bool>) -> some View {
        Toggle("", isOn: value).toggleStyle(MonoToggleStyle()).labelsHidden().confirmsChange(of: value.wrappedValue)
    }

    // MARK: Général

    private var general: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            SettingsSection(title: "Vous",
                            footer: "L'accueil vous salue par ce prénom. Le métier accorde les comptes rendus et la relecture des dictées ; « Refaire » rouvre l'accueil pour choisir aussi vos domaines et vos attentes.") {
                SettingsRow(label: "Votre métier", keywords: "profession personnalisation avocat notaire") {
                    Dropdown(options: Profession.allCases.map { ($0.rawValue, $0.label) }, selection: $profession)
                        .confirmsChange(of: profession)
                }
                SettingsRow(label: "Personnalisation", keywords: "accueil domaines attentes") {
                    Button("Refaire") { Settings.onboarded = false }
                        .buttonStyle(OutlineButtonStyle())
                        .keyboardFocusRing()
                }
                SettingsRow(label: "Votre prénom", last: true, keywords: "nom profil bonjour") {
                    Group {
                        if StaticPreview.active {
                            Text(userName).frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            TextField("Prénom", text: $userName)
                                .textFieldStyle(.plain)
                                .focused($nameFocused)
                        }
                    }
                        .font(.ui(12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .frame(width: 180)
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(nameFocused ? Theme.fg : Theme.line))
                        .confirmsChange(of: userName)
                }
            }
            SettingsSection(title: "Micro",
                            footer: "Le menu en haut choisit le micro de Murmure : gardez l'entrée du système, ou fixez un micro précis pour que Murmure ne bascule pas sur l'iPhone ou Teams. Avec des écouteurs Bluetooth en entrée du système, Murmure prend le micro du Mac : ouvrir leur micro les ferait passer en mode téléphone, son dégradé pour la dictée comme pour la musique. Le test écoute la pièce, puis vous lisez une phrase : il vérifie le niveau de votre voix, le bruit de fond et les mots reconnus. Le micro ne s'ouvre que pendant le test, et rien n'est gardé.") {
                MicTestView(framed: false)
                Rectangle().fill(Theme.line).frame(height: 1)
                SettingsRow(label: "Éviter le micro des écouteurs Bluetooth", last: true) { toggle($avoidBluetoothMic) }
            }
            SettingsSection(title: "Raccourci",
                            footer: "Une touche de modification seule, qu'on peut maintenir sans rien taper. Avec fn, réglez « Appuyer sur la touche 🌐 pour » sur « Ne rien faire » dans Réglages Système › Clavier.") {
                SettingsRow(label: "Touche de dictée") {
                    Dropdown(options: DictationKey.allCases.map { ($0.rawValue, $0.label) }, selection: $dictationKey)
                        .confirmsChange(of: dictationKey)
                }
                SettingsRow(label: "Couper le son pendant la dictée", last: true) { toggle($muteWhileDictating) }
            }
            Disclosure(title: "Comment dicter", symbol: "questionmark.circle") {
                SettingsRow(label: "Maintenir \(Settings.dictationKey.label)") { Hint("dicter, relâcher pour coller") }
                SettingsRow(label: "Appui bref") { Hint("dictée longue, mains libres ; même touche pour finir") }
                SettingsRow(label: "Échap") { Hint("annuler") }
                SettingsRow(label: "Maj + \(Settings.dictationKey.label)") { Hint("consigne pour réécrire le texte sélectionné") }
                SettingsRow(label: "« À la ligne », « nouveau paragraphe »", last: true) { Hint("mise en page à la voix") }
            }
            SettingsSection(title: "Après la dictée",
                            footer: "Coller : le texte s'insère là où se trouve le curseur. Copier seulement : il va dans le presse-papiers, à coller vous-même avec ⌘V.") {
                SettingsRow(label: "Texte dicté", last: true) {
                    Choice(options: [(true, "Coller"), (false, "Copier seulement")], selection: $autoPaste)
                        .confirmsChange(of: autoPaste)
                }
            }
            SettingsSection(title: "Dictées",
                            footer: "Passé ce délai, la dictée est supprimée de l'historique, sans passer par la corbeille. Les réunions sont toujours gardées. Une dictée rangée dans un dossier est gardée tant qu'elle y est, et « Garder » dans sa fiche la conserve sans limite. Le changement vaut pour les dictées à venir, pas pour celles déjà dans l'historique.") {
                SettingsRow(label: "Garder les dictées dans l'historique", last: true) {
                    Choice(options: Settings.DictationRetention.allCases.map { ($0.rawValue, $0.label) }, selection: $dictationRetention)
                        .confirmsChange(of: dictationRetention)
                }
            }
            SettingsSection(title: "Réunions",
                            footer: "En plus du micro, Murmure enregistre le son diffusé par le Mac : les participants d'une visio (Teams, Zoom, Meet…) sont captés nettement, sans robot ajouté à la réunion, et votre voix est reconnue et nommée « Moi ». \(meetingTranscription == "online" ? "Le son est transcrit en ligne (Réglages › Transcription › Réunions)." : "Tout reste sur ce Mac.") macOS demande une autorisation au premier usage. Pensez à prévenir les participants de l'enregistrement.") {
                SettingsRow(label: "Inclure le son de l'ordinateur") { toggle($meetingSystemAudio) }
                SettingsRow(label: "Proposer d'enregistrer un appel ou une visio") { toggle($detectMeetings) }
                SettingsRow(label: "Proposer d'enregistrer au début d'un rendez-vous") { toggle($proposeAtAppointments) }
                SettingsRow(label: "Rappeler un rendez-vous 2 min avant, dans le bouton flottant") { toggle($remindAppointments) }
                SettingsRow(label: "Proposer de terminer une réunion quand plus personne ne parle", last: true) { toggle($offerToEndQuietMeetings) }
            }
            SettingsSection(title: "Démarrage et notifications") {
                SettingsRow(label: "Ouvrir Murmure au démarrage du Mac") { toggle(Binding(get: { startup.active }, set: { startup.choisir($0) })) }
                SettingsRow(label: "Prévenir quand un compte rendu est prêt", last: true) { toggle($notifyWhenReady) }
            }
        }
    }

    // MARK: Connecteurs

    /// « Outlook · Google » : les services dont au moins un agenda est coché.
    private var calendarSummary: String {
        guard calendarAuthorized else { return "non autorisé" }
        var kinds: [String] = []
        for account in calendarAccounts where account.hasIncluded && !kinds.contains(account.kind) { kinds.append(account.kind) }
        return kinds.isEmpty ? "aucun agenda" : kinds.joined(separator: " · ")
    }

    /// La liste des connecteurs (`ConnectorsPane.swift`) ; le réglage « nommer la réunion d'après le rendez-vous »
    /// reste ici, sous la liste.
    private var connectors: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            ConnectorsPane(open: open, mailApp: $mailApp)
            SettingsSection(title: "Réunions",
                            footer: "Au lancement d'une réunion, le rendez-vous en cours lui donne son titre et ses invités : leurs noms guident le compte rendu, leurs adresses remplissent le brouillon d'e-mail.") {
                SettingsRow(label: "Nommer la réunion d'après le rendez-vous en cours", last: true) { toggle($useCalendar) }
            }
        }
        .onAppear(perform: refreshCalendar)
    }

    /// Sous-page d'un connecteur : l'en-tête, puis ses blocs.
    private func connectorPage<Content: View>(_ page: Subpage, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            subpageHeader(page, title: title)
            content()
        }
    }

    private func refreshCalendar() {
        calendarAuthorized = Connectors.calendarAuthorized
        calendarAccounts = Connectors.calendarAccounts
        currentEvent = Connectors.currentEvent()
    }

    private var calendarPage: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            subpageHeader(.calendar, title: "Agenda")
            SettingsSection(title: "Accès",
                            footer: "Murmure lit l'agenda du Mac, celui de l'application Calendrier, avec tous ses comptes, sans se connecter lui-même à aucun service. L'autorisation se retire dans Réglages Système › Confidentialité et sécurité › Calendriers.") {
                SettingsRow(label: "Autorisation Calendriers", last: true) {
                    if calendarAuthorized {
                        Label("Autorisée", systemImage: "checkmark").font(.ui(12, weight: .medium))
                    } else {
                        Button("Autoriser…") {
                            Connectors.requestCalendar { granted in
                                refreshCalendar()
                                if !granted { SystemSettings.open(.calendars) }
                            }
                        }
                        .buttonStyle(OutlineButtonStyle(prominent: true))
                        .keyboardFocusRing()
                    }
                }
            }
            if calendarAuthorized && calendarAccounts.isEmpty {
                SettingsSection(title: "Agendas") {
                    SettingsRow(label: "Aucun compte avec un agenda", last: true) { EmptyView() }
                }
            }
            ForEach(calendarAccounts) { account in
                SettingsSection(title: account.label,
                                footer: account.id == calendarAccounts.last?.id
                                    ? "Seuls les agendas cochés alimentent la page Aujourd'hui, le prochain rendez-vous et le titre des réunions. Un rendez-vous présent dans deux agendas n'est montré qu'une fois." : nil) {
                    ForEach(account.calendars) { calendar in
                        SettingsRow(label: calendar.title, last: calendar.id == account.calendars.last?.id,
                                    keywords: "agenda calendrier " + account.label, tint: calendar.color) {
                            toggle(Binding(get: { calendar.included },
                                           set: { Connectors.setIncluded(calendar.id, $0); refreshCalendar() }))
                        }
                    }
                }
            }
            SettingsSection(title: "Ajouter un agenda",
                            footer: "Outlook (Microsoft 365 ou Exchange), Google et iCloud s'ajoutent dans Réglages Système › Comptes Internet ; on peut en ajouter plusieurs de chaque. L'application Outlook pour Mac garde son agenda pour elle : ajoutez-y aussi le compte « Microsoft Exchange » pour que Murmure le voie. Si un compte ne peut pas être ajouté, collez son lien d'abonnement : « Adresse secrète au format iCal » dans les paramètres de l'agenda Google, « Publier un calendrier » dans Outlook sur le web. Calendrier vous demandera de confirmer, puis le tiendra à jour.") {
                SettingsRow(label: "Outlook, Google, iCloud", keywords: "compte microsoft exchange office 365 gmail") {
                    Button("Réglages Système…") { SystemSettings.open(.internetAccounts) }
                        .buttonStyle(OutlineButtonStyle())
                        .keyboardFocusRing()
                }
                SettingsRow(label: "Par un lien d'abonnement", last: true, keywords: "ics ical webcal publier adresse secrète") {
                    HStack(spacing: 8) {
                        if subscriptionError { Hint("lien non reconnu") }
                        Group {
                            if StaticPreview.active {
                                Text("https://…/calendar.ics").foregroundStyle(Theme.muted).frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                TextField("https://…/calendar.ics", text: $subscriptionLink)
                                    .textFieldStyle(.plain)
                                    .focused($subscriptionFocused)
                                    .onSubmit(subscribe)
                                    .onChange(of: subscriptionLink) { subscriptionError = false }
                            }
                        }
                        .font(.ui(12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .frame(width: 220)
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(subscriptionFocused ? Theme.fg : Theme.line))
                        Button("S'abonner", action: subscribe)
                            .fixedSize()
                            .buttonStyle(OutlineButtonStyle(prominent: true))
                            .keyboardFocusRing()
                            .disabled(subscriptionLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            SettingsSection(title: "Rendez-vous en cours",
                            footer: "Le rendez-vous en cours, ou qui commence dans les dix minutes, donnerait son titre et ses invités à une réunion lancée maintenant.") {
                if let event = currentEvent {
                    SettingsRow(label: event.title, tint: event.origin?.color) { Hint(event.origin?.label ?? "maintenant") }
                    SettingsRow(label: "Invités", last: true) {
                        Hint(event.attendees.isEmpty ? "aucun" : event.attendees.map(\.name).joined(separator: ", "))
                    }
                } else {
                    SettingsRow(label: useCalendar ? "Aucun rendez-vous en cours" : "Nommage d'après l'agenda désactivé", last: true) {
                        Button("Actualiser") { Connectors.refreshSources(); refreshCalendar() }
                            .buttonStyle(OutlineButtonStyle()).keyboardFocusRing()
                    }
                }
            }
        }
        .onAppear { Connectors.refreshSources(); refreshCalendar() }
        // Un compte ajouté, un abonnement confirmé dans Calendrier : la liste suit sans rouvrir la page.
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged, object: Connectors.eventStore)) { _ in
            refreshCalendar()
        }
    }

    /// Confie le lien collé à Calendrier ; un texte qui n'est pas un lien reste dans le champ, signalé en gris.
    private func subscribe() {
        if Connectors.subscribe(to: subscriptionLink) {
            subscriptionLink = ""
            subscriptionError = false
            subscriptionFocused = false
        } else {
            subscriptionError = true
        }
    }

    // MARK: Affichage

    private var motionLabel: String {
        switch Motion.Level(rawValue: motion) ?? .full {
        case .full: return "Fluides"
        case .reduced: return "Sobres"
        case .none: return "Aucune"
        }
    }

    private var display: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            SettingsSection(title: "Fenêtre",
                            footer: "Fluides : ouvertures, pages et sélections glissent. Sobres : simples fondus. Aucune : tout est instantané.") {
                SettingsRow(label: "Apparence") {
                    HStack(spacing: 14) {
                        AppearancePreview(selection: $appearance)
                        Choice(options: [("system", "Système"), ("light", "Clair"), ("dark", "Sombre")], selection: $appearance)
                    }
                    .confirmsChange(of: appearance)
                }
                SettingsRow(label: "Animations") {
                    HStack(spacing: 14) {
                        MotionPreview()
                        Choice(options: [("full", "Fluides"), ("reduced", "Sobres"), ("none", "Aucune")], selection: $motion)
                    }
                    .confirmsChange(of: motion)
                }
                SettingsRow(label: "Liste", last: true) {
                    Choice(options: [(false, "Confortable"), (true, "Compacte")], selection: $compactList)
                        .confirmsChange(of: compactList)
                }
            }
            SettingsSection(title: "Pastille de dictée",
                            footer: "La pastille montre l'état de la dictée et, au-dessus, le texte qui se transcrit pendant que vous parlez.") {
                SettingsLink(label: "Pastille",
                             value: "\(overlayPosition == "top" ? "En haut" : "En bas")\(overlayLiveText ? " · texte en direct" : "")",
                             last: true) { open(.pill) }
            }
            SettingsSection(title: "Bouton flottant",
                            footer: "Une petite capsule au bord de l'écran, par-dessus les autres fenêtres. Survolez-la : le micro lance une dictée (cliquez de nouveau pour finir), le rond lance ou arrête une réunion. Faites-la glisser pour la déplacer ; clic droit pour la masquer.") {
                SettingsRow(label: "Afficher le bouton", keywords: "flottant capsule bulle bord écran") { toggle($floatingButton) }
                SettingsRow(label: "Position", last: true, keywords: "flottant déplacer bord droit") {
                    Button("Remettre au bord droit") { AppDelegate.shared?.resetFloatingButton() }
                        .buttonStyle(OutlineButtonStyle())
                        .keyboardFocusRing()
                        .disabled(!floatingButton)
                }
            }
        }
    }

    private var pillPage: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            subpageHeader(.pill, title: "Pastille de dictée")
            PillPreview(atTop: overlayPosition == "top", liveText: overlayLiveText)
            SettingsSection(title: "Position et texte",
                            footer: "La pastille ne prend jamais le focus : le texte se colle toujours dans l'application où vous étiez. Le texte en direct montre la fin de ce qui est transcrit pendant que vous parlez.") {
                SettingsRow(label: "Position") {
                    Choice(options: [("bottom", "En bas"), ("top", "En haut")], selection: $overlayPosition)
                        .confirmsChange(of: overlayPosition)
                }
                SettingsRow(label: "Texte en direct", last: true) { toggle($overlayLiveText) }
            }
        }
    }

    // MARK: Accessibilité

    private var accessibility: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            SettingsSection(title: "Taille",
                            footer: "L'interface agrandit les menus, listes et boutons ; le texte de lecture agrandit les dictées, transcriptions, comptes rendus et la page En direct.") {
                SettingsRow(label: "Interface") {
                    Choice(options: [(0.9, "Petite"), (1.0, "Normale"), (1.1, "Grande"), (1.2, "Très grande")], selection: $uiScale)
                        .confirmsChange(of: uiScale)
                }
                SettingsRow(label: "Texte de lecture", last: true) {
                    Choice(options: [(13.0, "Petite"), (14.0, "Normale"), (16.0, "Grande"), (18.0, "Très grande")], selection: $readingSize)
                        .confirmsChange(of: readingSize)
                }
            }
            SettingsSection(title: "Vision",
                            footer: "Le contraste renforcé assombrit les textes secondaires et les filets. Il s'active aussi tout seul si « Augmenter le contraste » est coché dans macOS, de même que les animations se réduisent avec « Réduire les animations ».") {
                SettingsRow(label: "Contraste renforcé") { toggle($highContrast) }
                SettingsLink(label: "Animations", value: motionLabel, last: true) { select(.display) }
            }
            SettingsSection(title: "Audition et retour",
                            footer: "Un son discret confirme que l'enregistrement commence et s'arrête, sans devoir regarder l'écran.") {
                SettingsRow(label: "Signal sonore au début et à la fin", last: true) { toggle($dictationSounds) }
            }
            SettingsSection(title: "Autorisation macOS",
                            footer: "Nécessaire pour coller le texte à l'emplacement du curseur. Sans elle, le texte est seulement copié.") {
                SettingsRow(label: "Accessibilité", last: true) {
                    if state.accessibilityGranted {
                        Label("Autorisée", systemImage: "checkmark").font(.ui(12, weight: .medium))
                    } else {
                        Button("Autoriser…", action: SystemSettings.requestAccessibility)
                        .buttonStyle(OutlineButtonStyle(prominent: true))
                        .keyboardFocusRing()
                    }
                }
            }
        }
    }

    // MARK: Transcription

    private var engineNote: String {
        switch Cleaner.Engine(rawValue: cleanupEngine) ?? .local {
        case .claude:
            return "Claude, le modèle d'Anthropic, relit chaque dictée avec le texte qui entoure le curseur (noms, accords, mots mal entendus que le document rend évidents) et rédige titres, comptes rendus et réponses à partir de la réunion entière, sans découpage. Seul le texte part, jamais le son. Facturé à l'usage avec votre clé, indépendamment d'un abonnement Claude."
        case .local:
            return "Un modèle ouvert tourne sur ce Mac, sans connexion. Il retire les autocorrections (« non, pardon… ») et les répétitions, rédige les titres et les comptes rendus. Les plus gros modèles sont plus fins mais plus lents."
        case .apple:
            return Cleaner.appleUnavailableReason.map { "Indisponible : \($0)." } ?? "Modèle Apple Intelligence intégré au Mac."
        case .none:
            return "La transcription brute est collée telle quelle, avec seulement les règles fixes (hésitations, « à la ligne », corrections du dictionnaire)."
        }
    }

    /// « Qwen3 4B · prêt » : nom court du modèle choisi et état du moteur.
    private var modelSummary: String {
        let name = LocalLLM.catalog.first { $0.file == localModel }?.name ?? localModel
        return "\(Self.shortName(name)) · \(llmStatus)"
    }

    private static func shortName(_ name: String) -> String {
        name.replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression)
    }

    private var transcription: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            SettingsSection(title: "Transcription et rédaction", footer: engineNote) {
                SettingsRow(label: "Langue") {
                    Choice(options: [("fr", "Français"), ("auto", "Automatique")], selection: $language)
                        .confirmsChange(of: language)
                }
                SettingsRow(label: "Mise en forme", last: ![Cleaner.Engine.local.rawValue, Cleaner.Engine.claude.rawValue].contains(cleanupEngine)) {
                    Dropdown(options: Cleaner.Engine.allCases.map { ($0.rawValue, $0.label) }, selection: $cleanupEngine)
                        .confirmsChange(of: cleanupEngine)
                }
                if cleanupEngine == Cleaner.Engine.local.rawValue {
                    SettingsLink(label: "Modèle local", value: modelSummary, last: true) { open(.model) }
                }
                if cleanupEngine == Cleaner.Engine.claude.rawValue {
                    SettingsLink(label: "Claude", value: claudeSummary, last: true) { open(.claude) }
                }
            }
            SettingsSection(title: "Réunions",
                            footer: "La dictée est toujours transcrite sur ce Mac. Les réunions peuvent l'être par un service en ligne, plus précis, sur un serveur européen.") {
                SettingsLink(label: "Transcription des réunions", value: meetingTranscriptionSummary) { open(.meetingTranscription) }
                SettingsLink(label: "Voix connues", value: voicesSummary, last: true) { open(.voices) }
            }
            SettingsSection(title: "Dictionnaire",
                            footer: "Vos mots, vos corrections et vos raccourcis se gèrent dans le Lexique, dans le panneau de gauche. L'annuaire réunit, sans rien saisir, les noms de vos contacts, de votre agenda et de vos dossiers.") {
                SettingsLink(label: "Lexique", value: Lexicon.shared.summary) { go(.list(.lexicon)) }
                SettingsLink(label: "Annuaire des noms", value: useNameDirectory ? "activé" : "désactivé", last: true) { open(.names) }
            }
            SettingsSection(title: "Contexte du curseur",
                            footer: "Au début de la dictée, Murmure lit le texte qui entoure le curseur (environ 500 mots avant et après). Murmure s'en sert pour écrire les noms des parties, des juridictions et des sigles comme dans votre document, et le texte collé s'accorde à la phrase en cours : minuscule si vous la poursuivez, espaces, pas de point final si elle continue, pas de point à la fin d'un message court. Ce texte reste en mémoire le temps de la dictée : il n'est ni enregistré ni transmis. Les mots de passe ne sont jamais lus. En apprenant de vos corrections, Murmure relit l'endroit du collage 20 secondes plus tard : un nom que vous avez rectifié rejoint vos corrections, dans le Lexique, un autre mot à la deuxième fois.") {
                SettingsRow(label: "Se servir du texte autour du curseur") { toggle($fieldContext) }
                SettingsRow(label: "Apprendre de mes corrections", last: true) { toggle($learnCorrections) }
            }
        }
    }

    private var namesPage: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            subpageHeader(.names, title: "Annuaire des noms")
            NameDirectorySettings()
        }
    }

    private var llmStatus: String {
        switch state.llmStatus {
        case .loading: return installer.summary.map { "téléchargement, \($0)" } ?? "chargement…"
        case .ready: return "prêt"
        case .failed(let reason): return reason
        }
    }

    /// Taille du fichier d'un modèle sur le disque (« 2,5 Go »), nil s'il n'est pas installé.
    private func modelSize(_ model: LocalLLM.Model) -> String? {
        let path = LocalLLM.llmDir.appendingPathComponent(model.file).path
        guard let bytes = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 else { return nil }
        return LocalLLMInstaller.size(bytes)
    }

    private var modelPage: some View {
        let catalog = LocalLLM.catalog
        return VStack(alignment: .leading, spacing: sectionSpacing) {
            subpageHeader(.model, title: "Modèle local")
            SettingsSection(title: "Modèles",
                            footer: "Murmure télécharge le modèle choisi la première fois qu'il en a besoin, une fois pour toutes, puis le garde dans son dossier LLM. Le plus petit répond plus vite, le plus gros rédige plus finement. Changer de modèle le recharge en mémoire (quelques secondes), puis il y reste tant que Murmure est ouvert.") {
                ForEach(Array(catalog.enumerated()), id: \.element.file) { index, model in
                    let size = modelSize(model)
                    SettingsRow(label: model.name, last: index == catalog.count - 1) {
                        HStack(spacing: 10) {
                            if let fraction = installer.progress[model.file] {
                                Spinner(size: 12, color: Theme.muted, lineWidth: 1.4)
                                Hint(fraction < 1 ? "\(Int(fraction * 100)) %" : "vérification…")
                            } else if size == nil, let failure = installer.failures[model.file] {
                                Hint(failure)
                            } else {
                                Hint(size ?? LocalLLMInstaller.size(model.download.size) + " à télécharger")
                            }
                            if model.file == localModel {
                                Tag(text: "utilisé", filled: true)
                            } else if size != nil {
                                Button("Utiliser") { localModel = model.file }.buttonStyle(OutlineButtonStyle()).keyboardFocusRing()
                            } else if !installer.isDownloading(model.file) {
                                Button(installer.failures[model.file] == nil ? "Télécharger" : "Réessayer") {
                                    Task { try? await installer.install(model: model.file) }
                                }
                                .buttonStyle(OutlineButtonStyle())
                                .keyboardFocusRing()
                            }
                        }
                    }
                }
            }
            SettingsSection(title: "État") {
                SettingsRow(label: "Moteur", last: true) {
                    HStack(spacing: 8) {
                        if case .loading = state.llmStatus { Spinner(size: 12, color: Theme.muted, lineWidth: 1.4) }
                        Hint(llmStatus)
                        if case .failed = state.llmStatus {
                            Button("Réessayer") { AppDelegate.startLocalLLM() }.buttonStyle(OutlineButtonStyle()).keyboardFocusRing()
                        }
                    }
                }
            }
            SettingsSection(title: "Dossier",
                            footer: "Pour installer un autre modèle, déposez son fichier GGUF dans ce dossier sous le nom attendu par Murmure, puis relancez l'application.") {
                SettingsRow(label: "LLM", last: true) {
                    HStack(spacing: 10) {
                        Hint(LocalLLM.llmDir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        Button("Afficher dans le Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([LocalLLM.llmDir])
                        }
                        .buttonStyle(OutlineButtonStyle())
                        .keyboardFocusRing()
                    }
                }
            }
        }
    }

    // MARK: Claude

    /// « Opus 5.5 · clé enregistrée » ou « clé à ajouter ».
    private var claudeSummary: String {
        guard claudeKeyPresent else { return "clé à ajouter" }
        return ClaudeAPI.name(of: claudeWritingModel).replacingOccurrences(of: "Claude ", with: "") + " · clé enregistrée"
    }

    private var claudeModels: [(String, String)] { ClaudeAPI.catalog.map { ($0.id, "\($0.name) · \($0.note)") } }

    private var claudePage: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            subpageHeader(.claude, title: "Claude")
            SettingsSection(title: "Clé API",
                            footer: "Une clé se crée sur la Console Anthropic (console.anthropic.com) ; l'usage y est facturé, indépendamment d'un abonnement Claude. Murmure la garde sur ce Mac, dans son dossier, et ne l'envoie qu'à api.anthropic.com.") {
                SettingsRow(label: claudeKeyPresent ? "Remplacer la clé" : "Clé", last: !claudeKeyPresent) {
                    HStack(spacing: 8) {
                        SecureField("sk-ant-…", text: $claudeKeyDraft)
                            .textFieldStyle(.plain)
                            .font(.ui(12))
                            .frame(width: 220)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line))
                            .onSubmit(saveClaudeKey)
                        Button("Enregistrer", action: saveClaudeKey)
                            .buttonStyle(OutlineButtonStyle(prominent: true))
                            .keyboardFocusRing()
                            .disabled(claudeKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if claudeKeyPresent {
                    SettingsRow(label: "Clé enregistrée", last: true) {
                        HStack(spacing: 10) {
                            Hint(ClaudeAPI.maskedKey ?? "")
                            Button("Vérifier", action: verifyClaudeKey).buttonStyle(OutlineButtonStyle()).keyboardFocusRing().disabled(claudeChecking)
                            if claudeChecking { Spinner(size: 12, color: Theme.muted, lineWidth: 1.4) }
                            if let claudeCheck { Hint(claudeCheck) }
                            Button("Retirer") {
                                ClaudeAPI.setKey("")
                                claudeKeyPresent = false
                                claudeCheck = nil
                            }
                            .buttonStyle(OutlineButtonStyle())
                            .keyboardFocusRing()
                        }
                    }
                }
            }
            SettingsSection(title: "Modèles",
                            footer: "La dictée est relue à chaque fois : un modèle plus rapide raccourcit l'attente avant le collage. La rédaction (comptes rendus, questions, réécritures, titres) gagne à prendre le plus fin.") {
                SettingsRow(label: "Dictée") {
                    Dropdown(options: claudeModels, selection: $claudeDictationModel).confirmsChange(of: claudeDictationModel)
                }
                SettingsRow(label: "Rédaction", last: true) {
                    Dropdown(options: claudeModels, selection: $claudeWritingModel).confirmsChange(of: claudeWritingModel)
                }
            }
            SettingsSection(title: "Sans connexion",
                            footer: "Le modèle local reste chargé en mémoire pour prendre le relais quand Claude est injoignable (pas de réseau, service saturé). Dans la barre des menus, « Rester hors ligne » coupe l'envoi d'un clic ; le menu d'un dossier propose « Jamais en ligne » pour garder ses réunions sur le Mac.") {
                SettingsRow(label: "Repli sur le modèle local", last: true) { toggle($claudeFallback) }
            }
            SettingsSection(title: "Ce qui part",
                            footer: "Seul du texte est envoyé : la dictée transcrite avec le texte qui entoure le curseur, le titre de la fenêtre et les textes à l'écran ; la transcription des réunions pour les comptes rendus et les questions ; le texte sélectionné en mode commande. Jamais le son. Les données reçues par l'API ne servent pas à entraîner les modèles et leur conservation est limitée.") {
                SettingsRow(label: "Depuis le lancement", last: true) {
                    Hint("\(ClaudeAPI.shared.tokensIn.formatted()) jetons lus · \(ClaudeAPI.shared.tokensOut.formatted()) écrits")
                }
            }
        }
    }

    private func saveClaudeKey() {
        let draft = claudeKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        ClaudeAPI.setKey(draft)
        claudeKeyDraft = ""
        claudeKeyPresent = ClaudeAPI.hasKey
        claudeCheck = nil
        verifyClaudeKey()
    }

    /// Ce qui quitte le Mac, en une ligne (Avancé › Données).
    private var processingSummary: String {
        if stayOffline { return "Rester hors ligne : rien ne quitte ce Mac" }
        let soundOnline = meetingTranscription == "online" && onlineKeyPresent
        let textOnline = cleanupEngine == Cleaner.Engine.claude.rawValue && claudeKeyPresent
        switch (soundOnline, textOnline) {
        case (false, false): return "100 % local, rien ne quitte ce Mac"
        case (true, false): return "Son des réunions transcrit en ligne ; le reste sur ce Mac"
        case (false, true): return "Rédaction par Claude, en ligne ; le son reste sur ce Mac"
        case (true, true): return "Réunions transcrites et rédigées en ligne, dictées relues par Claude ; le son des dictées reste sur ce Mac"
        }
    }

    // MARK: Transcription des réunions

    /// « Sur ce Mac », « En ligne · clé à ajouter », « En ligne ».
    private var voicesSummary: String {
        guard Settings.recognizeVoices else { return "désactivé" }
        let count = VoiceBook.shared.voices.count
        return count == 0 ? "aucune" : "\(count) voix"
    }

    private var meetingTranscriptionSummary: String {
        guard meetingTranscription == "online" else { return "Sur ce Mac" }
        return onlineKeyPresent ? "En ligne" : "En ligne · clé à ajouter"
    }

    private var meetingTranscriptionPage: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            subpageHeader(.meetingTranscription, title: "Transcription des réunions")
            SettingsSection(title: "Où transcrire",
                            footer: meetingTranscription == "online"
                                ? "Le son de chaque réunion est envoyé à \(OnlineTranscription.serviceName), sur son serveur européen, transcrit en français avec les voix distinguées, puis la transcription et le son sont supprimés du service (une suppression empêchée est retentée, au lancement suivant au besoin). Le texte revient ici. Sans réseau ou en cas d'erreur, la réunion est transcrite sur ce Mac, et la fiche le dit. Coût indicatif : environ 0,30 $ par heure de réunion, facturé par le service."
                                : "Les réunions sont transcrites sur ce Mac : le son ne le quitte jamais.") {
                SettingsRow(label: "Transcription", last: true) {
                    Choice(options: [("local", "Sur ce Mac"), ("online", "En ligne, plus précise")], selection: $meetingTranscription)
                        .confirmsChange(of: meetingTranscription)
                }
            }
            if meetingTranscription == "online" {
                SettingsSection(title: "Clé API",
                                footer: "La clé se crée sur le site d'\(OnlineTranscription.serviceName) (assemblyai.com, rubrique API Keys). Murmure la garde sur ce Mac, dans son dossier, et ne l'envoie qu'au serveur européen du service.") {
                    SettingsRow(label: onlineKeyPresent ? "Remplacer la clé" : "Clé", last: !onlineKeyPresent) {
                        HStack(spacing: 8) {
                            SecureField("Clé API", text: $onlineKeyDraft)
                                .textFieldStyle(.plain)
                                .font(.ui(12))
                                .frame(width: 220)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line))
                                .onSubmit(saveOnlineKey)
                            Button("Enregistrer", action: saveOnlineKey)
                                .buttonStyle(OutlineButtonStyle(prominent: true))
                                .keyboardFocusRing()
                                .disabled(onlineKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    if onlineKeyPresent {
                        SettingsRow(label: "Clé enregistrée", last: true) {
                            HStack(spacing: 10) {
                                Hint(OnlineTranscription.maskedKey ?? "")
                                Button("Vérifier", action: verifyOnlineKey).buttonStyle(OutlineButtonStyle()).keyboardFocusRing().disabled(onlineChecking)
                                if onlineChecking { Spinner(size: 12, color: Theme.muted, lineWidth: 1.4) }
                                if let onlineCheck { Hint(onlineCheck) }
                                Button("Retirer") {
                                    OnlineTranscription.setKey("")
                                    onlineKeyPresent = false
                                    onlineCheck = nil
                                }
                                .buttonStyle(OutlineButtonStyle())
                                .keyboardFocusRing()
                            }
                        }
                    }
                }
                SettingsSection(title: "Ce qui part avec le son",
                                footer: "Le titre du rendez-vous et les noms des invités partent toujours avec le son : ils guident l'orthographe des noms. Le dictionnaire (termes et corrections, noms de clients compris) peut s'y ajouter. Les enregistrements importés (dictaphone, audience) partent dès leur lecture, sans cadenas possible : ils restent sur ce Mac sauf si vous l'autorisez ici.") {
                    SettingsRow(label: "Joindre le dictionnaire") { toggle($onlineSendsDictionary) }
                    SettingsRow(label: "Transcrire aussi les enregistrements importés", last: true) { toggle($onlineImports) }
                }
                SettingsSection(title: "Ce qui reste sur ce Mac",
                                footer: "Rien ne part pour une réunion rangée dans un dossier « Jamais en ligne » (menu du dossier), pour une réunion marquée d'un clic sur le cadenas de la page En direct, ni quand « Rester hors ligne » est coché (ici ou dans la barre des menus). Choisis pendant l'envoi, ils l'interrompent. Le dossier se choisit souvent après la réunion : pour une affaire sensible, utilisez le cadenas pendant l'enregistrement. Si l'envoi réussit mais que le service refuse ensuite la transcription (solde épuisé par exemple), le son reste chez lui jusqu'à sa purge automatique, 48 h au plus. Pensez à prévenir les participants de l'enregistrement et de sa transcription.") {
                    SettingsRow(label: "Rester hors ligne", last: true) { toggle($stayOffline) }
                }
            }
        }
    }

    private func saveOnlineKey() {
        let draft = onlineKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        OnlineTranscription.setKey(draft)
        onlineKeyDraft = ""
        onlineKeyPresent = OnlineTranscription.hasKey
        onlineCheck = nil
        verifyOnlineKey()
    }

    private func verifyOnlineKey() {
        onlineChecking = true
        onlineCheck = nil
        Task {
            let message = await OnlineTranscription.verify()
            await MainActor.run {
                onlineCheck = message
                onlineChecking = false
            }
        }
    }

    private func verifyClaudeKey() {
        claudeChecking = true
        claudeCheck = nil
        Task {
            do {
                let model = try await ClaudeAPI.shared.verify()
                await MainActor.run { claudeCheck = "clé valide · \(model) a répondu" }
            } catch {
                await MainActor.run { claudeCheck = error.localizedDescription }
            }
            await MainActor.run { claudeChecking = false }
        }
    }

    // MARK: Avancé

    private var advanced: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            SettingsSection(title: "Essais",
                            footer: "Garde l'audio de chaque dictée sur ce Mac (dossier Enregistrements, environ 2 Mo par minute) pour comparer les moteurs de transcription sur votre voix. Corrigez le texte des dictées dans l'historique : il sert de référence. L'audio est supprimé avec la dictée ; celui d'une réunion n'est gardé que le temps de son traitement.") {
                SettingsRow(label: "Garder l'audio des dictées", last: true) { toggle($keepAudio) }
            }
            SettingsSection(title: "Données") {
                SettingsRow(label: "Dossier de Murmure") {
                    Button("Ouvrir dans le Finder") { NSWorkspace.shared.open(Settings.supportDir) }
                        .buttonStyle(OutlineButtonStyle())
                        .keyboardFocusRing()
                }
                SettingsRow(label: "Accueil du premier lancement", keywords: "personnalisation métier domaines attentes") {
                    Button("Refaire la personnalisation") { Settings.onboarded = false }
                        .buttonStyle(OutlineButtonStyle())
                        .keyboardFocusRing()
                }
                SettingsRow(label: "Traitement", last: true) { Hint(processingSummary) }
            }
        }
    }
}

/// Valeur informative, en gris, à droite d'une ligne de réglage.
struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.ui(12)).foregroundStyle(Theme.muted).lineLimit(1)
    }
}

// MARK: - Aperçus vivants

/// Trois carrés (système, clair, sombre) ; l'anneau glisse sur celui qui est choisi. Un clic choisit.
private struct AppearancePreview: View {
    @Binding var selection: String
    @Namespace private var ring

    var body: some View {
        HStack(spacing: 6) {
            swatch("system") {
                ZStack {
                    Color.white
                    Color.black.clipShape(Triangle())
                }
            }
            swatch("light") { Color.white }
            swatch("dark") { Color.black }
        }
    }

    private func swatch(_ value: String, @ViewBuilder fill: () -> some View) -> some View {
        Button { withAnimation(Motion.quick) { selection = value } } label: {
            fill()
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line))
                .padding(3)
                .background {
                    if selection == value {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.fg, lineWidth: 1.5)
                            .matchedGeometryEffect(id: "ring", in: ring)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardFocusRing(radius: 6, inset: -2)
    }

    /// Moitié inférieure droite d'un carré : la part sombre du carré « Système ».
    private struct Triangle: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }
}

/// Mini-sélecteur à trois cases dont la pastille passe de l'une à l'autre toutes les 1,4 s, avec l'animation
/// du niveau choisi : elle glisse (Fluides), fond (Sobres) ou reste en place (Aucune).
private struct MotionPreview: View {
    private let period = 1.4

    var body: some View {
        TimelineView(.periodic(from: .now, by: period)) { context in
            let index = Motion.level == .none ? 1 : Int(context.date.timeIntervalSinceReferenceDate / period) % 3
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { slot in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(slot == index ? Theme.inverse : Color.clear)
                        .frame(width: 14, height: 8)
                }
            }
            .padding(2)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
            .animation(Motion.quick, value: index)
        }
    }
}

/// Sous les résultats d'une recherche : rappel de ce qui est cherché, et quoi faire si rien ne sort.
private struct SearchSummary: View {
    let query: String

    var body: some View {
        Text("Réglages contenant « \(query.trimmingCharacters(in: .whitespaces)) ». Échap pour revenir aux panneaux.")
            .font(.ui(11))
            .foregroundStyle(Theme.muted)
    }
}

/// « Ouvrir Murmure au démarrage du Mac ». Demander l'état à macOS (`SMAppService.status`) est un aller-retour
/// synchrone vers un service du système qui prend 150 à 350 ms : fait dans l'initialisation des Réglages, il
/// retardait leur ouverture et chaque redessin de la fenêtre. L'état est donc lu hors du fil principal au
/// lancement et à chaque ouverture des Réglages, et gardé ici.
@MainActor final class OuvertureAuDemarrage: ObservableObject {
    static let shared = OuvertureAuDemarrage()
    @Published private(set) var active = false

    /// Relit l'état réel (au lancement, puis à l'ouverture des Réglages : il peut changer dans Réglages Système).
    func actualiser() {
        Task.detached(priority: .utility) {
            let active = SMAppService.mainApp.status == .enabled
            await MainActor.run { OuvertureAuDemarrage.shared.active = active }
        }
    }

    /// Bascule tout de suite à l'écran, puis inscrit ou retire Murmure ; en cas de refus, l'état réel revient.
    func choisir(_ active: Bool) {
        self.active = active
        Task.detached(priority: .userInitiated) {
            do {
                if active { try SMAppService.mainApp.register() } else { try await SMAppService.mainApp.unregister() }
            } catch {
                await OuvertureAuDemarrage.shared.actualiser()
            }
        }
    }
}
