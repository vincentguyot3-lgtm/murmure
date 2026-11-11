import CryptoKit
import Foundation

/// Installation du moteur de rédaction locale (llama.cpp) et des modèles de langage, sans rien faire à la main :
/// au premier lancement, ou quand on choisit un modèle absent, Murmure télécharge ce qui manque depuis sa source
/// publique (GitHub pour le moteur, Hugging Face pour les modèles), vérifie son empreinte SHA-256, puis le range
/// dans Application Support. Un téléchargement interrompu (réseau coupé, Mac en veille, Murmure quitté) reprend
/// là où il s'était arrêté : le fichier partiel est gardé sous `….part` et complété par une requête « Range ».
@MainActor
final class LocalLLMInstaller: ObservableObject {
    static let shared = LocalLLMInstaller()

    /// Version du moteur, fixée : celle sur laquelle les réglages du serveur (ngram-mod, cache q8) ont été mesurés.
    nonisolated static let engineBuild = "b11701"

    nonisolated static let engine: LocalLLM.Download = {
        #if arch(arm64)
        LocalLLM.Download(url: "https://github.com/ggml-org/llama.cpp/releases/download/b11701/llama-b11701-bin-macos-arm64.tar.gz",
                          size: 12_249_449, sha256: "e4219b1442dcf0b68e860ea6f06d417163326391e8514b04019080f2444ff47c")
        #else
        LocalLLM.Download(url: "https://github.com/ggml-org/llama.cpp/releases/download/b11701/llama-b11701-bin-macos-x64.tar.gz",
                          size: 11_736_156, sha256: "88127ab93b9899631b86e9d5c36c0fd299642953878daec633b7370ceee15901")
        #endif
    }()

    private static let engineKey = "llama.cpp"

    /// Avancement de chaque téléchargement en cours (0 à 1, 1 pendant la vérification), par fichier.
    @Published private(set) var progress: [String: Double] = [:]
    /// Dernier échec par fichier (modèle ou moteur), effacé au prochain essai.
    @Published private(set) var failures: [String: String] = [:]
    private var running: [String: Task<Void, Error>] = [:]

    /// Installe le moteur et le modèle demandé s'il leur manque quelque chose ; ne fait rien sinon.
    func install(model file: String) async throws {
        if LocalLLM.serverBinary == nil {
            try await fetch(Self.engineKey) { try await Self.installEngine(report: $0) }
        }
        guard let model = LocalLLM.catalog.first(where: { $0.file == file }) else { throw LocalLLM.LLMError.notInstalled }
        if !FileManager.default.fileExists(atPath: LocalLLM.llmDir.appendingPathComponent(file).path) {
            try await fetch(file) { try await Self.installModel(model, report: $0) }
        }
    }

    func isDownloading(_ file: String) -> Bool { progress[file] != nil }

    /// « 34 % de 2,5 Go » pour l'ensemble des téléchargements en cours, « vérification… » une fois tout reçu,
    /// nil si rien ne se télécharge.
    var summary: String? {
        guard !progress.isEmpty else { return nil }
        var total: Int64 = 0
        var done = 0.0
        for (key, fraction) in progress {
            let size = key == Self.engineKey ? Self.engine.size : LocalLLM.catalog.first { $0.file == key }?.download.size ?? 0
            total += size
            done += Double(size) * fraction
        }
        guard done < Double(total) else { return "vérification…" }
        let percent = Int((done / Double(max(total, 1)) * 100).rounded(.down))
        return "\(percent) % de \(Self.size(total))"
    }

    /// « 2,5 Go », « 12 Mo » : `ByteCountFormatter` suit la langue du paquet (anglais, faute de traduction) et écrirait « GB ».
    nonisolated static func size(_ bytes: Int64) -> String {
        let value = Double(bytes)
        let (amount, unit) = value >= 1e9 ? (value / 1e9, "Go") : (value / 1e6, "Mo")
        let digits = amount < 10 ? 1 : 0
        return amount.formatted(.number.precision(.fractionLength(digits)).locale(Locale(identifier: "fr_FR"))) + " " + unit
    }

    /// Lance un téléchargement, ou rejoint celui du même fichier déjà en cours.
    private func fetch(_ key: String, _ work: @escaping @Sendable (@escaping @Sendable (Double) -> Void) async throws -> Void) async throws {
        if let task = running[key] { return try await task.value }
        failures[key] = nil
        progress[key] = 0
        let task = Task.detached {
            try await work { fraction in
                Task { @MainActor in
                    // Un dernier avancement peut arriver après la fin : il ne doit pas faire réapparaître la ligne.
                    if LocalLLMInstaller.shared.running[key] != nil { LocalLLMInstaller.shared.progress[key] = fraction }
                }
            }
        }
        running[key] = task
        defer {
            running[key] = nil
            progress[key] = nil
        }
        do {
            try await task.value
        } catch {
            let failure = Self.describe(error)
            failures[key] = failure.localizedDescription
            throw failure
        }
    }

    // MARK: - Installation

    nonisolated private static func installModel(_ model: LocalLLM.Model, report: @escaping @Sendable (Double) -> Void) async throws {
        let destination = LocalLLM.llmDir.appendingPathComponent(model.file)
        let part = destination.appendingPathExtension("part")
        try await download(model.download, to: part, report: report)
        try FileManager.default.moveItem(at: part, to: destination)
    }

    /// L'archive du moteur contient un dossier `llama-bNNNN/` : il est extrait à part, puis rangé dans `llama.cpp/`.
    nonisolated private static func installEngine(report: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        let root = Settings.supportDir.appendingPathComponent("llama.cpp", isDirectory: true)
        let archive = root.appendingPathComponent("llama-\(engineBuild).tar.gz.part")
        try await download(engine, to: archive, report: report)

        // Dossier temporaire sur le même volume (pour un déplacement sans copie), hors de `llama.cpp/` : un arrêt
        // pendant l'extraction n'y laisse pas un moteur à moitié écrit que `LocalLLM.serverBinary` trouverait.
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: root, create: true)
        defer { try? fm.removeItem(at: staging) }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", staging.path]
        tar.standardOutput = FileHandle.nullDevice
        tar.standardError = FileHandle.nullDevice
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0,
              let extracted = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil).first(where: \.hasDirectoryPath)
        else { throw InstallError.archive }
        let target = root.appendingPathComponent("llama-\(engineBuild)", isDirectory: true)
        try? fm.removeItem(at: target)
        try fm.moveItem(at: extracted, to: target)
        try? fm.removeItem(at: archive)
        guard LocalLLM.serverBinary != nil else { throw InstallError.archive }
    }

    /// Télécharge (ou complète) `part`, puis vérifie son empreinte ; un fichier abîmé est effacé.
    nonisolated private static func download(_ source: LocalLLM.Download, to part: URL, report: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
        let missing = source.size - fileSize(part)
        if missing > 0 {
            let free = (try? part.deletingLastPathComponent()
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage) ?? .max
            // 1 Go de marge : un disque plein ferait échouer l'historique et les enregistrements.
            guard free > missing + 1_000_000_000 else { throw InstallError.noSpace(missing + 1_000_000_000 - free) }
            // Trois essais, chacun reprenant où le précédent s'est arrêté (coupure brève du réseau, veille).
            for attempt in 1...3 {
                do {
                    try await FileDownload(source: source, part: part, report: report).run()
                    break
                } catch where attempt < 3 && retriable(error) {
                    try await Task.sleep(for: .seconds(5))
                }
            }
        }
        report(1)
        guard try sha256(of: part) == source.sha256 else {
            try? fm.removeItem(at: part)
            throw InstallError.corrupted
        }
    }

    /// Coupure du réseau ou réponse tronquée : un nouvel essai reprend la suite. Pas un arrêt demandé ni un refus du serveur.
    nonisolated private static func retriable(_ error: Error) -> Bool {
        if let error = error as? URLError { return error.code != .cancelled }
        if case InstallError.incomplete = error { return true }
        return false
    }

    nonisolated static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Erreurs du réseau traduites : leur texte système est en anglais.
    nonisolated private static func describe(_ error: Error) -> Error {
        guard let error = error as? URLError else { return error }
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return InstallError.offline
        default:
            return InstallError.network(error.code.rawValue)
        }
    }

    enum InstallError: LocalizedError {
        case noSpace(Int64), corrupted, http(Int), incomplete, archive, offline, network(Int)
        var errorDescription: String? {
            switch self {
            case .noSpace(let bytes):
                return "espace disque insuffisant pour le modèle local (\(LocalLLMInstaller.size(bytes)) à libérer)"
            case .corrupted: return "fichier du modèle local abîmé au téléchargement, il sera repris au prochain essai"
            case .http(let status): return "téléchargement du modèle local refusé par le serveur (erreur \(status))"
            case .incomplete: return "téléchargement du modèle local interrompu, il reprendra au prochain essai"
            case .archive: return "archive du moteur local illisible"
            case .offline: return "pas de connexion : le modèle local se téléchargera au prochain lancement"
            case .network(let code): return "téléchargement du modèle local interrompu (erreur réseau \(code))"
            }
        }
    }
}

/// Téléchargement d'un fichier dans `part`, repris à la taille déjà écrite (en-tête Range). Les morceaux sont écrits
/// au fil de l'eau : un modèle de 5 Go ne passe jamais par la mémoire.
private final class FileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let source: LocalLLM.Download
    private let part: URL
    private let report: @Sendable (Double) -> Void
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var reported = -1.0
    private var failure: Error?
    private var continuation: CheckedContinuation<Void, Error>?

    init(source: LocalLLM.Download, part: URL, report: @escaping @Sendable (Double) -> Void) {
        self.source = source
        self.part = part
        self.report = report
    }

    func run() async throws {
        if !FileManager.default.fileExists(atPath: part.path) { FileManager.default.createFile(atPath: part.path, contents: nil) }
        written = LocalLLMInstaller.fileSize(part)
        var request = URLRequest(url: source.url, timeoutInterval: 60)
        if written > 0 { request.setValue("bytes=\(written)-", forHTTPHeaderField: "Range") }
        // File d'attente des rappels en série : `written` et `handle` ne sont jamais touchés en même temps.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.continuation = continuation
                session.dataTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            let handle = try FileHandle(forWritingTo: part)
            switch status {
            case 206:
                try handle.seekToEnd()
            case 200:
                // Le serveur renvoie le fichier entier (reprise refusée) : on repart de zéro.
                try handle.truncate(atOffset: 0)
                written = 0
            default:
                try? handle.close()
                failure = LocalLLMInstaller.InstallError.http(status)
                completionHandler(.cancel)
                return
            }
            self.handle = handle
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
        } catch {
            failure = error
            dataTask.cancel()
            return
        }
        written += Int64(data.count)
        let fraction = min(Double(written) / Double(source.size), 0.999)
        if fraction - reported >= 0.002 {
            reported = fraction
            report(fraction)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        if let error = failure ?? error {
            continuation?.resume(throwing: error)
        } else if written != source.size {
            continuation?.resume(throwing: LocalLLMInstaller.InstallError.incomplete)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}
