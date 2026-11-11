import Combine
import Foundation

/// Commandes de la barre des menus (⌘N, ⌘F, ⌘K, ⌘1…) transmises à la fenêtre.
enum AppCommand {
    case go(ListFilter), settings, search, focusSearch, palette
    /// ⌘F sur l'onglet Transcription d'une fiche : ouvre la recherche du bandeau au lieu de revenir à la liste.
    case findInTranscript
    /// Palette › Archives : l'accueil passe sur les éléments archivés (le sélecteur Actives / Archivées est dans Filtres).
    case showArchives
}

/// État partagé entre le moteur de dictée (AppDelegate) et l'interface.
final class AppState: ObservableObject {
    static let shared = AppState()

    enum ModelStatus: Equatable { case loading, ready, failed(String) }

    @Published var modelStatus: ModelStatus = .loading
    /// État du modèle de langage local (mise en forme).
    @Published var llmStatus: ModelStatus = .loading
    @Published var accessibilityGranted = Paster.hasAccessibility

    /// Rendez-vous dont l'enregistrement est programmé à l'heure de début (« Enregistrer à l'heure »).
    @Published var scheduledMeeting: CalendarEvent?

    /// Début de la réunion en cours d'enregistrement, nil sinon.
    @Published var meetingStartedAt: Date?

    /// Aperçu en direct de l'enregistrement en cours (réunion ou dictée) : texte figé, puis fin encore provisoire.
    @Published var liveText = ""
    @Published var livePending = ""
    /// Notes tapées par l'utilisateur pendant la réunion (page En direct), gardées dans la fiche à l'arrêt.
    @Published var liveNotes = ""
    /// « Garder sur ce Mac » choisi pendant la réunion en cours (page En direct) : rien n'en partira en ligne.
    @Published var meetingKeepLocal = false

    /// Demande à la fenêtre d'ouvrir cette fiche (réunion qui vient d'être arrêtée).
    @Published var openRecording: UUID?

    let commands = PassthroughSubject<AppCommand, Never>()

    /// Recherche de l'accueil, surlignée dans la fiche ouverte depuis les résultats.
    @Published var highlight = ""
    /// L'onglet Transcription d'une fiche est affiché : ⌘F y cherche (non publié, ne sert qu'à aiguiller la commande).
    var transcriptShown = false
}
