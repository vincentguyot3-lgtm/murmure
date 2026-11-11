import Foundation

/// Serveur MCP (JSON-RPC ligne par ligne sur l'entrée et la sortie standard) : `Murmure --mcp`.
/// Donne à Claude (Claude Code, app Claude) un accès en lecture à l'historique : liste, recherche, contenu,
/// dossiers, export ponctuel en Markdown dans un dossier du Mac. L'historique est relu sur le disque à chaque
/// demande (l'application le garde en mémoire et l'écrit elle-même) ; rien n'y est jamais écrit d'ici.
/// Réglages › Connecteurs › « Relier à Claude » déclare ce serveur auprès de Claude Code et de l'app Claude.
enum MCPServer {
    static let protocolVersion = "2025-06-18"
    static let version = "1.0"

    /// L'historique tel qu'il est sur le disque au moment de la demande.
    struct Snapshot {
        let recordings: [Recording]
        let folders: [Folder]

        /// Sans la corbeille, et sans ce qui doit rester sur ce Mac (dossier « Jamais en ligne », réunion marquée
        /// du cadenas) : Claude, qui lit par ce serveur, est un service en ligne.
        static func read() -> Snapshot {
            let (recordings, folders) = RecordingStore.readDisk()
            let localOnly = Set(folders.filter(\.isLocalOnly).map(\.id))
            let shared = recordings.filter { recording in
                !recording.isTrashed && recording.keepLocal != true && !(recording.folderID.map(localOnly.contains) ?? false)
            }
            return Snapshot(recordings: shared, folders: folders)
        }

        func folderName(_ recording: Recording) -> String? { folders.first { $0.id == recording.folderID }?.name }
    }

    // MARK: - Outils

    static let tools: [[String: Any]] = [
        [
            "name": "murmure_list",
            "description": "Liste les dernières dictées et réunions transcrites par Murmure (app de dictée locale), "
                + "de la plus récente à la plus ancienne. Renvoie un identifiant court par ligne, à passer à murmure_get.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "kind": ["type": "string", "enum": ["all", "meeting", "dictation"], "default": "all"],
                    "folder": ["type": "string", "description": "Nom (ou partie du nom) d'un dossier Murmure"],
                    "limit": ["type": "integer", "default": 20],
                    "include_archived": ["type": "boolean", "default": false],
                ],
            ],
        ],
        [
            "name": "murmure_get",
            "description": "Renvoie le contenu d'une dictée ou d'une réunion Murmure : synthèse, transcription par "
                + "interlocuteur, texte ou brut. `query` : identifiant (ou son début), mots du titre, ou 'dernière'.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string"],
                    "part": ["type": "string", "enum": ["all", "summary", "transcript", "text", "raw"], "default": "all"],
                ],
                "required": ["query"],
            ],
        ],
        [
            "name": "murmure_search",
            "description": "Recherche plein texte dans toutes les transcriptions et synthèses Murmure.",
            "inputSchema": [
                "type": "object",
                "properties": ["query": ["type": "string"], "limit": ["type": "integer", "default": 10]],
                "required": ["query"],
            ],
        ],
        [
            "name": "murmure_folders",
            "description": "Liste les dossiers Murmure (clients / affaires) et le nombre d'éléments rangés dans chacun.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
        [
            "name": "murmure_export",
            "description": "Écrit une dictée ou une réunion Murmure (synthèse + transcription) en Markdown dans un dossier "
                + "du Mac, typiquement le dossier de l'affaire ou d'un projet. Renvoie le chemin du fichier créé.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Identifiant, mots du titre, ou 'dernière'"],
                    "destination": ["type": "string", "description": "Chemin du dossier de destination"],
                ],
                "required": ["query", "destination"],
            ],
        ],
    ]

    static func call(_ name: String, _ args: [String: Any]) throws -> String {
        let snapshot = Snapshot.read()
        switch name {
        case "murmure_list": return list(args, snapshot)
        case "murmure_get": return get(args, snapshot)
        case "murmure_search": return search(args, snapshot)
        case "murmure_folders": return folders(snapshot)
        case "murmure_export": return try export(args, snapshot)
        default: throw Failure.unknownTool
        }
    }

    enum Failure: Error { case unknownTool, notFound, unreadableInput }

    // MARK: Présentation

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "dd/MM/yyyy HH:mm"
        return formatter
    }()

    static func status(_ recording: Recording) -> String {
        if let progress = recording.progress { return "en cours : \(progress)" }
        if !(recording.summaries ?? []).isEmpty { return "synthèse prête" }
        return recording.text.isEmpty ? "sans contenu" : "transcrite"
    }

    static func summaryLine(_ recording: Recording, _ snapshot: Snapshot) -> String {
        var parts = [String(recording.id.uuidString.prefix(8)), dateFormatter.string(from: recording.date),
                     recording.isMeeting ? "Réunion" : "Dictée", recording.title, status(recording),
                     formatDuration(recording.duration), "\(recording.wordCount) mots"]
        if let folder = snapshot.folderName(recording) { parts.append("dossier : \(folder)") }
        if recording.isArchived { parts.append("archivée") }
        return parts.joined(separator: " · ")
    }

    static func render(_ recording: Recording, part: String, _ snapshot: Snapshot) -> String {
        var lines = ["# \(recording.title)", "", summaryLine(recording, snapshot), ""]
        if ["all", "summary"].contains(part), let summary = recording.summaries?.last {
            lines += ["## \(summary.template) (\(dateFormatter.string(from: summary.date)))", "", summary.text, ""]
        }
        if ["all", "transcript", "text"].contains(part) {
            lines += ["## Transcription", "", part == "text" ? recording.text : recording.transcript, ""]
        }
        if part == "raw" { lines += ["## Brut", "", recording.rawText, ""] }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Recherche

    /// Par identifiant (complet ou début), sinon par mots du titre, sinon par texte.
    static func find(_ query: String, in recordings: [Recording]) -> Recording? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        if let hit = recordings.first(where: { $0.id.uuidString.lowercased().hasPrefix(q) }) { return hit }
        let words = q.split(separator: " ").map(String.init)
        if let hit = recordings.first(where: { r in words.allSatisfy { r.title.lowercased().contains($0) } }) { return hit }
        return recordings.first { $0.text.lowercased().contains(q) }
    }

    static func resolve(_ query: String?, _ snapshot: Snapshot) -> Recording? {
        let q = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["dernière", "derniere", "last", "latest", ""].contains(q) { return snapshot.recordings.first }
        if ["dernière réunion", "derniere reunion", "last meeting"].contains(q) { return snapshot.recordings.first { $0.isMeeting } }
        return find(q, in: snapshot.recordings)
    }

    // MARK: Les cinq outils

    static func list(_ args: [String: Any], _ snapshot: Snapshot) -> String {
        let kind = args["kind"] as? String ?? "all"
        let folder = (args["folder"] as? String ?? "").lowercased()
        let limit = args["limit"] as? Int ?? 20
        let archived = args["include_archived"] as? Bool ?? false
        var lines: [String] = []
        for recording in snapshot.recordings {
            if kind == "meeting", !recording.isMeeting { continue }
            if kind == "dictation", recording.isMeeting { continue }
            if !folder.isEmpty, !(snapshot.folderName(recording) ?? "").lowercased().contains(folder) { continue }
            if recording.isArchived, !archived { continue }
            lines.append(summaryLine(recording, snapshot))
            if lines.count >= limit { break }
        }
        return lines.isEmpty ? "Aucun enregistrement." : lines.joined(separator: "\n")
    }

    static func get(_ args: [String: Any], _ snapshot: Snapshot) -> String {
        guard let recording = resolve(args["query"] as? String, snapshot) else {
            return "Introuvable. Utilisez murmure_list pour obtenir un identifiant."
        }
        return render(recording, part: args["part"] as? String ?? "all", snapshot)
    }

    static func search(_ args: [String: Any], _ snapshot: Snapshot) -> String {
        let q = (args["query"] as? String ?? "").lowercased()
        let limit = args["limit"] as? Int ?? 10
        guard !q.isEmpty else { return "Aucun résultat." }
        var hits: [String] = []
        for recording in snapshot.recordings {
            let haystack = ([recording.title, recording.text, recording.transcript]
                            + (recording.summaries ?? []).map(\.text)).joined(separator: " ").lowercased()
            guard let range = haystack.range(of: q) else { continue }
            let start = haystack.index(range.lowerBound, offsetBy: -80, limitedBy: haystack.startIndex) ?? haystack.startIndex
            let end = haystack.index(range.lowerBound, offsetBy: 120, limitedBy: haystack.endIndex) ?? haystack.endIndex
            let excerpt = haystack[start..<end].replacingOccurrences(of: "\n", with: " ")
            hits.append(summaryLine(recording, snapshot) + "\n    … \(excerpt) …")
            if hits.count >= limit { break }
        }
        return hits.isEmpty ? "Aucun résultat." : hits.joined(separator: "\n")
    }

    static func folders(_ snapshot: Snapshot) -> String {
        var counts: [UUID?: Int] = [:]
        for recording in snapshot.recordings { counts[recording.folderID, default: 0] += 1 }
        var lines = snapshot.folders
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
            .map { "\($0.name) · \(counts[$0.id] ?? 0) élément(s)" }
        lines.append("(à ranger) · \(counts[nil] ?? 0) élément(s)")
        return lines.joined(separator: "\n")
    }

    static func export(_ args: [String: Any], _ snapshot: Snapshot) throws -> String {
        guard let recording = resolve(args["query"] as? String, snapshot) else { return "Introuvable." }
        guard let destination = args["destination"] as? String, !destination.isEmpty else { throw Failure.unreadableInput }
        let directory = URL(fileURLWithPath: NSString(string: destination).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(Exporter.fileName(recording))
        try Exporter.markdown(recording).data(using: .utf8)?.write(to: target, options: .atomic)
        return "Écrit : \(target.path)"
    }

    // MARK: - Boucle JSON-RPC

    /// Sert jusqu'à la fermeture de l'entrée standard, puis quitte.
    static func serve() -> Never {
        // La sortie standard est réservée au protocole : les `print` de l'application partent sur stderr.
        let out = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
        dup2(STDERR_FILENO, STDOUT_FILENO)

        func reply(_ id: Any, result: Any? = nil, error: (code: Int, message: String)? = nil) {
            var body: [String: Any] = ["jsonrpc": "2.0", "id": id]
            if let error { body["error"] = ["code": error.code, "message": error.message] } else { body["result"] = result ?? [:] }
            guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes]) else { return }
            out.write(data)
            out.write(Data("\n".utf8))
        }

        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let method = message["method"] as? String else { continue }
            let params = message["params"] as? [String: Any] ?? [:]
            // Les notifications (initialized, cancelled…) n'ont pas d'identifiant et n'attendent pas de réponse.
            guard let id = message["id"] else { continue }
            switch method {
            case "initialize":
                reply(id, result: ["protocolVersion": params["protocolVersion"] as? String ?? protocolVersion,
                                   "capabilities": ["tools": [:]],
                                   "serverInfo": ["name": "murmure", "version": version]])
            case "ping":
                reply(id, result: [:])
            case "tools/list":
                reply(id, result: ["tools": tools])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let args = params["arguments"] as? [String: Any] ?? [:]
                do {
                    let text = try call(name, args)
                    reply(id, result: ["content": [["type": "text", "text": text]], "isError": false])
                } catch Failure.unknownTool {
                    reply(id, error: (-32601, "outil inconnu : \(name)"))
                } catch {
                    reply(id, result: ["content": [["type": "text", "text": "Erreur : \(error)"]], "isError": true])
                }
            default:
                reply(id, error: (-32601, "méthode inconnue : \(method)"))
            }
        }
        exit(0)
    }
}
