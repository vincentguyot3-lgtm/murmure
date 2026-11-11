import Foundation

/// Passage de parole attribué à un interlocuteur (numéroté à partir de 1, dans l'ordre d'apparition).
struct Turn: Codable, Hashable {
    var speaker: Int
    var text: String
}

struct Folder: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    /// Dossier du Mac (celui de l'affaire, par exemple) où chaque élément rangé ici est copié en Markdown.
    var exportPath: String?
    /// « Jamais en ligne » : les synthèses, questions et réécritures de ce dossier restent sur le Mac, même
    /// quand Claude est le moteur choisi (dossier pénal, opération sous accord de confidentialité…).
    var localOnly: Bool?
    /// Teinte de la pastille (0 à 5, voir `Theme.folderTints`) ; attribuée à la création, en tournant.
    var tint: Int?

    var exportURL: URL? { exportPath.map { URL(fileURLWithPath: $0, isDirectory: true) } }
    var isLocalOnly: Bool { localOnly ?? false }

    static let tintCount = 6
    /// Noms des teintes, dans l'ordre de `Theme.folderTints` (menu « Couleur » du dossier).
    static let tintNames = ["Bleu", "Orange", "Vert", "Violet", "Ambre", "Rose"]

    /// Teinte effective ; un dossier d'avant les teintes en reçoit une stable, tirée de son identifiant.
    var tintIndex: Int { tint.map { min(max($0, 0), Self.tintCount - 1) } ?? Int(id.uuid.0) % Self.tintCount }
}

/// Une version de compte rendu généré (Markdown simple : « ## » pour les titres, « - » pour les puces).
struct Summary: Codable, Identifiable, Hashable {
    var id = UUID()
    var template: String
    var text: String
    var date: Date
}

enum RecordingKind: String, Codable { case dictation, meeting }

struct Recording: Codable, Identifiable, Hashable {
    let id: UUID
    let date: Date
    var title: String
    var text: String
    var rawText: String
    var duration: Double
    var appName: String?
    /// Renseigné quand au moins deux voix différentes ont été reconnues.
    var turns: [Turn]?
    // Champs ajoutés après coup : facultatifs pour relire les anciens historiques.
    var kind: RecordingKind?
    var folderID: UUID?
    var speakerNames: [String: String]?
    var summaries: [Summary]?
    /// Étape en cours pendant le traitement d'une réunion (« Transcription… »), nil une fois terminé.
    var progress: String?
    /// Pourquoi le compte rendu automatique n'a pas pu être rédigé (contexte du modèle dépassé, délai…).
    var processingError: String?
    var archived: Bool?
    /// Dernier fichier Markdown écrit par l'export automatique (pour le renommer ou le retirer ensuite).
    var exportedPath: String?
    /// Date de mise à la corbeille ; supprimé définitivement 30 jours après.
    var deletedAt: Date?
    /// Invités du rendez-vous de l'agenda pendant lequel la réunion a été enregistrée.
    var attendees: [Attendee]?
    /// Titre d'origine d'une réunion : celui du rendez-vous de l'agenda ou le nom du fichier importé. Il sert
    /// de titre provisoire, puis d'indice (et de terme pour la transcription) une fois le titre généré.
    var sourceTitle: String?
    /// Notes prises par l'utilisateur pendant la réunion (page En direct) ou ajoutées ensuite dans la fiche :
    /// données au modèle, qui les reprend en priorité dans le compte rendu.
    var notes: String?
    /// Date à laquelle la dictée est supprimée définitivement (réglage « Garder les dictées dans l'historique »).
    /// nil : gardée sans limite. Les dictées d'avant ce champ n'en ont pas et n'expirent jamais.
    var expiresAt: Date?

    /// Épinglée : gardée sous la main dans la page Épinglés du panneau.
    var pinned: Bool?
    /// Compte rendu automatique prêt mais pas encore ouvert (point bleu de la liste, nombre bleu du panneau).
    /// nil pour les fiches d'avant ce champ : elles ne sont jamais « non lues ».
    var summaryUnread: Bool?
    /// Proposition d'accompagnement (le mail de fin de premier rendez-vous) rédigée depuis la réunion, relue dans la fiche.
    var proposal: String?

    /// Numéro de l'interlocuteur qui est l'utilisateur : voix reconnue au micro, ou « C'est moi » dans la fiche.
    /// Les fiches d'avant ce champ n'en ont pas : `ownVoice` se rabat sur la voix nommée « Moi ».
    var ownSpeaker: Int?
    /// Où la réunion a été transcrite : nil ou "local" (sur ce Mac), "online" (service en ligne). Affiché dans la fiche.
    var transcribedBy: String?
    /// Transcription en ligne demandée mais impossible (cause), la réunion ayant été transcrite sur ce Mac.
    var onlineFailure: String?
    /// « Garder sur ce Mac » choisi pendant l'enregistrement : rien de cette réunion ne part en ligne (son, texte).
    var keepLocal: Bool?
    /// Voix nommées d'office parce que reconnues d'une réunion précédente (numéro → similarité), jusqu'à ce que
    /// l'utilisateur confirme ou corrige le nom (`VoiceBook`).
    var recognizedSpeakers: [String: Double]?

    func isRecognized(_ speaker: Int) -> Bool { recognizedSpeakers?[String(speaker)] != nil }

    var isPinned: Bool { pinned == true }

    /// Compte rendu prêt, pas encore ouvert.
    var hasUnreadSummary: Bool { summaryUnread == true && !(summaries ?? []).isEmpty && progress == nil }

    /// L'interlocuteur « moi », s'il est connu.
    var ownVoice: Int? {
        if let ownSpeaker { return ownSpeaker }
        return speakerNames?.first { $0.value.compare("Moi", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            .flatMap { Int($0.key) }
    }

    func isOwn(_ speaker: Int) -> Bool { ownVoice == speaker }

    /// Voix distinctes, dans l'ordre où elles prennent la parole.
    var speakersInOrder: [Int] {
        var seen = Set<Int>()
        return (turns ?? []).compactMap { seen.insert($0.speaker).inserted ? $0.speaker : nil }
    }

    /// Rang de couleur d'une voix (`Theme.speakerTint`) : nil pour « moi », puis 0, 1, 2… pour les autres, dans
    /// l'ordre où elles prennent la parole.
    func speakerRank(_ speaker: Int) -> Int? {
        if isOwn(speaker) { return nil }
        let others = speakersInOrder.filter { !isOwn($0) }
        return others.firstIndex(of: speaker) ?? others.count
    }

    /// Voix que l'utilisateur n'a pas encore nommées (ni « moi »).
    var unnamedSpeakers: [Int] {
        speakersInOrder.filter { speakerNames?[String($0)] == nil && !isOwn($0) }
    }

    /// Notes non vides, sinon nil.
    var userNotes: String? {
        let trimmed = (notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Adresses des invités, sauf la sienne : destinataires du brouillon d'e-mail.
    var recipients: [String] { (attendees ?? []).filter { !$0.isMe }.compactMap(\.email) }

    /// Noms donnés au modèle pour le compte rendu : les invités du rendez-vous, sinon les interlocuteurs.
    var participantNames: [String] {
        if let attendees, !attendees.isEmpty { return attendees.map { $0.isMe ? "\($0.name) (moi)" : $0.name } }
        return Array(Set((turns ?? []).map(\.speaker))).sorted().map { speakerName($0) }
    }

    var isMeeting: Bool { kind == .meeting }
    var isArchived: Bool { archived == true }
    var isTrashed: Bool { deletedAt != nil }
    var isExpired: Bool { expiresAt.map { $0 <= Date() } ?? false }

    /// « dans 3 h », « dans 40 min », « dans 23 h » : délai avant l'expiration, arrondi ; nil sans expiration.
    var expiresIn: String? {
        guard let expiresAt else { return nil }
        let minutes = Int((expiresAt.timeIntervalSinceNow / 60).rounded(.up))
        if minutes < 1 { return "maintenant" }
        if minutes < 60 { return "dans \(minutes) min" }
        let hours = Int((Double(minutes) / 60).rounded())
        if hours < 48 { return "dans \(hours) h" }
        return "dans \(Int((Double(hours) / 24).rounded())) j"
    }

    /// Tout ce dans quoi on cherche : titre, texte, transcription, dernier compte rendu, notes.
    var searchText: String {
        [title, text, transcript, summaries?.last?.text ?? "", notes ?? ""].joined(separator: "\n")
    }

    /// Recherche sans tenir compte des accents ni de la casse (la liste passe par le cache de `RecordingStore.matches`).
    func matches(_ query: String) -> Bool {
        searchText.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    enum Status: String, CaseIterable {
        case processing = "En cours", summarized = "Synthèse prête", transcribed = "Transcrite", empty = "Sans contenu"
        var symbol: String {
            switch self {
            case .processing: return "clock"
            case .summarized: return "doc.text"
            case .transcribed: return "checkmark.circle"
            case .empty: return "exclamationmark.circle"
            }
        }
    }

    var status: Status {
        if progress != nil { return .processing }
        if !(summaries ?? []).isEmpty { return .summarized }
        return text.isEmpty ? .empty : .transcribed
    }
    var wordCount: Int { text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count }
    var speakerCount: Int { Set(turns?.map(\.speaker) ?? []).count }

    func speakerName(_ number: Int) -> String {
        speakerNames?[String(number)] ?? "Interlocuteur \(number)"
    }

    /// Transcription lisible, avec le nom de chaque interlocuteur s'il y en a plusieurs.
    var transcript: String {
        guard let turns, !turns.isEmpty else { return text }
        return turns.map { "\(speakerName($0.speaker)) : \($0.text)" }.joined(separator: "\n\n")
    }
}

/// Historique (dictées et réunions, texte uniquement : l'audio n'est jamais conservé) et dossiers.
/// Les dictées portent une date d'expiration selon le réglage « Garder les dictées dans l'historique »
/// (24 heures par défaut) ; ranger une dictée dans un dossier ou cliquer « Garder » la retire.
final class RecordingStore: ObservableObject {
    static let shared = RecordingStore()

    @Published private(set) var recordings: [Recording] = []
    @Published private(set) var folders: [Folder] = []

    /// Texte de recherche plié (minuscules, sans accents) de chaque enregistrement, calculé une fois et
    /// oublié à la modification : la liste ne reconstruit pas chaque transcription à chaque lettre tapée.
    private var searchIndex: [UUID: String] = [:]

    private let indexURL = Settings.supportDir.appendingPathComponent("historique.json")
    private let foldersURL = Settings.supportDir.appendingPathComponent("dossiers.json")
    private let ioQueue = DispatchQueue(label: "murmure.store")

    private init() {
        recordings = Self.load([Recording].self, from: indexURL) ?? []
        folders = Self.load([Folder].self, from: foldersURL) ?? []
    }

    func recording(_ id: UUID) -> Recording? { recordings.first { $0.id == id } }
    func folder(_ id: UUID?) -> Folder? { folders.first { $0.id == id } }

    // MARK: Dictées et réunions (à appeler sur le thread principal)

    @discardableResult
    func add(text: String, rawText: String, duration: Double, appName: String?, kind: RecordingKind = .dictation,
             title: String? = nil, progress: String? = nil, id: UUID = UUID(), date: Date = Date(),
             expiresAt: Date? = nil) -> UUID {
        let recording = Recording(
            id: id,
            date: date,
            title: title ?? Self.defaultTitle(for: text),
            text: text,
            rawText: rawText,
            duration: duration,
            appName: appName,
            turns: nil,
            kind: kind,
            progress: progress,
            expiresAt: kind == .meeting ? nil : expiresAt
        )
        // L'historique est trié du plus récent au plus ancien ; un enregistrement importé porte la date de son fichier.
        recordings.insert(recording, at: recordings.firstIndex { $0.date <= date } ?? recordings.count)
        save()
        return recording.id
    }

    func update(_ id: UUID, _ change: (inout Recording) -> Void) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        change(&recordings[index])
        searchIndex[id] = nil
        save()
        Exporter.schedule(id)
    }

    /// `foldedQuery` est déjà passé par `foldedForSearch`.
    func matches(_ recording: Recording, _ foldedQuery: String) -> Bool {
        if let cached = searchIndex[recording.id] { return cached.contains(foldedQuery) }
        let folded = foldedForSearch(recording.searchText)
        searchIndex[recording.id] = folded
        return folded.contains(foldedQuery)
    }

    /// Étape en cours du traitement d'une réunion (« Voix 42 % »). Affichage seulement : ni export ni écriture
    /// sur le disque, l'étape change plusieurs fois par seconde et ne vaut rien après un redémarrage.
    func setProgress(_ id: UUID, _ progress: String) {
        guard let index = recordings.firstIndex(where: { $0.id == id }),
              recordings[index].progress != nil, recordings[index].progress != progress else { return }
        recordings[index].progress = progress
    }

    /// Mémorise le fichier écrit par l'export, sans redéclencher d'export.
    func setExportedPath(_ id: UUID, _ path: String?) {
        guard let index = recordings.firstIndex(where: { $0.id == id }), recordings[index].exportedPath != path else { return }
        recordings[index].exportedPath = path
        save()
    }

    func rename(_ id: UUID, to title: String) { update(id) { $0.title = title } }
    func updateText(_ id: UUID, to text: String) { update(id) { $0.text = text } }
    func setTurns(_ id: UUID, _ turns: [Turn]) { update(id) { $0.turns = turns } }
    func setNotes(_ id: UUID, _ notes: String) {
        update(id) { $0.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes }
    }
    func setProposal(_ id: UUID, _ text: String?) {
        update(id) { $0.proposal = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text }
    }
    /// Ranger, c'est garder : une dictée mise dans un dossier n'expire plus (et ne réexpire pas si on l'en sort).
    func setFolder(_ id: UUID, _ folderID: UUID?) {
        update(id) {
            $0.folderID = folderID
            if folderID != nil { $0.expiresAt = nil }
        }
    }

    /// « Garder » : retire l'expiration d'une dictée.
    func keep(_ id: UUID) {
        guard recording(id)?.expiresAt != nil else { return }
        update(id) { $0.expiresAt = nil }
    }
    func setArchived(_ id: UUID, _ archived: Bool) { update(id) { $0.archived = archived ? true : nil } }
    /// Épingler, c'est aussi garder : une dictée épinglée n'expire plus.
    func setPinned(_ id: UUID, _ pinned: Bool) {
        update(id) {
            $0.pinned = pinned ? true : nil
            if pinned { $0.expiresAt = nil }
        }
    }

    func setSpeakerName(_ id: UUID, speaker: Int, name: String) {
        update(id) { recording in
            var names = recording.speakerNames ?? [:]
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            names[String(speaker)] = trimmed.isEmpty ? nil : trimmed
            recording.speakerNames = names
        }
    }

    /// « C'est moi » : `speaker` devient la voix de l'utilisateur (nil : personne). Une voix sans nom prend « Moi »,
    /// repris par les comptes rendus et les exports ; l'ancienne voix « Moi » redevient « Interlocuteur N ».
    func setOwnSpeaker(_ id: UUID, _ speaker: Int?) {
        update(id) { recording in
            var names = recording.speakerNames ?? [:]
            if let previous = recording.ownVoice, previous != speaker,
               names[String(previous)]?.compare("Moi", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
                names[String(previous)] = nil
            }
            if let speaker, names[String(speaker)] == nil { names[String(speaker)] = "Moi" }
            recording.speakerNames = names
            recording.ownSpeaker = speaker
        }
    }

    func addSummary(_ id: UUID, _ summary: Summary) {
        update(id) { $0.summaries = ($0.summaries ?? []) + [summary] }
    }

    /// Lu ou non lu : ouvrir la fiche la marque lue ; le compte rendu automatique la marque non lue.
    func setSummaryUnread(_ id: UUID, _ unread: Bool) {
        // Sans passer par `update` : ni l'index de recherche ni la copie Markdown ne dépendent de cet état.
        guard let index = recordings.firstIndex(where: { $0.id == id }),
              (recordings[index].summaryUnread == true) != unread else { return }
        recordings[index].summaryUnread = unread ? true : nil
        save()
    }

    /// Comptes rendus prêts et pas encore ouverts, hors archives et corbeille (dans un dossier, si `folder` est donné).
    func unreadCount(in folder: UUID? = nil) -> Int {
        recordings.filter { $0.hasUnreadSummary && !$0.isArchived && !$0.isTrashed && (folder == nil || $0.folderID == folder) }.count
    }

    /// Remplace le titre provisoire par un titre généré, sauf si l'utilisateur l'a déjà renommé.
    func setGeneratedTitle(_ id: UUID, _ title: String, replacing placeholder: String? = nil) {
        update(id) { recording in
            if recording.title == (placeholder ?? Self.defaultTitle(for: recording.text)) { recording.title = title }
        }
    }

    /// Place dans la corbeille ; la copie dans le dossier du Mac est retirée (voir `Exporter.sync`).
    func trash(_ id: UUID) { update(id) { $0.deletedAt = Date() } }
    func restore(_ id: UUID) { update(id) { $0.deletedAt = nil } }

    /// Supprime définitivement ce qui est dans la corbeille depuis plus de 30 jours (ou tout, avec `all`).
    func purgeTrash(all: Bool = false) {
        let limit = Date().addingTimeInterval(-30 * 24 * 3600)
        for recording in recordings {
            if let deleted = recording.deletedAt, all || deleted < limit { delete(recording.id) }
        }
    }

    /// Supprime définitivement (sans corbeille : l'expiration a été choisie) les dictées dont la date d'expiration
    /// est passée, avec leur audio gardé éventuel. Jamais une réunion ni une dictée rangée dans un dossier,
    /// qui n'ont pas d'expiration. Appelée au lancement puis toutes les dix minutes.
    @discardableResult
    func purgeExpired(now: Date = Date()) -> Int {
        let expired = recordings.filter { !$0.isMeeting && $0.folderID == nil && !$0.isPinned && ($0.expiresAt.map { $0 <= now } ?? false) }
        for recording in expired { delete(recording.id) }
        return expired.count
    }

    /// Au lancement : une réunion encore « en cours » vient d'un arrêt de l'application pendant son traitement.
    /// Si sa copie de sûreté audio est encore là, le traitement reprendra (`MeetingController.resumeInterrupted`) ;
    /// sinon ce qui n'était pas fini est perdu, et on la débloque.
    func clearInterruptedProcessing() {
        for recording in recordings where recording.progress != nil {
            if AudioSpool.exists(recording.id) {
                update(recording.id) { $0.progress = "Reprise au chargement des modèles…" }
                continue
            }
            update(recording.id) {
                $0.progress = nil
                if $0.text.isEmpty {
                    $0.title += " (interrompue)"
                    $0.processingError = "Murmure a été quitté pendant la transcription : l'audio n'a pas été conservé."
                } else if ($0.summaries ?? []).isEmpty {
                    $0.processingError = "Murmure a été quitté pendant la rédaction du compte rendu."
                }
            }
        }
    }

    func delete(_ id: UUID) {
        if let recording = recording(id) { Exporter.remove(recording) }
        AudioArchive.delete(id)
        VoiceBook.shared.forget(recording: id)
        recordings.removeAll { $0.id == id }
        searchIndex[id] = nil
        save()
    }

    // MARK: Dossiers

    @discardableResult
    func createFolder(_ name: String) -> Folder {
        // Les teintes tournent : la moins employée d'abord, pour que deux dossiers voisins se distinguent.
        let used = folders.map(\.tintIndex)
        func uses(_ tint: Int) -> Int { used.filter { $0 == tint }.count }
        let tint = (0..<Folder.tintCount).min { uses($0) < uses($1) } ?? 0
        let folder = Folder(id: UUID(), name: name.trimmingCharacters(in: .whitespaces), tint: tint)
        folders.append(folder)
        folders.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        saveFolders()
        return folder
    }

    func renameFolder(_ id: UUID, to name: String) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = name.trimmingCharacters(in: .whitespaces)
        saveFolders()
    }

    func setFolderTint(_ id: UUID, _ tint: Int) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].tint = min(max(tint, 0), Folder.tintCount - 1)
        saveFolders()
    }

    /// Lie (ou délie, avec nil) un dossier Murmure à un dossier du Mac, puis y copie tout son contenu.
    func setFolderExportPath(_ id: UUID, _ path: String?) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].exportPath = path
        saveFolders()
        for recording in recordings where recording.folderID == id { Exporter.schedule(recording.id) }
    }

    func setFolderLocalOnly(_ id: UUID, _ value: Bool) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].localOnly = value
        saveFolders()
    }

    /// L'élément est-il rangé dans un dossier « jamais en ligne » ?
    /// Ou réunion marquée « Garder sur ce Mac » pendant l'enregistrement.
    func isLocalOnly(_ recording: Recording) -> Bool {
        recording.keepLocal == true || (folder(recording.folderID)?.isLocalOnly ?? false)
    }

    /// Supprime le dossier ; ses dictées et réunions sont conservées, simplement « à ranger ».
    func deleteFolder(_ id: UUID) {
        folders.removeAll { $0.id == id }
        for index in recordings.indices where recordings[index].folderID == id {
            recordings[index].folderID = nil
            Exporter.schedule(recordings[index].id)
        }
        saveFolders()
        save()
    }

    // MARK: Persistance

    /// Les modifications rapprochées (frappe dans un titre ou un texte) sont regroupées : l'historique
    /// entier n'est pas réencodé à chaque caractère.
    private var saveScheduled = false

    private func save() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            saveScheduled = false
            write(recordings, to: indexURL)
        }
    }

    /// Écrit tout de suite ce qui est en attente (à la fermeture de l'application).
    func flush() {
        if saveScheduled {
            saveScheduled = false
            write(recordings, to: indexURL)
        }
        ioQueue.sync {}
    }

    private func saveFolders() { write(folders, to: foldersURL) }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        ioQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted]
            guard let data = try? encoder.encode(value) else { return }
            // Copie de sûreté de la version précédente (`historique.bak.json`) avant chaque écriture.
            let backup = Self.backupURL(for: url)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.copyItem(at: url, to: backup)
            }
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func backupURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("bak.json")
    }

    /// Un fichier non vide mais illisible n'est plus pris pour un historique vide (que la première sauvegarde
    /// aurait écrasé) : il est mis de côté sous `historique.illisible-<date>.json`, et la copie de sûreté est
    /// relue si elle l'est ; sinon on part vide.
    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        if let value = decode(type, data) { return value }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let stamp = formatter.string(from: Date())
        let aside = url.deletingPathExtension().appendingPathExtension("illisible-\(stamp).json")
        try? FileManager.default.moveItem(at: url, to: aside)
        print("[historique] \(url.lastPathComponent) illisible, mis de côté dans \(aside.lastPathComponent)")
        guard let backup = try? Data(contentsOf: backupURL(for: url)), let value = decode(type, backup) else { return nil }
        print("[historique] copie de sûreté relue")
        return value
    }

    /// Relit l'historique et les dossiers tels qu'ils sont sur le disque, sans passer par l'instance partagée
    /// ni rien mettre de côté : pour le serveur MCP, qui tourne à côté de l'application et doit voir ses
    /// dernières écritures.
    static func readDisk() -> (recordings: [Recording], folders: [Folder]) {
        func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
            guard let data = try? Data(contentsOf: Settings.supportDir.appendingPathComponent(name)), !data.isEmpty else { return nil }
            return decode(type, data)
        }
        return (read([Recording].self, "historique.json") ?? [], read([Folder].self, "dossiers.json") ?? [])
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: data)
        } catch {
            print("[historique] lecture impossible : \(error)")
            return nil
        }
    }

    static func defaultTitle(for text: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let head = words.prefix(7).joined(separator: " ")
        return words.count > 7 ? head + "…" : head
    }
}
