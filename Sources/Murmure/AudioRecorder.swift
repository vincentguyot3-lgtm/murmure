import AVFoundation
import CoreAudio

/// Capture le micro et accumule l'audio en 16 kHz mono Float32, le format attendu par Whisper.
/// Le moteur audio n'est allumé que pendant une capture : le micro ne s'ouvre que le temps de la dictée
/// ou de la réunion, et rien n'est gardé en dehors.
final class AudioRecorder {
    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var capturing = false
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    /// Niveau sonore (0...1) pour l'indicateur visuel, appelé sur le thread principal.
    var onLevel: ((Float) -> Void)?
    /// Appelé sur le thread principal si le micro ne repart pas après un changement de périphérique.
    var onFailure: ((String) -> Void)?
    /// Instant de l'échantillon 0 de la capture en cours : sert à combler par du silence le trou laissé
    /// par un changement de périphérique, pour que la piste reste calée sur celle du son de l'ordinateur.
    private var captureStart: Date?
    /// Copie de sûreté sur le disque de la capture en cours (réunion), alimentée hors du fil audio.
    private var spool: AudioSpool?

    init() {
        // Changement de périphérique audio (AirPods, micro externe) : le moteur s'arrête, on le relance.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            self?.restartAfterConfigurationChange(attempt: 1)
        }
    }

    /// Relance le moteur sur le nouveau périphérique. Le trou (entre l'arrêt et le premier son du nouveau micro)
    /// est d'abord comblé par du silence jusqu'au temps écoulé, pour que l'index des échantillons reste le temps.
    /// Le nouveau périphérique met parfois une seconde à répondre : trois essais, puis l'échec est signalé.
    private func restartAfterConfigurationChange(attempt: Int) {
        guard capturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        fillGap()
        do {
            try startEngine()
        } catch {
            print("[micro] redémarrage impossible après changement de périphérique (essai \(attempt)) : \(error.localizedDescription)")
            if attempt < 3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.restartAfterConfigurationChange(attempt: attempt + 1)
                }
            } else {
                onFailure?("Micro coupé par le changement de périphérique : vérifiez l'entrée dans Réglages Système › Son")
            }
        }
    }

    /// Complète la capture en cours par des zéros jusqu'à `temps écoulé × 16 000` échantillons.
    private func fillGap() {
        lock.lock(); defer { lock.unlock() }
        guard capturing, let captureStart else { return }
        let expected = Int(Date().timeIntervalSince(captureStart) * 16_000)
        guard samples.count < expected else { return }
        let silence = [Float](repeating: 0, count: expected - samples.count)
        samples.append(contentsOf: silence)
        spool?.append(silence)
    }

    /// `expecting` : durée probable en secondes (réunion) ; la place est réservée d'avance pour que le tableau
    /// ne soit jamais recopié sous le verrou, dans le rappel audio (2 h = 460 Mo, copiés par doublements).
    /// `spool` : copie de sûreté écrite au fil de l'eau (réunion), fermée à l'arrêt mais gardée sur le disque.
    func start(expecting seconds: Int = 0, spool: AudioSpool? = nil) throws {
        lock.lock()
        samples = []
        if seconds > 0 { samples.reserveCapacity(seconds * 16_000) }
        captureStart = Date()
        capturing = true
        self.spool = spool
        lock.unlock()
        if !engine.isRunning { try startEngine() }
    }

    /// Arrête la capture et renvoie l'audio enregistré.
    func stop() -> [Float] {
        lock.lock()
        capturing = false
        captureStart = nil
        let result = samples
        samples.removeAll()
        let spool = spool
        self.spool = nil
        lock.unlock()
        spool?.close()
        stopEngine()
        return result
    }

    /// Copie de l'audio capturé à partir de l'échantillon `index`, sans interrompre la capture
    /// (aperçu en direct). Vide hors enregistrement.
    func capturedAudio(from index: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        guard capturing, index < samples.count else { return [] }
        return Array(samples[index...])
    }

    /// Les `count` derniers échantillons capturés.
    func recentAudio(_ count: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return Array(samples.suffix(count))
    }

    private func startEngine() throws {
        guard !engine.isRunning else { return }
        let input = engine.inputNode
        // Micro choisi dans Murmure : il prime sur l'entrée du système, que macOS fait basculer d'elle-même
        // (iPhone à proximité, Teams, AirPods). Débranché, on retombe sur l'entrée du système.
        if var device = Microphones.chosenDevice(), let unit = input.audioUnit {
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &device, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { print("[micro] choix du micro refusé (\(status)) : entrée du système") }
        }
        let inputFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData?[0] else { return }
        let chunk = Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))

        lock.lock()
        let isCapturing = capturing
        if isCapturing {
            samples.append(contentsOf: chunk)
            spool?.append(chunk)
        }
        lock.unlock()

        if isCapturing, let onLevel, !chunk.isEmpty {
            let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
            let level = min(1, rms * 12)
            DispatchQueue.main.async { onLevel(level) }
        }
    }
}

/// Au début d'une dictée ou d'une réunion, prévient si le micro ne livre aucun son pendant 2 s : micro coupé,
/// débranché, ou entrée réglée sur un appareil absent. Un vrai micro, même dans le silence, a un souffle.
final class SilenceWatch {
    private var heard = false
    private var work: DispatchWorkItem?

    /// Niveau en dessous duquel le micro est tenu pour muet (un micro ouvert donne au moins 0,01).
    private static let floor: Float = 0.001
    static let delay: TimeInterval = 2

    /// À appeler sur le fil principal au départ de l'enregistrement.
    func start(onSilent: @escaping () -> Void) {
        work?.cancel()
        heard = false
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.heard else { return }
            onSilent()
        }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: item)
    }

    /// Niveau reçu de `AudioRecorder.onLevel` (fil principal).
    func note(_ level: Float) {
        guard !heard, level > Self.floor else { return }
        heard = true
        work?.cancel()
    }

    func stop() {
        work?.cancel()
        work = nil
    }
}

/// Micros branchés, lus dans Core Audio : le choix de Réglages › Général › Micro, gardé par son identifiant
/// (stable d'un branchement à l'autre), pas par son nom.
enum Microphones {
    struct Device: Hashable {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    /// Périphériques qui ont au moins une entrée.
    static func all() -> [Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Device(id: id, uid: uid, name: name)
        }
    }

    /// Entrée du système (Réglages Système › Son › Entrée).
    static func systemDefault() -> Device? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return all().first { $0.id == id }
    }

    /// Micro choisi dans Murmure, s'il est branché ; sinon le micro du Mac à la place d'écouteurs Bluetooth
    /// (voir `bluetoothReplacement`) ; nil : l'entrée du système.
    static func chosenDevice() -> AudioDeviceID? {
        let uid = Settings.microphone
        if !uid.isEmpty, let device = all().first(where: { $0.uid == uid }) { return device.id }
        return bluetoothReplacement()?.builtIn.id
    }

    /// Écouteurs Bluetooth en entrée du système (AirPods, casque) : dès qu'une app ouvre leur micro, macOS les fait
    /// passer en mode téléphone, son réduit à une bande étroite dans les deux sens (la dictée se dégrade, la musique
    /// aussi). Le micro du Mac est pris à leur place, les écouteurs gardent le son. Seulement pour l'entrée du
    /// système : un micro Bluetooth choisi exprès dans Murmure est respecté. Réglage Général › Micro.
    static func bluetoothReplacement() -> (headset: Device, builtIn: Device)? {
        guard Settings.avoidBluetoothMic, let input = systemDefault(), isBluetooth(input.id),
              let builtIn = all().first(where: { transport($0.id) == kAudioDeviceTransportTypeBuiltIn }) else { return nil }
        return (input, builtIn)
    }

    /// Nom du micro qu'utilisera la prochaine capture.
    static var currentName: String {
        let uid = Settings.microphone
        if !uid.isEmpty, let device = all().first(where: { $0.uid == uid }) { return device.name }
        if let replacement = bluetoothReplacement() { return "\(replacement.builtIn.name) (au lieu de \(replacement.headset.name))" }
        return systemDefault()?.name ?? "Micro du Mac"
    }

    static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        let type = transport(id)
        return type == kAudioDeviceTransportTypeBluetooth || type == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Liaison du périphérique (intégré, USB, Bluetooth…), `kAudioDeviceTransportType…`.
    private static func transport(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : 0
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// Repère la parole par l'énergie, avec un seuil calé sur l'enregistrement lui-même, entre le bruit de fond et
/// la voix. Un seuil fixe tombait sur la voix d'un micro de portable un peu loin (-35 à -45 dBFS) et la prenait
/// pour du silence ; il montait aussi avec le gain, alors que seul compte l'écart entre voix et fond.
enum SpeechLevels {
    /// Niveau (moyenne quadratique) de chaque tranche de `frame` échantillons.
    static func levels(_ audio: [Float], frame: Int) -> [Float] {
        stride(from: 0, to: audio.count - frame + 1, by: frame).map { start in
            var energy: Float = 0
            for i in start..<start + frame { energy += audio[i] * audio[i] }
            return (energy / Float(frame)).squareRoot()
        }
    }

    /// Seuil de parole : à mi-chemin (en décibels) entre le fond (dixième centile des tranches) et la voix
    /// (95e centile), mais au moins 8 dB et au plus 12 dB au-dessus du fond, et jamais sous -50 dBFS.
    /// Sans voix, le seuil reste à 8 dB au-dessus du fond : le souffle du micro n'en franchit pas.
    static func threshold(_ levels: [Float]) -> Float {
        guard !levels.isEmpty else { return 0.003 }
        let sorted = levels.sorted()
        let floor = sorted[sorted.count / 10]
        let voice = sorted[Int(Double(sorted.count - 1) * 0.95)]
        let middle = (floor * voice).squareRoot()
        return max(0.003, max(floor * 2.5, min(floor * 4, middle)))
    }

    /// Parole : au moins `run` tranches d'affilée au-dessus du seuil (un clic ou un souffle n'en est pas).
    static func hasSpeech(_ levels: [Float], threshold: Float, run needed: Int = 3) -> Bool {
        var run = 0
        for level in levels {
            run = level > threshold ? run + 1 : 0
            if run >= needed { return true }
        }
        return false
    }
}
