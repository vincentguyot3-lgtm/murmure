import Carbon.HIToolbox
import Foundation

/// Raccourcis valables dans toutes les applications. Contrairement aux moniteurs d'événements de
/// `HotkeyMonitor`, ils sont retenus par Murmure et n'arrivent pas à l'application active.
final class GlobalShortcuts {
    static let shared = GlobalShortcuts()

    private var actions: [UInt32: () -> Void] = [:]
    private var references: [EventHotKeyRef] = []
    private var installed = false

    /// `modifiers` : combinaison de `cmdKey`, `optionKey`, `controlKey`, `shiftKey` (Carbon).
    func register(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        install()
        let id = UInt32(actions.count + 1)
        actions[id] = action
        var reference: EventHotKeyRef?
        let hotKey = EventHotKeyID(signature: OSType(0x4D52_4D52), id: id) // « MRMR »
        if RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKey, GetApplicationEventTarget(), 0, &reference) == noErr,
           let reference {
            references.append(reference)
        }
    }

    private func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            DispatchQueue.main.async { GlobalShortcuts.shared.actions[hotKey.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
