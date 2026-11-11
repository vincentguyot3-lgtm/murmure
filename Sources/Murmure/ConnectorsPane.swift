import SwiftUI

// Réglages › Connecteurs : une liste, un connecteur par ligne (icône de la marque en monochrome, nom, ce qu'il
// fait), et à droite soit « Relié », soit un seul bouton. Les lignes qui ont des réglages ouvrent une sous-page.

/// Un connecteur de la liste.
struct Connector: Identifiable {
    enum State {
        /// Relié ; la valeur dit avec quoi (adresse du compte, page Notion, liste de rappels…), sinon « Relié ».
        case linked(String?)
        /// Pas encore relié : un bouton.
        case action(String, () -> Void)
        /// Simple constat, sans bouton (« Reconnue », « Installé »).
        case note(String)
    }

    let id: String
    let name: String
    let icon: BrandIcon
    let detail: String
    let state: State
    /// La ligne entière ouvre une sous-page.
    var open: (() -> Void)? = nil
}

/// Ligne d'un connecteur ; pendant une recherche de réglage, disparaît si rien ne correspond.
struct ConnectorRow: View {
    let connector: Connector
    var last = false
    @State private var hover = false
    @Environment(\.settingsFilter) private var filter

    @ViewBuilder var body: some View {
        if filter.isEmpty || foldedForSearch(connector.name + " " + connector.detail).contains(filter) {
            row.preference(key: SettingsMatchKey.self, value: 1)
        } else {
            Color.clear.frame(height: 0).preference(key: SettingsMatchKey.self, value: 0)
        }
    }

    private var row: some View {
        Group {
            if let open = connector.open {
                Button(action: open) { content }
                    .buttonStyle(.plain)
                    .keyboardFocusRing(radius: 8, inset: 3)
                    .activatesOnReturn(open)
                    .onHover { inside in withAnimation(Motion.quick) { hover = inside } }
            } else {
                content
            }
        }
        .overlay(alignment: .bottom) {
            if !last && filter.isEmpty { Rectangle().fill(Theme.line).frame(height: 1) }
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            BrandIconView(icon: connector.icon, size: 17)
                .frame(width: 30 * Settings.uiScale, height: 30 * Settings.uiScale)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
            VStack(alignment: .leading, spacing: 2) {
                Text(connector.name).font(.ui(13)).foregroundStyle(Theme.fg)
                Text(connector.detail).font(.ui(11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 12)
            trailing
            if connector.open != nil {
                Image(systemName: "chevron.right")
                    .font(.ui(10, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .offset(x: hover ? 2 : 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(hover ? Theme.soft : Color.clear)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var trailing: some View {
        switch connector.state {
        case .linked(let value):
            HStack(spacing: 5) {
                Image(systemName: "checkmark").font(.ui(10, weight: .semibold))
                Text(value ?? "Relié").lineLimit(1)
            }
            .font(.ui(12))
            .foregroundStyle(Theme.muted)
        case .action(let label, let run):
            Button(label, action: run).buttonStyle(OutlineButtonStyle()).keyboardFocusRing()
        case .note(let text):
            Text(text).font(.ui(12)).foregroundStyle(Theme.muted)
        }
    }
}

/// Le panneau Connecteurs.
struct ConnectorsPane: View {
    let open: (SettingsView.Subpage) -> Void
    @Binding var mailApp: String
    @Environment(\.settingsFilter) private var filter
    @ObservedObject private var store = RecordingStore.shared
    @State private var calendarAccounts = Connectors.calendarAccounts
    @State private var calendarAuthorized = Connectors.calendarAuthorized
    @State private var mcp = ClaudeCode.registration()
    /// Incrémenté après un geste (Relier, Utiliser) : la liste relit l'état des connecteurs.
    @State private var tick = 0

    var body: some View {
        let _ = tick
        VStack(alignment: .leading, spacing: filter.isEmpty ? 28 : 0) {
            group("Agenda", footer: "Murmure lit l'agenda du Mac, celui de l'application Calendrier, où l'on ajoute ses comptes (Réglages Système › Comptes Internet). Le rendez-vous en cours nomme la réunion et remplit l'e-mail du compte rendu. Rien ne quitte ce Mac.", agenda)
            group("Messagerie", footer: "« Préparer un e-mail » ouvre un brouillon de la synthèse, adressé aux invités du rendez-vous, dans la messagerie choisie. Rien n'est envoyé sans vous.", mail)
            group("Rédaction", footer: "Claude relit les dictées et rédige les comptes rendus en ligne (le son reste ici). Claude Code lit l'historique à la demande et reçoit une fiche dans le dossier d'un projet. Word reçoit les comptes rendus exportés.", writing)
            group("Notes et tâches", footer: "Chaque envoi est un geste depuis la fiche (bouton « … » › Envoyer dans…) ; rien ne part tout seul. Jetons et adresses de webhook restent sur ce Mac, dans le dossier de Murmure.", notes)
            group("Dossier de l'affaire", footer: "Clic droit sur un dossier Murmure › « Copier dans un dossier du Mac… » : ses dictées et réunions y sont écrites en Markdown et tenues à jour. Un dossier synchronisé (OneDrive, Google Drive, Dropbox, iCloud Drive) les met sur vos autres appareils.", folders)
            group("Visioconférence", footer: "Quand l'une de ces applications prend le micro, Murmure propose d'enregistrer la réunion ; le lien du rendez-vous dit laquelle.", video)
        }
        .onAppear(perform: refresh)
    }

    private func group(_ title: String, footer: String, _ rows: [Connector]) -> some View {
        SettingsSection(title: title, footer: footer) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, connector in
                ConnectorRow(connector: connector, last: index == rows.count - 1)
            }
        }
    }

    private func refresh() {
        calendarAccounts = Connectors.calendarAccounts
        calendarAuthorized = Connectors.calendarAuthorized
        mcp = ClaudeCode.registration()
        tick += 1
    }

    private static func installed(_ bundleIDs: [String]) -> Bool {
        bundleIDs.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    // MARK: Agenda

    private var agenda: [Connector] {
        let services: [(String, String, BrandIcon, String, String)] = [
            ("agenda-outlook", "Outlook", .outlook, "Agenda Microsoft 365 ou Exchange", "Outlook"),
            ("agenda-google", "Google Agenda", .googleCalendar, "Agenda Google", "Google"),
            ("agenda-icloud", "iCloud", .icloud, "Agenda iCloud", "iCloud"),
        ]
        return services.map { id, name, icon, detail, kind in
            let accounts = calendarAccounts.filter { $0.kind == kind }
            let state: Connector.State
            if let first = accounts.first {
                let count = accounts.flatMap(\.calendars).filter(\.included).count
                state = .linked(first.address ?? (count == 1 ? "1 agenda" : "\(count) agendas"))
            } else {
                state = .action(calendarAuthorized ? "Relier" : "Autoriser") { open(.calendar) }
            }
            return Connector(id: id, name: name, icon: icon, detail: detail, state: state) { open(.calendar) }
        }
    }

    // MARK: Messagerie

    private var mail: [Connector] {
        let outlookApp = Connectors.MailApp.outlookInstalled
        func row(_ id: String, _ name: String, _ icon: BrandIcon, _ detail: String,
                 _ values: [Connectors.MailApp], _ choice: Connectors.MailApp) -> Connector {
            let linked = values.map(\.rawValue).contains(mailApp)
            return Connector(id: id, name: name, icon: icon, detail: detail,
                             state: linked ? .linked("Brouillons ici") : .action("Utiliser") { mailApp = choice.rawValue; refresh() })
        }
        return [
            row("mail", "Mail", .mail, "Brouillon dans l'application Mail du Mac", [.system], .system),
            row("mail-outlook", "Outlook", .outlook, outlookApp ? "Brouillon dans l'application Outlook" : "Brouillon dans Outlook, dans le navigateur",
                [.outlook, .outlookWeb], outlookApp ? .outlook : .outlookWeb),
            row("mail-gmail", "Gmail", .gmail, "Brouillon dans Gmail, dans le navigateur", [.gmail], .gmail),
        ]
    }

    // MARK: Rédaction

    private var writing: [Connector] {
        [
            Connector(id: "claude", name: "Claude", icon: .claude, detail: "Relecture des dictées, comptes rendus, questions à la réunion",
                      state: ClaudeAPI.hasKey ? .linked(ClaudeAPI.name(of: Settings.claudeWritingModel)) : .action("Relier") { open(.claude) }) { open(.claude) },
            Connector(id: "claude-code", name: "Claude Code", icon: .claudeCode, detail: "Lit l'historique à la demande · reçoit une fiche dans un projet",
                      state: mcp.any ? .linked(mcp.stale ? "À mettre à jour" : mcp.summary) : .action("Relier") { registerMCP() }) { open(.claudeCode) },
            Connector(id: "word", name: "Word", icon: .word, detail: "Export des comptes rendus en .docx",
                      state: .note(Self.installed(["com.microsoft.Word"]) ? "Installé" : "Fichier .docx")),
        ]
    }

    private func registerMCP() {
        do { try ClaudeCode.register(true) } catch { Toasts.shared.show("Claude Code : \(error.localizedDescription)", seconds: 8) }
        refresh()
    }

    // MARK: Notes et tâches

    private var notes: [Connector] {
        var rows = [
            Connector(id: "notion", name: "Notion", icon: .notion, detail: "Une page par fiche, sous la page de votre choix",
                      state: Notion.isLinked ? .linked(Notion.parentTitle) : .action("Relier") { open(.notion) }) { open(.notion) },
            Connector(id: "slack", name: "Slack", icon: .slack, detail: "La synthèse dans un canal, par webhook entrant",
                      state: Slack.isLinked ? .linked(nil) : .action("Relier") { open(.slack) }) { open(.slack) },
            Connector(id: "todoist", name: "Todoist", icon: .todoist, detail: Todoist.isLinked && Todoist.automatic
                      ? "Les actions du compte rendu deviennent des tâches, d'elles-mêmes" : "Les actions du compte rendu deviennent des tâches",
                      state: Todoist.isLinked ? .linked(Todoist.projectName ?? "Boîte de réception") : .action("Relier") { open(.todoist) }) { open(.todoist) },
            Connector(id: "rappels", name: "Rappels", icon: .reminders, detail: "Les actions du compte rendu deviennent des rappels",
                      state: remindersState),
            Connector(id: "notes", name: "Notes", icon: .notes, detail: "Une note par fiche : synthèse puis transcription",
                      state: AppleNotes.isLinked ? .linked(nil) : .action("Relier") { linkNotes() }),
        ]
        if Obsidian.installed || Obsidian.isLinked {
            rows.append(Connector(id: "obsidian", name: "Obsidian", icon: .obsidian, detail: "Une note Markdown dans votre coffre",
                                  state: Obsidian.isLinked ? .linked(Obsidian.vault?.lastPathComponent) : .action("Relier") { linkObsidian() }) { open(.obsidian) })
        }
        rows.append(Connector(id: "webhook", name: "Webhook", icon: .webhook, detail: "La fiche en JSON vers Zapier, Make ou n8n",
                              state: Webhook.isLinked ? .linked(nil) : .action("Relier") { open(.webhook) }) { open(.webhook) })
        return rows
    }

    private var remindersState: Connector.State {
        if Reminders.authorized { return .linked(Reminders.listName.map { "Liste « \($0) »" }) }
        if Reminders.denied { return .action("Autoriser") { SystemSettings.open(.reminders) } }
        return .action("Relier") { Reminders.request { _ in refresh() } }
    }

    private func linkNotes() {
        do { try AppleNotes.link() } catch { Toasts.shared.show("Notes : \(error.localizedDescription)", seconds: 8) }
        refresh()
    }

    private func linkObsidian() {
        Obsidian.choose { folder in
            Obsidian.link(folder)
            refresh()
        }
    }

    // MARK: Dossier de l'affaire

    private var folders: [Connector] {
        let linked = store.folders.filter { $0.exportPath != nil }.count
        return [
            Connector(id: "dossier", name: "Dossier du Mac", icon: .folder, detail: "Copie Markdown tenue à jour : OneDrive, Google Drive, Dropbox, iCloud Drive…",
                      state: linked > 0 ? .linked(linked == 1 ? "1 dossier relié" : "\(linked) dossiers reliés") : .note("Clic droit sur un dossier")),
        ]
    }

    // MARK: Visioconférence

    private var video: [Connector] {
        func row(_ id: String, _ name: String, _ icon: BrandIcon, _ bundleIDs: [String], browser: Bool = false) -> Connector {
            let state: Connector.State = browser ? .note("Dans le navigateur") : .note(Self.installed(bundleIDs) ? "Reconnue" : "Non installée")
            return Connector(id: id, name: name, icon: icon, detail: "Détection automatique de la réunion", state: state)
        }
        return [
            row("teams", "Teams", .teams, ["com.microsoft.teams2", "com.microsoft.teams"]),
            row("zoom", "Zoom", .zoom, ["us.zoom.xos"]),
            row("meet", "Google Meet", .googleMeet, [], browser: true),
            row("webex", "Webex", .webex, ["Cisco-Systems.Spark", "com.cisco.webex"]),
            row("facetime", "FaceTime", .faceTime, ["com.apple.FaceTime"]),
        ]
    }
}

// MARK: - Sous-pages

/// Champ de saisie d'un jeton ou d'un lien, dans le style des Réglages.
struct LinkField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var width: CGFloat = 260
    var onSubmit: () -> Void = {}

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $text).onSubmit(onSubmit)
            } else {
                TextField(placeholder, text: $text).onSubmit(onSubmit)
            }
        }
        .textFieldStyle(.plain)
        .font(.ui(12))
        .frame(width: width)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line))
    }
}

/// Sous-page Claude Code : où le serveur est déclaré, et les projets qui ont déjà reçu une fiche.
struct ClaudeCodePage: View {
    @State private var mcp = ClaudeCode.registration()
    @State private var error: String?

    var body: some View {
        SettingsSection(title: "Lecture de l'historique",
                        footer: "Relié, Claude Code et l'app Claude listent, cherchent et lisent vos dictées et réunions à la demande (« résume la réunion d'hier avec Me Delorme »), sur ce Mac, en lecture seule : Murmure se déclare dans leur configuration et répond quand ils l'interrogent. Une session déjà ouverte doit être relancée pour le voir.") {
            SettingsRow(label: "Claude Code") { status(mcp.claudeCode) }
            SettingsRow(label: "App Claude") { status(mcp.claudeDesktop) }
            SettingsRow(label: "Déclaration", last: true) {
                HStack(spacing: 10) {
                    if let error { Hint(error) }
                    if mcp.stale {
                        Button("Mettre à jour") { register(true) }.buttonStyle(OutlineButtonStyle(prominent: true)).keyboardFocusRing()
                    }
                    if mcp.any {
                        Button("Délier") { register(false) }.buttonStyle(OutlineButtonStyle()).keyboardFocusRing()
                    } else {
                        Button("Relier") { register(true) }.buttonStyle(OutlineButtonStyle(prominent: true)).keyboardFocusRing()
                    }
                }
            }
        }
        SettingsSection(title: "Envoi d'une fiche",
                        footer: "Sur une dictée ou une réunion, le bouton « Claude Code » copie la fiche en Markdown dans le dossier d'un projet, puis propose d'y ouvrir Claude Code. Les derniers projets utilisés sont proposés en premier.") {
            let projects = ClaudeCode.recentProjects
            if projects.isEmpty {
                SettingsRow(label: "Aucun projet encore", last: true) { Hint("bouton « Claude Code » sur une fiche") }
            } else {
                ForEach(Array(projects.enumerated()), id: \.element.path) { index, project in
                    SettingsRow(label: project.lastPathComponent, last: index == projects.count - 1) {
                        Hint(project.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    }
                }
            }
        }
    }

    private func status(_ linked: Bool) -> some View {
        Label(linked ? "Relié" : "Non relié", systemImage: linked ? "checkmark" : "minus")
            .font(.ui(12)).foregroundStyle(Theme.muted)
    }

    private func register(_ on: Bool) {
        do {
            try ClaudeCode.register(on)
            error = nil
        } catch let failure {
            error = failure.localizedDescription
        }
        mcp = ClaudeCode.registration()
    }
}

/// Sous-page Notion : jeton d'intégration et page parente.
struct NotionPage: View {
    @State private var token = ""
    @State private var parent = ""
    @State private var working = false
    @State private var result: String?
    @State private var linked = Notion.isLinked

    var body: some View {
        if linked {
            SettingsSection(title: "Relié",
                            footer: "Chaque « Envoyer dans Notion » crée une page sous cette page, avec la synthèse puis la transcription. Le jeton reste sur ce Mac et n'est envoyé qu'à api.notion.com.") {
                SettingsRow(label: "Page parente") { Hint(Notion.parentTitle ?? "") }
                SettingsRow(label: "Jeton", last: true) {
                    HStack(spacing: 10) {
                        Hint("gardé sur ce Mac")
                        Button("Délier") { Notion.unlink(); linked = false; result = nil }.buttonStyle(OutlineButtonStyle()).keyboardFocusRing()
                    }
                }
            }
        } else {
            SettingsSection(title: "Intégration Notion",
                            footer: "1. Sur notion.so/profile/integrations, créez une intégration interne (avec le droit d'insérer du contenu) et copiez son jeton secret. 2. Dans Notion, ouvrez la page qui recevra les fiches : menu ••• › Connexions › ajoutez l'intégration. 3. Collez ici le jeton et le lien de cette page.") {
                SettingsRow(label: "Jeton secret") { LinkField(placeholder: "ntn_… ou secret_…", text: $token, secure: true) }
                SettingsRow(label: "Lien de la page") { LinkField(placeholder: "https://www.notion.so/…", text: $parent, onSubmit: link) }
                SettingsRow(label: "Vérification", last: true) {
                    HStack(spacing: 10) {
                        if working { Spinner(size: 12, color: Theme.muted, lineWidth: 1.4) }
                        if let result { Hint(result) }
                        Button("Relier", action: link)
                            .buttonStyle(OutlineButtonStyle(prominent: true))
                            .keyboardFocusRing()
                            .disabled(working || token.trimmingCharacters(in: .whitespaces).isEmpty || parent.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func link() {
        guard !working else { return }
        working = true
        result = nil
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines), parent = parent
        Task {
            do {
                let title = try await Notion.link(token: token, parent: parent)
                await MainActor.run {
                    result = "relié à « \(title) »"
                    linked = true
                    self.token = ""
                }
            } catch {
                await MainActor.run { result = error.localizedDescription }
            }
            await MainActor.run { working = false }
        }
    }
}

/// Sous-page Todoist : jeton, projet de destination, ajout automatique.
struct TodoistPage: View {
    @State private var token = ""
    @State private var working = false
    @State private var result: String?
    @State private var linked = Todoist.isLinked
    @State private var projects: [Todoist.Project] = []
    /// Identifiant du projet choisi ; "" = boîte de réception.
    @State private var project = Todoist.projectID ?? ""
    @State private var automatic = Todoist.automatic

    var body: some View {
        if linked {
            SettingsSection(title: "Relié",
                            footer: "« Créer les tâches dans Todoist » (menu « … » d'une fiche) ajoute une tâche par action du compte rendu (« Responsable : action (échéance) »), avec la réunion en description et l'échéance comprise par Todoist. Avec l'ajout automatique, les actions partent d'elles-mêmes dès que le compte rendu d'une réunion est prêt, une seule fois par réunion, jamais pour un dossier « jamais en ligne ».") {
                SettingsRow(label: "Projet") {
                    HStack(spacing: 10) {
                        if working { Spinner(size: 12, color: Theme.muted, lineWidth: 1.4) }
                        if let result { Hint(result) }
                        Dropdown(options: [("", "Boîte de réception")] + projects.filter { !$0.inbox }.map { ($0.id, $0.name) }, selection: $project)
                            .onChange(of: project) { _, id in Todoist.setProject(projects.first { $0.id == id }) }
                    }
                }
                SettingsRow(label: "Ajouter dès que le compte rendu est prêt") {
                    Toggle("", isOn: $automatic).toggleStyle(MonoToggleStyle()).labelsHidden()
                        .onChange(of: automatic) { _, value in Todoist.automatic = value }
                }
                SettingsRow(label: "Jeton", last: true) {
                    HStack(spacing: 10) {
                        Hint("gardé sur ce Mac")
                        Button("Délier") { Todoist.unlink(); linked = false; result = nil; projects = []; project = "" }
                            .buttonStyle(OutlineButtonStyle()).keyboardFocusRing()
                    }
                }
            }
            .onAppear(perform: loadProjects)
        } else {
            SettingsSection(title: "Jeton Todoist",
                            footer: "Dans Todoist : Réglages › Intégrations › Développeur › « Jeton API », à copier ici. Il reste sur ce Mac et n'est envoyé qu'à api.todoist.com.") {
                SettingsRow(label: "Jeton API") { LinkField(placeholder: "jeton personnel", text: $token, secure: true, onSubmit: link) }
                SettingsRow(label: "Vérification", last: true) {
                    HStack(spacing: 10) {
                        if working { Spinner(size: 12, color: Theme.muted, lineWidth: 1.4) }
                        if let result { Hint(result) }
                        Button("Relier", action: link).buttonStyle(OutlineButtonStyle(prominent: true)).keyboardFocusRing()
                            .disabled(working || token.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func link() {
        guard !working else { return }
        working = true
        result = nil
        let token = token
        Task {
            do {
                let list = try await Todoist.link(token: token)
                await MainActor.run {
                    projects = list
                    linked = true
                    result = nil
                    self.token = ""
                }
            } catch {
                await MainActor.run { result = error.localizedDescription }
            }
            await MainActor.run { working = false }
        }
    }

    private func loadProjects() {
        guard projects.isEmpty, !working else { return }
        working = true
        Task {
            do {
                let list = try await Todoist.projects()
                await MainActor.run { projects = list }
            } catch {
                await MainActor.run { result = error.localizedDescription }
            }
            await MainActor.run { working = false }
        }
    }
}

/// Sous-page Slack : adresse du webhook entrant.
struct SlackPage: View {
    @State private var webhook = ""
    @State private var result: String?
    @State private var working = false
    @State private var linked = Slack.isLinked

    var body: some View {
        if linked {
            SettingsSection(title: "Relié",
                            footer: "« Envoyer dans Slack » poste la synthèse dans le canal du webhook (un webhook = un canal). L'adresse reste sur ce Mac.") {
                SettingsRow(label: "Webhook", last: true) {
                    HStack(spacing: 10) {
                        if working { Spinner(size: 12, color: Theme.muted, lineWidth: 1.4) }
                        if let result { Hint(result) }
                        Button("Tester", action: test).buttonStyle(OutlineButtonStyle()).keyboardFocusRing().disabled(working)
                        Button("Délier") { Slack.unlink(); linked = false; result = nil }.buttonStyle(OutlineButtonStyle()).keyboardFocusRing()
                    }
                }
            }
        } else {
            SettingsSection(title: "Webhook entrant",
                            footer: "Sur api.slack.com/apps, créez une application, activez « Incoming Webhooks », ajoutez un webhook au canal voulu et copiez son adresse.") {
                SettingsRow(label: "Adresse") { LinkField(placeholder: "https://hooks.slack.com/services/…", text: $webhook, secure: true, onSubmit: link) }
                SettingsRow(label: "Vérification", last: true) {
                    HStack(spacing: 10) {
                        if let result { Hint(result) }
                        Button("Relier", action: link).buttonStyle(OutlineButtonStyle(prominent: true)).keyboardFocusRing()
                            .disabled(webhook.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func link() {
        do {
            try Slack.link(webhook)
            webhook = ""
            result = nil
            linked = true
        } catch {
            result = error.localizedDescription
        }
    }

    private func test() {
        working = true
        result = nil
        Task {
            do {
                try await Slack.post("Murmure est relié à ce canal.")
                await MainActor.run { result = "message envoyé" }
            } catch {
                await MainActor.run { result = error.localizedDescription }
            }
            await MainActor.run { working = false }
        }
    }
}

/// Sous-page Webhook : adresse d'un scénario Zapier, Make ou n8n.
struct WebhookPage: View {
    @State private var address = ""
    @State private var result: String?
    @State private var working = false
    @State private var linked = Webhook.isLinked

    var body: some View {
        if linked {
            SettingsSection(title: "Relié",
                            footer: "« Envoyer au webhook » poste la fiche en JSON : id, kind, title, date, duration, summary, summary_kind, transcript, text, notes, participants, folder, source. L'adresse reste sur ce Mac.") {
                SettingsRow(label: "Adresse", last: true) {
                    HStack(spacing: 10) {
                        if working { Spinner(size: 12, color: Theme.muted, lineWidth: 1.4) }
                        if let result { Hint(result) }
                        Button("Tester", action: test).buttonStyle(OutlineButtonStyle()).keyboardFocusRing().disabled(working)
                        Button("Délier") { Webhook.unlink(); linked = false; result = nil }.buttonStyle(OutlineButtonStyle()).keyboardFocusRing()
                    }
                }
            }
        } else {
            SettingsSection(title: "Adresse du webhook",
                            footer: "Dans Zapier (« Webhooks by Zapier › Catch Hook »), Make (« Webhooks › Custom webhook ») ou n8n (nœud Webhook), créez un déclencheur et copiez son adresse. Murmure y poste la fiche en JSON à chaque « Envoyer au webhook ».") {
                SettingsRow(label: "Adresse") { LinkField(placeholder: "https://hooks.zapier.com/…", text: $address, secure: true, onSubmit: link) }
                SettingsRow(label: "Vérification", last: true) {
                    HStack(spacing: 10) {
                        if let result { Hint(result) }
                        Button("Relier", action: link).buttonStyle(OutlineButtonStyle(prominent: true)).keyboardFocusRing()
                            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func link() {
        do {
            try Webhook.link(address)
            address = ""
            result = nil
            linked = true
        } catch {
            result = error.localizedDescription
        }
    }

    private func test() {
        working = true
        result = nil
        Task {
            do {
                guard let saved = Secrets.get("webhook"), let url = URL(string: saved) else { throw ConnectorError("Non relié.") }
                let (data, status) = try await ConnectorHTTP.send(try ConnectorHTTP.json(url, body: ["source": "Murmure", "test": true]))
                guard (200..<300).contains(status) else { throw ConnectorHTTP.failure(data, status) }
                await MainActor.run { result = "reçu (\(status))" }
            } catch {
                await MainActor.run { result = error.localizedDescription }
            }
            await MainActor.run { working = false }
        }
    }
}

/// Sous-page Obsidian : le coffre.
struct ObsidianPage: View {
    @State private var vault = Obsidian.vault

    var body: some View {
        SettingsSection(title: "Coffre",
                        footer: "« Envoyer dans Obsidian » écrit la fiche en Markdown dans le sous-dossier « Murmure » du coffre, puis l'ouvre dans Obsidian. Pour une copie automatique de tout un dossier Murmure, reliez plutôt ce dossier au coffre (clic droit › Copier dans un dossier du Mac…).") {
            SettingsRow(label: vault.map { "Coffre « \($0.lastPathComponent) »" } ?? "Aucun coffre", last: true) {
                HStack(spacing: 10) {
                    if let vault { Hint(vault.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) }
                    Button(vault == nil ? "Choisir…" : "Changer…") {
                        Obsidian.choose { folder in
                            Obsidian.link(folder)
                            vault = Obsidian.vault
                        }
                    }
                    .buttonStyle(OutlineButtonStyle(prominent: vault == nil))
                    .keyboardFocusRing()
                    if vault != nil {
                        Button("Délier") { Obsidian.unlink(); vault = nil }.buttonStyle(OutlineButtonStyle()).keyboardFocusRing()
                    }
                }
            }
        }
    }
}
