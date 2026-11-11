import AVFoundation
import SwiftUI

/// Test du micro en une dizaine de secondes : Murmure écoute d'abord la pièce (bruit de fond), puis la lecture
/// d'une phrase du métier, qu'il transcrit au fil de l'eau. Le verdict dit ce qui ne va pas et quoi y faire.
/// Le micro n'est ouvert que pendant le test ; l'audio n'est gardé qu'en mémoire, pour la réécoute.
@MainActor
final class MicTest: ObservableObject {
    enum Phase: Equatable { case idle, room, reading, checking, done }

    struct Verdict: Equatable {
        var title: String
        var detail: String
        var good: Bool
        /// Réglages Système › Son peut aider (entrée, volume d'entrée).
        var suggestsSound = false
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var level: Float = 0
    /// Mots de la phrase reconnus (indices dans `words`).
    @Published private(set) var heard: Set<Int> = []
    @Published private(set) var verdict: Verdict?
    /// Bruit de la pièce (dBFS) et écart de la voix au-dessus du bruit (dB).
    @Published private(set) var noise: Float?
    @Published private(set) var margin: Float?
    @Published private(set) var playing = false

    let sentence: String
    let words: [String]
    private let folded: [String]
    private let recorder = AudioRecorder()
    private var run: Task<Void, Never>?
    private var speech: [Float] = []
    private var player: AVAudioPlayer?
    private var playerDelegate: PlayerDelegate?

    init(sentence: String) {
        self.sentence = sentence
        words = sentence.split(separator: " ").map(String.init)
        folded = words.map(Self.fold)
    }


    func start() {
        cancel()
        heard = []; verdict = nil; noise = nil; margin = nil; speech = []
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            finish(Verdict(title: "Micro non autorisé", detail: "Autorisez le micro pour Murmure dans Réglages Système › Confidentialité › Micro, puis relancez le test.", good: false))
            return
        }
        recorder.onLevel = { [weak self] value in self?.level = value }
        do {
            try recorder.start()
        } catch {
            finish(Verdict(title: "Micro indisponible", detail: error.localizedDescription, good: false, suggestsSound: true))
            return
        }
        phase = .room
        run = Task { await listen() }
    }

    func cancel() {
        run?.cancel()
        run = nil
        if phase == .room || phase == .reading { _ = recorder.stop() }
        if phase != .done { phase = .idle }
        level = 0
        player?.stop()
        playing = false
    }

    // MARK: Déroulé

    private func listen() async {
        // 1. La pièce, en silence : 2 s, dont on ne garde que la dernière seconde et demie (le clic de départ s'estompe).
        //    Le fond est le niveau des tranches de 100 ms les plus calmes (cinquième centile) : une moyenne
        //    grimpait au moindre clic, souffle ou démarrage du micro, et annonçait une pièce bruyante à tort.
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }
        let room = SpeechLevels.levels(recorder.recentAudio(24_000), frame: 1_600).sorted()
        let roomLevel = room.isEmpty ? 0 : room[room.count / 5]
        noise = Self.decibels(roomLevel)
        let start = recorder.recentAudio(Int.max).count

        // 2. La phrase : transcrite au fil de l'eau ; fin quand tout est reconnu, après 1,5 s de silence
        //    une fois la voix entendue, sans voix au bout de 7 s, ou au bout de 15 s.
        phase = .reading
        let began = Date()
        var spokeAt: Date?
        var quietSince: Date?
        var lastPass = Date.distantPast
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(150))
            let elapsed = Date().timeIntervalSince(began)
            let recent = Self.rms(recorder.recentAudio(3_200))
            let loud = recent > max(roomLevel * 3, 0.002)
            if loud { spokeAt = spokeAt ?? Date(); quietSince = nil } else if quietSince == nil { quietSince = Date() }

            if spokeAt != nil, Date().timeIntervalSince(lastPass) > 0.7 {
                lastPass = Date()
                await recognize(recorder.capturedAudio(from: start))
            }
            if heard.count == words.count { try? await Task.sleep(for: .milliseconds(400)); break }
            if spokeAt != nil, let quietSince, Date().timeIntervalSince(quietSince) > 1.5 { break }
            if spokeAt == nil, elapsed > 7 { break }
            if elapsed > 15 { break }
        }
        guard !Task.isCancelled else { return }

        // 3. Vérification : dernière transcription sur toute la lecture, puis le verdict.
        phase = .checking
        let audio = recorder.stop()
        level = 0
        speech = start < audio.count ? Array(audio[start...]) : []
        await recognize(speech)
        guard !Task.isCancelled else { return }
        finish(judge(roomLevel: roomLevel))
    }

    private func recognize(_ audio: [Float]) async {
        guard audio.count > 8_000, AppState.shared.modelStatus == .ready,
              let transcriber = AppDelegate.shared?.transcriber,
              let text = try? await transcriber.transcribe(audio) else { return }
        let found = Set(text.split(whereSeparator: { $0.isWhitespace || $0 == "'" || $0 == "’" }).map { Self.fold(String($0)) })
        var matched = heard
        for (index, word) in folded.enumerated() {
            // « l'acte » : il suffit que la partie après l'apostrophe soit entendue.
            let core = word.split(separator: "'").last.map(String.init) ?? word
            if found.contains(word) || found.contains(core) { matched.insert(index) }
        }
        if matched != heard { withAnimation(Motion.quick) { heard = matched } }
    }

    private func judge(roomLevel: Float) -> Verdict {
        let frames = stride(from: 0, to: max(speech.count - 1_600, 0), by: 1_600).map { Self.rms(Array(speech[$0 ..< $0 + 1_600])) }.sorted()
        let voice = frames.isEmpty ? 0 : frames[Int(Double(frames.count - 1) * 0.9)]
        let clipped = speech.lazy.filter { abs($0) > 0.98 }.count
        margin = voice > 0 && roomLevel > 0 ? 20 * log10f(voice / roomLevel) : nil
        let total = words.count
        let recognized = heard.count

        if (frames.last ?? 0) < 0.001 && roomLevel < 0.001 {
            return Verdict(title: "Aucun son", detail: "Le micro ne livre rien : il est peut-être coupé, ou l'entrée choisie n'est pas la bonne.", good: false, suggestsSound: true)
        }
        if voice < 0.003 || (margin ?? 0) < 8 {
            return Verdict(title: "Voix à peine audible", detail: "Rapprochez-vous du micro ou montez le volume d'entrée.", good: false, suggestsSound: true)
        }
        if clipped > speech.count / 1_000 {
            return Verdict(title: "Son saturé", detail: "Votre voix arrive trop fort : éloignez-vous un peu ou baissez le volume d'entrée.", good: false, suggestsSound: true)
        }
        if AppState.shared.modelStatus == .ready, recognized * 10 < total * 6 {
            return Verdict(title: "Voix captée, mots mal reconnus", detail: "\(recognized) mots sur \(total) reconnus. Parlez un peu plus lentement, ou essayez un autre micro.", good: false, suggestsSound: true)
        }
        // Écart faible : la pièce n'est en cause que si son fond est vraiment haut ; sinon, la voix arrive de loin.
        if (margin ?? 99) < 18, Self.decibels(roomLevel) > Self.noisyRoom {
            return Verdict(title: "Voix captée, pièce bruyante", detail: "Le bruit de fond peut gêner en réunion : un casque avec micro aide beaucoup.", good: true)
        }
        if (margin ?? 99) < 18 || Self.decibels(voice) < -40 {
            return Verdict(title: "Voix captée, un peu lointaine", detail: "Rapprochez-vous du micro : un micro externe ou un casque, toujours à la même distance de la bouche, rend la dictée plus régulière.", good: true)
        }
        let words = AppState.shared.modelStatus == .ready ? " : \(recognized) mots sur \(total) reconnus" : ""
        return Verdict(title: "Voix bien captée", detail: "Murmure vous entend clairement\(words).", good: true)
    }

    private func finish(_ result: Verdict) {
        withAnimation(Motion.pop) {
            verdict = result
            phase = .done
        }
    }

    // MARK: Réécoute

    var canReplay: Bool { speech.count > 8_000 }

    func replay() {
        if playing { player?.stop(); playing = false; return }
        guard let player = try? AVAudioPlayer(data: Self.wav(speech)) else { return }
        let delegate = PlayerDelegate { [weak self] in Task { @MainActor in self?.playing = false } }
        player.delegate = delegate
        self.player = player
        playerDelegate = delegate
        playing = player.play()
    }

    private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
        let done: () -> Void
        init(done: @escaping () -> Void) { self.done = done }
        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { done() }
    }

    // MARK: Calculs

    static func rms(_ samples: [Float]) -> Float {
        samples.isEmpty ? 0 : sqrtf(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
    }

    static func decibels(_ rms: Float) -> Float { 20 * log10f(max(rms, 1e-6)) }

    /// Fond de pièce (dBFS) au-delà duquel on la dit bruyante. Un micro de portable au calme donne -50 à -60.
    static let noisyRoom: Float = -40

    /// Minuscules, sans accents ni ponctuation : « Maître, » et « maitre » se valent.
    static func fold(_ word: String) -> String {
        word.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "'")))
            .trimmingCharacters(in: CharacterSet(charactersIn: "'"))
    }

    /// WAV 16 kHz mono 16 bits, pour la réécoute.
    private static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); put(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(16_000)); put(UInt32(32_000)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(bytes)
        for sample in samples { put(Int16(max(-1, min(1, sample)) * 32_767)) }
        return data
    }
}

// MARK: - Vue

/// Carte du test micro : vumètre avec sa zone idéale, phrase dont les mots s'allument, verdict et réécoute.
struct MicTestView: View {
    @StateObject private var test: MicTest
    /// Carte à filet (accueil) ; sans filet dans une section de Réglages, qui a déjà le sien.
    private let framed: Bool

    init(sentence: String = Settings.profession.testSentence, framed: Bool = true) {
        _test = StateObject(wrappedValue: MicTest(sentence: sentence))
        self.framed = framed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                MicrophonePicker { test.cancel() }
                Spacer()
                status.foregroundStyle(Theme.muted)
            }

            Meter(level: test.level, active: test.phase == .room || test.phase == .reading)

            Text(phrase)
                .font(.ui(17, weight: .medium))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .animation(Motion.quick, value: test.heard)

            if test.phase == .done, let verdict = test.verdict {
                result(verdict).transition(Motion.popTransition())
            } else {
                HStack {
                    Text(hint).font(.ui(12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    if test.phase == .idle {
                        Button("Lancer le test", action: test.start).buttonStyle(OutlineButtonStyle(prominent: true))
                    } else {
                        Button("Arrêter", action: test.cancel).buttonStyle(OutlineButtonStyle())
                    }
                }
            }
        }
        .padding(framed ? 18 : 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(framed ? Theme.line : .clear))
        .onDisappear { test.cancel() }
    }

    /// La phrase, mot par mot : en gris tant qu'il n'est pas reconnu, à l'encre une fois entendu.
    private var phrase: AttributedString {
        var result = AttributedString()
        for (index, word) in test.words.enumerated() {
            var part = AttributedString(word + (index < test.words.count - 1 ? " " : ""))
            part.foregroundColor = test.heard.contains(index) || test.phase == .idle ? Theme.fg : Theme.muted.opacity(0.55)
            result += part
        }
        return result
    }

    @ViewBuilder private var status: some View {
        switch test.phase {
        case .room: Text("Écoute de la pièce…").font(.ui(12))
        case .reading: Text("\(test.heard.count) / \(test.words.count) mots").font(.ui(12)).monospacedDigit()
        case .checking: HStack(spacing: 6) { Spinner(size: 10, color: Theme.muted, lineWidth: 1.2); Text("Vérification…").font(.ui(12)) }
        default: EmptyView()
        }
    }

    private var hint: String {
        switch test.phase {
        case .idle: return "Une dizaine de secondes : un instant de silence, puis cette phrase à lire."
        case .room: return "Ne dites rien : Murmure mesure le bruit de la pièce."
        case .reading: return "Lisez la phrase à voix haute, à votre rythme."
        default: return "Murmure vérifie ce qu'il a entendu."
        }
    }

    private func result(_ verdict: MicTest.Verdict) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: verdict.good ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.ui(18))
                    .foregroundStyle(verdict.good ? Theme.fg : Theme.folderTint(1))
                VStack(alignment: .leading, spacing: 3) {
                    Text(verdict.title).font(.ui(14, weight: .semibold))
                    Text(verdict.detail).font(.ui(12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                if let noise = test.noise { Figure(label: "Pièce", value: Self.room(noise)) }
                if let margin = test.margin { Figure(label: "Voix au-dessus du bruit", value: "\(Int(margin.rounded())) dB") }
                if AppState.shared.modelStatus == .ready { Figure(label: "Mots reconnus", value: "\(test.heard.count) / \(test.words.count)") }
            }
            HStack(spacing: 8) {
                if test.canReplay {
                    Button(test.playing ? "Arrêter la réécoute" : "Réécouter", action: test.replay).buttonStyle(OutlineButtonStyle())
                }
                if verdict.suggestsSound {
                    Button("Réglages Son") { SystemSettings.open(.soundInput) }.buttonStyle(OutlineButtonStyle())
                }
                Spacer()
                Button("Recommencer", action: test.start).buttonStyle(OutlineButtonStyle(prominent: !verdict.good))
            }
        }
    }

    static func room(_ decibels: Float) -> String {
        decibels < -50 ? "Calme" : decibels < MicTest.noisyRoom ? "Bruit modéré" : "Bruyante"
    }

    private struct Figure: View {
        let label: String
        let value: String

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.ui(11)).foregroundStyle(Theme.muted)
                Text(value).font(.ui(15, weight: .semibold)).monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.soft))
        }
    }
}

/// Vumètre en barres : les barres s'allument de gauche à droite avec la voix ; la bande sous elles marque
/// la zone où la voix est bien captée (ni trop faible, ni saturée).
private struct Meter: View {
    let level: Float
    let active: Bool
    private static let count = 32
    static let zone: ClosedRange<Double> = 0.3...0.85

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<Self.count, id: \.self) { index in
                    let position = Double(index) / Double(Self.count)
                    let lit = active && position < Double(level)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(lit ? (position > Self.zone.upperBound ? Theme.folderTint(1) : Theme.fg) : Theme.line)
                        .frame(height: 10 + 26 * CGFloat(position))
                }
            }
            .frame(height: 36, alignment: .bottom)
            .animation(Motion.meter, value: level)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.soft)
                    Capsule().fill(Theme.line)
                        .frame(width: geometry.size.width * (Self.zone.upperBound - Self.zone.lowerBound))
                        .offset(x: geometry.size.width * Self.zone.lowerBound)
                }
            }
            .frame(height: 4)
            HStack {
                Text("Trop faible")
                Spacer()
                Text("Idéal")
                Spacer()
                Text("Trop fort")
            }
            .font(.ui(10))
            .foregroundStyle(Theme.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Niveau du micro")
        .accessibilityValue(active ? "\(Int(level * 100)) %" : "arrêté")
    }
}

/// Choix du micro, en tête du test : l'entrée du système, ou un micro précis que Murmure garde même quand macOS
/// bascule ailleurs (iPhone à proximité, Teams, AirPods). La liste est relue à chaque ouverture du menu.
struct MicrophonePicker: View {
    /// Appelé quand le choix change (le test en cours s'arrête : il écoutait l'ancien micro).
    var onChange: () -> Void = {}
    @AppStorage("microphone") private var microphone = ""
    /// Lu ici pour que le libellé suive le réglage « Éviter le micro des écouteurs Bluetooth ».
    @AppStorage("avoidBluetoothMic") private var avoidBluetoothMic = true

    var body: some View {
        MenuButton(entries: entries) {
            HStack(spacing: 6) {
                Image(systemName: "mic").font(.ui(12))
                Text(label).font(.ui(12)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.ui(9))
            }
            .foregroundStyle(Theme.fg)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line))
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Micro utilisé par Murmure")
    }

    private var label: String {
        guard !microphone.isEmpty, !Microphones.all().contains(where: { $0.uid == microphone }) else { return Microphones.currentName }
        return "Micro choisi débranché : \(Microphones.currentName)"
    }

    private func entries() -> [MenuEntry] {
        let devices = Microphones.all()
        let replacement = Microphones.bluetoothReplacement()
        let system = replacement.map { "\($0.builtIn.name) au lieu de \($0.headset.name)" } ?? Microphones.systemDefault()?.name ?? "micro du Mac"
        var entries: [MenuEntry] = [
            .action("Entrée du système (\(system))", checked: microphone.isEmpty) { choose("") },
        ]
        if replacement != nil, microphone.isEmpty {
            entries.append(.header("Les écouteurs gardent le son, sans passer en mode téléphone"))
        }
        entries.append(.divider)
        entries += devices.map { device in .action(device.name, checked: device.uid == microphone) { choose(device.uid) } }
        if !microphone.isEmpty, !devices.contains(where: { $0.uid == microphone }) {
            entries += [.divider, .header("Micro choisi débranché : Murmure prend l'entrée du système")]
        }
        return entries
    }

    private func choose(_ uid: String) {
        guard uid != microphone else { return }
        microphone = uid
        onChange()
    }
}
