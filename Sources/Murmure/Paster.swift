import AppKit
import ApplicationServices

/// Colle le texte à l'emplacement du curseur dans l'application active, puis restaure le presse-papiers.
enum Paster {
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Le texte n'est mis dans le presse-papiers que sous forme de promesse : l'application qui colle
    /// vient le chercher. Si personne ne le demande (aucun champ actif, application qui refuse ⌘V),
    /// le collage a échoué : le texte reste alors dans le presse-papiers et `done(false)` est appelé.
    /// `pressReturn` : la touche Entrée suit le collage (« appuie sur entrée » dicté), pour envoyer un message.
    static func paste(_ text: String, pressReturn: Bool = false, done: ((Bool) -> Void)? = nil) {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        let promise = Promise(text)
        let item = NSPasteboardItem()
        item.setDataProvider(promise, forTypes: [.string])
        // Marque « confidentiel » respectée par les gestionnaires de presse-papiers (Maccy, Paste, Alfred…) :
        // une dictée n'entre pas dans leur historique, et ils ne consomment pas la promesse à la place du champ.
        item.setString("", forType: concealed)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        // Cmd+V. Le keycode 9 désigne la touche physique V, identique en AZERTY et QWERTY.
        press(9, flags: .maskCommand)
        if pressReturn { returnOnceDelivered(promise, attempts: 12) }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if promise.delivered {
                restore(saved, to: pasteboard)
                done?(true)
            } else {
                // Promesse non tenue : on remplace par le texte lui-même, pour un ⌘V manuel.
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                pasteboard.setString("", forType: concealed)
                done?(false)
            }
        }
    }

    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Touche Entrée seule (« Entrée » dicté sans autre texte).
    static func pressReturn() { press(36) }

    private static func press(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Entrée seulement une fois le texte remis à l'application : sinon on enverrait un message vide,
    /// ou l'on validerait autre chose. Puis un court délai, le temps que l'application l'insère.
    private static func returnOnceDelivered(_ promise: Promise, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if promise.delivered {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { press(36) }
            } else if attempts > 0 {
                returnOnceDelivered(promise, attempts: attempts - 1)
            }
        }
    }

    /// Met le texte dans le presse-papiers, sans coller.
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private final class Promise: NSObject, NSPasteboardItemDataProvider {
        let text: String
        private(set) var delivered = false
        init(_ text: String) { self.text = text }

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            delivered = true
            item.setString(text, forType: type)
        }
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type] = data }
            }
            return entry
        }
    }

    private static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        guard !saved.isEmpty else { return }
        pasteboard.clearContents()
        let items = saved.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
