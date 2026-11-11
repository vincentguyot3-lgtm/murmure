import AppKit
import SwiftUI

/// Carte « Appel en cours · Enregistrer » posée en haut à droite de l'écran, au-dessus des autres fenêtres.
/// Elle remplace la notification macOS, qui n'apparaît pas tant que l'autorisation n'est pas donnée et se perd
/// au premier appel (la demande d'autorisation part en même temps). Même style que la pastille de dictée.
struct MeetingPromptView: View {
    let proposal: MeetingProposal
    var onRecord: () -> Void = {}
    var onDismiss: () -> Void = {}

    private var scale: CGFloat { Settings.uiScale }

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * scale) {
            HStack(alignment: .top, spacing: 10 * scale) {
                Image(systemName: proposal.symbol)
                    .font(.system(size: 13 * scale, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30 * scale, height: 30 * scale)
                    .background(Circle().fill(Color.white.opacity(0.14)))
                VStack(alignment: .leading, spacing: 3 * scale) {
                    Text(proposal.title)
                        .font(.system(size: 13 * scale, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(proposal.subtitle)
                        .font(.system(size: 11.5 * scale))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Pensez à prévenir les participants.")
                        .font(.system(size: 10.5 * scale))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8 * scale) {
                Spacer(minLength: 0)
                PromptButton(title: "Ignorer", primary: false, action: onDismiss)
                PromptButton(title: "Enregistrer", primary: true, action: onRecord)
            }
        }
        .padding(14 * scale)
        .frame(width: 330 * scale)
        .background(RoundedRectangle(cornerRadius: 16 * scale).fill(Color.black.opacity(0.86)))
        .overlay(RoundedRectangle(cornerRadius: 16 * scale).strokeBorder(Color.white.opacity(0.12)))
    }
}

/// Bouton de la carte : blanc plein pour « Enregistrer », discret pour « Ignorer ». Repris par la capsule dépliée.
struct PromptButton: View {
    let title: String
    let primary: Bool
    let action: () -> Void
    @State private var hovered = false

    private var scale: CGFloat { Settings.uiScale }

    var body: some View {
        Text(title)
            .font(.system(size: 12 * scale, weight: .semibold))
            .foregroundStyle(primary ? Color.black : Color.white.opacity(hovered ? 1 : 0.8))
            .padding(.horizontal, 12 * scale)
            .padding(.vertical, 6 * scale)
            .background(Capsule().fill(primary ? Color.white.opacity(hovered ? 0.88 : 1) : Color.white.opacity(hovered ? 0.16 : 0.08)))
            .contentShape(Capsule())
            .onHover { hovered = $0 }
            .onTapGesture(perform: action)
            .animation(Motion.quick, value: hovered)
    }
}

/// Une seule proposition à la fois, retirée d'elle-même au bout de 2 min. Elle se déplie dans la capsule du
/// bouton flottant quand celle-ci est à l'écran (comme l'encoche de Wispr Flow) ; sinon, carte en haut à droite.
final class MeetingPrompt {
    var onRecord: (MeetingProposal) -> Void = { _ in }
    /// Capsule du bouton flottant, où la proposition se déplie quand elle est affichée.
    weak var notch: FloatingButton?

    private var panel: NSPanel?
    private(set) var current: MeetingProposal?
    private var hideWork: DispatchWorkItem?
    /// « Ignorer » met en sourdine visios et rendez-vous pendant 10 min (un rendez-vous ignoré ne revient pas
    /// sous forme de visio 20 s plus tard). Un appel reste proposé : il arrive sans prévenir.
    private var quietUntil = Date.distantPast

    func show(_ proposal: MeetingProposal) {
        if proposal != .call, Date() < quietUntil { return }
        if let current, current != proposal { notch?.collapse(only: .proposal(current)) }
        current = proposal
        panel?.orderOut(nil)
        panel = nil
        if let notch, notch.isShown {
            notch.notify(.proposal(proposal), seconds: nil)
        } else {
            showCard(proposal)
        }
        Feedback.proposal()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: work)
    }

    private func showCard(_ proposal: MeetingProposal) {
        let view = MeetingPromptView(proposal: proposal,
                                     onRecord: { [weak self] in self?.record() },
                                     onDismiss: { [weak self] in self?.dismiss() })
        let host = FirstClickHostingView(rootView: view)
        host.frame.size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = host
        place(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        self.panel = panel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.seconds(0.18)
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    /// Proposition en attente de réponse qui n'est pas déjà sur la carte en haut à droite : la capsule la redéplie
    /// quand une autre annonce ou une dictée lui a pris la place.
    var pending: MeetingProposal? { panel == nil ? current : nil }

    /// Le bouton flottant vient d'être masqué : la proposition en attente passe à la carte en haut à droite.
    func reroute() {
        guard let current, panel == nil else { return }
        showCard(current)
    }

    /// Retire la carte si elle concerne `source` (conversation terminée sans enregistrement).
    func end(_ source: String) {
        if current?.source == source { hide() }
    }

    func hide() {
        hideWork?.cancel()
        if let current { notch?.collapse(only: .proposal(current)) }
        current = nil
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Motion.seconds(0.2)
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    func record() {
        guard let proposal = current else { return }
        hide()
        onRecord(proposal)
    }

    func dismiss() {
        quietUntil = Date().addingTimeInterval(600)
        hide()
    }

    /// En haut à droite de l'écran où se trouve le pointeur, sous la barre des menus, là où macOS montre ses notifications.
    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 12))
    }
}
