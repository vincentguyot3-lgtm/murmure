import AppKit
import SwiftUI

// Composants maison qui remplacent les éléments natifs de macOS (menus, clic droit, dialogues,
// interrupteurs, sélecteurs) pour que toute l'application garde la même direction artistique.

// MARK: - Focus clavier

/// Anneau de focus clavier dessiné dans la direction artistique (trait `Theme.fg`), à la place de l'anneau
/// bleu de macOS. S'applique à un bouton ou à une vue rendue `focusable()` ; `inset` négatif pour dessiner
/// l'anneau autour du contrôle, positif pour le dessiner à l'intérieur (ligne d'une carte).
/// Comme sous macOS, l'anneau ne paraît que si le focus est venu du clavier (Tab) : un clic ne le montre pas.
private struct KeyboardFocusRing: ViewModifier {
    var radius: CGFloat
    var inset: CGFloat
    var color: Color
    @FocusState private var focused: Bool
    @State private var viaKeyboard = false

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .focusEffectDisabled()
            .onChange(of: focused) { _, now in
                viaKeyboard = now && NSApp.currentEvent?.type == .keyDown
            }
            .overlay {
                if focused && viaKeyboard {
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(color, lineWidth: 1.5)
                        .padding(inset)
                        .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    /// Anneau de focus clavier maison (voir `KeyboardFocusRing`).
    func keyboardFocusRing(radius: CGFloat = 7, inset: CGFloat = -3, color: Color = Theme.fg) -> some View {
        modifier(KeyboardFocusRing(radius: radius, inset: inset, color: color))
    }
}

/// Un bouton macOS ne réagit qu'à l'espace ; Murmure accepte aussi Entrée sur ses contrôles maison.
private struct ActivatesOnReturn: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content.onKeyPress(.return) {
            action()
            return .handled
        }
    }
}

extension View {
    func activatesOnReturn(_ action: @escaping () -> Void) -> some View { modifier(ActivatesOnReturn(action: action)) }
}

// MARK: - Menu flottant

struct MenuEntry: Identifiable {
    enum Kind { case action(() -> Void), header, divider }

    let id = UUID()
    var title = ""
    var symbol: String?
    var checked = false
    /// Pastille de couleur à la place du symbole (teinte d'un dossier).
    var tint: Color?
    var kind: Kind

    static func action(_ title: String, _ symbol: String? = nil, checked: Bool = false, tint: Color? = nil,
                       _ run: @escaping () -> Void) -> MenuEntry {
        MenuEntry(title: title, symbol: symbol, checked: checked, tint: tint, kind: .action(run))
    }

    static func header(_ title: String) -> MenuEntry { MenuEntry(title: title, kind: .header) }
    static var divider: MenuEntry { MenuEntry(kind: .divider) }
}

/// Ligne active d'un menu flottant, partagée entre la souris (survol) et le clavier (↑ ↓ Entrée).
final class MenuCursor: ObservableObject {
    @Published var id: UUID?
}

private struct MenuContent: View {
    let entries: [MenuEntry]
    let pick: (MenuEntry) -> Void
    @ObservedObject var cursor: MenuCursor
    @Namespace private var highlight

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(entries) { entry in
                switch entry.kind {
                case .divider:
                    Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 4)
                case .header:
                    Text(entry.title)
                        .font(.ui(11))
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 10)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                case .action:
                    let active = cursor.id == entry.id
                    HStack(spacing: 9) {
                        if let tint = entry.tint {
                            Circle().fill(tint).frame(width: 7, height: 7).frame(width: 16)
                        } else {
                            Image(systemName: entry.symbol ?? "circle")
                                .font(.ui(12))
                                .frame(width: 16)
                                .opacity(entry.symbol == nil ? 0 : 1)
                        }
                        Text(entry.title).lineLimit(1)
                        Spacer(minLength: 18)
                        if entry.checked { Image(systemName: "checkmark").font(.ui(11, weight: .semibold)) }
                    }
                    .font(.ui(13))
                    .foregroundStyle(active ? Theme.onInverse : Theme.fg)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background {
                        if active {
                            RoundedRectangle(cornerRadius: 6).fill(Theme.inverse)
                                .matchedGeometryEffect(id: "hover", in: highlight)
                        }
                    }
                    .contentShape(Rectangle())
                    // On ne vide pas le survol en quittant une ligne, seulement en quittant le menu :
                    // le surlignage glisse ainsi d'une ligne à l'autre au lieu de clignoter.
                    .onHover { inside in
                        if inside { withAnimation(Motion.quick) { cursor.id = entry.id } }
                    }
                    .onTapGesture { pick(entry) }
                }
            }
        }
        .padding(5)
        .frame(minWidth: 220)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onHover { inside in
            if !inside { withAnimation(Motion.quick) { cursor.id = nil } }
        }
    }
}

/// Vue d'hébergement qui accepte le premier clic : le menu (comme la carte de proposition ou la capsule
/// du bouton flottant) réagit sans devoir devenir la fenêtre active.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Menu déroulant dessiné par Murmure (et non par macOS), dans une petite fenêtre flottante.
final class FloatingMenu {
    static let shared = FloatingMenu()

    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var entries: [MenuEntry] = []
    private let cursor = MenuCursor()

    /// Sous l'élément `anchor` (coordonnées écran), aligné sur son bord droit.
    /// `fromKeyboard` : ouvert à l'espace ou à Entrée, la ligne active est posée d'emblée (l'option cochée, sinon la première).
    func show(_ entries: [MenuEntry], below anchor: NSRect, fromKeyboard: Bool = false) {
        present(entries, fromKeyboard: fromKeyboard) { size in NSPoint(x: anchor.maxX - size.width, y: anchor.minY - size.height - 4) }
    }

    /// Coin supérieur gauche au point donné (clic droit).
    func show(_ entries: [MenuEntry], at point: NSPoint) {
        present(entries) { size in NSPoint(x: point.x, y: point.y - size.height) }
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Motion.seconds(0.1)
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    private func move(_ step: Int) {
        let actions = entries.filter { if case .action = $0.kind { return true } else { return false } }
        guard !actions.isEmpty else { return }
        let index = actions.firstIndex { $0.id == cursor.id }
        let next = index.map { min(max($0 + step, 0), actions.count - 1) } ?? (step > 0 ? 0 : actions.count - 1)
        withAnimation(Motion.quick) { cursor.id = actions[next].id }
    }

    private func present(_ entries: [MenuEntry], fromKeyboard: Bool = false, origin: (NSSize) -> NSPoint) {
        close()
        self.entries = entries
        let actions = entries.filter { if case .action = $0.kind { return true } else { return false } }
        cursor.id = fromKeyboard ? (actions.first { $0.checked } ?? actions.first)?.id : nil
        let host = FirstClickHostingView(rootView: MenuContent(entries: entries, pick: { [weak self] entry in
            self?.close()
            if case .action(let run) = entry.kind { run() }
        }, cursor: cursor))
        let size = host.fittingSize
        var frame = NSRect(origin: origin(size), size: size)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(frame.origin) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            frame.origin.x = min(max(frame.origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            if frame.minY < visible.minY { frame.origin.y = min(visible.maxY - size.height, frame.maxY + size.height + 8) }
        }

        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.contentView = host
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.seconds(0.12)
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        // Se ferme au clic ailleurs, avec Échap, ou quand l'application passe en arrière-plan.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
            if event.window !== self?.panel { self?.close() }
            return event
        }) { monitors.append(monitor) }
        // Clavier : Échap ferme, ↑ ↓ déplacent la ligne active, Entrée la choisit.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 53:
                close()
                return nil
            case 125, 126:
                move(event.keyCode == 125 ? 1 : -1)
                return nil
            case 36, 76:
                guard let entry = self.entries.first(where: { $0.id == self.cursor.id }), case .action(let run) = entry.kind else { return event }
                close()
                run()
                return nil
            default:
                return event
            }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.close()
        }) { monitors.append(monitor) }
    }
}

/// Repère l'emplacement à l'écran d'une vue SwiftUI, pour y accrocher un menu.
final class ScreenAnchor {
    weak var view: NSView?

    var rect: NSRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

private struct AnchorView: NSViewRepresentable {
    let anchor: ScreenAnchor
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { anchor.view = nsView }
}

/// Bouton qui ouvre un menu flottant sous lui-même. Au clavier : tabulation pour l'atteindre (anneau de focus
/// maison), espace, Entrée ou ↓ pour ouvrir, puis ↑ ↓ Entrée Échap dans le menu.
struct MenuButton<Label: View>: View {
    let entries: () -> [MenuEntry]
    /// Rayon de l'anneau de focus, à accorder aux coins du libellé.
    var focusRadius: CGFloat = 7
    @ViewBuilder let label: () -> Label
    @State private var anchor = ScreenAnchor()

    var body: some View {
        Button(action: open) { label() }
            .buttonStyle(.plain)
            .keyboardFocusRing(radius: focusRadius)
            .activatesOnReturn(open)
            .onKeyPress(.downArrow) {
                open()
                return .handled
            }
            .background(AnchorView(anchor: anchor))
    }

    private func open() {
        guard let rect = anchor.rect else { return }
        // Le bouton activé au clavier (espace, Entrée, ↓) pose la ligne active ; à la souris, elle suit le survol.
        let fromKeyboard = NSApp.currentEvent.map { $0.type == .keyDown || $0.type == .keyUp } ?? false
        FloatingMenu.shared.show(entries(), below: rect, fromKeyboard: fromKeyboard)
    }
}

/// Zone qui intercepte uniquement le clic droit (et Ctrl-clic) ; les autres clics la traversent.
private struct RightClickArea: NSViewRepresentable {
    let action: () -> Void

    final class Catcher: NSView {
        var action: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let secondary = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return secondary ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) { action?() }
        override func mouseDown(with event: NSEvent) { action?() }
    }

    func makeNSView(context: Context) -> Catcher {
        let view = Catcher()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: Catcher, context: Context) { nsView.action = action }
}

extension View {
    /// Menu flottant au clic droit, à l'emplacement de la souris.
    func onRightClick(_ entries: @escaping () -> [MenuEntry]) -> some View {
        overlay(RightClickArea { FloatingMenu.shared.show(entries(), at: NSEvent.mouseLocation) })
    }
}

// MARK: - Dialogues

struct ModalRequest: Identifiable {
    let id = UUID()
    var title: String
    var message: String?
    /// Champ de saisie (texte indicatif, valeur initiale), ou nil pour une simple confirmation.
    var field: (placeholder: String, initial: String)?
    var confirm: String
    var onConfirm: (String) -> Void
    /// Appelé si le dialogue est refusé (Annuler, Échap, clic à côté).
    var onCancel: (() -> Void)? = nil
}

/// File unique des dialogues de l'application, affichés par `ModalHost` dans la fenêtre principale.
final class Modals: ObservableObject {
    static let shared = Modals()
    @Published var current: ModalRequest?
    /// Carte « À propos de Murmure », dessinée par l'app à la place du panneau standard de macOS.
    @Published var aboutShown = false

    func ask(_ title: String, message: String? = nil, placeholder: String, initial: String = "",
             confirm: String, then action: @escaping (String) -> Void) {
        current = ModalRequest(title: title, message: message, field: (placeholder, initial), confirm: confirm) { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { action(trimmed) }
        }
    }

    func confirm(_ title: String, message: String? = nil, confirm: String, cancel: (() -> Void)? = nil,
                 then action: @escaping () -> Void) {
        current = ModalRequest(title: title, message: message, field: nil, confirm: confirm, onConfirm: { _ in action() }, onCancel: cancel)
    }
}

struct ModalHost: View {
    @ObservedObject private var modals = Modals.shared
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            if let request = modals.current {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { dismiss(request) }
                    .transition(.opacity)
                card(request)
                    .transition(Motion.popTransition())
                    .onAppear {
                        text = request.field?.initial ?? ""
                        focused = request.field != nil
                    }
                    .id(request.id)
            }
            if modals.aboutShown {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { modals.aboutShown = false }
                    .transition(.opacity)
                AboutCard { modals.aboutShown = false }
                    .transition(Motion.popTransition())
            }
        }
        .animation(Motion.pop, value: modals.current?.id)
        .animation(Motion.pop, value: modals.aboutShown)
    }

    private func card(_ request: ModalRequest) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.title).font(.ui(16, weight: .semibold)).tracking(-0.2)
            if let message = request.message {
                Text(message).font(.ui(12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let field = request.field {
                TextField(field.placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.ui(13))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? Theme.fg : Theme.line))
                    .focused($focused)
                    .onSubmit { finish(request) }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Annuler") { dismiss(request) }
                    .buttonStyle(OutlineButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .keyboardFocusRing()
                Button(request.confirm) { finish(request) }
                    .buttonStyle(OutlineButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .keyboardFocusRing()
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 400)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
    }

    private func finish(_ request: ModalRequest) {
        modals.current = nil
        request.onConfirm(text)
    }

    private func dismiss(_ request: ModalRequest) {
        modals.current = nil
        request.onCancel?()
    }
}

/// « À propos » : logo, version, ce que fait l'app et avec quoi.
private struct AboutCard: View {
    /// Ce qui quitte le Mac : son des réunions (transcription en ligne), texte (Claude), ou rien.
    static var privacyLine: String {
        if Settings.stayOffline { return "Rester hors ligne : dictée et réunions sont transcrites et rédigées sur ce Mac. Rien ne quitte l'ordinateur." }
        switch (OnlineTranscription.isChosen && OnlineTranscription.hasKey, Cleaner.chosen == .claude && ClaudeAPI.hasKey) {
        case (false, false): return "Dictée et réunions, transcrites et rédigées sur ce Mac. Rien ne quitte l'ordinateur."
        case (false, true): return "Dictée et réunions, transcrites sur ce Mac : le son ne quitte jamais l'ordinateur. La rédaction est confiée à Claude, en ligne."
        case (true, false): return "Dictée transcrite sur ce Mac. Les réunions sont transcrites en ligne, sur un serveur européen ; la rédaction reste sur ce Mac."
        case (true, true): return "Dictée transcrite sur ce Mac. Les réunions sont transcrites en ligne, sur un serveur européen, et la rédaction est confiée à Claude, en ligne."
        }
    }

    let close: () -> Void

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return short.map { "Version \($0)" } ?? "Version de développement"
    }

    var body: some View {
        VStack(spacing: 12) {
            LogoMark(height: 44)
                .padding(.bottom, 4)
            Text("Murmure").font(.ui(20, weight: .semibold)).tracking(-0.3)
            Text(version).font(.ui(12)).foregroundStyle(Theme.muted)
            Text(Self.privacyLine)
                .font(.ui(12))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            HStack(spacing: 6) {
                Tag(text: "Transcription sur ce Mac")
                Tag(text: Cleaner.chosen == .claude ? "Rédaction par Claude" : "Rédaction sur ce Mac")
                Tag(text: "macOS 26")
            }
            .padding(.top, 6)
            Button("Fermer", action: close)
                .buttonStyle(OutlineButtonStyle())
                .keyboardShortcut(.cancelAction)
                .keyboardFocusRing()
                .padding(.top, 8)
        }
        .padding(26)
        .frame(width: 340)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
    }
}

// MARK: - Toast

struct ToastRequest: Identifiable {
    let id = UUID()
    var text: String
    var action: (title: String, run: () -> Void)?
}

/// Message bref en bas de la fenêtre, avec une action (« Annuler ») ; disparaît seul après quelques secondes.
final class Toasts: ObservableObject {
    static let shared = Toasts()
    @Published var current: ToastRequest?
    private var work: DispatchWorkItem?

    func show(_ text: String, action: (title: String, run: () -> Void)? = nil, seconds: Double = 5) {
        work?.cancel()
        let toast = ToastRequest(text: text, action: action)
        current = toast
        let item = DispatchWorkItem { [weak self] in
            if self?.current?.id == toast.id { self?.current = nil }
        }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func dismiss() {
        work?.cancel()
        current = nil
    }
}

struct ToastHost: View {
    @ObservedObject private var toasts = Toasts.shared

    var body: some View {
        VStack {
            Spacer()
            if let toast = toasts.current {
                HStack(spacing: 14) {
                    Text(toast.text).font(.ui(12, weight: .medium))
                    if let action = toast.action {
                        Button(action.title) {
                            toasts.dismiss()
                            action.run()
                        }
                        .buttonStyle(.plain)
                        .font(.ui(12, weight: .semibold))
                        .underline()
                        .keyboardFocusRing(radius: 4, inset: -4, color: Theme.onInverse)
                    }
                    Button { toasts.dismiss() } label: {
                        Image(systemName: "xmark").font(.ui(10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .keyboardFocusRing(radius: 4, inset: -4, color: Theme.onInverse)
                    .help("Fermer")
                }
                .foregroundStyle(Theme.onInverse)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(Theme.inverse))
                .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
                .padding(.bottom, 22)
                .transition(Motion.slideTransition(from: .bottom))
                .id(toast.id)
            }
        }
        .animation(Motion.pop, value: toasts.current?.id)
        .allowsHitTesting(toasts.current != nil)
    }
}

// MARK: - Indicateur d'attente

/// Anneau qui tourne, à la place de la roue native de macOS. Immobile quand les animations sont coupées.
struct Spinner: View {
    var size: CGFloat = 14
    var color: Color = Theme.fg
    var lineWidth: CGFloat = 1.6
    @State private var turning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .onAppear {
                guard let loop = Motion.loop(0.9, reduced: 1.4) else { return }
                withAnimation(loop) { turning = true }
            }
    }
}

/// Bouton « Copier » : l'icône devient une coche une seconde et demie.
struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            copy(text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
            .buttonStyle(OutlineButtonStyle())
            .keyboardFocusRing()
            .help("Copier")
    }
}

// MARK: - Contrôles

/// Interrupteur noir et blanc ; un bouton, donc accessible au clavier : tabulation pour l'atteindre
/// (anneau de focus maison), espace ou Entrée pour basculer.
struct MonoToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 12)
            Button(action: { flip(configuration) }) {
                Capsule()
                    .fill(configuration.isOn ? Theme.inverse : Theme.line)
                    .frame(width: 34, height: 20)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(configuration.isOn ? Theme.onInverse : Theme.muted).padding(3)
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardFocusRing(radius: 13)
            .activatesOnReturn { flip(configuration) }
        }
    }

    private func flip(_ configuration: Configuration) {
        withAnimation(Motion.quick) { configuration.isOn.toggle() }
    }
}

/// Sélecteur à segments ; l'option active, sur une pastille grise (`Theme.selected`, inversée en contraste renforcé),
/// glisse d'une option à l'autre.
/// `expands` : les segments se partagent toute la largeur disponible (onglets d'une page).
/// Au clavier : le sélecteur entier prend le focus (anneau maison), ← → changent l'option.
struct Choice<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var expands = false
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let active = option.value == selection
                Button { choose(option.value) } label: {
                    Text(option.label)
                        .font(.ui(12, weight: active ? .medium : .regular))
                        .frame(maxWidth: expands ? .infinity : nil)
                        .padding(.horizontal, 11)
                        .padding(.vertical, expands ? 6 : 5)
                        .foregroundStyle(active ? Theme.onSelected : Theme.muted)
                        .background {
                            if active {
                                RoundedRectangle(cornerRadius: 5).fill(Theme.selected)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false) // un seul arrêt de tabulation pour tout le sélecteur
            }
        }
        .padding(2)
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line))
        .fixedSize(horizontal: !expands, vertical: true)
        .focusable()
        .keyboardFocusRing(radius: 9)
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
    }

    private func choose(_ value: Value) {
        withAnimation(Motion.quick) { selection = value }
    }

    /// Option précédente ou suivante ; on s'arrête aux bords.
    private func step(_ delta: Int) -> KeyPress.Result {
        guard let index = options.firstIndex(where: { $0.value == selection }) else { return .ignored }
        let next = min(max(index + delta, 0), options.count - 1)
        guard next != index else { return .handled }
        choose(options[next].value)
        return .handled
    }
}

/// Onglets d'une page, en texte simple : libellés gris, l'actif en noir et medium, souligné d'un trait de 2 pt qui
/// glisse d'un onglet à l'autre, sur un filet qui court sur toute la largeur. Comme `Choice`, un seul arrêt de
/// tabulation (anneau maison) et ← → pour changer d'onglet ; pas de ⌘chiffre (pris par le menu Aller).
/// La rangée disparaît quand il n'y a qu'un onglet. `filet` faux : sans le filet (onglets de l'accueil, posés sur la
/// même ligne que la recherche) ; `ecart` : espace entre le libellé et son trait.
struct TextTabs<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var filet = true
    var ecart: CGFloat = 9
    @Namespace private var underline

    var body: some View {
        if options.count > 1 {
            HStack(spacing: 24 * Settings.uiScale) {
                ForEach(options, id: \.value) { option in
                    let active = option.value == selection
                    Button { choose(option.value) } label: {
                        // La largeur est réservée par le libellé en medium, caché dessous : le texte
                        // ne bouge pas quand l'onglet s'active, seul le trait glisse.
                        ZStack {
                            Text(option.label).font(.ui(13, weight: .medium)).hidden()
                            Text(option.label)
                                .font(.ui(13, weight: active ? .medium : .regular))
                                .foregroundStyle(active ? Theme.fg : Theme.muted)
                        }
                            .padding(.bottom, ecart)
                            .overlay(alignment: .bottom) {
                                if active {
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(Theme.fg)
                                        .frame(height: 2)
                                        .matchedGeometryEffect(id: "trait", in: underline)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false) // un seul arrêt de tabulation pour toute la rangée
                }
                Spacer(minLength: 0)
            }
            .background(alignment: .bottom) { if filet { Rectangle().fill(Theme.line).frame(height: 1) } }
            .focusable()
            .keyboardFocusRing(radius: 6, inset: -4)
            .onKeyPress(.leftArrow) { step(-1) }
            .onKeyPress(.rightArrow) { step(1) }
        }
    }

    private func choose(_ value: Value) {
        withAnimation(Motion.quick) { selection = value }
    }

    /// Onglet précédent ou suivant ; on s'arrête aux bords.
    private func step(_ delta: Int) -> KeyPress.Result {
        guard let index = options.firstIndex(where: { $0.value == selection }) else { return .ignored }
        let next = min(max(index + delta, 0), options.count - 1)
        guard next != index else { return .handled }
        choose(options[next].value)
        return .handled
    }
}

/// Liste déroulante (menu flottant) pour un choix parmi plusieurs options longues.
struct Dropdown<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        MenuButton {
            options.map { option in
                MenuEntry.action(option.label, checked: option.value == selection) { selection = option.value }
            }
        } label: {
            HStack(spacing: 6) {
                Text(options.first { $0.value == selection }?.label ?? "Choisir").lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.ui(9))
            }
            .font(.ui(12))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line))
            .contentShape(Rectangle())
        }
    }
}

// MARK: - Recherche dans les Réglages

/// Texte tapé dans « Rechercher un réglage », plié (minuscules, sans accents) ; vide quand on ne filtre pas.
private struct SettingsFilterKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    var settingsFilter: String {
        get { self[SettingsFilterKey.self] }
        set { self[SettingsFilterKey.self] = newValue }
    }
}

/// Nombre de lignes qui correspondent au filtre, remonté par les lignes à leur section, puis au panneau.
struct SettingsMatchKey: PreferenceKey {
    static var defaultValue = 0
    static func reduce(value: inout Int, nextValue: () -> Int) { value += nextValue() }
}

/// Minuscules sans accents, pour comparer une recherche à un libellé.
func foldedForSearch(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
}

/// Cache un bloc des Réglages quand aucune de ses lignes ne correspond au filtre ; si son titre correspond,
/// toutes ses lignes restent. Le bloc caché garde une hauteur nulle mais reste disposé, pour que ses lignes
/// continuent de remonter leur correspondance. Pendant une recherche, la pile parente n'a pas d'espacement :
/// c'est le bloc visible qui ajoute le sien (`spacing`) en dessous, un bloc caché n'en laisse donc aucun.
struct HidesWhenFiltered: ViewModifier {
    let title: String
    var spacing: CGFloat = 28
    @Environment(\.settingsFilter) private var filter
    @State private var matched = 0

    func body(content: Content) -> some View {
        let titleHit = !filter.isEmpty && foldedForSearch(title).contains(filter)
        let visible = filter.isEmpty || titleHit || matched > 0
        content
            .environment(\.settingsFilter, titleHit ? "" : filter)
            .onPreferenceChange(SettingsMatchKey.self) { matched = $0 }
            .frame(height: visible ? nil : 0, alignment: .top)
            .clipped()
            .padding(.bottom, visible && !filter.isEmpty ? spacing : 0)
            .opacity(visible ? 1 : 0)
            .accessibilityHidden(!visible)
    }
}

/// Bloc des pages Réglages et Dictionnaire : titre discret, carte à filets, note en dessous.
struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String?
    /// Faux quand le titre de la page dit déjà la même chose (page Extraits) : le titre sert encore au filtre.
    var showsTitle = true
    @ViewBuilder let content: Content
    /// Une note longue est repliée sur sa première ligne ; un chevron la déplie.
    @State private var expanded = false

    private var collapsible: Bool { (footer?.count ?? 0) > 120 }

    var body: some View {
        section.modifier(HidesWhenFiltered(title: title))
    }

    private var section: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsTitle {
                Text(title).font(.ui(12, weight: .medium)).foregroundStyle(Theme.muted)
            }
            VStack(spacing: 0) { content }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
            if let footer {
                if collapsible {
                    Button { withAnimation(Motion.quick) { expanded.toggle() } } label: {
                        HStack(alignment: .top, spacing: 6) {
                            Text(footer).font(.ui(11)).foregroundStyle(Theme.muted)
                                .lineLimit(expanded ? nil : 1)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.down")
                                .font(.ui(9, weight: .semibold)).foregroundStyle(Theme.muted)
                                .rotationEffect(.degrees(expanded ? 180 : 0))
                                .padding(.top, 3)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardFocusRing(radius: 5, inset: -4)
                    .activatesOnReturn { withAnimation(Motion.quick) { expanded.toggle() } }
                    .help(expanded ? "Replier" : "En savoir plus")
                } else {
                    Text(footer).font(.ui(11)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Ligne d'une `SettingsSection` : libellé à gauche, contrôle à droite, filet en dessous.
/// Pendant une recherche, la ligne disparaît si son libellé (ou ses `keywords`) ne correspond pas.
struct SettingsRow<Control: View>: View {
    let label: String
    var last = false
    var keywords = ""
    /// Pastille de couleur devant le libellé (agendas de la sous-page Agenda).
    var tint: Color?
    @ViewBuilder let control: Control
    @Environment(\.settingsFilter) private var filter

    @ViewBuilder var body: some View {
        if filter.isEmpty || foldedForSearch(label + " " + keywords).contains(filter) {
            HStack(spacing: 12) {
                if let tint {
                    Circle().fill(tint).frame(width: 8 * Settings.uiScale, height: 8 * Settings.uiScale)
                }
                Text(label).font(.ui(13))
                Spacer(minLength: 12)
                control
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) {
                if !last && filter.isEmpty { Rectangle().fill(Theme.line).frame(height: 1) }
            }
            .preference(key: SettingsMatchKey.self, value: 1)
        } else {
            Color.clear.frame(height: 0).preference(key: SettingsMatchKey.self, value: 0)
        }
    }
}

/// Ligne d'une `SettingsSection` qui ouvre une sous-page : libellé, valeur courante en gris, chevron.
struct SettingsLink: View {
    let label: String
    var value: String?
    var last = false
    let action: () -> Void
    @State private var hover = false
    @Environment(\.settingsFilter) private var filter

    @ViewBuilder var body: some View {
        if filter.isEmpty || foldedForSearch(label + " " + (value ?? "")).contains(filter) {
            link.preference(key: SettingsMatchKey.self, value: 1)
        } else {
            Color.clear.frame(height: 0).preference(key: SettingsMatchKey.self, value: 0)
        }
    }

    private var link: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(label).font(.ui(13)).foregroundStyle(Theme.fg)
                Spacer(minLength: 12)
                if let value {
                    Text(value).font(.ui(12)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.ui(10, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .offset(x: hover ? 2 : 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(hover ? Theme.soft : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardFocusRing(radius: 8, inset: 3) // à l'intérieur : la ligne est au bord de sa carte, qui rogne
        .activatesOnReturn(action)
        .onHover { inside in withAnimation(Motion.quick) { hover = inside } }
        .overlay(alignment: .bottom) {
            if !last && filter.isEmpty { Rectangle().fill(Theme.line).frame(height: 1) }
        }
    }
}

/// Carte repliée : un titre et un chevron qui tourne ; le contenu se déplie en dessous.
/// Pendant une recherche, elle s'ouvre d'elle-même sur les lignes qui correspondent.
struct Disclosure<Content: View>: View {
    let title: String
    var symbol: String?
    @ViewBuilder let content: Content
    @State private var expanded = false
    @Environment(\.settingsFilter) private var filter

    var body: some View {
        card.modifier(HidesWhenFiltered(title: title))
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(Motion.quick) { expanded.toggle() } } label: {
                HStack(spacing: 9) {
                    if let symbol { Image(systemName: symbol).font(.ui(12)).frame(width: 16) }
                    Text(title).font(.ui(13, weight: .medium))
                    Spacer(minLength: 12)
                    Image(systemName: "chevron.right")
                        .font(.ui(10, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardFocusRing(radius: 8, inset: 3)
            .activatesOnReturn { withAnimation(Motion.quick) { expanded.toggle() } }
            if expanded || !filter.isEmpty {
                VStack(spacing: 0) {
                    Rectangle().fill(Theme.line).frame(height: 1)
                    content
                }
                .transition(Motion.slideTransition(from: .top))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
    }
}

/// Coche qui apparaît une seconde à gauche d'un contrôle quand sa valeur change : la modification est prise.
private struct ChangeMark<Value: Equatable>: ViewModifier {
    let value: Value
    @State private var shown = false
    @State private var work: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .leading) {
                if shown {
                    Image(systemName: "checkmark")
                        .font(.ui(11, weight: .semibold))
                        .foregroundStyle(Theme.fg)
                        .offset(x: -22)
                        .transition(Motion.popTransition(scale: 0.6))
                }
            }
            .onChange(of: value) { _, _ in
                work?.cancel()
                withAnimation(Motion.quick) { shown = true }
                let item = DispatchWorkItem { withAnimation(Motion.quick) { shown = false } }
                work = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
            }
    }
}

extension View {
    /// Retour de modification : une coche brève quand `value` change.
    func confirmsChange<Value: Equatable>(of value: Value) -> some View { modifier(ChangeMark(value: value)) }
}

/// Carte d'erreur commune : le message et, quand l'action peut être relancée, « Réessayer ».
struct ErrorCard: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.ui(12, weight: .semibold))
            Text(message).font(.ui(12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let retry {
                Button("Réessayer", action: retry).buttonStyle(OutlineButtonStyle()).keyboardFocusRing()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.soft))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.fg))
    }
}

/// Panneaux de Réglages Système que Murmure ouvre pour l'utilisateur.
enum SystemSettings {
    enum Pane: String {
        case accessibility = "com.apple.preference.security?Privacy_Accessibility"
        case microphone = "com.apple.preference.security?Privacy_Microphone"
        case calendars = "com.apple.preference.security?Privacy_Calendars"
        case reminders = "com.apple.preference.security?Privacy_Reminders"
        case automation = "com.apple.preference.security?Privacy_Automation"
        case internetAccounts = "com.apple.Internet-Accounts-Settings.extension"
        /// Son › Entrée : choix du micro et volume d'entrée.
        case soundInput = "com.apple.Sound-Settings.extension?input"
    }

    static func open(_ pane: Pane) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:" + pane.rawValue)!)
    }

    /// Demande l'autorisation Accessibilité à macOS, puis ouvre le panneau où l'accorder.
    static func requestAccessibility() {
        Paster.requestAccessibility()
        open(.accessibility)
    }
}

/// Disposition en lignes qui passent à la ligne suivante quand la largeur manque (étiquettes).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
