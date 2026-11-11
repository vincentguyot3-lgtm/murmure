import Foundation

/// Réglages persistants et emplacement des fichiers de l'application.
enum Settings {
    static let supportDir: URL = {
        // MURMURE_SUPPORT_DIR : dossier de données de remplacement pour les essais en ligne de commande,
        // afin de ne jamais écrire l'historique de l'utilisateur pendant que l'application tourne.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = ProcessInfo.processInfo.environment["MURMURE_SUPPORT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? base.appendingPathComponent("Murmure", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Reconnaître les voix d'une réunion à l'autre (`VoiceBook`). Désactivé : plus rien n'est comparé ni gardé.
    static var recognizeVoices: Bool {
        get { UserDefaults.standard.object(forKey: "recognizeVoices") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "recognizeVoices") }
    }

    static var modelsDir: URL { subdirectory("Models") }
    static var audioDir: URL { subdirectory("Enregistrements") }

    private static func subdirectory(_ name: String) -> URL {
        let dir = supportDir.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Modèle Whisper large-v3 turbo, optimisé Core ML (~1,6 Go).
    static let whisperModel = "large-v3-v20240930_turbo"

    /// Moteur de mise en forme : "local", "apple", "claude" ou "none".
    static var cleanupEngine: String {
        get { UserDefaults.standard.string(forKey: "cleanupEngine") ?? "local" }
        set { UserDefaults.standard.set(newValue, forKey: "cleanupEngine") }
    }

    /// Modèle Claude pour la relecture de la dictée (la vitesse compte) et pour la rédaction (la finesse compte).
    static var claudeDictationModel: String {
        // MURMURE_CLAUDE_MODELE_DICTEE : modèle imposé pour un essai (`--essai-claude`), sans toucher au réglage.
        get { ProcessInfo.processInfo.environment["MURMURE_CLAUDE_MODELE_DICTEE"]
            ?? UserDefaults.standard.string(forKey: "claudeDictationModel") ?? ClaudeAPI.defaultDictationModel }
        set { UserDefaults.standard.set(newValue, forKey: "claudeDictationModel") }
    }
    static var claudeWritingModel: String {
        get { UserDefaults.standard.string(forKey: "claudeWritingModel") ?? ClaudeAPI.defaultModel }
        set { UserDefaults.standard.set(newValue, forKey: "claudeWritingModel") }
    }

    /// Avec Claude, garder le modèle local chargé pour prendre le relais sans connexion.
    static var claudeFallback: Bool { UserDefaults.standard.object(forKey: "claudeFallback") as? Bool ?? true }

    /// « Rester hors ligne » (barre des menus) : rien ne part vers Claude tant que c'est coché.
    static var stayOffline: Bool {
        get { UserDefaults.standard.bool(forKey: "stayOffline") }
        set { UserDefaults.standard.set(newValue, forKey: "stayOffline") }
    }

    /// Transcription des réunions : "local" (sur ce Mac, par défaut) ou "online" (service en ligne, serveur européen ;
    /// voir `OnlineTranscription`). La dictée reste toujours transcrite sur ce Mac.
    static var meetingTranscription: String {
        get { UserDefaults.standard.string(forKey: "meetingTranscription") ?? "local" }
        set { UserDefaults.standard.set(newValue, forKey: "meetingTranscription") }
    }

    /// Transcription en ligne : joindre au son les termes et corrections du dictionnaire (noms de clients compris).
    static var onlineSendsDictionary: Bool { UserDefaults.standard.object(forKey: "onlineSendsDictionary") as? Bool ?? true }

    /// Transcription en ligne : y envoyer aussi les enregistrements importés (dictaphone, audience). Désactivé par
    /// défaut : un fichier importé part dès la fin de sa lecture, sans cadenas possible.
    static var onlineImports: Bool { UserDefaults.standard.bool(forKey: "onlineImports") }

    /// Fichier du modèle local utilisé (dans Application Support/Murmure/LLM).
    static var localModel: String {
        get { UserDefaults.standard.string(forKey: "localModel") ?? "qwen3-4b.gguf" }
        set { UserDefaults.standard.set(newValue, forKey: "localModel") }
    }

    /// Prénom affiché par l'accueil (« Bonjour Vincent ») ; par défaut, le premier mot du nom du compte macOS.
    static var userName: String {
        get { UserDefaults.standard.string(forKey: "userName") ?? defaultUserName }
        set { UserDefaults.standard.set(newValue, forKey: "userName") }
    }

    static var defaultUserName: String { NSFullUserName().split(separator: " ").first.map(String.init) ?? "" }

    /// "fr" pour forcer le français, "auto" pour la détection automatique.
    static var language: String {
        get { UserDefaults.standard.string(forKey: "language") ?? "fr" }
        set { UserDefaults.standard.set(newValue, forKey: "language") }
    }

    static var isAutoLanguage: Bool { language == "auto" }

    /// Micro choisi dans Murmure (identifiant Core Audio) ; vide : l'entrée de Réglages Système › Son.
    static var microphone: String { UserDefaults.standard.string(forKey: "microphone") ?? "" }

    /// Micro du Mac plutôt que celui d'écouteurs Bluetooth en entrée du système (activé par défaut).
    static var avoidBluetoothMic: Bool { UserDefaults.standard.object(forKey: "avoidBluetoothMic") as? Bool ?? true }

    /// Garde l'audio de chaque dictée (dans Enregistrements/) pour comparer les moteurs sur de vraies dictées.
    static var keepAudio: Bool {
        get { UserDefaults.standard.bool(forKey: "keepAudio") }
        set { UserDefaults.standard.set(newValue, forKey: "keepAudio") }
    }

    /// Réunions : reprendre le titre et les invités du rendez-vous en cours dans l'agenda.
    static var useCalendar: Bool { UserDefaults.standard.object(forKey: "useCalendar") as? Bool ?? true }

    /// Annuaire des noms (Contacts, agenda, réunions) rapproché de chaque dictée pour rétablir la graphie des noms.
    static var useNameDirectory: Bool {
        get { UserDefaults.standard.object(forKey: "useNameDirectory") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "useNameDirectory") }
    }

    /// Agendas cochés ou décochés par l'utilisateur (identifiant EventKit → pris en compte). Un agenda absent
    /// suit la règle par défaut de `Connectors.includedByDefault` : tout sauf anniversaires et jours fériés.
    static var calendarChoices: [String: Bool] {
        get { UserDefaults.standard.dictionary(forKey: "calendarChoices") as? [String: Bool] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "calendarChoices") }
    }

    /// Réunions : capter aussi le son diffusé par le Mac (participants d'une visio), en plus du micro.
    static var meetingSystemAudio: Bool { UserDefaults.standard.object(forKey: "meetingSystemAudio") as? Bool ?? true }

    /// Animations de l'interface : "full", "reduced" ou "none".
    static var motion: String { UserDefaults.standard.string(forKey: "motion") ?? "full" }

    /// Apparence : "system", "light" ou "dark".
    static var appearance: String { UserDefaults.standard.string(forKey: "appearance") ?? "system" }

    /// Signal sonore au début et à la fin d'une dictée.
    static var dictationSounds: Bool { UserDefaults.standard.bool(forKey: "dictationSounds") }

    /// Pastille de dictée en haut de l'écran plutôt qu'en bas.
    static var overlayAtTop: Bool { UserDefaults.standard.string(forKey: "overlayPosition") == "top" }

    /// Bouton flottant au bord de l'écran (dictée et réunion d'un clic) ; affiché par défaut.
    static var floatingButton: Bool {
        get { UserDefaults.standard.object(forKey: "floatingButton") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "floatingButton") }
    }

    /// Touche maintenue pour dicter.
    static var dictationKey: DictationKey {
        DictationKey(rawValue: UserDefaults.standard.string(forKey: "dictationKey") ?? "") ?? .rightOption
    }

    /// Colle le texte dicté à l'emplacement du curseur ; sinon, le copie seulement.
    static var autoPaste: Bool { UserDefaults.standard.object(forKey: "autoPaste") as? Bool ?? true }

    /// Combien de temps une dictée reste dans l'historique : jamais, 24 heures (par défaut) ou toujours.
    /// Les réunions sont toujours gardées ; une dictée rangée dans un dossier aussi, tant qu'elle y est.
    enum DictationRetention: String, CaseIterable {
        case never, day, always

        var label: String {
            switch self {
            case .never: return "Jamais"
            case .day: return "24 heures"
            case .always: return "Toujours"
            }
        }

        /// Date d'expiration d'une dictée créée maintenant (nil : gardée sans limite).
        func expiry(from date: Date = Date()) -> Date? {
            self == .day ? date.addingTimeInterval(24 * 3600) : nil
        }
    }

    static var dictationRetention: DictationRetention {
        get { DictationRetention(rawValue: UserDefaults.standard.string(forKey: "dictationRetention") ?? "") ?? .day }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "dictationRetention") }
    }

    /// Lit le texte autour du curseur (≈ 500 mots de chaque côté) pour mieux transcrire et accorder le collage.
    static var fieldContext: Bool { UserDefaults.standard.object(forKey: "fieldContext") as? Bool ?? true }

    /// Propose d'enregistrer un appel (micro tenu depuis 6 s) ou une visio (application de réunion, 20 s).
    static var detectMeetings: Bool { UserDefaults.standard.object(forKey: "detectMeetings") as? Bool ?? true }

    /// Propose d'enregistrer au début d'un rendez-vous de l'agenda, même sans visio.
    static var proposeAtAppointments: Bool { UserDefaults.standard.object(forKey: "proposeAtAppointments") as? Bool ?? true }

    /// Deux minutes avant un rendez-vous, le bouton flottant se déplie : « Rejoindre », « Rejoindre et enregistrer ».
    static var remindAppointments: Bool { UserDefaults.standard.object(forKey: "remindAppointments") as? Bool ?? true }

    /// Après 3 min sans parole pendant une réunion, le bouton flottant propose de la terminer.
    static var offerToEndQuietMeetings: Bool { UserDefaults.standard.object(forKey: "offerToEndQuietMeetings") as? Bool ?? true }

    /// Coupe le son du Mac (musique, vidéo) pendant la dictée.
    static var muteWhileDictating: Bool { UserDefaults.standard.bool(forKey: "muteWhileDictating") }

    /// Relit le texte collé quelques secondes plus tard pour apprendre les mots que l'utilisateur corrige.
    static var learnCorrections: Bool { UserDefaults.standard.object(forKey: "learnCorrections") as? Bool ?? true }

    /// Notification quand la transcription ou le compte rendu d'une réunion est prêt.
    static var notifyWhenReady: Bool { UserDefaults.standard.object(forKey: "notifyWhenReady") as? Bool ?? true }

    /// Échelle de toute l'interface (1 = normale).
    static var uiScale: Double { UserDefaults.standard.object(forKey: "uiScale") as? Double ?? 1 }

    /// Accueil du premier lancement terminé.
    static var onboarded: Bool {
        get { UserDefaults.standard.bool(forKey: "onboarded") }
        set { UserDefaults.standard.set(newValue, forKey: "onboarded") }
    }

    /// Termes à reconnaître correctement (noms propres, sigles).
    static func vocabulary() -> [String] { Lexicon.shared.snapshot().terms }

    /// Corrections « mal entendu => correct » appliquées au texte transcrit.
    static func replacements() -> [(from: String, to: String)] {
        Lexicon.shared.snapshot().replacements
            .filter { !$0.from.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { ($0.from.trimmingCharacters(in: .whitespaces), $0.to.trimmingCharacters(in: .whitespaces)) }
    }
}

/// Profil de l'utilisateur. Un seul profil aujourd'hui, dont le prénom vient de `Settings.userName` :
/// c'est le point d'entrée des futurs comptes utilisateurs (plusieurs profils, chacun son historique et ses
/// réglages). Tout ce qui nomme l'utilisateur doit passer par ici, et non par `NSFullUserName` directement.
struct UserProfile {
    var firstName: String

    static var current: UserProfile { UserProfile(firstName: Settings.userName.trimmingCharacters(in: .whitespaces)) }

    /// « Bonjour Vincent », ou « Bonjour » seul si le prénom est vide.
    var greeting: String { firstName.isEmpty ? "Bonjour" : "Bonjour \(firstName)" }
}
