import AppKit
import SwiftUI

// Mouvements, apparence et retours de l'interface. Toutes les animations passent par `Motion`,
// qui suit le réglage « Animations » de Murmure et « Réduire les animations » de macOS.
// Uniquement des effets bon marché (opacité, décalage, échelle) : rien ne force un recalcul de mise en page.

enum Motion {
    enum Level: String, CaseIterable { case full, reduced, none }

    static var level: Level {
        let chosen = Level(rawValue: Settings.motion) ?? .full
        if chosen == .full, NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return .reduced }
        return chosen
    }

    /// Changement de page.
    static var page: Animation? { pick(.smooth(duration: 0.35), reduced: .easeOut(duration: 0.15)) }
    /// Petits éléments : survol, onglets, sélecteurs, interrupteurs.
    static var quick: Animation? { pick(.snappy(duration: 0.25), reduced: .easeOut(duration: 0.1)) }
    /// Dialogues.
    static var pop: Animation? { pick(.spring(response: 0.3, dampingFraction: 0.8), reduced: .easeOut(duration: 0.12)) }

    /// Carte qui se déplie depuis le bouton flottant : ressort plus ample que `pop`, sans rebond visible.
    static var unfold: Animation? { pick(.spring(response: 0.42, dampingFraction: 0.88), reduced: .easeOut(duration: 0.15)) }

    /// Valeur continue qui suit un signal (vumètre de la pastille) : très court, pour ne pas traîner derrière la voix.
    static var meter: Animation? { pick(.easeOut(duration: 0.08), reduced: .easeOut(duration: 0.08)) }

    /// Mouvement en boucle (anneau d'attente, ligne qui balaie la pastille) : plus lent en mode sobre, absent sans animations.
    static func loop(_ full: Double, reduced: Double) -> Animation? {
        pick(.linear(duration: full).repeatForever(autoreverses: false),
             reduced: .linear(duration: reduced).repeatForever(autoreverses: false))
    }

    /// Durée d'une animation AppKit (fenêtre, panneau de menu, pastille) ; nulle sans animations.
    static func seconds(_ full: Double, reduced: Double? = nil) -> Double {
        switch level {
        case .full: return full
        case .reduced: return reduced ?? full
        case .none: return 0
        }
    }

    /// Point qui clignote (réunion en cours) : seulement en mode Fluides ; fixe en mode sobre ou sans animations.
    static var blinks: Bool { level == .full }

    /// Nouvelle page : glisse de quelques points depuis la droite en apparaissant ; l'ancienne s'efface sur place.
    static var pageTransition: AnyTransition {
        level == .full ? .asymmetric(insertion: .offset(x: 18).combined(with: .opacity), removal: .opacity) : .opacity
    }

    /// Élément qui s'ouvre sur place (dialogue, carte, coche de confirmation) ; simple fondu en mode sobre.
    static func popTransition(scale: CGFloat = 0.96) -> AnyTransition {
        level == .full ? .scale(scale: scale).combined(with: .opacity) : .opacity
    }

    /// Élément qui entre par un bord (message en bas de fenêtre, carte dépliée) ; simple fondu en mode sobre.
    static func slideTransition(from edge: Edge) -> AnyTransition {
        level == .full ? .move(edge: edge).combined(with: .opacity) : .opacity
    }

    private static func pick(_ full: Animation, reduced: Animation) -> Animation? {
        switch level {
        case .full: return full
        case .reduced: return reduced
        case .none: return nil
        }
    }
}

/// Ouverture et fermeture de la fenêtre principale : fondu et léger glissement vertical.
/// Seule la position bouge (pas la taille) : le contenu n'est pas recalculé pendant l'animation.
enum WindowMotion {
    static func open(_ window: NSWindow) {
        guard Motion.level != .none else { window.makeKeyAndOrderFront(nil); return }
        let frame = window.frame
        window.alphaValue = 0
        if Motion.level == .full { window.setFrame(frame.offsetBy(dx: 0, dy: -14), display: false) }
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.seconds(0.32, reduced: 0.16)
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1) // départ vif, arrivée douce
            window.animator().alphaValue = 1
            if Motion.level == .full { window.animator().setFrame(frame, display: true) }
        }
    }

    static func close(_ window: NSWindow) {
        guard Motion.level != .none else { window.orderOut(nil); return }
        let frame = window.frame
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Motion.seconds(0.18)
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
            if Motion.level == .full { window.animator().setFrame(frame.offsetBy(dx: 0, dy: -10), display: true) }
        }, completionHandler: {
            window.orderOut(nil)
            window.setFrame(frame, display: false)
            window.alphaValue = 1
        })
    }
}

enum Appearance {
    /// Publiée quand la fenêtre passe d'un mode à l'autre en animation ; `object` : vrai si la nuit tombe.
    static let twilight = Notification.Name("murmure.crepuscule")

    /// La fenêtre est-elle affichée en sombre en ce moment ?
    static var isDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    /// Le Mac est-il réglé en sombre (Réglages Système › Apparence, y compris en mode automatique) ?
    static var systemIsDark: Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }

    /// Applique le réglage « Apparence » (système, clair, sombre) à toute l'application. `animated` : si l'affichage
    /// change vraiment de mode, la fenêtre principale passe de l'un à l'autre en fondu, pendant qu'un voile de
    /// crépuscule descend (vers le sombre) ou qu'une lueur d'aube monte (vers le clair) ; instantané sans animations.
    @MainActor
    static func apply(animated: Bool = false) {
        let value = Settings.appearance
        let willBeDark = value == "dark" || (value == "system" && systemIsDark)
        let duration = Motion.seconds(1.2, reduced: 0.35)
        if animated, willBeDark != isDark, duration > 0 {
            for window in NSApp.windows where window.isVisible {
                guard let view = window.contentView, view is NSHostingView<MainView> else { continue }
                view.wantsLayer = true
                let fade = CATransition()
                fade.type = .fade
                fade.duration = duration
                fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.25, 1)
                view.layer?.add(fade, forKey: "murmure.apparence")
            }
            if Motion.level == .full { NotificationCenter.default.post(name: twilight, object: willBeDark) }
        }
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}

/// Voile qui traverse la fenêtre pendant le changement d'apparence : un dégradé de bleu nuit bordé d'une lueur
/// rosée descend du haut quand la nuit tombe ; une lueur dorée monte du bas quand le jour se lève. Ne capte aucun clic.
struct TwilightSweep: View {
    @State private var progress: CGFloat = 0
    @State private var nightfall = true
    @State private var visible = false

    private static let duration = 1.2

    private var stops: [Gradient.Stop] {
        nightfall
            ? [.init(color: .clear, location: 0),
               .init(color: Color(red: 0.05, green: 0.07, blue: 0.20).opacity(0.30), location: 0.35),
               .init(color: Color(red: 0.22, green: 0.18, blue: 0.42).opacity(0.24), location: 0.72),
               .init(color: Color(red: 0.85, green: 0.48, blue: 0.42).opacity(0.16), location: 0.9),
               .init(color: .clear, location: 1)]
            : [.init(color: .clear, location: 0),
               .init(color: Color(red: 1.0, green: 0.86, blue: 0.55).opacity(0.22), location: 0.12),
               .init(color: Color(red: 0.98, green: 0.66, blue: 0.45).opacity(0.20), location: 0.32),
               .init(color: Color(red: 0.92, green: 0.62, blue: 0.70).opacity(0.10), location: 0.6),
               .init(color: .clear, location: 1)]
    }

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let band = height * 0.9
            // La nuit entre par le haut et sort par le bas ; l'aube fait le chemin inverse.
            let travel = -band + progress * (height + band)
            LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
                .frame(width: geometry.size.width, height: band)
                .offset(y: nightfall ? travel : height - band - travel)
                .opacity(visible ? 1 : 0)
        }
        .allowsHitTesting(false)
        .onReceive(NotificationCenter.default.publisher(for: Appearance.twilight)) { note in
            nightfall = (note.object as? Bool) ?? true
            progress = 0
            visible = true
            withAnimation(.timingCurve(0.45, 0, 0.25, 1, duration: Self.duration)) { progress = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration) {
                visible = false
                progress = 0
            }
        }
    }
}

/// Signal sonore discret au début et à la fin d'une dictée ou d'une réunion (réglage Accessibilité).
enum Feedback {
    static func start() { play("Tink") }
    static func stop() { play("Pop") }
    /// Murmure propose d'enregistrer un appel, une visio ou un rendez-vous.
    static func proposal() { play("Glass") }

    private static func play(_ name: String) {
        guard Settings.dictationSounds, let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        sound.volume = 0.35
        sound.play()
    }
}

/// Taille du texte de lecture (transcriptions, comptes rendus, dictées), réglable dans Accessibilité.
struct ReadingFont: ViewModifier {
    @AppStorage("readingSize") private var size = 14.0
    var weight: Font.Weight = .regular
    var delta: Double = 0

    func body(content: Content) -> some View {
        content.font(.system(size: size + delta, weight: weight))
    }
}

extension View {
    func readingFont(_ weight: Font.Weight = .regular, delta: Double = 0) -> some View {
        modifier(ReadingFont(weight: weight, delta: delta))
    }
}

extension Font {
    /// Police de l'interface, à la taille choisie dans Réglages › Accessibilité.
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size * Settings.uiScale, weight: weight)
    }
}

extension Font {
    /// Titre de page (titre de la fiche, « Bonjour … », Aujourd'hui, dossiers…) : serif système New York, en graisse
    /// moyenne. Le reste de l'interface, la lecture et le logo restent en SF.
    static func titre(_ size: CGFloat = 30) -> Font {
        .system(size: size * Settings.uiScale, weight: .medium, design: .serif)
    }
}

/// Mesures communes des pages (`Gabarit` et non `Layout`, déjà pris par SwiftUI) : une colonne de lecture centrée
/// dans l'espace à droite du panneau, où titre, puces, onglets et contenu partagent le même bord gauche.
/// Les Réglages n'en font pas partie.
enum Gabarit {
    /// Largeur de la colonne (sans les gouttières) : environ 80 signes par ligne à la taille de lecture.
    static var colonne: CGFloat { 720 * Settings.uiScale }
    /// Marge de chaque côté de la colonne.
    static var gouttiere: CGFloat { 36 * Settings.uiScale }
    /// Largeur maximale d'une bulle de transcription.
    static var bulle: CGFloat { 600 * Settings.uiScale }
}

extension View {
    /// Place la vue dans la colonne commune (`Gabarit.colonne`), centrée dans l'espace disponible.
    func colonne() -> some View {
        frame(maxWidth: Gabarit.colonne, alignment: .leading)
            .padding(.horizontal, Gabarit.gouttiere)
            .frame(maxWidth: .infinity)
    }
}
