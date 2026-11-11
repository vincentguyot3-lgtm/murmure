import Foundation

/// Copie de sûreté d'une piste de réunion, écrite au fil de l'eau dans `Enregistrements/en-cours-<id>-<piste>.wav`
/// (PCM 16 bits, 16 kHz, mono, ~1,9 Mo par minute) pour ne plus perdre deux heures de rendez-vous en cas de
/// plantage ou de fermeture. Rien n'est écrit dans le rappel audio : les paquets sont regroupés (une seconde)
/// et écrits par une file série. L'en-tête est tenu à jour à chaque écriture, le fichier est donc lisible à
/// tout instant. Gardé pendant tout le traitement, supprimé ensuite (`delete`) ; rien ne quitte le Mac.
final class AudioSpool {
    enum Track: String, CaseIterable { case mic = "micro", system = "ordinateur" }

    private let url: URL
    private let queue = DispatchQueue(label: "murmure.spool", qos: .utility)
    private var handle: FileHandle?
    private var pending: [Float] = []
    private var dataBytes: UInt32 = 0

    static func url(id: UUID, track: Track) -> URL {
        Settings.audioDir.appendingPathComponent("en-cours-\(id.uuidString)-\(track.rawValue).wav")
    }

    init(id: UUID, track: Track) {
        url = Self.url(id: id, track: track)
        queue.async { [self] in
            FileManager.default.createFile(atPath: url.path, contents: Self.header(dataBytes: 0))
            handle = try? FileHandle(forWritingTo: url)
        }
    }

    /// Depuis le rappel audio : le paquet est seulement passé à la file.
    func append(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        queue.async { [self] in
            pending.append(contentsOf: chunk)
            if pending.count >= 16_000 { flush() }
        }
    }

    /// Écrit ce qui reste et ferme le fichier, qui reste sur le disque.
    func close() {
        queue.sync {
            flush()
            try? handle?.close()
            handle = nil
        }
    }

    private func flush() {
        guard let handle, !pending.isEmpty else { return }
        var data = Data(count: pending.count * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for (i, sample) in pending.enumerated() { out[i] = Int16(max(-1, min(1, sample)) * 32_767) }
        }
        pending.removeAll(keepingCapacity: true)
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            dataBytes += UInt32(data.count)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Self.header(dataBytes: dataBytes))
        } catch {
            print("[réunion] copie de sûreté : \(error.localizedDescription)")
        }
    }

    private static func header(dataBytes: UInt32) -> Data {
        var data = Data()
        func put(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func put(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); put(36 + dataBytes); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(16_000)); put(UInt32(32_000)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(dataBytes)
        return data
    }

    // MARK: Fichiers laissés par un arrêt brutal

    /// Identifiants des réunions dont une piste est encore sur le disque.
    static func interrupted() -> [UUID] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Settings.audioDir.path)) ?? []
        let ids = names.compactMap { name -> UUID? in
            guard name.hasPrefix("en-cours-"), name.hasSuffix("-\(Track.mic.rawValue).wav") else { return nil }
            return UUID(uuidString: String(name.dropFirst("en-cours-".count).dropLast("-\(Track.mic.rawValue).wav".count)))
        }
        return Array(Set(ids)).sorted { $0.uuidString < $1.uuidString }
    }

    static func exists(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: url(id: id, track: .mic).path)
    }

    /// Date de création de la piste micro : celle du début de la réunion.
    static func startDate(_ id: UUID) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url(id: id, track: .mic).path))?[.creationDate] as? Date
    }

    static func delete(_ id: UUID) {
        for track in Track.allCases { try? FileManager.default.removeItem(at: url(id: id, track: track)) }
    }
}
