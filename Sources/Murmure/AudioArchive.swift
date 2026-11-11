import AVFoundation

/// Audio des dictées gardé à la demande (réglage « Garder l'audio des dictées »), pour le banc d'essai
/// sur de vraies dictées. Un fichier par dictée, nommé par son identifiant, supprimé avec elle.
enum AudioArchive {
    private static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    /// Fichier de la dictée, s'il existe (WAV, ou M4A pour les plus anciens).
    static func url(for id: UUID) -> URL? {
        ["wav", "m4a"]
            .map { Settings.audioDir.appendingPathComponent("\(id.uuidString).\($0)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Écrit l'audio en WAV 16 kHz mono 16 bits (~1,9 Mo par minute), hors du thread principal.
    static func save(_ samples: [Float], id: UUID) {
        DispatchQueue.global(qos: .utility).async {
            let url = Settings.audioDir.appendingPathComponent("\(id.uuidString).wav")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ]
            guard !samples.isEmpty,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                  let file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            else { return }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            try? file.write(from: buffer)
        }
    }

    static func delete(_ id: UUID) {
        if let url = url(for: id) { try? FileManager.default.removeItem(at: url) }
    }
}
