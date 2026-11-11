import AVFoundation
import CoreAudio

/// Capture le son diffusé par le Mac (Teams, Zoom, Meet, navigateur…) en 16 kHz mono Float32,
/// par un « tap » Core Audio sur tous les processus sauf Murmure. Rien ne passe par le réseau :
/// les autres participants d'une visio sont enregistrés tels que le Mac les reçoit, sans écho de la pièce.
///
/// Autorisation « Enregistrement audio du système » demandée par macOS au premier démarrage.
/// Si elle est refusée, macOS ne renvoie pas d'erreur mais du silence.
final class SystemAudioRecorder {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let queue = DispatchQueue(label: "murmure.system-audio", qos: .userInitiated)
    /// Instant auquel l'audio doit commencer (début du micro) ; nil une fois le premier son calé dessus.
    private var reference: Date?
    /// Même instant, gardé toute la capture : pour combler par du silence le trou d'un changement de sortie.
    private var startedAt: Date?
    /// Écoute du changement de sortie par défaut (AirPods, écran avec haut-parleurs), sur le thread principal.
    private var outputListener: AudioObjectPropertyListenerBlock?
    /// Appelé sur le thread principal si la capture ne repart pas après un changement de sortie.
    var onFailure: ((String) -> Void)?
    /// Copie de sûreté sur le disque de la capture en cours, alimentée hors du fil audio.
    private var spool: AudioSpool?
    /// Temps de mise en place mesuré au dernier démarrage, en secondes (diagnostic).
    private(set) var startDelay: Double = 0

    enum Failure: LocalizedError {
        case coreAudio(String, OSStatus)
        var errorDescription: String? {
            if case .coreAudio(let step, let status) = self { return "son de l'ordinateur indisponible (\(step), \(status))" }
            return nil
        }
    }

    var isRunning: Bool { procID != nil }

    /// Démarre la capture. La mise en place prend 1 à 2 s : le début est comblé par du silence pour que
    /// l'échantillon 0 corresponde à `reference` (le démarrage du micro), et que les deux pistes se superposent.
    func start(alignedWith reference: Date = Date(), expecting seconds: Int = 0, spool: AudioSpool? = nil) throws {
        guard !isRunning else { return }
        lock.lock()
        samples = []
        if seconds > 0 { samples.reserveCapacity(seconds * 16_000) }
        self.reference = reference
        startedAt = reference
        self.spool = spool
        lock.unlock()
        do {
            try createTap()
            try createAggregateDevice()
            try startIO()
        } catch {
            teardown()
            throw error
        }
        listenForOutputChange()
    }

    /// Arrête la capture et renvoie l'audio enregistré.
    func stop() -> [Float] {
        teardown()
        lock.lock()
        let result = samples
        samples.removeAll()
        let spool = spool
        self.spool = nil
        lock.unlock()
        spool?.close()
        return result
    }

    /// Copie de l'audio capturé à partir de l'échantillon `index`, sans interrompre la capture (aperçu en direct).
    func capturedAudio(from index: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        guard index < samples.count else { return [] }
        return Array(samples[index...])
    }

    // MARK: Core Audio

    private func createTap() throws {
        // Tous les processus sauf Murmure, mixés en stéréo ; le son continue d'être joué normalement.
        let own = try Self.processObject(pid: ProcessInfo.processInfo.processIdentifier)
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: own.map { [$0] } ?? [])
        description.name = "Murmure"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check("tap", AudioHardwareCreateProcessTap(description, &tapID))

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        try check("format", AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format))
        guard let source = AVAudioFormat(streamDescription: &format) else { throw Failure.coreAudio("format", -1) }
        sourceFormat = source
        converter = AVAudioConverter(from: source, to: targetFormat)
        converter?.downmix = true
    }

    /// Le tap se lit à travers un périphérique agrégé privé (invisible dans les réglages Son),
    /// calé sur l'horloge de la sortie audio actuelle.
    private func createAggregateDevice() throws {
        let outputUID = try Self.defaultOutputUID()
        var tapUID: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        try check("uid", withUnsafeMutablePointer(to: &tapUID) { AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, $0) })

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Murmure – son de l'ordinateur",
            kAudioAggregateDeviceUIDKey: "com.vincentguyot.murmure.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUID as String]],
        ]
        try check("agrégat", AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID))
    }

    private func startIO() throws {
        try check("lecture", AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { [weak self] _, input, _, _, _ in
            self?.process(input)
        })
        try check("démarrage", AudioDeviceStart(deviceID, procID))
    }

    private func teardown() {
        stopListening()
        stopIO()
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Arrête la lecture et détruit l'agrégat ; le tap reste.
    private func stopIO() {
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
        if deviceID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(deviceID) }
        deviceID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: Changement de sortie

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private func listenForOutputChange() {
        guard outputListener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.outputChanged() }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress,
                                                         DispatchQueue.main, block)
        if status == noErr { outputListener = block } else { print("[son] écoute du changement de sortie impossible (\(status))") }
    }

    private func stopListening() {
        guard let outputListener else { return }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress,
                                               DispatchQueue.main, outputListener)
        self.outputListener = nil
    }

    /// La sortie par défaut a changé : l'agrégat était calé sur l'horloge de l'ancienne et ne livre plus rien.
    /// Le trou est comblé par du silence jusqu'au temps écoulé (les deux pistes restent alignées par index),
    /// puis l'agrégat est recréé sur la nouvelle sortie, avec le même tap.
    private func outputChanged() {
        guard isRunning else { return }
        stopIO()
        lock.lock()
        if let startedAt {
            let expected = Int(Date().timeIntervalSince(startedAt) * targetFormat.sampleRate)
            if samples.count < expected {
                let silence = [Float](repeating: 0, count: expected - samples.count)
                samples.append(contentsOf: silence)
                spool?.append(silence)
            }
        }
        lock.unlock()
        do {
            try createAggregateDevice()
            try startIO()
            print("[son] sortie changée, capture relancée")
        } catch {
            print("[son] relance impossible après changement de sortie : \(error.localizedDescription)")
            onFailure?("Son de l'ordinateur coupé par le changement de sortie : les participants à distance ne sont plus enregistrés")
        }
    }

    private func process(_ input: UnsafePointer<AudioBufferList>) {
        guard let sourceFormat, let converter,
              let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, bufferListNoCopy: input, deallocator: nil),
              buffer.frameLength > 0 else { return }
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                         frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData?[0] else { return }
        let chunk = UnsafeBufferPointer(start: data, count: Int(out.frameLength))
        lock.lock()
        if let reference {
            let delay = Date().timeIntervalSince(reference) - Double(buffer.frameLength) / sourceFormat.sampleRate
            let silence = [Float](repeating: 0, count: max(0, Int(delay * targetFormat.sampleRate)))
            samples.append(contentsOf: silence)
            spool?.append(silence)
            startDelay = delay
            self.reference = nil
        }
        samples.append(contentsOf: chunk)
        spool?.append(Array(chunk))
        lock.unlock()
    }

    // MARK: Outils

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else { throw Failure.coreAudio(step, status) }
    }

    private static func processObject(pid: pid_t) throws -> AudioObjectID? {
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        // Murmure n'a pas encore d'objet audio s'il n'a rien joué : rien à exclure.
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = defaultOutputAddress
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr else { throw Failure.coreAudio("sortie", status) }

        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        status = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }
        guard status == noErr else { throw Failure.coreAudio("sortie", status) }
        return uid as String
    }
}
