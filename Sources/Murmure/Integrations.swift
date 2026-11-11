import AppKit
import EventKit

// Connecteurs sortants : une dictée ou une réunion part, sur demande et jamais d'elle-même, vers Notion,
// Slack, un webhook (Zapier, Make, n8n), Rappels, Notes ou un coffre Obsidian. Chaque envoi est un geste
// explicite depuis la fiche ; les secrets (jeton Notion, adresses de webhook) restent sur ce Mac (`Coffre`).

/// Secrets des connecteurs, dans le coffre de Murmure (`Coffre`), sous « connecteurs.<nom> ».
enum Secrets {
    static func get(_ account: String) -> String? {
        Coffre.get("connecteurs." + account, ancien: .init(service: "Murmure · Connecteurs", account: account))
    }

    /// Enregistre (ou retire, si vide) un secret.
    static func set(_ account: String, _ value: String?) { Coffre.set("connecteurs." + account, value) }

    static func has(_ account: String) -> Bool { !(get(account) ?? "").isEmpty }
}

/// Erreur lisible d'un connecteur.
struct ConnectorError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// Appels HTTP des connecteurs : JSON en entrée, erreur lisible en sortie.
enum ConnectorHTTP {
    static func send(_ request: URLRequest) async throws -> (Data, Int) {
        var request = request
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func json(_ url: URL, method: String = "POST", headers: [String: String] = [:], body: Any?) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return request
    }

    /// Message d'une réponse en erreur (champ `message` de Notion, texte brut de Slack…).
    static func failure(_ data: Data, _ status: Int) -> ConnectorError {
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let message = object["message"] as? String {
            return ConnectorError("\(message) (\(status))")
        }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ConnectorError(text.isEmpty ? "réponse \(status)" : "\(text.prefix(120)) (\(status))")
    }
}

/// Ce que l'on envoie d'une fiche : la synthèse si elle existe, sinon la transcription.
extension Recording {
    var bestBody: String { summaries?.last?.text ?? transcript }
    var dateLine: String { "\(date.formatted(date: .long, time: .shortened)) · \(formatDuration(duration))" }
}

// MARK: - Notion

/// Notion : chaque envoi crée une page sous la page parente choisie (jeton d'intégration interne + page partagée
/// avec l'intégration). Synthèse et transcription deviennent des blocs Notion.
enum Notion {
    static let version = "2022-06-28"
    static var token: String? { Secrets.get("notion") }
    static var parentID: String? { UserDefaults.standard.string(forKey: "notionParent") }
    static var parentTitle: String? { UserDefaults.standard.string(forKey: "notionParentTitle") }
    static var isLinked: Bool { Secrets.has("notion") && parentID != nil }

    /// Identifiant de page (32 hexadécimaux) tiré d'un lien Notion ou d'un identifiant collé tel quel.
    static func pageID(from text: String) -> String? {
        let compact = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-", with: "")
        guard let match = compact.range(of: "[0-9a-fA-F]{32}", options: [.regularExpression, .backwards]) else { return nil }
        return String(compact[match]).lowercased()
    }

    private static func headers(_ token: String) -> [String: String] {
        ["Authorization": "Bearer \(token)", "Notion-Version": version]
    }

    /// Vérifie le jeton et la page parente, puis les mémorise ; renvoie le titre de la page.
    static func link(token: String, parent: String) async throws -> String {
        guard let id = pageID(from: parent) else { throw ConnectorError("Collez le lien de la page Notion parente.") }
        let request = try ConnectorHTTP.json(URL(string: "https://api.notion.com/v1/pages/\(id)")!, method: "GET", headers: headers(token), body: nil)
        let (data, status) = try await ConnectorHTTP.send(request)
        guard status == 200 else {
            throw status == 404 ? ConnectorError("Page introuvable : partagez-la avec l'intégration (••• › Connexions).") : ConnectorHTTP.failure(data, status)
        }
        let title = pageTitle(data) ?? "page Notion"
        Secrets.set("notion", token)
        UserDefaults.standard.set(id, forKey: "notionParent")
        UserDefaults.standard.set(title, forKey: "notionParentTitle")
        return title
    }

    static func unlink() {
        Secrets.set("notion", nil)
        UserDefaults.standard.removeObject(forKey: "notionParent")
        UserDefaults.standard.removeObject(forKey: "notionParentTitle")
    }

    private static func pageTitle(_ data: Data) -> String? {
        guard let page = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let properties = page["properties"] as? [String: Any] else { return nil }
        for property in properties.values {
            guard let property = property as? [String: Any], property["type"] as? String == "title",
                  let parts = property["title"] as? [[String: Any]] else { continue }
            let title = parts.compactMap { $0["plain_text"] as? String }.joined()
            if !title.isEmpty { return title }
        }
        return nil
    }

    /// Crée la page et renvoie son adresse.
    static func send(_ recording: Recording) async throws -> URL {
        guard let token, let parentID else { throw ConnectorError("Notion n'est pas relié.") }
        var blocks = [paragraph(recording.dateLine)]
        if let summary = recording.summaries?.last {
            blocks += Self.blocks(from: summary.text)
            blocks.append(heading("Transcription", level: 2))
        }
        blocks += Self.blocks(from: recording.transcript)
        let first = Array(blocks.prefix(100)), rest = Array(blocks.dropFirst(100))
        let body: [String: Any] = [
            "parent": ["page_id": parentID],
            "properties": ["title": ["title": [text(recording.title)]]],
            "children": first,
        ]
        let (data, status) = try await ConnectorHTTP.send(try ConnectorHTTP.json(URL(string: "https://api.notion.com/v1/pages")!, headers: headers(token), body: body))
        guard status == 200, let page = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = page["id"] as? String else { throw ConnectorHTTP.failure(data, status) }
        // Au-delà de 100 blocs (longue réunion), la suite est ajoutée par lots.
        var remaining = rest
        while !remaining.isEmpty {
            let batch = Array(remaining.prefix(100))
            remaining.removeFirst(batch.count)
            let append = try ConnectorHTTP.json(URL(string: "https://api.notion.com/v1/blocks/\(id)/children")!, method: "PATCH",
                                                headers: headers(token), body: ["children": batch])
            let (moreData, moreStatus) = try await ConnectorHTTP.send(append)
            guard moreStatus == 200 else { throw ConnectorHTTP.failure(moreData, moreStatus) }
        }
        let url = (page["url"] as? String).flatMap(URL.init) ?? URL(string: "https://www.notion.so/\(id.replacingOccurrences(of: "-", with: ""))")!
        return url
    }

    // Blocs Notion d'un Markdown simple : titres, puces, paragraphes ; textes découpés à 2 000 caractères.
    private static func text(_ string: String) -> [String: Any] { ["type": "text", "text": ["content": string]] }

    private static func richText(_ string: String) -> [[String: Any]] {
        var parts: [[String: Any]] = []
        var rest = Substring(string)
        while !rest.isEmpty {
            let chunk = rest.prefix(2000)
            parts.append(text(String(chunk)))
            rest = rest.dropFirst(chunk.count)
        }
        return parts.isEmpty ? [text("")] : parts
    }

    private static func block(_ type: String, _ string: String) -> [String: Any] {
        ["object": "block", "type": type, type: ["rich_text": richText(string)]]
    }

    private static func paragraph(_ string: String) -> [String: Any] { block("paragraph", string) }
    private static func heading(_ string: String, level: Int) -> [String: Any] { block("heading_\(min(max(level, 1), 3))", string) }

    static func blocks(from markdown: String) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                blocks.append(heading(line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")), level: min(level + 1, 3)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                blocks.append(block("bulleted_list_item", String(line.dropFirst(2))))
            } else {
                blocks.append(paragraph(line))
            }
        }
        return blocks
    }
}

// MARK: - Slack

/// Slack : un webhook entrant (une adresse = un canal) reçoit la synthèse, en message simple.
enum Slack {
    static var isLinked: Bool { Secrets.has("slack-webhook") }

    static func link(_ url: String) throws {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("https://hooks.slack.com/") else { throw ConnectorError("Collez l'adresse du webhook entrant (https://hooks.slack.com/services/…).") }
        Secrets.set("slack-webhook", trimmed)
    }

    static func unlink() { Secrets.set("slack-webhook", nil) }

    /// Markdown simple → mise en forme Slack (titres en gras, puces).
    static func mrkdwn(_ markdown: String) -> String {
        markdown.components(separatedBy: "\n").map { raw -> String in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { return "*\(line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")))*" }
            if line.hasPrefix("- ") || line.hasPrefix("* ") { return "• " + line.dropFirst(2) }
            return line
        }.joined(separator: "\n")
    }

    static func post(_ text: String) async throws {
        guard let webhook = Secrets.get("slack-webhook"), let url = URL(string: webhook) else { throw ConnectorError("Slack n'est pas relié.") }
        let (data, status) = try await ConnectorHTTP.send(try ConnectorHTTP.json(url, body: ["text": text]))
        guard status == 200 else { throw ConnectorHTTP.failure(data, status) }
    }

    static func send(_ recording: Recording) async throws {
        let body = String(mrkdwn(recording.bestBody).prefix(30_000))
        try await post("*\(recording.title)*\n_\(recording.dateLine)_\n\n\(body)")
    }
}

// MARK: - Webhook (Zapier, Make, n8n…)

/// Webhook : la fiche entière en JSON, à l'adresse donnée par un scénario Zapier, Make ou n8n.
enum Webhook {
    static var isLinked: Bool { Secrets.has("webhook") }

    static func link(_ url: String) throws {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmed), ["https", "http"].contains(parsed.scheme ?? ""), parsed.host != nil else {
            throw ConnectorError("Collez l'adresse https du webhook.")
        }
        Secrets.set("webhook", trimmed)
    }

    static func unlink() { Secrets.set("webhook", nil) }

    static func payload(_ recording: Recording) -> [String: Any] {
        var payload: [String: Any] = [
            "id": recording.id.uuidString,
            "kind": recording.isMeeting ? "reunion" : "dictee",
            "title": recording.title,
            "date": recording.date.formatted(.iso8601),
            "duration": Int(recording.duration.rounded()),
            "transcript": recording.transcript,
            "text": recording.text,
            "source": "Murmure",
        ]
        if let summary = recording.summaries?.last { payload["summary"] = summary.text; payload["summary_kind"] = summary.template }
        if let folder = RecordingStore.shared.folder(recording.folderID) { payload["folder"] = folder.name }
        if let notes = recording.userNotes { payload["notes"] = notes }
        let names = recording.participantNames
        if !names.isEmpty { payload["participants"] = names }
        return payload
    }

    @MainActor
    static func send(_ recording: Recording) async throws {
        guard let address = Secrets.get("webhook"), let url = URL(string: address) else { throw ConnectorError("Le webhook n'est pas relié.") }
        let (data, status) = try await ConnectorHTTP.send(try ConnectorHTTP.json(url, body: payload(recording)))
        guard (200..<300).contains(status) else { throw ConnectorHTTP.failure(data, status) }
    }
}

// MARK: - Rappels

/// Rappels : les actions du compte rendu (« Responsable : action (échéance) ») deviennent des rappels
/// dans la liste par défaut, avec la réunion en note et l'échéance quand elle est datée.
enum Reminders {
    static var authorized: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }
    static var denied: Bool { [.denied, .restricted].contains(EKEventStore.authorizationStatus(for: .reminder)) }

    static func request(_ done: @escaping (Bool) -> Void) {
        Connectors.eventStore.requestFullAccessToReminders { granted, _ in DispatchQueue.main.async { done(granted) } }
    }

    static var listName: String? { authorized ? Connectors.eventStore.defaultCalendarForNewReminders()?.title : nil }

    struct Action { let who: String?; let what: String; let when: String? }

    /// Actions de la dernière synthèse.
    static func actions(of recording: Recording) -> [Action] {
        guard let summary = recording.summaries?.last else { return [] }
        return SummarySection.parse(summary.text).filter { $0.kind == .actions }.flatMap(\.lines).map { line in
            let split = SummaryView.split(line.text)
            return Action(who: split.who, what: split.what, when: split.when)
        }
    }

    /// Date d'une échéance écrite en clair (« 15 novembre », « vendredi prochain »), si on la reconnaît.
    static func dueDate(from text: String?) -> DateComponents? {
        guard let text, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let date = detector.firstMatch(in: text, range: range)?.date else { return nil }
        return Calendar.current.dateComponents([.year, .month, .day], from: date)
    }

    /// Crée les rappels ; renvoie leur nombre.
    static func create(from recording: Recording) throws -> Int {
        guard authorized else { throw ConnectorError("Rappels n'est pas autorisé.") }
        let store = Connectors.eventStore
        guard let list = store.defaultCalendarForNewReminders() else { throw ConnectorError("Aucune liste de rappels par défaut.") }
        let actions = actions(of: recording)
        guard !actions.isEmpty else { throw ConnectorError("Le compte rendu n'a pas d'actions.") }
        for action in actions {
            let reminder = EKReminder(eventStore: store)
            reminder.calendar = list
            reminder.title = action.who.map { "\($0) : \(action.what)" } ?? action.what
            var notes = "Réunion « \(recording.title) », \(recording.date.formatted(date: .long, time: .omitted))"
            if let when = action.when { notes += "\nÉchéance : \(when)" }
            reminder.notes = notes
            if let due = dueDate(from: action.when) {
                reminder.dueDateComponents = due
                if let date = Calendar.current.date(from: due) { reminder.addAlarm(EKAlarm(absoluteDate: Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date)) }
            }
            try store.save(reminder, commit: false)
        }
        try store.commit()
        return actions.count
    }
}

// MARK: - Notes

/// Notes (Apple) : une note par envoi, créée par AppleScript (la seule porte de Notes) ; macOS demande une fois
/// l'autorisation « Automatisation ».
enum AppleNotes {
    static let bundleID = "com.apple.Notes"
    static var installed: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }
    static var isLinked: Bool { UserDefaults.standard.bool(forKey: "notesLinked") }

    /// Demande l'autorisation en lisant simplement le nom de l'application.
    static func link() throws {
        try run("tell application \"Notes\" to get name")
        UserDefaults.standard.set(true, forKey: "notesLinked")
    }

    static func unlink() { UserDefaults.standard.set(false, forKey: "notesLinked") }

    private static func escape(_ string: String) -> String {
        string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func html(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Markdown simple → HTML que Notes met en forme (titres, listes, paragraphes).
    static func body(_ recording: Recording) -> String {
        var out = ["<h1>\(html(recording.title))</h1>", "<p>\(html(recording.dateLine))</p>"]
        var inList = false
        func close() { if inList { out.append("</ul>"); inList = false } }
        let markdown = recording.summaries?.last.map { $0.text + "\n## Transcription\n" + recording.transcript } ?? recording.transcript
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                close()
                out.append("<h2>\(html(line.trimmingCharacters(in: CharacterSet(charactersIn: "# "))))</h2>")
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                if !inList { out.append("<ul>"); inList = true }
                out.append("<li>\(html(String(line.dropFirst(2))))</li>")
            } else {
                close()
                out.append("<p>\(html(line))</p>")
            }
        }
        close()
        return out.joined(separator: "\n")
    }

    @discardableResult
    private static func run(_ source: String) throws -> String {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw ConnectorError("Script illisible.") }
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            let message = error[NSAppleScript.errorMessage] as? String ?? "erreur \(number)"
            throw ConnectorError(number == -1743 ? "Autorisez Murmure à piloter Notes (Réglages Système › Confidentialité › Automatisation)." : message)
        }
        return result.stringValue ?? ""
    }

    static func send(_ recording: Recording) throws {
        try run("tell application \"Notes\" to make new note with properties {name:\"\(escape(recording.title))\", body:\"\(escape(body(recording)))\"}")
    }
}

// MARK: - Obsidian

/// Obsidian : la fiche est écrite en Markdown dans le coffre choisi (dossier « Murmure » du coffre), puis ouverte.
enum Obsidian {
    static let bundleID = "md.obsidian"
    static var installed: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }
    static var vault: URL? {
        UserDefaults.standard.string(forKey: "obsidianVault").map { URL(fileURLWithPath: $0, isDirectory: true) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }
    static var isLinked: Bool { vault != nil }

    static func link(_ folder: URL) { UserDefaults.standard.set(folder.path, forKey: "obsidianVault") }
    static func unlink() { UserDefaults.standard.removeObject(forKey: "obsidianVault") }

    @MainActor
    static func choose(_ done: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choisir ce coffre"
        panel.message = "Choisissez le dossier du coffre Obsidian : chaque envoi y écrit une note Markdown dans un sous-dossier « Murmure »."
        if let vault { panel.directoryURL = vault }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            done(url)
        }
    }

    /// Écrit la note et renvoie son chemin.
    static func send(_ recording: Recording) throws -> URL {
        guard let vault else { throw ConnectorError("Aucun coffre Obsidian choisi.") }
        let folder = vault.appendingPathComponent("Murmure", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(Exporter.fileName(recording))
        try Exporter.markdown(recording).data(using: .utf8)?.write(to: target, options: .atomic)
        return target
    }

    static func open(_ note: URL) {
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: note.path)]
        if installed, let url = components.url { NSWorkspace.shared.open(url) } else { NSWorkspace.shared.activateFileViewerSelecting([note]) }
    }
}

// MARK: - Todoist

/// Todoist : les actions du compte rendu (« Responsable : action (échéance) ») deviennent des tâches dans le
/// projet choisi, à la demande depuis la fiche, ou d'elles-mêmes dès que le compte rendu d'une réunion est prêt.
/// API v1 (`https://api.todoist.com/api/v1`), jeton personnel dans le coffre de Murmure.
enum Todoist {
    static let base = "https://api.todoist.com/api/v1"
    static var token: String? { Secrets.get("todoist") }
    static var isLinked: Bool { Secrets.has("todoist") }
    /// Projet de destination ; nil = boîte de réception.
    static var projectID: String? { UserDefaults.standard.string(forKey: "todoistProject") }
    static var projectName: String? { UserDefaults.standard.string(forKey: "todoistProjectName") }
    /// Ajouter les actions dès qu'un compte rendu de réunion est prêt (par défaut, une fois relié).
    static var automatic: Bool {
        get { UserDefaults.standard.object(forKey: "todoistAuto") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "todoistAuto") }
    }

    struct Project: Identifiable, Hashable {
        let id: String
        let name: String
        let inbox: Bool
    }

    private static func headers(_ token: String) -> [String: String] { ["Authorization": "Bearer \(token)"] }

    /// Les projets, page après page.
    static func projects(token given: String? = nil) async throws -> [Project] {
        guard let token = given ?? token else { throw ConnectorError("Todoist n'est pas relié.") }
        var projects: [Project] = []
        var cursor: String?
        repeat {
            var components = URLComponents(string: "\(base)/projects")!
            components.queryItems = [URLQueryItem(name: "limit", value: "200")] + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
            let request = try ConnectorHTTP.json(components.url!, method: "GET", headers: headers(token), body: nil)
            let (data, status) = try await ConnectorHTTP.send(request)
            guard status == 200, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw status == 401 || status == 403 ? ConnectorError("Jeton refusé par Todoist.") : ConnectorHTTP.failure(data, status)
            }
            let page = (object["results"] as? [[String: Any]]) ?? (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            projects += page.compactMap { item in
                guard let id = (item["id"] as? String) ?? (item["id"] as? Int).map(String.init), let name = item["name"] as? String else { return nil }
                return Project(id: id, name: name, inbox: (item["inbox_project"] as? Bool) ?? (item["is_inbox_project"] as? Bool) ?? false)
            }
            cursor = object["next_cursor"] as? String
        } while cursor != nil && !(cursor ?? "").isEmpty
        return projects.sorted { ($0.inbox ? 0 : 1, $0.name.lowercased()) < ($1.inbox ? 0 : 1, $1.name.lowercased()) }
    }

    /// Vérifie le jeton en listant les projets, puis le garde ; renvoie les projets.
    static func link(token: String) async throws -> [Project] {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let projects = try await projects(token: trimmed)
        Secrets.set("todoist", trimmed)
        return projects
    }

    static func unlink() {
        Secrets.set("todoist", nil)
        UserDefaults.standard.removeObject(forKey: "todoistProject")
        UserDefaults.standard.removeObject(forKey: "todoistProjectName")
    }

    static func setProject(_ project: Project?) {
        if let project, !project.inbox {
            UserDefaults.standard.set(project.id, forKey: "todoistProject")
            UserDefaults.standard.set(project.name, forKey: "todoistProjectName")
        } else {
            UserDefaults.standard.removeObject(forKey: "todoistProject")
            UserDefaults.standard.removeObject(forKey: "todoistProjectName")
        }
    }

    // Fiches dont les actions sont déjà parties d'elles-mêmes (pour ne pas créer deux fois les mêmes tâches).
    private static let sentKey = "todoistSent"
    static func sent(_ recording: Recording) -> Bool { (UserDefaults.standard.stringArray(forKey: sentKey) ?? []).contains(recording.id.uuidString) }
    private static func markSent(_ recording: Recording) {
        var list = UserDefaults.standard.stringArray(forKey: sentKey) ?? []
        list.append(recording.id.uuidString)
        UserDefaults.standard.set(Array(list.suffix(500)), forKey: sentKey)
    }

    /// Crée une tâche par action ; renvoie leur nombre.
    static func create(from recording: Recording) async throws -> Int {
        guard let token else { throw ConnectorError("Todoist n'est pas relié.") }
        let actions = Reminders.actions(of: recording)
        guard !actions.isEmpty else { throw ConnectorError("Le compte rendu n'a pas d'actions.") }
        for action in actions {
            var body: [String: Any] = [
                "content": action.who.map { "\(action.what) — \($0)" } ?? action.what,
                "description": "Réunion « \(recording.title) », \(recording.date.formatted(date: .long, time: .omitted)) · Murmure",
            ]
            if let projectID { body["project_id"] = projectID }
            if let when = action.when {
                body["due_string"] = when
                body["due_lang"] = "fr"
            }
            let request = try ConnectorHTTP.json(URL(string: "\(base)/tasks")!, headers: headers(token), body: body)
            let (data, status) = try await ConnectorHTTP.send(request)
            guard (200..<300).contains(status) else { throw ConnectorHTTP.failure(data, status) }
        }
        await MainActor.run { markSent(recording) }
        return actions.count
    }

    static var webURL: URL {
        URL(string: projectID.map { "https://app.todoist.com/app/project/\($0)" } ?? "https://app.todoist.com/app/inbox")!
    }
}

/// Ce qui part de lui-même quand un compte rendu de réunion est prêt.
enum Automations {
    /// Todoist : les actions du compte rendu, une seule fois par fiche, jamais pour un dossier « jamais en ligne ».
    @MainActor
    static func summaryReady(_ id: UUID, localOnly: Bool) {
        guard Todoist.isLinked, Todoist.automatic, !localOnly, !Settings.stayOffline,
              let recording = RecordingStore.shared.recording(id), !Todoist.sent(recording),
              !Reminders.actions(of: recording).isEmpty else { return }
        Outbound.todoist(recording)
    }
}

// MARK: - Envoi depuis une fiche

/// Les gestes « Envoyer dans … » d'une fiche, avec leur message de confirmation ou d'erreur.
enum Outbound {
    @MainActor
    static func notion(_ recording: Recording) {
        Toasts.shared.show("Envoi dans Notion…", seconds: 30)
        Task {
            do {
                let url = try await Notion.send(recording)
                await MainActor.run { Toasts.shared.show("Page créée dans Notion", action: ("Ouvrir", { NSWorkspace.shared.open(url) }), seconds: 8) }
            } catch {
                await MainActor.run { Toasts.shared.show("Notion : \(error.localizedDescription)", seconds: 8) }
            }
        }
    }

    @MainActor
    static func slack(_ recording: Recording) {
        Toasts.shared.show("Envoi dans Slack…", seconds: 30)
        Task {
            do {
                try await Slack.send(recording)
                await MainActor.run { Toasts.shared.show("Envoyé dans Slack") }
            } catch {
                await MainActor.run { Toasts.shared.show("Slack : \(error.localizedDescription)", seconds: 8) }
            }
        }
    }

    @MainActor
    static func webhook(_ recording: Recording) {
        Toasts.shared.show("Envoi au webhook…", seconds: 30)
        Task {
            do {
                try await Webhook.send(recording)
                await MainActor.run { Toasts.shared.show("Envoyé au webhook") }
            } catch {
                await MainActor.run { Toasts.shared.show("Webhook : \(error.localizedDescription)", seconds: 8) }
            }
        }
    }

    @MainActor
    static func todoist(_ recording: Recording) {
        Toasts.shared.show("Envoi dans Todoist…", seconds: 30)
        Task {
            do {
                let count = try await Todoist.create(from: recording)
                await MainActor.run {
                    Toasts.shared.show(count == 1 ? "1 tâche créée dans Todoist" : "\(count) tâches créées dans Todoist",
                                       action: ("Ouvrir Todoist", { NSWorkspace.shared.open(Todoist.webURL) }), seconds: 8)
                }
            } catch {
                await MainActor.run { Toasts.shared.show("Todoist : \(error.localizedDescription)", seconds: 8) }
            }
        }
    }

    @MainActor
    static func reminders(_ recording: Recording) {
        func go() {
            do {
                let count = try Reminders.create(from: recording)
                Toasts.shared.show(count == 1 ? "1 rappel créé" : "\(count) rappels créés", action: ("Ouvrir Rappels", {
                    NSWorkspace.shared.open(URL(string: "x-apple-reminderkit://")!)
                }))
            } catch {
                Toasts.shared.show("Rappels : \(error.localizedDescription)", seconds: 8)
            }
        }
        if Reminders.authorized { go() } else { Reminders.request { granted in if granted { go() } else { SystemSettings.open(.reminders) } } }
    }

    @MainActor
    static func notes(_ recording: Recording) {
        do {
            try AppleNotes.send(recording)
            Toasts.shared.show("Note créée dans Notes", action: ("Ouvrir Notes", {
                if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AppleNotes.bundleID) {
                    NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
                }
            }))
        } catch {
            Toasts.shared.show("Notes : \(error.localizedDescription)", seconds: 8)
        }
    }

    @MainActor
    static func obsidian(_ recording: Recording) {
        do {
            let note = try Obsidian.send(recording)
            Toasts.shared.show("Note écrite dans le coffre Obsidian", action: ("Ouvrir dans Obsidian", { Obsidian.open(note) }), seconds: 8)
        } catch {
            Toasts.shared.show("Obsidian : \(error.localizedDescription)", seconds: 8)
        }
    }

    /// Entrées de menu « Envoyer dans … » des connecteurs reliés (rien si aucun ne l'est).
    static func entries(for recording: Recording) -> [MenuEntry] {
        var entries: [MenuEntry] = []
        func add(_ title: String, _ symbol: String, _ run: @escaping @MainActor (Recording) -> Void) {
            entries.append(.action(title, symbol) { Task { @MainActor in run(recording) } })
        }
        if Notion.isLinked { add("Envoyer dans Notion", "doc.badge.plus", notion) }
        if Slack.isLinked { add("Envoyer dans Slack", "number", slack) }
        if Obsidian.isLinked { add("Envoyer dans Obsidian", "doc.text", obsidian) }
        if AppleNotes.isLinked { add("Envoyer dans Notes", "note.text", notes) }
        let hasActions = !Reminders.actions(of: recording).isEmpty
        if Todoist.isLinked, hasActions { add(Todoist.sent(recording) ? "Recréer les tâches dans Todoist" : "Créer les tâches dans Todoist", "checkmark.circle", todoist) }
        if Reminders.authorized, hasActions { add("Créer les actions dans Rappels", "checklist", reminders) }
        if Webhook.isLinked { add("Envoyer au webhook", "arrow.up.forward.app", webhook) }
        return entries
    }
}
