import AppKit
import SwiftUI

/// Murmure ↔ Claude Code, dans les deux sens : « Envoyer dans Claude Code » pousse une fiche dans le dossier
/// d'un projet (et y ouvre Claude Code) ; « Relier à Claude » déclare le serveur MCP (`Murmure --mcp`,
/// voir `MCPServer.swift`) pour que Claude lise l'historique à la demande.
enum ClaudeCode {
    static let bundleID = "com.anthropic.claudefordesktop"
    static var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }

    // MARK: - Envoyer une fiche dans un projet

    private static let recentKey = "claudeProjects"
    static let recentLimit = 4

    /// Dossiers de projet déjà utilisés, du plus récent au plus ancien ; ceux qui n'existent plus sont oubliés.
    static var recentProjects: [URL] {
        get {
            (UserDefaults.standard.stringArray(forKey: recentKey) ?? [])
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        set { UserDefaults.standard.set(Array(newValue.prefix(recentLimit)).map(\.path), forKey: recentKey) }
    }

    private static func remember(_ folder: URL) {
        recentProjects = [folder] + recentProjects.filter { $0.path != folder.path }
    }

    /// Entrées de menu : les projets récents, puis « Autre dossier de projet… ».
    static func entries(for recording: Recording) -> [MenuEntry] {
        var entries: [MenuEntry] = [.header("Envoyer dans Claude Code")]
        let recent = recentProjects
        for folder in recent {
            entries.append(.action(folder.lastPathComponent, "folder") { Task { @MainActor in send(recording, to: folder) } })
        }
        entries.append(.action(recent.isEmpty ? "Choisir le dossier du projet…" : "Autre dossier de projet…", "folder.badge.plus") {
            Task { @MainActor in choose(for: recording) }
        })
        return entries
    }

    @MainActor
    static func choose(for recording: Recording) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Envoyer ici"
        panel.message = "« \(recording.title) » sera écrite en Markdown dans ce dossier de projet, où Claude Code pourra la lire."
        if let last = recentProjects.first { panel.directoryURL = last }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            send(recording, to: url)
        }
    }

    /// Écrit la fiche (synthèse puis transcription) dans le dossier du projet, puis propose d'y ouvrir Claude Code.
    @MainActor
    static func send(_ recording: Recording, to folder: URL) {
        let target = folder.appendingPathComponent(Exporter.fileName(recording))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Exporter.markdown(recording).data(using: .utf8)?.write(to: target, options: .atomic)
        } catch {
            Toasts.shared.show("Impossible d'écrire dans « \(folder.lastPathComponent) »")
            return
        }
        remember(folder)
        let text = "Copié dans « \(folder.lastPathComponent) »"
        if isInstalled {
            Toasts.shared.show(text, action: ("Ouvrir dans Claude Code", { open(folder) }), seconds: 8)
        } else {
            Toasts.shared.show(text, action: ("Afficher dans le Finder", { NSWorkspace.shared.activateFileViewerSelecting([target]) }))
        }
    }

    /// Ouvre une nouvelle session Claude Code sur le dossier (lien `claude://code/new?folder=…` de l'app Claude) ;
    /// sans l'app, le dossier s'ouvre dans le Finder.
    static func open(_ folder: URL) {
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "code"
        components.path = "/new"
        components.queryItems = [URLQueryItem(name: "folder", value: folder.path), URLQueryItem(name: "source", value: "murmure")]
        guard isInstalled, let url = components.url else {
            NSWorkspace.shared.open(folder)
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Serveur MCP : déclaration auprès de Claude Code et de l'app Claude

    static let serverName = "murmure"

    /// Le binaire de Murmure tel qu'il est installé (`~/Applications/Murmure.app/Contents/MacOS/Murmure`).
    static var executable: String { Bundle.main.executablePath ?? CommandLine.arguments[0] }

    /// Claude Code lit `~/.claude.json` (portée utilisateur : tous les projets) ; l'app Claude, son fichier de
    /// configuration dans Application Support. Les deux ont la même forme : `mcpServers.<nom>.{command, args}`.
    /// MURMURE_HOME_DIR : faux dossier personnel pour les essais en ligne de commande, afin de ne jamais toucher
    /// la vraie configuration de Claude (même esprit que MURMURE_SUPPORT_DIR).
    private static var home: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["MURMURE_HOME_DIR"] ?? NSHomeDirectory(), isDirectory: true)
    }
    static var claudeCodeConfig: URL { home.appendingPathComponent(".claude.json") }
    static var claudeDesktopConfig: URL { home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json") }

    struct Registration: Equatable {
        var claudeCode = false
        var claudeDesktop = false
        /// Déclaré, mais vers un autre binaire (app déplacée, ancien script) : à mettre à jour.
        var stale = false
        var any: Bool { claudeCode || claudeDesktop }
        var summary: String {
            [claudeCode ? "Claude Code" : nil, claudeDesktop ? "app Claude" : nil].compactMap { $0 }.joined(separator: " · ")
        }
    }

    static func registration() -> Registration {
        var result = Registration()
        for (file, keyPath) in [(claudeCodeConfig, \Registration.claudeCode), (claudeDesktopConfig, \Registration.claudeDesktop)] {
            guard let servers = readJSON(file)?["mcpServers"] as? [String: Any], let entry = servers[serverName] as? [String: Any] else { continue }
            result[keyPath: keyPath] = true
            if entry["command"] as? String != executable { result.stale = true }
        }
        return result
    }

    enum RegistrationError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let name): return "\(name) est illisible ; Murmure n'y touche pas."
            }
        }
    }

    /// Déclare (ou retire) le serveur dans la configuration de Claude Code, et dans celle de l'app Claude si
    /// elle est installée. Les autres entrées des fichiers sont conservées telles quelles.
    static func register(_ on: Bool) throws {
        try edit(claudeCodeConfig, on: on, entry: ["type": "stdio", "command": executable, "args": ["--mcp"]])
        if isInstalled || FileManager.default.fileExists(atPath: claudeDesktopConfig.path) {
            try edit(claudeDesktopConfig, on: on, entry: ["command": executable, "args": ["--mcp"]])
        }
    }

    private static func edit(_ file: URL, on: Bool, entry: [String: Any]) throws {
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: file.path) {
            // Un fichier présent mais illisible n'est jamais remplacé par un fichier vide.
            guard let existing = readJSON(file) else { throw RegistrationError.unreadable(file.lastPathComponent) }
            root = existing
        } else if !on {
            return
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        if on { servers[serverName] = entry } else { servers[serverName] = nil }
        root["mcpServers"] = servers
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    private static func readJSON(_ file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
