import Foundation

/// Modèle de langage local : un serveur llama.cpp lancé en tâche de fond, accessible uniquement
/// depuis ce Mac (127.0.0.1). Le modèle reste chargé en mémoire tant que Murmure est ouvert.
final class LocalLLM {
    static let shared = LocalLLM()

    /// Fichier à télécharger quand il manque (`LocalLLMInstaller`) : adresse, taille exacte et empreinte SHA-256.
    struct Download: Hashable, Sendable {
        let url: URL
        let size: Int64
        let sha256: String

        init(url: String, size: Int64, sha256: String) {
            self.url = URL(string: url)!
            self.size = size
            self.sha256 = sha256
        }
    }

    struct Model: Identifiable, Hashable {
        let file: String
        let name: String
        let download: Download
        var id: String { file }
    }

    /// Quantification Q4_K_M de chaque modèle. Qwen3 doit rester la variante « Instruct-2507 » (sans réflexion) :
    /// la variante hybride consomme `max_tokens` en jetons de pensée et viderait titres et mises en forme.
    static let catalog = [
        Model(file: "qwen3-4b.gguf", name: "Qwen3 4B (recommandé)",
              download: Download(url: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
                                 size: 2_497_281_120, sha256: "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597")),
        Model(file: "ministral-3b.gguf", name: "Ministral 3 3B (Mistral AI, plus rapide)",
              download: Download(url: "https://huggingface.co/mistralai/Ministral-3-3B-Instruct-2512-GGUF/resolve/main/Ministral-3-3B-Instruct-2512-Q4_K_M.gguf",
                                 size: 2_147_023_008, sha256: "9ed150d4367e68df0ac8e1540f6ddc65b42d0ee26378329d1ecbca60f93fc5f8")),
        Model(file: "ministral-8b.gguf", name: "Ministral 3 8B (Mistral AI, plus fin, plus lent)",
              download: Download(url: "https://huggingface.co/mistralai/Ministral-3-8B-Instruct-2512-GGUF/resolve/main/Ministral-3-8B-Instruct-2512-Q4_K_M.gguf",
                                 size: 5_198_911_904, sha256: "33e7a72cf5e6e2cfc2f2847075acc013d68bba023e35310cef86b5cf8fdca761")),
    ]

    /// Port tiré au hasard à chaque démarrage : deux instances (app, tests) ne se gênent jamais.
    private var port = 8765
    /// Jeton exigé par le serveur : seul Murmure peut lui parler (et non toute page ou tout processus du Mac).
    private var apiKey = UUID().uuidString
    private var process: Process?
    private var loadedModel: String?
    private let lock = NSLock()

    static var llmDir: URL { Settings.supportDir.appendingPathComponent("LLM", isDirectory: true) }

    /// Modèles présents sur le disque.
    static var installedModels: [Model] {
        catalog.filter { FileManager.default.fileExists(atPath: llmDir.appendingPathComponent($0.file).path) }
    }

    static var serverBinary: URL? {
        let root = Settings.supportDir.appendingPathComponent("llama.cpp", isDirectory: true)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == "llama-server" { return url }
        }
        return nil
    }

    static var isInstalled: Bool { serverBinary != nil && !installedModels.isEmpty }

    var isRunning: Bool { process?.isRunning == true }

    /// Démarre le serveur avec le modèle demandé (ou le redémarre si le modèle change).
    func start(model file: String) async throws {
        let sameModel = lock.withLock { loadedModel == file && self.process?.isRunning == true }
        if sameModel { return }
        stop()
        // Un serveur resté orphelin (Murmure ou un essai en ligne de commande arrêté brutalement) garde plusieurs
        // gigaoctets : sur un Mac de 16 Go, quelques-uns suffisent à faire relire le modèle depuis le disque.
        Self.killOrphans()
        port = Int.random(in: 20_000...60_000)
        apiKey = UUID().uuidString

        guard let binary = Self.serverBinary else { throw LLMError.notInstalled }
        let modelURL = Self.llmDir.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: modelURL.path) else { throw LLMError.notInstalled }

        let process = Process()
        process.executableURL = binary
        process.currentDirectoryURL = binary.deletingLastPathComponent()
        process.arguments = [
            "-m", modelURL.path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "-ngl", "99",       // tout sur le GPU de la puce
            // Deux emplacements : la mise en forme et les autres tâches (titres, retravail) gardent
            // chacune leurs consignes en cache, la dictée suivante ne repaie pas leur lecture.
            // 8 192 jetons par emplacement pour résumer de longues réunions ; cache compressé (q8)
            // et Flash Attention pour tenir dans la mémoire d'un Mac de 16 Go.
            "-c", "16384",
            "-np", "2",
            "-fa", "on",
            "-ctk", "q8_0",
            "-ctv", "q8_0",
            // Décodage spéculatif par n-grammes (sans second modèle) : quand la réponse recopie des passages du
            // message (dictée corrigée, texte retouché), plusieurs jetons sont validés d'un coup. Mesuré ici :
            // correction d'un texte de 300 mots en 2 s au lieu de 9, sans ralentir les autres consignes.
            "--spec-type", "ngram-mod",
            "--no-webui",
        ]
        // La clé passe par l'environnement et non par un argument, qui serait lisible par tout processus (ps).
        process.environment = ProcessInfo.processInfo.environment.merging(["LLAMA_API_KEY": apiKey]) { $1 }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        lock.withLock {
            self.process = process
            loadedModel = file
        }

        // Attend que le modèle soit chargé (jusqu'à 2 minutes).
        for _ in 0..<240 {
            if await healthy() { return }
            guard process.isRunning else { throw LLMError.serverFailed }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw LLMError.serverFailed
    }

    /// Arrête les serveurs restés orphelins après un arrêt brutal de Murmure (ils occupent de la mémoire) :
    /// seulement ceux dont le parent a disparu (rattachés à launchd), pour ne pas tuer le serveur d'un banc
    /// d'essai lancé en ligne de commande par une autre session. Tout serveur installé par Murmure compte,
    /// quel que soit son dossier (`MURMURE_SUPPORT_DIR` d'un essai compris).
    static func killOrphans() {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        guard (try? ps.run()) != nil else { return }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        for line in output.split(separator: "\n") where line.contains("/llama.cpp/llama-b") && line.contains("llama-server") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = pid_t(fields[0]), fields[1] == "1" else { continue }
            kill(pid, SIGTERM)
        }
    }

    func stop() {
        lock.withLock {
            process?.terminate()
            process = nil
            loadedModel = nil
        }
    }

    private func healthy() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health"),
              let (_, response) = try? await URLSession.shared.data(from: url) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Envoie une consigne et un texte, renvoie la réponse du modèle. `timeout` : délai de la génération entière
    /// (60 s suffisent à une dictée ; une synthèse de réunion passe `Summarizer.longTimeout`), ou délai sans nouveau
    /// morceau reçu quand la réponse est diffusée. `onPartial` reçoit le texte déjà produit à chaque morceau, pour
    /// l'afficher au fil de la rédaction ; sans lui, la réponse n'arrive qu'à la fin.
    func complete(system: String, user: String, maxTokens: Int, timeout: TimeInterval = 60,
                  onPartial: ((String) -> Void)? = nil) async throws -> String {
        guard isRunning, let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions") else {
            throw LLMError.serverFailed
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout
        let body: [String: Any] = [
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "temperature": 0,
            "max_tokens": maxTokens,
            "cache_prompt": true,
            "stream": onPartial != nil,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        if let onPartial { return Self.tidy(try await stream(request, onPartial: onPartial)) }
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // Erreur du serveur (par exemple « request exceeds the available context size ») : on la remonte telle quelle.
        if let failure = json?["error"] as? [String: Any], let message = failure["message"] as? String {
            throw LLMError.server(message)
        }
        guard
            let json,
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else { throw LLMError.badResponse }
        return Self.tidy(content)
    }

    /// Réponse diffusée en flux d'événements (« data: {…} ») : chaque morceau s'ajoute au texte, transmis à `onPartial`.
    private func stream(_ request: URLRequest, onPartial: (String) -> Void) async throws -> String {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            let message = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
            throw LLMError.server(message ?? "erreur \(status)")
        }
        var text = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let failure = event["error"] as? [String: Any], let message = failure["message"] as? String {
                throw LLMError.server(message)
            }
            if let piece = ((event["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any])?["content"] as? String,
               !piece.isEmpty {
                text += piece
                onPartial(Self.tidy(text))
            }
        }
        guard !text.isEmpty else { throw LLMError.badResponse }
        return text
    }

    /// Les petits modèles ajoutent parfois du gras Markdown : on le retire.
    private static func tidy(_ content: String) -> String {
        content
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum LLMError: LocalizedError {
        case notInstalled, serverFailed, badResponse, server(String)
        var errorDescription: String? {
            switch self {
            case .notInstalled: return "modèle local non installé"
            case .serverFailed: return "le modèle local n'a pas démarré"
            case .badResponse: return "réponse illisible du modèle local"
            case .server(let message): return "le modèle local a refusé la demande (\(message))"
            }
        }
    }
}
