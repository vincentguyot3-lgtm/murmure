import AVFoundation
import UniformTypeIdentifiers

/// Lecture d'un fichier audio (dictaphone, mémo vocal, enregistrement d'audience) en 16 kHz mono Float32,
/// le format attendu par Whisper. Le fichier n'est ni copié ni modifié.
enum AudioFile {
    /// Formats acceptés à l'import (menu Fichier, palette, glisser-déposer).
    static let types: [UTType] = [.wav, .mpeg4Audio, .mp3, .aiff]
    static let extensions = ["wav", "m4a", "mp3", "aiff", "aif"]

    static func isSupported(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    static func load(_ url: URL) throws -> [Float] {
        // L'erreur de Core Audio (« error 1954115647 ») ne dit rien à l'utilisateur : un seul message, en français.
        guard let file = try? AVAudioFile(forReading: url) else { throw Failure.unreadable }
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 32)
        else { throw Failure.unreadable }
        do { try file.read(into: input) } catch { throw Failure.unreadable }
        var consumed = false
        converter.convert(to: output, error: nil) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true; status.pointee = .haveData; return input
        }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    /// Date de création du fichier (celle de l'enregistrement, pour un mémo vocal), à défaut maintenant.
    static func creationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
    }

    enum Failure: LocalizedError {
        case unreadable
        var errorDescription: String? { "le fichier audio est illisible" }
    }
}

/// Lit un fichier audio et le convertit en 16 kHz mono Float32 (modes de ligne de commande).
func loadAudio(_ path: String) throws -> [Float] { try AudioFile.load(URL(fileURLWithPath: path)) }
