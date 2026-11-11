import Foundation

/// Moteur en ligne : l'API Claude d'Anthropic. Seul du texte part (la dictée transcrite, le texte autour du
/// curseur, les transcriptions de réunions), jamais le son. La clé est gardée sur ce Mac (`Coffre`).
final class ClaudeAPI {
    static let shared = ClaudeAPI()

    struct Model: Identifiable, Hashable {
        let id: String
        let name: String
        let note: String
    }

    static let catalog = [
        Model(id: "claude-opus-5-5", name: "Claude Opus 5.5", note: "le plus fin"),
        Model(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", note: "équilibré, plus rapide"),
        Model(id: "claude-haiku-5-5", name: "Claude Haiku 5.5", note: "le plus rapide"),
    ]
    static let defaultModel = "claude-opus-5-5"
    /// Modèle de la relecture des dictées, où la vitesse compte : Sonnet 5.5 sans réflexion. Essai du 04/11/2026,
    /// huit dictées types : 1,6 s en moyenne contre 3,0 à 3,6 s pour Opus 5.5, textes aussi justes ; Haiku 5.5
    /// (1,1 s) laissait des « pardon » et des autocorrections, et coupait une dictée quand il réfléchissait.
    static let defaultDictationModel = "claude-sonnet-5-5"

    static func name(of model: String) -> String { catalog.first { $0.id == model }?.name ?? model }

    /// Profondeur de réflexion demandée : basse pour une relecture de dictée (vitesse), haute pour un compte rendu.
    enum Effort: String { case low, medium, high }

    // MARK: - Clé

    /// Ancien emplacement dans le trousseau, repris une fois par `Coffre`.
    private static let ancien = Coffre.AncienEmplacement(service: "Murmure · Claude", account: "clé API")

    /// Clé : variable d'environnement `MURMURE_CLAUDE_KEY` (essais en ligne de commande), sinon le coffre de Murmure.
    static var key: String? {
        if let env = ProcessInfo.processInfo.environment["MURMURE_CLAUDE_KEY"], !env.isEmpty { return env }
        return Coffre.get("claude", ancien: ancien)
    }

    static var hasKey: Bool { !(key ?? "").isEmpty }

    /// Enregistre la clé (ou la retire si elle est vide).
    static func setKey(_ value: String) { Coffre.set("claude", value) }

    /// « sk-ant-…1234 » : de quoi reconnaître la clé sans la montrer.
    static var maskedKey: String? {
        guard let key, key.count > 12 else { return key.map { _ in "••••" } }
        return String(key.prefix(7)) + "…" + String(key.suffix(4))
    }

    // MARK: - Appels

    /// Adresse de l'API ; `MURMURE_CLAUDE_URL` permet de la remplacer par un serveur d'essai local.
    private static var baseURL: URL {
        URL(string: ProcessInfo.processInfo.environment["MURMURE_CLAUDE_URL"] ?? "https://api.anthropic.com")!
    }

    /// Jetons consommés depuis le lancement (entrée, sortie), pour information dans les réglages.
    private(set) var tokensIn = 0
    private(set) var tokensOut = 0
    /// Détail pour chiffrer le coût (banc `--bench-relecture`) : demandes envoyées, jetons lus en cache, mis en cache.
    private(set) var requests = 0
    private(set) var tokensCacheRead = 0
    private(set) var tokensCacheWrite = 0

    /// Envoie des consignes et un message, renvoie le texte de la réponse. La réponse arrive en flux : un long
    /// compte rendu ne risque pas de dépasser le délai, qui ne court qu'entre deux morceaux reçus. `onPartial`
    /// reçoit le texte déjà reçu à chaque morceau, pour l'afficher au fil de la rédaction.
    /// `quick` : réponse sans réflexion préalable quand le modèle le permet (Haiku : réflexion désactivée ; Sonnet :
    /// réflexion seulement entre deux outils, donc jamais ici). Opus réfléchit toujours. Pour la relecture des dictées,
    /// où chaque dixième de seconde retarde le collage.
    func complete(system: String, user: String, maxTokens: Int, timeout: TimeInterval = 60,
                  effort: Effort = .medium, model: String? = nil, quick: Bool = false,
                  onPartial: ((String) -> Void)? = nil) async throws -> String {
        guard let key = Self.key, !key.isEmpty else { throw ClaudeError.noKey }
        let model = model ?? Settings.claudeWritingModel
        do {
            return try await request(key: key, model: model, system: system, user: user, maxTokens: maxTokens,
                                     timeout: timeout, effort: effort, fallbacks: Self.supportsFallbacks(model), quick: quick,
                                     onPartial: onPartial)
        } catch ClaudeError.server(let message) where Self.supportsFallbacks(model) && message.lowercased().contains("fallback") {
            // Si le repli serveur en cas de refus n'est pas accepté, on refait la demande sans.
            return try await request(key: key, model: model, system: system, user: user, maxTokens: maxTokens,
                                     timeout: timeout, effort: effort, fallbacks: false, quick: quick, onPartial: onPartial)
        }
    }

    /// Réglage de la réflexion pour une réponse rapide, selon le modèle (nil : laisser la valeur par défaut).
    static func quickThinking(_ model: String) -> [String: Any]? {
        if model.hasPrefix("claude-haiku") { return ["type": "disabled"] }
        if model.hasPrefix("claude-sonnet-5-5") { return ["type": "between_tools"] }
        return nil
    }

    /// Vérifie la clé par une demande minuscule ; renvoie le nom du modèle qui a répondu.
    func verify() async throws -> String {
        guard let key = Self.key, !key.isEmpty else { throw ClaudeError.noKey }
        let model = Settings.claudeDictationModel
        _ = try await request(key: key, model: model, system: "Réponds seulement « OK ».", user: "Test", maxTokens: 16,
                              timeout: 30, effort: .low, fallbacks: false)
        return Self.name(of: model)
    }

    /// Le repli serveur en cas de refus (classifieurs de sécurité) existe pour Opus et Sonnet, pas pour Haiku.
    private static func supportsFallbacks(_ model: String) -> Bool {
        model.hasPrefix("claude-opus") || model.hasPrefix("claude-sonnet")
    }

    private func request(key: String, model: String, system: String, user: String, maxTokens: Int,
                         timeout: TimeInterval, effort: Effort, fallbacks: Bool, quick: Bool = false,
                         onPartial: ((String) -> Void)? = nil) async throws -> String {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        if fallbacks { request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta") }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            // Les consignes, stables, sont mises en cache côté serveur : seule la dictée est relue à chaque fois.
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": user]],
            "output_config": ["effort": effort.rawValue],
        ]
        if fallbacks { body["fallbacks"] = "default" }
        // Sans réflexion : accepté jusqu'à l'effort « high », le plus haut que Murmure demande.
        if quick, let thinking = Self.quickThinking(model) { body["thinking"] = thinking }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        requests += 1

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError() // demande abandonnée (relecture anticipée devenue inutile)
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                 .internationalRoamingOff, .dataNotAllowed:
                throw ClaudeError.offline
            case .timedOut: throw ClaudeError.timeout
            default: throw ClaudeError.network(error.localizedDescription)
            }
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            let message = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
            switch status {
            case 401, 403: throw ClaudeError.badKey
            case 429: throw ClaudeError.rateLimited
            case 529, 503: throw ClaudeError.overloaded
            default: throw ClaudeError.server(message ?? "erreur \(status)")
            }
        }

        // Flux d'événements : seuls les morceaux de texte nous intéressent, et la raison d'arrêt.
        var text = ""
        var stopReason: String?
        do {
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let data = payload.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = event["type"] as? String else { continue }
                switch type {
                case "content_block_delta":
                    if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                       let piece = delta["text"] as? String {
                        text += piece
                        onPartial?(text)
                    }
                case "message_start":
                    if let usage = ((event["message"] as? [String: Any])?["usage"] as? [String: Any]) {
                        tokensIn += (usage["input_tokens"] as? Int ?? 0) + (usage["cache_read_input_tokens"] as? Int ?? 0)
                            + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                        tokensCacheRead += usage["cache_read_input_tokens"] as? Int ?? 0
                        tokensCacheWrite += usage["cache_creation_input_tokens"] as? Int ?? 0
                        Self.debug("entrée : \(usage)")
                    }
                case "message_delta":
                    stopReason = (event["delta"] as? [String: Any])?["stop_reason"] as? String
                    if let usage = event["usage"] as? [String: Any] { tokensOut += usage["output_tokens"] as? Int ?? 0 }
                case "error":
                    let message = (event["error"] as? [String: Any])?["message"] as? String ?? "erreur de flux"
                    if message.lowercased().contains("overloaded") { throw ClaudeError.overloaded }
                    throw ClaudeError.server(message)
                default:
                    break
                }
            }
        } catch let error as URLError where error.code == .timedOut {
            throw ClaudeError.timeout
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
        if stopReason == "refusal" { throw ClaudeError.refused }
        guard !text.isEmpty else { throw ClaudeError.badResponse }
        Self.debug("\(model) · arrêt : \(stopReason ?? "?") · \(text.count) caractères")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func debug(_ message: String) {
        if ProcessInfo.processInfo.environment["MURMURE_DEBUG"] != nil { print("[claude] \(message)") }
    }

    enum ClaudeError: LocalizedError {
        case noKey, badKey, rateLimited, overloaded, offline, timeout, refused, badResponse, network(String), server(String)

        var errorDescription: String? {
            switch self {
            case .noKey: return "aucune clé Claude : ajoutez-la dans Réglages › Transcription"
            case .badKey: return "clé Claude refusée : vérifiez-la dans Réglages › Transcription"
            case .rateLimited: return "trop de demandes à Claude en même temps, réessayez dans un instant"
            case .overloaded: return "Claude est saturé, réessayez dans un instant"
            case .offline: return "pas de connexion"
            case .timeout: return "Claude n'a pas répondu à temps"
            case .refused: return "Claude a refusé cette demande"
            case .badResponse: return "réponse vide de Claude"
            case .network(let message): return "connexion à Claude impossible (\(message))"
            case .server(let message): return "Claude a renvoyé une erreur (\(message))"
            }
        }

        /// Erreurs qui justifient de se rabattre sur le modèle local, quand il est prêt.
        var allowsFallback: Bool {
            switch self {
            case .offline, .timeout, .overloaded, .rateLimited, .network: return true
            default: return false
            }
        }
    }
}
