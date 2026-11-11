import AVFoundation
import Foundation

/// Transcription des réunions par un service en ligne (AssemblyAI, serveur européen), en option : Réglages ›
/// Transcription › Réunions. La dictée reste toujours transcrite sur ce Mac ; une réunion part en ligne seulement si le
/// réglage est choisi, la clé enregistrée, « Rester hors ligne » décoché, et la réunion ni marquée du cadenas
/// « Garder sur ce Mac » ni rangée dans un dossier « Jamais en ligne » (relu juste avant l'envoi, avant la création et
/// à chaque sondage). Toute erreur (réseau, clé, service) fait reprendre la transcription sur ce Mac.
///
/// Déroulé : la clé est essayée (rien ne part si elle est refusée) ; le son mixé (16 kHz mono) est codé en AAC dans un
/// fichier m4a temporaire, envoyé (le fichier local est aussitôt effacé), transcrit en français avec distinction des
/// voix et les termes du contexte (et du dictionnaire, si le réglage le permet). L'identifiant de la transcription est
/// noté dans `suppressions-en-attente.json` dès sa création ; elle est supprimée du service (son compris) dès qu'elle
/// est terminée, et une suppression qui n'a pas pu se faire (réseau, arrêt de l'app) est reprise au lancement suivant
/// et après chaque réunion. Les mots horodatés, chacun avec sa voix, donnent les tours de parole par la même fonction
/// que la transcription sur ce Mac (`Transcriber.buildTurns`), « Moi » compris.
enum OnlineTranscription {
    /// Nom du service, montré seulement dans la sous-page où l'utilisateur le choisit.
    static let serviceName = "AssemblyAI"

    // MARK: Choix

    /// Le réglage « en ligne » est choisi (que la clé soit là ou non).
    static var isChosen: Bool { Settings.meetingTranscription == "online" }

    /// Une réunion peut partir en ligne maintenant : réglage choisi, clé présente, pas « Rester hors ligne ». En ligne de
    /// commande (`--meeting`, `--import`, lancés aussi par des sessions d'essai), seulement sur demande expresse
    /// (`MURMURE_EN_LIGNE=1` ou un serveur d'essai `MURMURE_TRANSCRIPTION_URL`) : un essai ne doit pas envoyer de son.
    static var isUsable: Bool {
        guard isChosen, hasKey, !Settings.stayOffline else { return false }
        let commandLine = CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--") }
        let env = ProcessInfo.processInfo.environment
        return !commandLine || env["MURMURE_EN_LIGNE"] == "1" || env["MURMURE_TRANSCRIPTION_URL"] != nil
    }

    // MARK: Clé

    /// Ancien emplacement dans le trousseau, repris une fois par `Coffre`.
    private static let ancien = Coffre.AncienEmplacement(service: "Murmure · Transcription", account: "clé API")

    /// Clé : variable d'environnement `MURMURE_TRANSCRIPTION_KEY` (essais en ligne de commande), sinon le coffre de Murmure.
    static var key: String? {
        if let env = ProcessInfo.processInfo.environment["MURMURE_TRANSCRIPTION_KEY"], !env.isEmpty { return env }
        return Coffre.get("transcription", ancien: ancien)
    }

    static var hasKey: Bool { !(key ?? "").isEmpty }

    /// Enregistre la clé (ou la retire si elle est vide).
    static func setKey(_ value: String) { Coffre.set("transcription", value) }

    /// « 1a2b…9z8y » : de quoi reconnaître la clé sans la montrer.
    static var maskedKey: String? {
        guard let key, key.count > 10 else { return key.map { _ in "••••" } }
        return String(key.prefix(4)) + "…" + String(key.suffix(4))
    }

    // MARK: Service

    /// Serveur européen ; `MURMURE_TRANSCRIPTION_URL` le remplace par un serveur d'essai (tools/faux-transcription.py).
    static var baseURL: URL {
        URL(string: ProcessInfo.processInfo.environment["MURMURE_TRANSCRIPTION_URL"] ?? "https://api.eu.assemblyai.com")!
    }

    /// Modèle demandé ; `MURMURE_TRANSCRIPTION_MODEL` permet d'en essayer un autre.
    static var model: String {
        ProcessInfo.processInfo.environment["MURMURE_TRANSCRIPTION_MODEL"] ?? "universal-3-5-pro"
    }

    indirect enum Failure: LocalizedError {
        case noKey, badKey, noCredit, busy, refused(Int), server, timeout, empty, keptLocal
        /// La création a échoué après l'envoi : le son reste chez le service jusqu'à sa purge automatique (24 à 48 h).
        case afterUpload(Failure)

        var errorDescription: String? {
            switch self {
            case .noKey: return "aucune clé enregistrée"
            case .badKey: return "clé refusée par le service"
            case .noCredit: return "solde du compte épuisé"
            case .busy: return "service saturé, réessayez plus tard"
            case .refused(let code): return "demande refusée par le service (\(code))"
            case .server: return "erreur du service"
            case .timeout: return "le service n'a pas répondu à temps"
            case .empty: return "le service n'a rendu aucune parole"
            case .keptLocal: return "réunion gardée sur ce Mac pendant l'envoi"
            case .afterUpload(let cause):
                return (cause.errorDescription ?? "erreur") + " ; le son envoyé reste chez le service jusqu'à sa purge automatique (48 h au plus)"
            }
        }
    }

    /// Vérifie la clé par une demande minuscule (liste d'une transcription) ; renvoie un message à afficher.
    static func verify() async -> String {
        guard let key, !key.isEmpty else { return "Aucune clé" }
        do {
            try await probe(key: key)
            return "Clé valide"
        } catch Failure.badKey {
            return "Clé refusée"
        } catch let failure as Failure {
            return failure.errorDescription ?? "Réponse inattendue"
        } catch {
            return "Service injoignable"
        }
    }

    private static func probe(key: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("v2/transcript").appending(queryItems: [URLQueryItem(name: "limit", value: "1")]))
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        _ = try await send(request)
    }

    // MARK: Transcription

    /// Transcrit une réunion : tours de parole et « Moi ». `context` : termes du contexte (titre, invités) ;
    /// `recording` : la fiche, notée avec l'identifiant à supprimer ; `stillAllowed` : relu avant l'envoi, avant la
    /// création et à chaque sondage (cadenas, dossier « Jamais en ligne », « Rester hors ligne » choisis entre-temps).
    /// `local` : voix distinguées sur ce Mac, dont les empreintes sont prêtées aux voix du service qu'elles recouvrent
    /// (le service n'en donne pas), pour reconnaître les interlocuteurs d'une réunion à l'autre.
    static func turns(_ audio: [Float], micShare: ((Int, Int) -> Float)?, context: [String], recording: UUID? = nil,
                      local: Transcriber.Voices? = nil, stillAllowed: @escaping @Sendable () async -> Bool = { true },
                      progress: Transcriber.Progress?) async throws -> Transcriber.SpeakerTurns {
        guard let key, !key.isEmpty else { throw Failure.noKey }
        let debug = ProcessInfo.processInfo.environment["MURMURE_DEBUG"] != nil
        let started = Date()
        let duration = Double(audio.count) / 16_000

        // Une clé refusée ou un service injoignable se voient avant que le son parte.
        try await probe(key: key)
        progress?("Envoi du son…")
        let file = try encode(audio)
        let uploadURL: String
        do {
            defer { try? FileManager.default.removeItem(at: file) }
            guard await stillAllowed() else { throw Failure.keptLocal }
            uploadURL = try await upload(file, key: key)
        }

        let sent = sentTerms(context: context)
        let id: String
        do {
            guard await stillAllowed() else { throw Failure.keptLocal }
            id = try await create(audioURL: uploadURL, key: key, terms: sent.terms, spelling: sent.spelling)
        } catch let failure as Failure {
            throw Failure.afterUpload(failure)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.afterUpload(.server)
        }
        PendingDeletions.add(id, recording: recording)

        let result: Result
        do {
            result = try await wait(for: id, key: key, duration: duration, stillAllowed: stillAllowed, progress: progress)
        } catch {
            // Travail peut-être encore en cours : il sera supprimé dès qu'il sera terminé (balayage différé).
            Task.detached { await PendingDeletions.sweep() }
            throw error
        }
        // Terminé (ou en erreur) : suppression tout de suite, attendue ; à défaut, reprise au balayage suivant.
        if await delete(id, key: key) { PendingDeletions.remove(id) }

        let words = (result.words ?? []).filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        if debug || result.speech_model_used.map({ !$0.hasPrefix(model) }) == true {
            print(String(format: "[en ligne] %.0f s d'audio (%@ côté service) transcrites en %.1f s, %d mots, modèle %@", duration,
                         result.audio_duration.map { String(format: "%.0f s", $0) } ?? "?", Date().timeIntervalSince(started),
                         words.count, result.speech_model_used ?? "?"))
        }
        if let served = result.audio_duration, abs(served - duration) > 5 {
            print(String(format: "[en ligne] durée reçue par le service (%.0f s) différente de la réunion (%.0f s)", served, duration))
        }
        guard !words.isEmpty else { throw Failure.empty }

        // Mots horodatés et leur voix ; plages de parole par voix (mots consécutifs d'une même voix, pauses < 1 s).
        // Un mot sans voix (rare) prend celle du mot précédent.
        var attributed: [(Transcriber.TimedWord, String)] = []
        var spans: [Transcriber.VoiceSpan] = []
        for word in words {
            let voice = word.speaker ?? attributed.last?.1 ?? "A"
            let start = Float(word.start) / 1000, end = Float(max(word.end, word.start)) / 1000
            attributed.append((Transcriber.TimedWord(text: " " + word.text, start: start, end: end), voice))
            if let last = spans.last, last.voice == voice, start - last.end < 1 {
                spans[spans.count - 1].end = max(last.end, end)
            } else {
                spans.append(Transcriber.VoiceSpan(voice: voice, start: start, end: end))
            }
        }
        return Transcriber.buildTurns(attributed, spans: spans, sampleCount: audio.count, micShare: micShare,
                                      terms: Transcriber.correctionTerms(context: context),
                                      prints: local.map { Voiceprint.borrow(from: $0, for: spans) } ?? [:])
    }

    /// Ce qui accompagne le son : les termes du contexte, puis, si le réglage le permet, ceux du dictionnaire et ses
    /// corrections d'un mot.
    static func sentTerms(context: [String]) -> (terms: [String], spelling: [[String: Any]]) {
        guard Settings.onlineSendsDictionary else { return (keyterms(context), []) }
        return (keyterms(Transcriber.correctionTerms(context: context)), customSpelling())
    }

    /// Code le son en AAC (m4a, 16 kHz mono, 32 kbit/s : environ 15 Mo par heure) dans un fichier temporaire, effacé
    /// en cas d'erreur. Le fichier est refermé (finalisé) avant d'être rendu.
    static func encode(_ audio: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("murmure-\(UUID().uuidString).m4a")
        do {
            try write(audio, to: url)
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private static func write(_ audio: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000,
        ]
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        defer { file.close() }
        // Par tranches d'une minute : pas de second tableau de la taille de la réunion.
        let chunk = 16_000 * 60
        var start = 0
        while start < audio.count {
            let count = min(chunk, audio.count - start)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { break }
            buffer.frameLength = AVAudioFrameCount(count)
            audio.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress! + start, count: count)
            }
            try file.write(from: buffer)
            start += count
        }
    }

    /// Fichiers m4a temporaires laissés par un arrêt brutal pendant l'envoi : effacés au lancement.
    static func purgeTemporaryFiles() {
        let dir = FileManager.default.temporaryDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        where name.hasPrefix("murmure-") && name.hasSuffix(".m4a") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    // MARK: Appels

    /// Une requête, avec trois nouvelles tentatives sur une erreur passagère (réseau, 500, 503, 504 : après 1, 3 puis
    /// 9 s ; 429 : après le délai `Retry-After`). Les erreurs du service sont traduites ; le message d'origine, en
    /// anglais, ne va qu'au journal.
    @discardableResult
    private static func send(_ request: URLRequest, file: URL? = nil) async throws -> Data {
        var attempt = 0
        while true {
            do {
                let (data, response) = if let file {
                    try await URLSession.shared.upload(for: request, fromFile: file)
                } else {
                    try await URLSession.shared.data(for: request)
                }
                let http = response as? HTTPURLResponse
                let code = http?.statusCode ?? 0
                if (200..<300).contains(code) { return data }
                let message = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String)
                    ?? String(data: data.prefix(300), encoding: .utf8) ?? ""
                print("[en ligne] \(request.httpMethod ?? "GET") \(request.url?.path ?? "") : \(code) \(message)")
                if message.localizedCaseInsensitiveContains("balance") { throw Failure.noCredit }
                let transient = [429, 500, 502, 503, 504].contains(code)
                guard transient, attempt < 3 else {
                    switch code {
                    case 401: throw Failure.badKey
                    case 429, 503: throw Failure.busy
                    case 400..<500: throw Failure.refused(code)
                    default: throw Failure.server
                    }
                }
                let wait = code == 429 ? (http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 5) : pow(3, Double(attempt))
                try await Task.sleep(for: .seconds(min(wait, 60)))
            } catch let error as URLError where attempt < 3 && error.code != .cancelled {
                print("[en ligne] \(request.url?.path ?? "") : \(error.localizedDescription), nouvel essai")
                try await Task.sleep(for: .seconds(pow(3, Double(attempt))))
            }
            attempt += 1
        }
    }

    private static func upload(_ file: URL, key: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("v2/upload"))
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        // 2 h de réunion font environ 30 Mo : 15 min laissent passer une connexion lente.
        request.timeoutInterval = 900
        let data = try await send(request, file: file)
        guard let url = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["upload_url"] as? String else {
            throw Failure.server
        }
        return url
    }

    /// Mots d'un terme (espaces de toute sorte).
    private static func words(_ text: String) -> [Substring] { text.split(whereSeparator: { $0.isWhitespace }) }

    /// Termes donnés au service (`keyterms_prompt`) : expressions de 6 mots au plus, 1 000 mots en tout (chaque mot
    /// d'une expression compte), les premières (contexte de la réunion) d'abord ; espaces normalisées.
    static func keyterms(_ terms: [String]) -> [String] {
        var kept: [String] = []
        var total = 0
        for term in terms {
            let parts = words(term)
            guard !parts.isEmpty, parts.count <= 6, words(term).joined(separator: " ").count <= 80, total + parts.count <= 1_000 else { continue }
            let normalized = parts.joined(separator: " ")
            guard !kept.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) else { continue }
            kept.append(normalized)
            total += parts.count
        }
        return kept
    }

    /// Corrections du dictionnaire données au service (`custom_spelling`) : graphie corrigée d'un seul mot, non vide ;
    /// graphie entendue de cinq mots au plus ; une graphie entendue qui mène à deux corrections différentes est écartée.
    /// Les autres corrections restent appliquées par Murmure après coup.
    static func customSpelling() -> [[String: Any]] {
        var targets: [String: Set<String>] = [:]
        for (from, to) in Settings.replacements() {
            let target = to.trimmingCharacters(in: .whitespacesAndNewlines)
            let heard = words(from).joined(separator: " ").lowercased()
            guard !target.isEmpty, words(target).count == 1, !heard.isEmpty, words(heard).count <= 5 else { continue }
            targets[heard, default: []].insert(target)
        }
        var byTarget: [String: [String]] = [:]
        for (heard, set) in targets where set.count == 1 { byTarget[set.first!, default: []].append(heard) }
        return byTarget.sorted { $0.key < $1.key }.map { ["from": $0.value.sorted(), "to": $0.key] }
    }

    private static func create(audioURL: String, key: String, terms: [String], spelling: [[String: Any]]) async throws -> String {
        var body: [String: Any] = [
            "audio_url": audioURL,
            "speech_models": [model],
            "language_code": "fr",
            "punctuate": true,
            "format_text": true,
            "speaker_labels": true,
            // Une seule voix possible (monologue, dictaphone) ; au plus huit : au-delà, le service découpe trop.
            "speaker_options": ["min_speakers_expected": 1, "max_speakers_expected": 8],
            // Ni [rires] ni [musique] dans le texte.
            "remove_audio_tags": "all",
        ]
        if !terms.isEmpty { body["keyterms_prompt"] = terms }
        if !spelling.isEmpty { body["custom_spelling"] = spelling }
        var request = URLRequest(url: baseURL.appendingPathComponent("v2/transcript"))
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60
        let data = try await send(request)
        guard let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String else {
            throw Failure.server
        }
        return id
    }

    struct Word: Decodable {
        let text: String
        let start: Int
        let end: Int
        let speaker: String?
    }

    struct Result: Decodable {
        let status: String
        let error: String?
        let words: [Word]?
        let speech_model_used: String?
        let audio_duration: Double?
    }

    /// Attend la fin de la transcription : sondage toutes les 3 s la première minute, puis toutes les 6 s (le service
    /// en accepte 60 par minute), au plus 15 min plus la moitié de la durée de la réunion, et 60 min en tout.
    private static func wait(for id: String, key: String, duration: Double, stillAllowed: @Sendable () async -> Bool,
                             progress: Transcriber.Progress?) async throws -> Result {
        let deadline = Date().addingTimeInterval(min(3_600, 900 + duration / 2))
        var request = URLRequest(url: baseURL.appendingPathComponent("v2/transcript/\(id)"))
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let started = Date()
        while Date() < deadline {
            try Task.checkCancellation()
            guard await stillAllowed() else { throw Failure.keptLocal }
            let result = try JSONDecoder().decode(Result.self, from: try await send(request))
            switch result.status {
            case "completed": return result
            case "error":
                print("[en ligne] transcription \(id) en erreur : \(result.error ?? "?")")
                _ = await delete(id, key: key) ? PendingDeletions.remove(id) : ()
                throw Failure.server
            default:
                let elapsed = Date().timeIntervalSince(started)
                progress?("Transcription en ligne · \(Int(elapsed)) s")
                try await Task.sleep(for: .seconds(elapsed < 60 ? 3 : 6))
            }
        }
        throw Failure.timeout
    }

    /// Supprime une transcription terminée du service (avec le son envoyé). Vrai si elle n'y est plus.
    @discardableResult
    static func delete(_ id: String, key: String) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("v2/transcript/\(id)"))
        request.httpMethod = "DELETE"
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        do {
            try await send(request)
            return true
        } catch Failure.refused(let code) where code == 404 || code == 400 {
            // Déjà absente (supprimée, ou purgée par le service).
            return true
        } catch {
            print("[en ligne] suppression de la transcription \(id) remise à plus tard : \(error.localizedDescription)")
            return false
        }
    }

    /// État d'une transcription chez le service : "completed", "error", "queued", "processing", ou nil si absente.
    static func status(_ id: String, key: String) async -> String?? {
        var request = URLRequest(url: baseURL.appendingPathComponent("v2/transcript/\(id)"))
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        do {
            let data = try await send(request)
            return .some((try? JSONDecoder().decode(Result.self, from: data))?.status)
        } catch Failure.refused(let code) where code == 404 || code == 400 {
            return .some(nil)
        } catch {
            return nil
        }
    }
}

/// Transcriptions créées chez le service et pas encore supprimées : `suppressions-en-attente.json` dans le dossier de
/// Murmure. Un identifiant y est noté dès la création et retiré quand le service ne l'a plus. Le balayage (au
/// lancement, après chaque réunion) supprime celles qui sont terminées ; celles encore en cours attendent le suivant.
/// Au-delà de 30 jours, le service les a de toute façon purgées : elles sont oubliées.
enum PendingDeletions {
    struct Entry: Codable {
        let id: String
        let recording: UUID?
        let date: Date
    }

    private static let lock = NSLock()
    private static var url: URL { Settings.supportDir.appendingPathComponent("suppressions-en-attente.json") }

    private static func read() -> [Entry] {
        (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))) ?? []
    }

    private static func write(_ entries: [Entry]) {
        if entries.isEmpty { try? FileManager.default.removeItem(at: url); return }
        try? JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }

    static func add(_ id: String, recording: UUID?) {
        lock.withLock { write(read() + [Entry(id: id, recording: recording, date: Date())]) }
    }

    static func remove(_ id: String) {
        lock.withLock { write(read().filter { $0.id != id }) }
    }

    /// Une transcription de cette fiche attend encore sa suppression chez le service.
    static func isPending(recording: UUID) -> Bool {
        lock.withLock { read().contains { $0.recording == recording } }
    }

    static var isEmpty: Bool { lock.withLock { read().isEmpty } }

    /// Supprime ce qui peut l'être ; garde ce qui est encore en cours ou injoignable.
    static func sweep() async {
        guard let key = OnlineTranscription.key, !key.isEmpty else { return }
        let entries = lock.withLock { read() }
        for entry in entries {
            if Date().timeIntervalSince(entry.date) > 30 * 86_400 { remove(entry.id); continue }
            switch await OnlineTranscription.status(entry.id, key: key) {
            case .some(.none): remove(entry.id)                  // absente du service
            case .some(.some("completed")), .some(.some("error")):
                if await OnlineTranscription.delete(entry.id, key: key) { remove(entry.id) }
            default: continue                                    // en cours, ou service injoignable
            }
        }
    }
}
