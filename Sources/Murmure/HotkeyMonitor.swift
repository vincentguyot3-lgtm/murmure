import AppKit

/// Touches de dictée possibles : des touches de modification seules, qu'on peut maintenir sans rien taper.
enum DictationKey: String, CaseIterable {
    case rightOption, leftOption, rightCommand, rightControl, fn

    var label: String {
        switch self {
        case .rightOption: return "Option droite"
        case .leftOption: return "Option gauche"
        case .rightCommand: return "Commande droite"
        case .rightControl: return "Contrôle droite"
        case .fn: return "fn"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .rightOption: return 61
        case .leftOption: return 58
        case .rightCommand: return 54
        case .rightControl: return 62
        case .fn: return 63
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .rightOption, .leftOption: return .option
        case .rightCommand: return .command
        case .rightControl: return .control
        case .fn: return .function
        }
    }
}

/// Surveille la touche de dictée choisie dans les réglages (Option droite par défaut) :
/// - maintien : dictée tant que la touche est enfoncée ;
/// - appui bref : dictée verrouillée, un nouvel appui la termine ;
/// - Échap : annule ; toute autre touche pendant le maintien annule aussi (combinaison touche + lettre).
final class HotkeyMonitor {
    enum Event { case pressed, released(heldFor: TimeInterval), otherKey, escape }

    var onEvent: ((Event) -> Void)?
    /// Maj était enfoncée au moment de l'appui : la dictée est une consigne pour le texte sélectionné.
    private(set) var shiftAtPress = false
    /// Depuis combien de temps la touche est maintenue (0 si elle ne l'est pas).
    var heldSoFar: TimeInterval { isDown ? Date().timeIntervalSince(downAt) : 0 }

    private let escapeKeyCode: UInt16 = 53
    private var isDown = false
    private var downAt = Date()
    private var monitors: [Any] = []

    func start() {
        let flags: (NSEvent) -> Void = { [weak self] event in self?.handleFlags(event) }
        let keys: (NSEvent) -> Void = { [weak self] event in self?.handleKey(event) }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keys) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { flags($0); return $0 }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { keys($0); return $0 }) { monitors.append(m) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func handleFlags(_ event: NSEvent) {
        let key = Settings.dictationKey
        guard event.keyCode == key.keyCode else { return }
        let held = event.modifierFlags.contains(key.flag)
        if held && !isDown {
            isDown = true
            downAt = Date()
            shiftAtPress = event.modifierFlags.contains(.shift)
            onEvent?(.pressed)
        } else if !held && isDown {
            isDown = false
            onEvent?(.released(heldFor: Date().timeIntervalSince(downAt)))
        }
    }

    private func handleKey(_ event: NSEvent) {
        if event.keyCode == escapeKeyCode {
            onEvent?(.escape)
        } else if isDown {
            onEvent?(.otherKey)
        }
    }
}
