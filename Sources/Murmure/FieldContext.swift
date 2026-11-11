import AppKit
@preconcurrency import ApplicationServices

/// Texte autour du curseur dans l'application où l'on dicte, lu par l'accessibilité au début de la dictée.
/// Il sert à mieux transcrire (amorce de Whisper, noms propres, mise en forme) puis à accorder le texte
/// collé à ce qui l'entoure (majuscule, espaces, point final). Il reste en mémoire le temps d'une dictée :
/// rien n'est enregistré, rien ne quitte le Mac.
struct FieldContext {
    var bundleID: String?
    /// Jusqu'à ~500 mots avant le curseur (ou avant la sélection).
    var before: String
    var selected: String
    /// Jusqu'à ~500 mots après.
    var after: String
    /// Titre de la fenêtre active (nom du document Word, objet du courriel…).
    var windowTitle = ""
    /// Textes visibles ailleurs dans la fenêtre : en-têtes d'un courriel, conversation, panneaux.
    var screen: [String] = []
    /// Faux quand seul l'écran a pu être lu : le collage n'est alors pas accordé.
    var fieldRead = true
    /// Champ lu et position (UTF-16) où le texte sera collé : de quoi relire ensuite ce que l'utilisateur corrige.
    var field: AXUIElement?
    var start = 0

    /// Caractères lus de chaque côté du curseur : environ 500 mots en français.
    static let span = 3_000

    var isEmpty: Bool { before.isEmpty && selected.isEmpty && after.isEmpty && windowTitle.isEmpty && screen.isEmpty }

    /// Ligne en cours, avant et après le curseur.
    var lineBefore: String { before.components(separatedBy: .newlines).last ?? "" }
    var lineAfter: String { after.components(separatedBy: .newlines).first ?? "" }

    // MARK: - Lecture par l'accessibilité

    /// Les lectures d'accessibilité se font hors du fil principal : une application occupée
    /// peut mettre jusqu'au délai maximal à répondre.
    private static let queue = DispatchQueue(label: "murmure.contexte", qos: .userInitiated)
    private static var prepared = Set<pid_t>()

    /// Electron et Chromium (Slack, Teams, Notion, VS Code…) n'exposent leur texte qu'à la demande.
    /// Demandé dès que l'application passe au premier plan, pour que l'arbre soit prêt à la dictée.
    static func prepare(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != getpid(), Paster.hasAccessibility else { return }
        queue.async {
            guard !prepared.contains(pid) else { return }
            prepared.insert(pid)
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.25)
            AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
    }

    /// Lit le champ de saisie actif de l'application, ou nil s'il n'y en a pas (ou si c'est un mot de passe).
    static func capture(_ app: NSRunningApplication) async -> FieldContext? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: read(app)) }
        }
    }

    private static func read(_ app: NSRunningApplication) -> FieldContext? {
        let pid = app.processIdentifier
        guard pid != getpid(), Paster.hasAccessibility else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        if !prepared.contains(pid) {
            prepared.insert(pid)
            AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        let window = element(application, kAXFocusedWindowAttribute)
        let field = element(application, kAXFocusedUIElementAttribute)
        if let field { AXUIElementSetMessagingTimeout(field, 0.25) }
        let role = field.flatMap { string($0, kAXRoleAttribute) }
        let subrole = field.flatMap { string($0, kAXSubroleAttribute) }
        // Jamais de mot de passe, ni dans le champ ni autour.
        guard role != "AXSecureTextField", subrole != "AXSecureTextField" else { return nil }

        var context = readField(field) ?? FieldContext(bundleID: nil, before: "", selected: "", after: "", fieldRead: false)
        context.bundleID = app.bundleIdentifier
        if let window {
            context.windowTitle = string(window, kAXTitleAttribute) ?? ""
            context.screen = visibleTexts(in: window, skipping: field)
        }
        return context.isEmpty ? nil : context
    }

    private static func readField(_ field: AXUIElement?) -> FieldContext? {
        guard let field, let selection = range(field, kAXSelectedTextRangeAttribute) else { return nil }

        let start = selection.location
        let end = selection.location + selection.length
        var before = "", selected = "", after = ""
        // Lecture ciblée autour du curseur : évite de rapatrier un long document Word en entier.
        if let total = number(field, kAXNumberOfCharactersAttribute),
           let head = text(field, CFRange(location: max(0, start - span), length: min(start, span))) {
            before = head
            if selection.length > 0 { selected = text(field, selection) ?? "" }
            after = text(field, CFRange(location: end, length: max(0, min(span, total - end)))) ?? ""
        } else if let value = string(field, kAXValueAttribute) {
            // Repli : valeur complète, découpée selon les positions UTF-16 de l'accessibilité.
            let whole = value as NSString
            let from = min(start, whole.length), to = min(end, whole.length)
            before = whole.substring(with: NSRange(location: max(0, from - span), length: from - max(0, from - span)))
            selected = whole.substring(with: NSRange(location: from, length: to - from))
            after = whole.substring(with: NSRange(location: to, length: min(span, whole.length - to)))
        } else {
            return nil
        }
        // Coupé à un mot entier aux extrémités lues.
        if start > span, let space = before.firstIndex(where: \.isWhitespace) { before = String(before[space...]) }
        if after.count >= span, let space = after.lastIndex(where: \.isWhitespace) { after = String(after[..<space]) }
        var context = FieldContext(bundleID: nil, before: before, selected: selected, after: after)
        context.field = field
        context.start = start
        return context
    }

    /// Relit un passage d'un champ (positions UTF-16), hors du fil principal.
    static func read(_ field: AXUIElement, location: Int, length: Int) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                let total = number(field, kAXNumberOfCharactersAttribute) ?? Int.max
                let from = max(0, min(location, total))
                let span = CFRange(location: from, length: max(0, min(length, total - from)))
                var result = text(field, span)
                if result == nil, let value = string(field, kAXValueAttribute) as NSString? {
                    let end = min(value.length, from + span.length)
                    result = from <= end ? value.substring(with: NSRange(location: from, length: end - from)) : nil
                }
                continuation.resume(returning: result)
            }
        }
    }

    /// Textes de la fenêtre hors du champ : parcours en largeur, borné en nombre d'éléments, en volume
    /// et en temps, pour ne jamais retarder la dictée. Les zones de saisie (le document lui-même) sont sautées.
    private static func visibleTexts(in window: AXUIElement, skipping field: AXUIElement?) -> [String] {
        let deadline = Date().addingTimeInterval(0.15)
        var queue = [window]
        var texts: [String] = []
        var visited = 0, volume = 0
        while !queue.isEmpty, visited < 2_500, volume < 30_000, Date() < deadline {
            let current = queue.removeFirst()
            visited += 1
            if let field, CFEqual(current, field) { continue }
            let role = string(current, kAXRoleAttribute) ?? ""
            if role == "AXTextArea" || role == "AXTextField" || role == "AXSecureTextField" { continue }
            for name in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                if let text = string(current, name)?.trimmingCharacters(in: .whitespacesAndNewlines), text.count >= 3 {
                    texts.append(text)
                    volume += text.count
                }
            }
            if let children = attribute(current, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        return texts
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private static func number(_ element: AXUIElement, _ name: String) -> Int? {
        (attribute(element, name) as? NSNumber)?.intValue
    }

    private static func range(_ element: AXUIElement, _ name: String) -> CFRange? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func text(_ element: AXUIElement, _ range: CFRange) -> String? {
        guard range.length > 0 else { return "" }
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value)
        guard status == .success else { return nil }
        return value as? String
    }

    // MARK: - Ce que le contexte apprend à la transcription

    /// Noms propres, sigles et termes à majuscule du contexte, les plus proches du curseur d'abord.
    /// Un mot en majuscule en début de phrase ne compte que s'il apparaît aussi en milieu de phrase.
    /// Viennent ensuite ceux du titre de la fenêtre, puis les plus fréquents du reste de l'écran.
    var terms: [String] {
        // L'ordre de lecture rapproche du curseur : fin du texte avant, puis début du texte après.
        let field = Self.notable(in: [selected, String(before.suffix(600)), String(after.prefix(600)), before, after])
        // Dans un titre, « AXO E-CAR - Réclamation contentieuse » : chaque segment commence une phrase,
        // sauf s'il s'ouvre sur deux mots à majuscule (« Kerdraon Fabrications ») : c'est alors un nom.
        let segments = windowTitle
            .replacingOccurrences(of: #"\.(docx?|pdf|pages|txt|rtf|eml|msg)\b"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+[-–—|·:]\s+|_+"#, with: "\u{1}", options: .regularExpression)
            .components(separatedBy: "\u{1}")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { segment -> String in
                let words = segment.split(separator: " ")
                return words.count >= 2 && words[1].first?.isUppercase == true ? "de " + segment : segment
            }
        var found = field
        let others = Self.notable(in: segments) + Self.notable(in: screen, byFrequency: true).prefix(25)
        for term in others where !found.contains(term) {
            found.append(term)
        }
        return Array(found.prefix(50))
    }

    /// Termes notables de textes, dans l'ordre d'apparition ou du plus fréquent au moins fréquent.
    static func notable(in texts: [String], byFrequency: Bool = false) -> [String] {
        let pattern = #"\p{L}[\p{L}\p{N}'’\-]*\p{L}|\p{Lu}\p{N}*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var found: [String] = []
        var counts: [String: Int] = [:]
        for text in texts {
            let ns = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let word = ns.substring(with: match.range)
                guard word.count >= 3, isNotable(word, at: match.range.location, in: ns) else { continue }
                if counts[word] == nil { found.append(word) }
                counts[word, default: 0] += 1
            }
        }
        guard byFrequency else { return found }
        return found.enumerated().sorted { (counts[$0.element]!, -$0.offset) > (counts[$1.element]!, -$1.offset) }.map(\.element)
    }

    private static let ordinaryCapitals: Set<String> = [
        "Monsieur", "Madame", "Mademoiselle", "Messieurs", "Mesdames", "Maître", "Cher", "Chère", "Chers",
        "Bonjour", "Cordialement", "Objet", "Article", "Le", "La", "Les", "Un", "Une", "Des", "Je", "Il", "Elle",
        "Nous", "Vous", "Ils", "Elles", "On", "Ce", "Cette", "Ces", "En", "Dans", "Pour", "Par", "Sur", "Si",
        "Mais", "Et", "Ou", "Donc", "Or", "Ni", "Car", "Que", "Qui", "Au", "Aux", "Du", "De", "À",
    ]

    private static func isNotable(_ word: String, at location: Int, in text: NSString) -> Bool {
        guard let first = word.first, first.isUppercase, !ordinaryCapitals.contains(word) else { return false }
        // Sigle (SCI, URSSAF) ou majuscule interne (LegalTech) : toujours retenu.
        if word.dropFirst().contains(where: \.isUppercase) { return true }
        // Sinon, seulement en milieu de phrase.
        var index = location - 1
        while index >= 0, let scalar = Unicode.Scalar(text.character(at: index)), CharacterSet.whitespaces.contains(scalar) {
            index -= 1
        }
        guard index >= 0, let previous = Unicode.Scalar(text.character(at: index)) else { return false }
        return !".!?…:\n\r«\"".unicodeScalars.contains(previous)
    }

    /// Fin du texte qui précède le curseur, pour amorcer Whisper : il poursuit alors la phrase
    /// dans le même registre, avec la même graphie des noms.
    func promptTail(characters: Int) -> String {
        let flat = before.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard flat.count > characters else { return flat }
        let tail = flat.suffix(characters)
        guard let space = tail.firstIndex(of: " ") else { return String(tail) }
        return String(tail[tail.index(after: space)...])
    }

    // MARK: - Collage accordé au texte voisin

    /// Messageries : un message court s'envoie sans point final.
    private static let messagingApps: Set<String> = [
        "com.apple.MobileSMS", "net.whatsapp.WhatsApp", "desktop.WhatsApp", "com.tinyspeck.slackmacgap",
        "com.microsoft.teams2", "com.microsoft.teams", "ru.keepcoder.Telegram", "com.tdesktop.Telegram",
        "org.whispersystems.signal-desktop", "com.facebook.archon", "com.hnc.Discord",
    ]

    /// Courriel : la formule d'appel dictée en tête de message passe sur sa propre ligne.
    private static let mailApps: Set<String> = [
        "com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.superhuman.electron",
    ]

    /// Formules qui gardent leur majuscule même en milieu de phrase dans un écrit d'avocat.
    private static let keptCapitals: Set<String> = ["Maître", "Me", "Monsieur", "Madame", "Mademoiselle", "Messieurs", "Mesdames"]

    /// Accorde le texte dicté à ce qui l'entoure : minuscule si l'on reprend une phrase en cours,
    /// pas de point final si la phrase continue après le curseur, espaces de part et d'autre,
    /// et pas de point final pour un message court dans une messagerie.
    func fit(_ dictated: String, properNouns: Set<String>) -> String {
        var text = dictated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard fieldRead, !text.isEmpty else { return dictated }
        let left = lineBefore
        let right = lineAfter
        let lastBefore = left.last(where: { !$0.isWhitespace })
        let firstAfter = right.first(where: { !$0.isWhitespace })

        // Début : reprise d'une phrase en cours (après une lettre, un chiffre, une virgule, deux-points…).
        if let lastBefore, lastBefore.isLetter || lastBefore.isNumber || ",;:(–—-".contains(lastBefore) {
            let firstWord = String(text.prefix(while: { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "'" || $0 == "’" }))
            // Sigle (SCI) ou référence (L145-41) : la majuscule fait partie du mot.
            let isAcronym = firstWord.count >= 2 && firstWord.allSatisfy { !$0.isLetter || $0.isUppercase }
            let isProper = properNouns.contains(firstWord) || Self.keptCapitals.contains(firstWord)
            if let first = text.first, first.isUppercase, !isAcronym, !isProper {
                text = first.lowercased() + text.dropFirst()
            }
        }

        // Fin : la phrase continue après le curseur, ou une ponctuation suit déjà.
        if let firstAfter, firstAfter.isLetter || firstAfter.isNumber || ",;:.)»".contains(firstAfter) {
            if text.hasSuffix("."), !text.hasSuffix("...") { text.removeLast() }
        }

        // Messagerie : message court, champ sans ponctuation finale, rien après le curseur.
        if let bundleID, Self.messagingApps.contains(bundleID), selected.isEmpty, firstAfter == nil,
           text.hasSuffix("."), !text.hasSuffix("...") {
            let sentences = text.split(whereSeparator: { ".!?".contains($0) }).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let fieldIsPunctuated = (before + after).contains(where: { ".!?".contains($0) })
            if sentences.count <= 2, !fieldIsPunctuated { text.removeLast() }
        }

        // Courriel commencé par la dictée : « Cher Confrère, je reviens… » → formule seule sur sa ligne,
        // puis une ligne vide. Seulement en tête de message (rien d'écrit avant le curseur).
        if let bundleID, Self.mailApps.contains(bundleID), before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let range = text.range(of: #"^(Madame|Monsieur|Maître|Mesdames|Messieurs|Cher|Chère|Chers|Chères|Bonjour|Bonsoir)[^,.!?\n]{0,60},\s*"#,
                                  options: .regularExpression),
           range.upperBound < text.endIndex {
            let greeting = text[range].trimmingCharacters(in: .whitespaces)
            var body = String(text[range.upperBound...])
            body = body.prefix(1).uppercased() + body.dropFirst()
            text = greeting + "\n\n" + body
        }

        // Espaces : une avant si l'on colle contre un mot, une après si un mot suit.
        if let last = left.last, !last.isWhitespace {
            if last == "«" { text = "\u{00A0}" + text } else if !"([{'’\"/-".contains(last) { text = " " + text }
        }
        if let next = right.first, next.isLetter || next.isNumber || "«(".contains(next) {
            text += " "
        }
        return text
    }
}
