import FluidAudio
import Foundation

/// Empreinte d'une voix : moyenne normalisée des empreintes (256 nombres) que le module de distinction des voix
/// calcule sur chaque tranche de 10 s où elle parle, et durée de parole entendue. Deux empreintes d'une même
/// personne sont proches (similarité cosinus élevée), même d'une réunion à l'autre ; celles de deux personnes
/// différentes le sont moins. Rien de l'audio ne peut en être reconstitué.
struct Voiceprint: Codable, Hashable, Sendable {
    var vector: [Float]
    var seconds: Double

    /// Similarité cosinus (de -1 à 1) entre deux empreintes normalisées.
    func similarity(_ other: [Float]) -> Float {
        guard vector.count == other.count else { return -1 }
        var dot: Float = 0
        for i in vector.indices { dot += vector[i] * other[i] }
        return dot
    }

    /// Moyenne pondérée de vecteurs, normalisée (longueur 1). Vide si rien à moyenner.
    static func mean(_ items: [(vector: [Float], weight: Double)]) -> [Float] {
        guard let size = items.first(where: { !$0.vector.isEmpty })?.vector.count else { return [] }
        var sum = [Float](repeating: 0, count: size)
        for item in items where item.vector.count == size && item.weight > 0 {
            for i in 0..<size { sum[i] += item.vector[i] * Float(item.weight) }
        }
        let norm = sqrt(sum.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return [] }
        return sum.map { $0 / norm }
    }

    /// Empreinte de chaque voix d'une réunion : moyenne des empreintes de ses tranches, chacune pesée par le temps
    /// où cette voix y parle (une tranche où elle ne dit que « oui » compte peu). Durée : ses plages de parole.
    static func byVoice(chunks: [ChunkEmbedding], spans: [Transcriber.VoiceSpan]) -> [String: Voiceprint] {
        var items: [String: [(vector: [Float], weight: Double)]] = [:]
        for chunk in chunks where !chunk.embedding256.isEmpty {
            var spoken = 0.0
            for span in spans where span.voice == chunk.speakerId {
                spoken += max(0, min(Double(span.end), chunk.endTimeSeconds) - max(Double(span.start), chunk.startTimeSeconds))
            }
            guard spoken > 0.3 else { continue }
            items[chunk.speakerId, default: []].append((chunk.embedding256, spoken))
        }
        var result: [String: Voiceprint] = [:]
        for (voice, list) in items {
            let vector = mean(list)
            guard !vector.isEmpty else { continue }
            let seconds = spans.filter { $0.voice == voice }.reduce(0.0) { $0 + Double($1.end - $1.start) }
            result[voice] = Voiceprint(vector: vector, seconds: seconds)
        }
        return result
    }

    /// Prête aux voix d'un service en ligne (qui ne donne pas d'empreintes) celles des voix distinguées sur ce Mac :
    /// chaque voix du service prend l'empreinte de la voix locale qu'elle recouvre le plus, si ce recouvrement
    /// couvre au moins 60 % de sa parole. Deux voix du service sur une même voix locale : seule la principale la garde.
    static func borrow(from local: Transcriber.Voices, for spans: [Transcriber.VoiceSpan]) -> [String: Voiceprint] {
        var overlaps: [String: [String: Double]] = [:]
        var spoken: [String: Double] = [:]
        for span in spans {
            spoken[span.voice, default: 0] += Double(span.end - span.start)
            for other in local.spans {
                let overlap = Double(min(span.end, other.end) - max(span.start, other.start))
                if overlap > 0 { overlaps[span.voice, default: [:]][other.voice, default: 0] += overlap }
            }
        }
        var best: [String: (local: String, overlap: Double)] = [:]
        for (voice, byLocal) in overlaps {
            guard let top = byLocal.max(by: { $0.value < $1.value }), top.value >= 0.6 * (spoken[voice] ?? .infinity) else { continue }
            best[voice] = (top.key, top.value)
        }
        var result: [String: Voiceprint] = [:]
        for (voice, match) in best {
            let rivals = best.filter { $0.key != voice && $0.value.local == match.local }
            guard rivals.allSatisfy({ $0.value.overlap < match.overlap }), let print = local.prints[match.local] else { continue }
            result[voice] = Voiceprint(vector: print.vector, seconds: spoken[voice] ?? print.seconds)
        }
        return result
    }
}

/// Voix connue : un nom donné par l'utilisateur et les empreintes des réunions où il l'a donné.
struct KnownVoice: Codable, Identifiable, Hashable {
    /// Empreinte d'un interlocuteur d'une réunion, rattachée à ce nom.
    struct Sample: Codable, Hashable {
        var recording: UUID
        var speaker: Int
        var vector: [Float]
        var seconds: Double
        var date: Date
    }

    let id: UUID
    var name: String
    var samples: [Sample]

    /// Empreinte de référence : moyenne des réunions, chacune pesée par sa durée de parole (plafonnée à 5 min,
    /// pour qu'une longue réunion n'efface pas les autres conditions d'écoute).
    var centroid: [Float] { Voiceprint.mean(samples.map { ($0.vector, min($0.seconds, 300)) }) }
    var seconds: Double { samples.reduce(0) { $0 + $1.seconds } }
    var meetings: Int { Set(samples.map(\.recording)).count }
    var lastHeard: Date? { samples.map(\.date).max() }
    var isOwn: Bool { VoiceBook.isOwnName(name) }
}

/// Carnet des voix : reconnaît d'une réunion à l'autre les interlocuteurs que l'utilisateur a déjà nommés.
///
/// - Après la distinction des voix, l'empreinte de chaque interlocuteur est gardée avec la réunion
///   (`empreintes.json`, supprimée avec elle) : elle sert si l'utilisateur nomme cette voix plus tard.
/// - Nommer une voix (ou « C'est moi », ou la voix reconnue au micro) range son empreinte sous ce nom (`voix.json`).
/// - À la réunion suivante, chaque interlocuteur est comparé aux voix connues ; un nom assez proche est proposé
///   d'office, marqué « reconnu » dans la fiche jusqu'à ce que l'utilisateur le confirme ou le corrige.
///   Seule une confirmation ou un nom donné à la main enrichit le carnet : une erreur ne s'y renforce pas.
/// - Les invités du rendez-vous de l'agenda sont plus faciles à reconnaître (seuil plus bas) : choisir parmi trois
///   invités est plus sûr que parmi toutes les voix connues.
///
/// Tout reste sur ce Mac. Le réglage « Reconnaître les voix » arrête tout et « Oublier toutes les voix » efface les deux
/// fichiers (données biométriques : rien n'est gardé sans que l'utilisateur ait nommé la voix lui-même).
/// Comme `RecordingStore`, à appeler sur le thread principal.
final class VoiceBook: ObservableObject {
    static let shared = VoiceBook()

    @Published private(set) var voices: [KnownVoice] = []
    /// Empreinte de chaque interlocuteur des réunions (identifiant de la réunion → numéro → empreinte).
    private var prints: [String: [String: Voiceprint]] = [:]

    private let voicesURL = Settings.supportDir.appendingPathComponent("voix.json")
    private let printsURL = Settings.supportDir.appendingPathComponent("empreintes.json")

    /// Similarité au-dessus de laquelle une voix est reconnue ; plus basse pour un invité du rendez-vous.
    /// Banc du 06/11/2026 (`Murmure --bench-voix`, voir README) : une même personne de 0,54 à 0,97 (0,72 au moins
    /// contre une empreinte apprise sur plusieurs enregistrements, micro et pièce différents), deux personnes
    /// différentes 0,43 au plus. MURMURE_SEUIL_VOIX pour un essai.
    static var threshold: Float {
        ProcessInfo.processInfo.environment["MURMURE_SEUIL_VOIX"].flatMap(Float.init) ?? 0.55
    }
    static var invitedThreshold: Float { threshold - 0.07 }
    /// Écart demandé avec la deuxième voix connue la plus proche : sans lui, deux noms se valent et on ne devine pas.
    static let margin: Float = 0.06
    /// En dessous, la voix a trop peu parlé pour que son empreinte soit fiable : ni reconnue, ni apprise.
    static let minimumSeconds = 8.0
    /// Réunions gardées par voix connue (les plus récentes) : la voix suit l'évolution des conditions d'écoute.
    static let maximumSamples = 30

    private init() {
        voices = Self.load([KnownVoice].self, from: voicesURL) ?? []
        prints = Self.load([String: [String: Voiceprint]].self, from: printsURL) ?? [:]
    }

    static func isOwnName(_ name: String) -> Bool {
        name.compare("Moi", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    func hasPrints(_ recording: UUID) -> Bool { prints[recording.uuidString] != nil }

    // MARK: Réunion terminée

    /// Garde les empreintes d'une réunion (si le réglage le permet).
    func remember(_ recording: UUID, prints new: [Int: Voiceprint]) {
        guard Settings.recognizeVoices, !new.isEmpty else { return }
        prints[recording.uuidString] = Dictionary(uniqueKeysWithValues: new.map { (String($0.key), $0.value) })
        savePrints()
    }

    /// Nomme les interlocuteurs reconnus d'une réunion. Une voix déjà nommée (ou « moi ») n'est pas touchée.
    /// Renvoie les noms donnés (numéro → nom), pour le journal.
    @discardableResult
    func recognize(_ id: UUID) -> [Int: String] {
        let store = RecordingStore.shared
        guard Settings.recognizeVoices, let recording = store.recording(id), let meeting = prints[id.uuidString] else { return [:] }
        let invited = recording.attendees ?? []
        let debug = ProcessInfo.processInfo.environment["MURMURE_DEBUG"] != nil
        var candidates: [(speaker: Int, voice: KnownVoice, score: Float)] = []
        for (key, heard) in meeting {
            guard let speaker = Int(key), heard.seconds >= Self.minimumSeconds,
                  recording.speakerNames?[key] == nil, !recording.isOwn(speaker) else { continue }
            let scored = voices.map { ($0, heard.similarity($0.centroid)) }.sorted { $0.1 > $1.1 }
            guard let (voice, score) = scored.first else { continue }
            let second = scored.dropFirst().first?.1 ?? -1
            let isInvited = Self.isInvited(voice, among: invited)
            let needed = isInvited ? Self.invitedThreshold : Self.threshold
            if debug {
                let list = scored.prefix(3).map { String(format: "%@ %.2f", $0.0.name, $0.1) }.joined(separator: ", ")
                print("[voix] interlocuteur \(speaker) (\(Int(heard.seconds)) s) : \(list)\(isInvited ? " (invité)" : "")")
            }
            guard score >= needed, score - second >= Self.margin else { continue }
            candidates.append((speaker, voice, score))
        }
        // Un nom pour une seule voix, et la voix « moi » seulement si le micro ne l'a pas déjà trouvée :
        // les rapprochements les plus sûrs d'abord.
        var given: [Int: String] = [:]
        var usedNames = Set((recording.speakerNames ?? [:]).values.map(foldedForSearch))
        var ownTaken = recording.ownVoice != nil
        var recognized = recording.recognizedSpeakers ?? [:]
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            guard given[candidate.speaker] == nil else { continue }
            if candidate.voice.isOwn {
                guard !ownTaken else { continue }
                ownTaken = true
                store.setOwnSpeaker(id, candidate.speaker)
            } else {
                guard usedNames.insert(foldedForSearch(candidate.voice.name)).inserted else { continue }
                store.setSpeakerName(id, speaker: candidate.speaker, name: candidate.voice.name)
            }
            given[candidate.speaker] = candidate.voice.name
            recognized[String(candidate.speaker)] = Double(candidate.score)
        }
        if !given.isEmpty { store.update(id) { $0.recognizedSpeakers = recognized } }
        return given
    }

    /// Le nom d'une voix connue est-il celui d'un invité du rendez-vous ? « Moi » : le titulaire du compte invité.
    /// Ailleurs, chaque mot du nom connu doit se retrouver dans le nom de l'invité, ou l'inverse
    /// (« Sophie » ↔ « Sophie Martin », « Me Martin » ↔ « Martin »), titres de civilité mis à part.
    static func isInvited(_ voice: KnownVoice, among attendees: [Attendee]) -> Bool {
        if voice.isOwn { return attendees.contains(where: \.isMe) }
        let courtesy: Set<String> = ["me", "maitre", "m", "mme", "mlle", "mr", "dr", "monsieur", "madame"]
        func words(_ text: String) -> Set<String> {
            Set(foldedForSearch(text).split { !$0.isLetter && !$0.isNumber }.map(String.init)).subtracting(courtesy)
        }
        let known = words(voice.name)
        guard !known.isEmpty else { return false }
        return attendees.contains { attendee in
            let other = words(attendee.name)
            return !other.isEmpty && (known.isSubset(of: other) || other.isSubset(of: known))
        }
    }

    // MARK: Ce que fait l'utilisateur

    /// L'utilisateur nomme (ou renomme) une voix dans la fiche : le nom est donné et l'empreinte rangée sous ce nom
    /// (retirée de l'ancien). Un nom vide la retire seulement.
    func name(_ id: UUID, speaker: Int, name: String) {
        RecordingStore.shared.setSpeakerName(id, speaker: speaker, name: name)
        clearRecognized(id, speaker)
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let own = RecordingStore.shared.recording(id)?.isOwn(speaker) ?? false
        learn(id, speaker: speaker, as: trimmed.isEmpty ? (own ? "Moi" : nil) : (Self.isOwnName(trimmed) || own ? "Moi" : trimmed))
    }

    /// « C'est moi » coché ou décoché dans la fiche.
    func setOwn(_ id: UUID, speaker: Int?) {
        let previous = RecordingStore.shared.recording(id)?.ownVoice
        RecordingStore.shared.setOwnSpeaker(id, speaker)
        if let previous, previous != speaker {
            clearRecognized(id, previous)
            let name = RecordingStore.shared.recording(id)?.speakerNames?[String(previous)]
            learn(id, speaker: previous, as: name.flatMap { Self.isOwnName($0) ? nil : $0 })
        }
        if let speaker {
            clearRecognized(id, speaker)
            learn(id, speaker: speaker, as: "Moi")
        }
    }

    /// « C'est bien elle » : le nom reconnu est confirmé, l'empreinte de cette réunion l'enrichit.
    func confirm(_ id: UUID, speaker: Int) {
        guard let recording = RecordingStore.shared.recording(id) else { return }
        clearRecognized(id, speaker)
        learn(id, speaker: speaker, as: recording.isOwn(speaker) ? "Moi" : recording.speakerNames?[String(speaker)])
    }

    /// La voix « moi » trouvée au micro (seule voix nettement plus forte au micro qu'au son de l'ordinateur) :
    /// assez sûre pour être apprise sans confirmation.
    func learnOwnFromMicrophone(_ id: UUID, speaker: Int) { learn(id, speaker: speaker, as: "Moi") }

    private func clearRecognized(_ id: UUID, _ speaker: Int) {
        guard RecordingStore.shared.recording(id)?.recognizedSpeakers?[String(speaker)] != nil else { return }
        RecordingStore.shared.update(id) { recording in
            recording.recognizedSpeakers?[String(speaker)] = nil
            if recording.recognizedSpeakers?.isEmpty == true { recording.recognizedSpeakers = nil }
        }
    }

    /// Range l'empreinte de l'interlocuteur `speaker` sous `name` (nil : nulle part), en la retirant d'où elle était.
    private func learn(_ id: UUID, speaker: Int, as name: String?) {
        guard Settings.recognizeVoices else { return }
        var changed = false
        for index in voices.indices {
            let before = voices[index].samples.count
            voices[index].samples.removeAll { $0.recording == id && $0.speaker == speaker }
            changed = changed || voices[index].samples.count != before
        }
        if let name, let print = prints[id.uuidString]?[String(speaker)], print.seconds >= Self.minimumSeconds {
            let date = RecordingStore.shared.recording(id)?.date ?? Date()
            let sample = KnownVoice.Sample(recording: id, speaker: speaker, vector: print.vector, seconds: print.seconds, date: date)
            let folded = foldedForSearch(name)
            if let index = voices.firstIndex(where: { foldedForSearch($0.name) == folded }) {
                voices[index].samples.append(sample)
                voices[index].samples.sort { $0.date < $1.date }
                voices[index].samples = Array(voices[index].samples.suffix(Self.maximumSamples))
            } else {
                voices.append(KnownVoice(id: UUID(), name: Self.isOwnName(name) ? "Moi" : name, samples: [sample]))
            }
            changed = true
        }
        // Une voix connue sans plus aucune réunion n'a plus d'empreinte : elle disparaît.
        voices.removeAll { $0.samples.isEmpty }
        if changed { saveVoices() }
    }

    // MARK: Liste des voix connues (Réglages)

    func rename(_ voiceID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let index = voices.firstIndex(where: { $0.id == voiceID }) else { return }
        // Même nom qu'une autre voix connue : les deux n'en font plus qu'une.
        if let other = voices.firstIndex(where: { $0.id != voiceID && foldedForSearch($0.name) == foldedForSearch(trimmed) }) {
            voices[other].samples = Array((voices[other].samples + voices[index].samples).sorted { $0.date < $1.date }.suffix(Self.maximumSamples))
            voices.remove(at: index)
        } else {
            voices[index].name = Self.isOwnName(trimmed) ? "Moi" : trimmed
        }
        saveVoices()
    }

    func delete(_ voiceID: UUID) {
        voices.removeAll { $0.id == voiceID }
        saveVoices()
    }

    /// Efface tout : voix connues et empreintes des réunions. Les noms déjà donnés dans les fiches restent.
    func forgetAll() {
        voices = []
        prints = [:]
        try? FileManager.default.removeItem(at: voicesURL)
        try? FileManager.default.removeItem(at: printsURL)
    }

    /// Réunion supprimée définitivement : ses empreintes partent avec elle (celles déjà rangées sous un nom restent).
    func forget(recording id: UUID) {
        guard prints.removeValue(forKey: id.uuidString) != nil else { return }
        savePrints()
    }

    // MARK: Fichiers

    private func saveVoices() { Self.write(voices, to: voicesURL) }
    private func savePrints() { Self.write(prints, to: printsURL) }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
