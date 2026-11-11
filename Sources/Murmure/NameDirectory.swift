import Contacts
import EventKit
import Foundation

/// Annuaire des noms : les personnes, sociétés et dossiers que l'utilisateur côtoie, réunis sans rien saisir
/// (Contacts du Mac, invités et titres des rendez-vous de l'année, dossiers et réunions de Murmure, dictionnaire).
///
/// Whisper déforme les noms rares (« Baligaux » entendu « Bali go », « Lefebvre » écrit « Lefèvre ») et Claude ne
/// peut les rétablir que s'il en connaît la graphie. L'annuaire entier serait trop long à lui donner à chaque
/// dictée : une clé phonétique française rapproche, sur le Mac, les passages entendus des noms de l'annuaire qui
/// sonnent pareil, et seuls ces quelques noms accompagnent la dictée (`candidates`). Claude choisit d'après le sens.
final class NameDirectory: @unchecked Sendable {
    static let shared = NameDirectory()
    /// Publiée après chaque reconstruction (réglages : nombre de noms).
    static let changed = Notification.Name("murmure.annuaire")

    /// D'où vient un nom ; l'ordre sert à départager deux graphies qui sonnent pareil (le dictionnaire d'abord).
    enum Source: Int, Comparable {
        case lexicon, contact, calendar, meeting, folder
        static func < (a: Source, b: Source) -> Bool { a.rawValue < b.rawValue }
    }

    struct Entry {
        let name: String
        let source: Source
        /// Nombre d'apparitions (rendez-vous, réunions) : un nom fréquent passe devant un nom croisé une fois.
        var weight: Int
    }

    /// Un nom de l'annuaire qui sonne comme un passage de la dictée.
    struct Candidate: Equatable {
        let heard: String
        /// Graphie proposée : le nom complet s'il sonne comme le passage entier, sinon le seul mot qui lui ressemble
        /// (« Baligaux » et non chacune des fiches qui portent ce nom).
        let name: String
        /// Distance entre les clés phonétiques (0 : même son).
        let distance: Int
    }

    /// Une graphie indexée : un nom complet, ou un mot rare d'un nom, avec le poids cumulé des fiches qui la portent.
    private struct Indexed {
        let key: [UInt8]
        let display: String
        /// Graphie repliée (sans accents ni espaces) : un passage déjà écrit ainsi n'est pas proposé.
        let spelled: String
        var weight: Int
        var source: Source
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    /// Clés indexées par longueur, pour ne comparer que des clés de longueur voisine.
    private var byLength: [Int: [Indexed]] = [:]
    private var lastQuery: (text: String, result: [Candidate])?
    /// Graphies repliées des noms complets (deux mots ou plus) et des mots rares des noms : un passage déjà écrit
    /// ainsi est un nom de l'annuaire.
    private var knownNames = Set<String>()
    private var knownWords = Set<String>()
    private var commonCache: [String: Bool] = [:]
    private let queue = DispatchQueue(label: "murmure.annuaire", qos: .utility)
    private var timer: Timer?

    /// Nombre de noms connus, par source (réglages).
    var counts: [Source: Int] { lock.lock(); defer { lock.unlock() }; return sourceCounts }
    private var sourceCounts: [Source: Int] = [:]

    // MARK: - Ce que la dictée en tire

    /// Graphies de l'annuaire qui sonnent comme un passage de `text` (un à trois mots consécutifs). Au plus `limit`,
    /// les plus proches d'abord ; trois au plus pour un même passage. Règles qui écartent le bruit :
    /// - un passage ne contient ni civilité ni abréviation (« M. », « Maître »), ni pronom, verbe ou mot-outil
    ///   (« matin il ») ; une particule (« de », « le ») ne le termine pas ;
    /// - un passage fait seulement de mots courants (« deux mois », « partie ») ne rapproche que des noms de même son ;
    /// - un nom complet de l'annuaire déjà écrit tel quel (« Anne-Sophie Desmarais ») n'est pas touché ; un nom de
    ///   famille de l'annuaire déjà écrit (« Lefebvre ») ne l'est que par un nom complet (« Matthieu Lefebvre ») ;
    /// - un nom complet rapproché couvre les mots qu'il contient : on ne propose pas en plus chacun d'eux.
    func candidates(for text: String, limit: Int = 12) -> [Candidate] {
        guard Settings.useNameDirectory else { return [] }
        lock.lock()
        if let lastQuery, lastQuery.text == text { lock.unlock(); return lastQuery.result }
        let byLength = byLength, knownNames = knownNames, knownWords = knownWords
        lock.unlock()
        guard !byLength.isEmpty else { return [] }

        let words = Self.words(text)
        let folded = words.map(Self.fold)
        var fullyKnown = Set<Int>(), knownWord = Set<Int>()
        for start in words.indices {
            if knownWords.contains(folded[start]) { knownWord.insert(start) }
            for span in 2...4 where start + span <= words.count && knownNames.contains(folded[start..<start + span].joined()) {
                fullyKnown.formUnion(start..<start + span)
            }
        }
        var best: [String: (candidate: Candidate, start: Int, span: Int, item: Indexed)] = [:]
        for start in words.indices {
            for span in 1...3 where start + span <= words.count {
                let range = start..<start + span
                let gram = words[range]
                let spelled = folded[range].joined()
                guard spelled.count >= 4, !range.contains(where: fullyKnown.contains),
                      !gram.contains(where: { $0.contains(where: \.isNumber) }),
                      !range.contains(where: { Self.excluded.contains(folded[$0]) || words[$0].count < 2 }),
                      !Self.particles.contains(folded[start + span - 1]) else { continue }
                let holdsKnownWord = range.contains(where: knownWord.contains)
                if holdsKnownWord, span == 1 { continue }
                let key = Self.key(gram.joined(separator: " "))
                guard key.count >= 3 else { continue }
                let allowed = range.allSatisfy({ isCommon(words[$0]) }) ? 0 : Self.allowedDistance(key.count)
                for length in max(1, key.count - allowed)...(key.count + allowed) {
                    for item in byLength[length] ?? [] {
                        let bound = min(allowed, Self.allowedDistance(item.key.count))
                        guard item.spelled != spelled, !holdsKnownWord || item.display.contains(" "),
                              let distance = Self.distance(key, item.key, bound: bound) else { continue }
                        let candidate = Candidate(heard: gram.joined(separator: " "), name: item.display, distance: distance)
                        if let current = best[item.display],
                           (current.candidate.distance, -current.span) <= (distance, -span) { continue }
                        best[item.display] = (candidate, start, span, item)
                    }
                }
                // Fin de nom mal entendue (« Bouchareb » écrit « Bouchardet ») : un mot rare à majuscule dont tous les
                // sons ouvrent un nom un peu plus long de l'annuaire lui est rapproché, au dernier rang.
                guard span == 1, key.count >= 5, gram.first?.first?.isUppercase == true, !isCommon(gram.first!) else { continue }
                let worst = Self.allowedDistance(key.count) + 1
                for length in (key.count + 1)...(key.count + 3) {
                    for item in byLength[length] ?? [] where item.key.starts(with: key) && item.spelled != spelled
                        && !holdsKnownWord && best[item.display] == nil {
                        best[item.display] = (Candidate(heard: gram.joined(separator: " "), name: item.display, distance: worst), start, span, item)
                    }
                }
            }
        }
        let ranked = best.values.sorted { a, b in
            if a.candidate.distance != b.candidate.distance { return a.candidate.distance < b.candidate.distance }
            if a.span != b.span { return a.span > b.span }
            if (a.item.source == .lexicon) != (b.item.source == .lexicon) { return a.item.source == .lexicon }
            if a.item.weight != b.item.weight { return a.item.weight > b.item.weight }
            if a.item.source != b.item.source { return a.item.source < b.item.source }
            return a.item.display < b.item.display
        }
        var perHeard: [String: Int] = [:]
        var covered: [(range: Range<Int>, distance: Int)] = []
        var result: [Candidate] = []
        for value in ranked where result.count < limit {
            let range = value.start..<value.start + value.span
            if covered.contains(where: { $0.range.count > range.count && $0.range.contains(range.lowerBound)
                                         && $0.range.contains(range.upperBound - 1) && $0.distance <= value.candidate.distance }) { continue }
            let heard = value.candidate.heard.lowercased()
            guard perHeard[heard, default: 0] < 3 else { continue }
            perHeard[heard, default: 0] += 1
            result.append(value.candidate)
            if value.span >= 2, value.item.display.contains(where: { $0 == " " || $0 == "-" }) { covered.append((range, value.candidate.distance)) }
        }
        lock.lock(); lastQuery = (text, result); lock.unlock()
        return result
    }

    /// Mot courant du français : le correcteur l'accepte en minuscules et avec sa majuscule, et l'utilisateur ne l'a
    /// pas appris comme un nom. Le correcteur accepte « baligaux » (qu'il prend pour un pluriel) mais refuse
    /// « Baligaux », et accepte « Lefebvre » mais refuse « lefebvre » : il faut les deux formes.
    private func isCommon(_ word: String) -> Bool {
        let lower = word.lowercased()
        lock.lock()
        if let known = commonCache[lower] { lock.unlock(); return known }
        lock.unlock()
        let capitalized = lower.prefix(1).uppercased() + lower.dropFirst()
        let common = Cleaner.isFrenchWord(lower) && Cleaner.isFrenchWord(capitalized) && !Cleaner.isLearnedWord(capitalized)
        lock.lock(); commonCache[lower] = common; lock.unlock()
        return common
    }

    /// Mots qui n'entrent dans aucun passage rapproché : civilités et abréviations (indices d'un nom, pas des noms),
    /// pronoms, auxiliaires et mots-outils.
    private static let excluded: Set<String> = [
        "m", "mme", "mlle", "me", "dr", "maitre", "monsieur", "madame", "mademoiselle", "messieurs", "mesdames",
        "docteur", "societe", "cabinet", "confrere", "consoeur",
        "il", "ils", "elle", "elles", "on", "je", "j", "tu", "nous", "vous", "te", "se", "ce", "ca", "cela", "lui", "leur",
        "que", "qu", "qui", "quoi", "dont", "et", "ou", "a", "au", "aux", "en", "un", "une", "est", "sont", "ai", "as",
        "avons", "avez", "ont", "eu", "ete", "etait", "ne", "n", "pas", "plus", "y", "l", "d", "s", "c", "mais", "donc",
        "or", "ni", "car", "pour", "par", "sur", "dans", "avec", "chez", "sans", "sous", "vers", "mon", "ma", "mes",
        "ton", "ta", "tes", "son", "sa", "ses", "notre", "votre", "nos", "vos", "leurs", "cet", "cette", "ces", "si",
    ]

    func hasCandidates(_ text: String) -> Bool { !candidates(for: text).isEmpty }

    // MARK: - Constitution

    /// Reconstruit l'annuaire maintenant, puis toutes les heures. À appeler au lancement de l'application.
    @MainActor
    func start() {
        refresh()
        // Les Contacts sont la meilleure source de noms : macOS demande l'accès une seule fois ; ensuite, Réglages ›
        // Dictionnaire › Annuaire des noms renvoie aux réglages du Mac.
        if Settings.useNameDirectory, !Self.contactsAsked { Self.requestContacts { _ in } }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Relit les sources et remplace l'annuaire (hors du fil principal).
    @MainActor
    func refresh(done: (@Sendable () -> Void)? = nil) {
        let store = RecordingStore.shared
        let folders = store.folders.map(\.name)
        var people: [String] = []
        for recording in store.recordings where !recording.isTrashed {
            people += (recording.attendees ?? []).filter { !$0.isMe }.map(\.name)
            people += (recording.speakerNames ?? [:]).values.filter {
                $0.compare("Moi", options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
            }
        }
        let terms = Lexicon.shared.snapshot().terms
        let useCalendar = Settings.useCalendar
        queue.async { [self] in
            var names: [(String, Source)] = []
            names += Self.contacts().map { ($0, .contact) }
            let calendar = useCalendar ? Self.calendarNames() : []
            names += calendar.map { ($0, .calendar) }
            names += people.map { ($0, .meeting) }
            names += folders.map { ($0, .folder) }
            names += terms.map { ($0, .lexicon) }
            load(names)
            done?()
        }
    }

    /// Remplace l'annuaire par ces noms (sert aussi au banc d'essai).
    func load(_ names: [(String, Source)]) {
        var entries: [Entry] = []
        var positions: [String: Int] = [:]
        for (raw, source) in names {
            guard let name = Self.normalized(raw) else { continue }
            let id = Self.fold(name)
            if let index = positions[id] {
                entries[index].weight += 1
                continue
            }
            positions[id] = entries.count
            entries.append(Entry(name: name, source: source, weight: 1))
        }
        // Une même graphie (« Baligaux ») portée par plusieurs fiches n'est indexée qu'une fois, avec leur poids cumulé.
        var indexed: [String: Indexed] = [:]
        for entry in entries {
            func add(_ text: String) {
                let key = Self.key(text)
                guard key.count >= 3 else { return }
                let spelled = Self.fold(text)
                if var item = indexed[spelled] {
                    item.weight += entry.weight
                    item.source = min(item.source, entry.source)
                    indexed[spelled] = item
                } else {
                    indexed[spelled] = Indexed(key: key, display: text, spelled: spelled, weight: entry.weight, source: entry.source)
                }
            }
            add(entry.name)
            // Chaque mot du nom (« Roux-Combaluzier », puis « Combaluzier »), sauf les particules et les mots du
            // français (« Invest », « Conseil », « Martin » : un homonyme de mot courant est écrit correctement par
            // Whisper, et le proposer partout serait du bruit ; voir `isCommon`).
            let spaced = entry.name.split(separator: " ").map(String.init)
            var parts = spaced.count > 1 ? spaced : []
            for word in spaced where word.contains("-") { parts += word.split(separator: "-").map(String.init) }
            for part in parts where Self.fold(part).count >= 3 && !Self.particles.contains(part.lowercased()) {
                if !isCommon(part) { add(part) }
            }
        }
        var byLength: [Int: [Indexed]] = [:]
        for item in indexed.values { byLength[item.key.count, default: []].append(item) }
        var knownNames = Set<String>(), knownWords = Set<String>()
        for entry in entries where entry.name.contains(where: { $0 == " " || $0 == "-" }) { knownNames.insert(Self.fold(entry.name)) }
        for item in indexed.values where !item.display.contains(" ") && item.spelled.count >= 4 { knownWords.insert(item.spelled) }
        var counts: [Source: Int] = [:]
        for entry in entries { counts[entry.source, default: 0] += 1 }
        lock.lock()
        self.entries = entries
        self.byLength = byLength
        self.knownNames = knownNames
        self.knownWords = knownWords
        self.sourceCounts = counts
        lastQuery = nil
        lock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) }
        Cleaner.debug("annuaire : \(entries.count) noms (\(byLength.values.map(\.count).reduce(0, +)) clés)")
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    private static let particles: Set<String> = ["de", "du", "des", "le", "la", "les", "van", "von", "der", "den", "di", "da", "del", "et"]

    // MARK: Contacts

    static var contactsAuthorized: Bool { CNContactStore.authorizationStatus(for: .contacts) == .authorized }
    static var contactsAsked: Bool { CNContactStore.authorizationStatus(for: .contacts) != .notDetermined }

    /// Demande l'accès aux Contacts (une fois ; ensuite, Réglages Système › Confidentialité › Contacts).
    static func requestContacts(_ done: @escaping @Sendable (Bool) -> Void) {
        CNContactStore().requestAccess(for: .contacts) { granted, _ in
            DispatchQueue.main.async {
                done(granted)
                if granted { MainActor.assumeIsolated { shared.refresh() } }
            }
        }
    }

    /// « Prénom Nom » et société de chaque fiche des Contacts.
    private static func contacts() -> [String] {
        guard contactsAuthorized else { return [] }
        let keys = [CNContactGivenNameKey, CNContactMiddleNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey] as [CNKeyDescriptor]
        var names: [String] = []
        try? CNContactStore().enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
            let person = [contact.givenName, contact.middleName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            if !person.isEmpty { names.append(person) }
            if !contact.organizationName.isEmpty { names.append(contact.organizationName) }
        }
        return names
    }

    // MARK: Agenda

    /// Invités et noms des titres des rendez-vous, d'un an en arrière à trois mois devant.
    private static func calendarNames() -> [String] {
        let now = Date()
        let events = Connectors.events(from: now.addingTimeInterval(-365 * 86_400), to: now.addingTimeInterval(90 * 86_400))
        var all: [String] = []
        for event in events {
            all += ((event.attendees ?? []) + [event.organizer].compactMap { $0 }).filter { !$0.isCurrentUser }.compactMap { participant -> String? in
                guard let name = participant.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty, !name.contains("@") else { return nil }
                return name
            }
            all += titleNames(event.title ?? "")
        }
        return all
    }

    /// Noms d'un titre de rendez-vous : suites de mots à majuscule qui ne sont ni des mots du français ni des
    /// sigles courts (« RDV Kervoalen Invest - conclusions » → « Kervoalen Invest »).
    static func titleNames(_ title: String) -> [String] {
        var runs: [String] = [], run: [String] = []
        func close() { if !run.isEmpty { runs.append(run.joined(separator: " ")) }; run = [] }
        for raw in title.split(whereSeparator: { $0.isWhitespace || "-–—|/:,;()[]«»\"".contains($0) }) {
            let word = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: ".'’"))
            let isAcronym = word == word.uppercased() && word.count <= 4
            guard word.count >= 3, word.first?.isUppercase == true, !isAcronym, !word.contains(where: \.isNumber),
                  !Cleaner.isFrenchWord(word.lowercased()) else { close(); continue }
            run.append(word)
        }
        close()
        return runs
    }

    // MARK: - Clé phonétique

    /// Nom présentable : espaces resserrés, mot tout en capitales remis en minuscules avec une initiale (« DUPONT Jean »
    /// → « Dupont Jean ») sauf les sigles courts ; nil pour une adresse, un numéro ou un nom trop court.
    static func normalized(_ raw: String) -> String? {
        let words = raw.split(whereSeparator: \.isWhitespace).map { word -> String in
            let text = String(word)
            let letters = text.filter(\.isLetter)
            guard letters.count >= 5, text == text.uppercased(), text != text.lowercased() else { return text }
            return text.split(separator: "-").map { $0.prefix(1) + $0.dropFirst().lowercased() }.joined(separator: "-")
        }
        let name = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard name.filter(\.isLetter).count >= 3, !name.contains("@"), name.filter(\.isNumber).count < 3 else { return nil }
        return name
    }

    /// Mots d'un texte (lettres, apostrophes et traits d'union retirés en bordure).
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Minuscules sans accents ni séparateurs : « Anne-Sophie Lefèvre » → « annesophielefevre ».
    static func fold(_ text: String) -> String {
        text.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr_FR")).filter(\.isLetter)
    }

    /// Clé phonétique française d'un mot ou d'une suite de mots, mots accolés : deux graphies qui se prononcent
    /// pareil ont la même clé (« Lefebvre » et « Lefèvre », « Baligaux » et « Bali go », « Thibault » et « Thibaut »).
    static func key(_ text: String) -> [UInt8] {
        let lowered = text.lowercased().replacingOccurrences(of: "ç", with: "s").replacingOccurrences(of: "œ", with: "oe")
            .replacingOccurrences(of: "æ", with: "e")
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr_FR"))
        var key: [UInt8] = []
        for word in lowered.split(whereSeparator: { !$0.isLetter }) {
            let ascii = word.unicodeScalars.filter { $0.isASCII && CharacterSet.lowercaseLetters.contains($0) }
            key += wordKey(String(String.UnicodeScalarView(ascii)))
        }
        // Les mots accolés peuvent former une lettre double (« Bali » + « io ») : resserrée.
        return collapse(key)
    }

    /// Règles appliquées dans l'ordre à un mot en minuscules sans accents. Majuscules : sons notés d'une lettre
    /// (S = ch, A = an, I = in, O = on). « eu » se confond avec « e » : Whisper les échange (« Quéméneur », « Kémener »).
    private static let rules: [(NSRegularExpression, String)] = [
        (#"(.)\1"#, "$1"),
        (#"szcz|sz"#, "S"), (#"cz|ci(?=[aeou])"#, "tS"), (#"ae"#, "e"),
        (#"ch(?=[rl])"#, "k"), (#"sch|sh|ch"#, "S"),
        (#"ph"#, "f"), (#"th"#, "t"), (#"gh"#, "g"), (#"rh"#, "r"),
        (#"gn"#, "n"),
        (#"cq|ck|qu|q"#, "k"),
        (#"gu(?=[eiy])"#, "G"), (#"ge(?=[aou])"#, "j"), (#"g(?=[eiy])"#, "j"),
        (#"c(?=[eiy])"#, "s"), (#"c"#, "k"),
        (#"ault$"#, "o"), (#"eaux$|aux$|eau|au"#, "o"),
        (#"x$"#, ""), (#"x"#, "ks"),
        (#"w"#, "v"), (#"z"#, "s"), (#"y"#, "i"), (#"h"#, ""),
        (#"oeu|eu|oe"#, "e"),
        (#"oi"#, "oa"), (#"ou"#, "u"),
        (#"ien(?=[^aeiou]|$)"#, "iI"),
        (#"(ain|ein|aim|in|im|un|um)(?=[^aeiou]|$)"#, "I"),
        (#"(an|am|en|em)(?=[^aeiou]|$)"#, "A"),
        (#"(on|om)(?=[^aeiou]|$)"#, "O"),
        (#"ai|ei"#, "e"),
        (#"bv"#, "v"),
        (#"(er|et|ez)$"#, "e"),
        (#"(?<=.{2})e$"#, ""), (#"(?<=.{2})[tdspx]+$"#, ""), (#"(?<=.{2})e$"#, ""),
        (#"G"#, "g"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    private static func wordKey(_ word: String) -> [UInt8] {
        var text = word
        for (regex, template) in rules {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
        return collapse(Array(text.utf8))
    }

    private static func collapse(_ key: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        for byte in key where result.last != byte { result.append(byte) }
        return result
    }

    /// Écart toléré entre deux clés selon leur longueur : aucun en dessous de cinq sons, un jusqu'à sept, deux au-delà.
    static func allowedDistance(_ length: Int) -> Int { length <= 4 ? 0 : length <= 7 ? 1 : 2 }

    /// Distance d'édition entre deux clés, nil si elle dépasse `bound`.
    static func distance(_ a: [UInt8], _ b: [UInt8], bound: Int) -> Int? {
        guard abs(a.count - b.count) <= bound else { return nil }
        if a == b { return 0 }
        let nasals: Set<UInt8> = [UInt8(ascii: "A"), UInt8(ascii: "I"), UInt8(ascii: "O")]
        if a.count == b.count, zip(a, b).allSatisfy({ $0 == $1 || (nasals.contains($0) && nasals.contains($1)) }) { return 0 }
        guard bound > 0 else { return nil }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowMin = i
            for j in 1...b.count {
                // Whisper confond les voyelles nasales (« Guéguen » entendu « Gaigain ») : les échanger ne coûte rien.
                let cost = a[i - 1] == b[j - 1] || (nasals.contains(a[i - 1]) && nasals.contains(b[j - 1])) ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowMin = min(rowMin, current[j])
            }
            guard rowMin <= bound else { return nil }
            swap(&previous, &current)
        }
        return previous[b.count] <= bound ? previous[b.count] : nil
    }
}
