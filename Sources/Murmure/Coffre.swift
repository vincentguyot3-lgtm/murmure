import Foundation
import Security

/// Secrets de Murmure (clé Claude, clé du service de transcription, jetons et adresses des connecteurs), gardés
/// dans `secrets.json` du dossier de Murmure, lisible et modifiable par le seul compte de l'utilisateur (droits 600).
///
/// Pourquoi pas le trousseau : l'app est signée avec un certificat local que macOS ne tient pas pour fiable ; le
/// trousseau la reconnaît donc à l'empreinte de son exécutable, qui change à chaque compilation, et redemandait
/// le mot de passe de session après chaque mise à jour (et à chaque essai en ligne de commande). Le fichier ne
/// demande rien ; le disque reste chiffré par FileVault.
///
/// Reprise : un secret encore absent du fichier est cherché une seule fois dans l'ancien emplacement du trousseau
/// (dernière demande d'autorisation), recopié ici, puis le trousseau n'est plus jamais consulté pour lui.
enum Coffre {
    /// Emplacement d'un secret dans le trousseau, avant le passage au fichier.
    struct AncienEmplacement { let service: String; let account: String }

    private struct Contenu: Codable {
        var secrets: [String: String] = [:]
        /// Noms déjà cherchés dans le trousseau, trouvés ou non : on n'y retourne pas.
        var repris: [String] = []
    }

    private static let lock = NSLock()
    private static var contenu: Contenu?
    static var url: URL { Settings.supportDir.appendingPathComponent("secrets.json") }

    static func get(_ name: String, ancien: AncienEmplacement? = nil) -> String? {
        lock.withLock {
            var c = charger()
            if let value = c.secrets[name] { return value }
            // Les essais en ligne de commande (binaire signé autrement) ne touchent pas au trousseau : ce serait
            // une demande d'autorisation de plus. La reprise est faite par l'application.
            let ligneDeCommande = CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--") }
            guard let ancien, !ligneDeCommande, !c.repris.contains(name) else { return nil }
            c.repris.append(name)
            if let value = lireTrousseau(ancien), !value.isEmpty { c.secrets[name] = value }
            enregistrer(c)
            return c.secrets[name]
        }
    }

    /// Enregistre (ou retire, si vide) un secret.
    static func set(_ name: String, _ value: String?) {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        lock.withLock {
            var c = charger()
            c.secrets[name] = trimmed.isEmpty ? nil : trimmed
            // Le choix de l'utilisateur prime : ne plus rien reprendre du trousseau pour ce nom.
            if !c.repris.contains(name) { c.repris.append(name) }
            enregistrer(c)
        }
    }

    // MARK: - Fichier

    private static func charger() -> Contenu {
        if let contenu { return contenu }
        let lu = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Contenu.self, from: $0) } ?? Contenu()
        contenu = lu
        return lu
    }

    private static func enregistrer(_ c: Contenu) {
        contenu = c
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(c) else { return }
        // Créé d'emblée en 600 : le fichier n'est jamais lisible par un autre compte, même un instant.
        let tmp = url.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600])
        if rename(tmp.path, url.path) != 0 { try? FileManager.default.removeItem(at: tmp) }
    }

    // MARK: - Ancien trousseau

    private static func lireTrousseau(_ e: AncienEmplacement) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: e.service,
            kSecAttrAccount as String: e.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }
}
