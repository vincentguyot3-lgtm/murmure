import AppKit
import SwiftUI

/// Petite pastille flottante (en bas ou en haut de l'écran) qui montre l'état de la dictée.
final class OverlayModel: ObservableObject {
    enum Phase: Equatable { case listening, instruction, locked, transcribing, cleaning, rewriting, message(String, error: Bool = false) }
    @Published var phase: Phase = .listening
    @Published var level: Float = 0
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    @ObservedObject private var live = AppState.shared
    @AppStorage("overlayLiveText") private var liveEnabled = true
    @AppStorage("overlayPosition") private var position = "bottom"

    private var atTop: Bool { position == "top" }

    var body: some View {
        VStack(spacing: 8) {
            if atTop {
                PillView(phase: model.phase, level: model.level)
                liveCard
            } else {
                liveCard
                PillView(phase: model.phase, level: model.level)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: atTop ? .top : .bottom)
        .animation(Motion.quick, value: showsLive)
        .animation(Motion.quick, value: model.phase)
    }

    @ViewBuilder private var liveCard: some View {
        if showsLive {
            LiveTextCard(text: liveText, atTop: atTop)
        }
    }

    /// Les ~280 derniers caractères : la pastille montre la fin de ce qui est dit.
    private var liveText: String {
        let text = [live.liveText, live.livePending].filter { !$0.isEmpty }.joined(separator: " ")
        return text.count > 280 ? "…" + text.suffix(280) : text
    }

    private var showsLive: Bool {
        guard liveEnabled, !live.liveText.isEmpty || !live.livePending.isEmpty else { return false }
        return PillView.showsLive(model.phase)
    }
}

/// La pastille elle-même : glyphe du mode, indicateur (vumètre monochrome, anneau, pictogramme) et libellé.
/// Tout en blanc sur noir, à l'échelle de « Taille de l'interface ». Partagée avec l'aperçu des Réglages.
struct PillView: View {
    let phase: OverlayModel.Phase
    var level: Float = 0

    private var scale: CGFloat { Settings.uiScale }

    var body: some View {
        HStack(spacing: 10 * scale) {
            indicator
            Text(label)
                .font(.system(size: 13 * scale, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 16 * scale)
        .padding(.vertical, 10 * scale)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .overlay {
            if sweeps { SweepLine().clipShape(Capsule()) }
        }
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
        .fixedSize()
    }

    /// Pendant le traitement, une fine ligne claire balaie la capsule.
    private var sweeps: Bool {
        guard Motion.level != .none else { return false }
        switch phase {
        case .transcribing, .cleaning, .rewriting: return true
        default: return false
        }
    }

    /// Phases pendant lesquelles le texte en direct s'affiche au-dessus de la pastille.
    static func showsLive(_ phase: OverlayModel.Phase) -> Bool {
        switch phase {
        case .listening, .instruction, .locked, .transcribing: return true
        case .cleaning, .rewriting, .message: return false
        }
    }

    /// Glyphe du mode d'écoute : micro (dictée), étincelles (consigne), cadenas (dictée verrouillée).
    private var glyph: String? {
        switch phase {
        case .listening: return "mic.fill"
        case .instruction: return "sparkles"
        case .locked: return "lock.fill"
        default: return nil
        }
    }

    @ViewBuilder private var indicator: some View {
        switch phase {
        case .listening, .instruction, .locked:
            HStack(spacing: 8 * scale) {
                if let glyph {
                    Image(systemName: glyph).font(.system(size: 11 * scale, weight: .semibold)).foregroundStyle(.white)
                }
                HStack(spacing: 3 * scale) {
                    ForEach(0..<5, id: \.self) { i in
                        let weights: [Float] = [0.5, 0.8, 1, 0.8, 0.5]
                        Capsule()
                            .fill(.white)
                            .frame(width: 3 * scale, height: CGFloat(4 + 14 * level * weights[i]) * scale)
                    }
                }
                .frame(height: 18 * scale)
                .animation(Motion.meter, value: level)
            }
        case .transcribing, .cleaning, .rewriting:
            Spinner(size: 14 * scale, color: .white, lineWidth: 1.5)
        case .message(_, let error):
            Image(systemName: error ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.system(size: 13 * scale))
                .foregroundStyle(.white)
        }
    }

    private var label: String {
        switch phase {
        case .listening: return "À l'écoute…"
        case .instruction: return "Consigne pour le texte sélectionné…"
        // Le texte part en ligne : la pastille le dit.
        case .rewriting: return Cleaner.engine == .claude ? "Réécriture par Claude…" : "Réécriture…"
        case .locked: return "Dictée verrouillée · \(Settings.dictationKey.label) pour finir · Échap pour annuler"
        case .transcribing: return "Transcription…"
        case .cleaning: return Cleaner.engine == .claude ? "Relecture par Claude…" : "Mise en forme…"
        case .message(let text, _): return text
        }
    }
}

/// Fine ligne claire qui traverse la capsule de gauche à droite, en boucle, pendant un traitement.
private struct SweepLine: View {
    @State private var running = false

    var body: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, .white.opacity(0.28), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 56)
                .offset(x: running ? geo.size.width : -56)
                .onAppear {
                    // Sans animations, la ligne reste hors de la capsule : rien ne bouge.
                    guard let loop = Motion.loop(1.3, reduced: 2) else { return }
                    withAnimation(loop) { running = true }
                }
        }
        .allowsHitTesting(false)
    }
}

/// Écran miniature où la pastille vit comme en vrai : elle passe d'À l'écoute à Transcription, Mise en forme,
/// puis « Collé », en bas ou en haut selon le réglage, avec le texte en direct si activé.
/// Sert à la sous-page Pastille des Réglages et à l'accueil du premier lancement.
struct PillPreview: View {
    let atTop: Bool
    let liveText: Bool
    var size = CGSize(width: 360, height: 210)
    var scale: CGFloat = 0.78
    private let period = 1.6

    private static let phases: [OverlayModel.Phase] = [.listening, .listening, .transcribing, .cleaning, .message("Collé dans Word")]
    private static let sample = "…le bailleur n'a pas respecté le délai de préavis prévu à l'article 15 de la loi du 6 juillet 1989"

    var body: some View {
        TimelineView(.periodic(from: .now, by: period)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate / period)
            let phase = Self.phases[tick % Self.phases.count]
            let level: Float = tick % 2 == 0 ? 0.55 : 0.9
            ZStack(alignment: atTop ? .top : .bottom) {
                RoundedRectangle(cornerRadius: 12).fill(Theme.soft)
                RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line)
                // Barre des menus et une fenêtre esquissées, pour situer la pastille.
                VStack(spacing: 0) {
                    Rectangle().fill(Theme.line).frame(height: 10)
                    Spacer()
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line)
                    .padding(.horizontal, size.width / 6).padding(.top, 28).padding(.bottom, size.height * 0.21)
                VStack(spacing: 6) {
                    if atTop {
                        PillView(phase: phase, level: level)
                        if liveText && PillView.showsLive(phase) { LiveTextCard(text: Self.sample, atTop: true, width: 240, fontSize: 10) }
                    } else {
                        if liveText && PillView.showsLive(phase) { LiveTextCard(text: Self.sample, atTop: false, width: 240, fontSize: 10) }
                        PillView(phase: phase, level: level)
                    }
                }
                .scaleEffect(scale)
                .padding(.vertical, atTop ? 16 : 14)
                .animation(Motion.quick, value: phase)
                .animation(Motion.quick, value: liveText)
            }
            .frame(width: size.width, height: size.height)
            .animation(Motion.page, value: atTop)
        }
    }
}

/// Carte sombre du texte en direct, au-dessus (ou au-dessous) de la pastille.
struct LiveTextCard: View {
    let text: String
    var atTop = false
    var width: CGFloat = 520
    var fontSize: CGFloat = 13

    var body: some View {
        Text(text)
            .font(.system(size: fontSize))
            .foregroundStyle(.white)
            .lineLimit(4)
            .frame(width: width, alignment: .leading)
            .padding(fontSize + 1)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.82)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.12)))
            .transition(Motion.level == .full ? .opacity.combined(with: .offset(y: atTop ? -6 : 6)) : .opacity)
    }
}

final class Overlay {
    let model = OverlayModel()
    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))
        return panel
    }()

    private var hideWork: DispatchWorkItem?
    /// Incrémenté à chaque affichage : un fondu de fermeture en cours ne cache pas une pastille réaffichée entre-temps.
    private var generation = 0

    func show(_ phase: OverlayModel.Phase) {
        hideWork?.cancel()
        generation += 1
        model.phase = phase
        if phase == .listening { model.level = 0 }
        if !panel.isVisible {
            position()
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        fade(to: 1)
    }

    /// Message bref ; `error` distingue un échec (triangle) d'une simple information (i).
    func flash(_ text: String, seconds: Double = 2.5, error: Bool = false) {
        show(.message(text, error: error))
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        generation += 1
        let current = generation
        fade(to: 0) { [weak self] in
            guard let self, self.generation == current else { return }
            self.panel.orderOut(nil)
        }
    }

    private func fade(to alpha: CGFloat, then done: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Motion.seconds(alpha > 0 ? 0.14 : 0.2)
            context.timingFunction = CAMediaTimingFunction(name: alpha > 0 ? .easeOut : .easeIn)
            panel.animator().alphaValue = alpha
        }, completionHandler: done)
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let y = Settings.overlayAtTop ? frame.maxY - size.height - 12 : frame.minY + 40
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: y))
    }
}
