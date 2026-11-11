import Foundation

/// Enregistrement d'une réunion (micro ouvert jusqu'à l'arrêt), puis traitement en arrière-plan :
/// voix → transcription → compte rendu → titre. L'audio est gardé en mémoire le temps du traitement ;
/// une copie de sûreté de chaque piste (`AudioSpool`) est écrite au fil de l'eau dans `Enregistrements/`
/// et supprimée à la fin du traitement : un plantage ou une fermeture ne perd plus la réunion, qui reprend
/// au lancement suivant (`resumeInterrupted`).
///
/// Avec le réglage « son de l'ordinateur », le son diffusé par le Mac (visio Teams, Zoom, Meet…) est capté
/// en plus du micro : les participants à distance sont enregistrés nettement, et la voix de l'utilisateur,
/// seule à dominer au micro, est reconnue et nommée « Moi ».
final class MeetingController {
    private let recorder = AudioRecorder()
    private let system = SystemAudioRecorder()
    private let transcriber: Transcriber
    private let state = AppState.shared
    /// Rendez-vous de l'agenda en cours au lancement : titre et invités de la réunion.
    private var event: CalendarEvent?
    /// Avertissement à montrer dans la pastille (micro ou son de l'ordinateur coupé en cours de réunion).
    var onWarning: ((String) -> Void)?
    /// Identifiant de la réunion en cours, choisi au départ : nomme les copies de sûreté, puis la fiche.
    private var currentID = UUID()
    private lazy var live = LiveTranscriber(transcriber: transcriber) { [recorder, system] index in
        MeetingAudio.sum(recorder.capturedAudio(from: index), system.capturedAudio(from: index))
    }

    /// Niveau du micro pendant la réunion (fil principal), pour prévenir d'un micro muet.
    var onLevel: ((Float) -> Void)?
    /// Toutes les 10 s pendant la réunion (fil principal) : secondes écoulées sans que personne parle,
    /// au micro ou dans le son de l'ordinateur (0 dès que l'on reparle).
    var onQuiet: ((TimeInterval) -> Void)?
    private var quiet = QuietMeter()
    private var quietTimer: Timer?
    /// Premier échantillon pas encore mesuré par `quiet`.
    private var quietRead = 0

    init(transcriber: Transcriber) {
        self.transcriber = transcriber
        recorder.onFailure = { [weak self] message in self?.onWarning?(message) }
        system.onFailure = { [weak self] message in self?.onWarning?(message) }
        recorder.onLevel = { [weak self] level in self?.onLevel?(level) }
    }

    var isRecording: Bool { state.meetingStartedAt != nil }

    /// Place réservée dans chaque piste au départ (2 h) : au-delà, le tableau grandit comme avant.
    private static let expectedSeconds = 2 * 3600

    /// `event` : rendez-vous imposé (enregistrement programmé à son heure) ; sinon celui en cours dans l'agenda.
    func start(event: CalendarEvent? = nil) throws {
        guard !isRecording else { return }
        let started = Date()
        currentID = UUID()
        try recorder.start(expecting: Self.expectedSeconds, spool: AudioSpool(id: currentID, track: .mic))
        self.event = event ?? Connectors.currentEvent(at: started)
        if Settings.meetingSystemAudio {
            // Sans le son de l'ordinateur, la réunion s'enregistre quand même, au micro seul.
            do {
                try system.start(alignedWith: started, expecting: Self.expectedSeconds, spool: AudioSpool(id: currentID, track: .system))
            } catch { print("[réunion] \(error.localizedDescription)") }
        }
        state.meetingStartedAt = Date()
        state.liveNotes = ""
        state.meetingKeepLocal = false
        live.start()
        startQuietWatch()
    }

    private func startQuietWatch() {
        quiet = QuietMeter()
        quietRead = 0
        quietTimer?.invalidate()
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            guard let self, self.isRecording else { return }
            let chunk = MeetingAudio.sum(self.recorder.capturedAudio(from: self.quietRead), self.system.capturedAudio(from: self.quietRead))
            guard !chunk.isEmpty else { return }
            self.quietRead += chunk.count
            self.quiet.feed(chunk)
            self.onQuiet?(self.quiet.quietSeconds)
        }
        RunLoop.main.add(timer, forMode: .common)
        quietTimer = timer
    }

    private func stopQuietWatch() {
        quietTimer?.invalidate()
        quietTimer = nil
    }

    func cancel() {
        live.stop()
        stopQuietWatch()
        _ = recorder.stop()
        _ = system.stop()
        AudioSpool.delete(currentID)
        state.meetingStartedAt = nil
        state.liveNotes = ""
        state.meetingKeepLocal = false
    }

    /// Arrête l'enregistrement et lance le traitement ; renvoie la réunion créée.
    @discardableResult
    func stop() -> UUID? {
        guard isRecording else { return nil }
        live.stop()
        stopQuietWatch()
        let tracks = MeetingAudio(mic: recorder.stop(), system: system.stop())
        let audio = tracks.mixed
        state.meetingStartedAt = nil
        let notes = state.liveNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        state.liveNotes = ""
        let keepLocal = state.meetingKeepLocal
        state.meetingKeepLocal = false
        guard audio.count > 16_000 * 2 else { AudioSpool.delete(currentID); return nil }

        let date = Date()
        let dated = Self.datedTitle(date)
        let id = RecordingStore.shared.add(
            text: "", rawText: "", duration: Double(audio.count) / 16_000, appName: nil,
            kind: .meeting, title: event?.title ?? dated, progress: "Transcription…", id: currentID
        )
        if let attendees = event?.attendees, !attendees.isEmpty { RecordingStore.shared.update(id) { $0.attendees = attendees } }
        if let eventTitle = event?.title { RecordingStore.shared.update(id) { $0.sourceTitle = eventTitle } }
        if !notes.isEmpty { RecordingStore.shared.setNotes(id, notes) }
        if keepLocal { RecordingStore.shared.update(id) { $0.keepLocal = true } }
        // Le titre du rendez-vous (souvent un créneau : « Bosser anglais », « ERIKSSON ») n'est que provisoire :
        // à la fin, un titre est tiré du compte rendu, qui reprend le nom du rendez-vous s'il est cohérent.
        // Un titre changé par l'utilisateur entre-temps est gardé.
        let placeholder = event?.title ?? dated
        event = nil
        state.openRecording = id
        let transcriber = transcriber
        // Seules les énergies par tranche sont gardées pour reconnaître « Moi » : les deux pistes
        // (2 × 460 Mo pour 2 h) sont libérées dès maintenant, l'audio mixé suffit au traitement.
        let micShare = tracks.hasSystemAudio ? tracks.micShareByFrame() : nil
        Task.detached(priority: .utility) {
            await Self.process(id: id, audio: audio, placeholder: placeholder, transcriber: transcriber, micShare: micShare)
        }
        return id
    }

    /// Termes donnés à la transcription pour la graphie des noms : le titre de la réunion (celui du rendez-vous ou
    /// du fichier importé, pas un titre daté) et les noms des invités. Un nom du titre tout en capitales
    /// (« ERIKSSON », usage des dossiers : cinq lettres au moins, deux voyelles) est remis en minuscules avec une
    /// initiale, comme on l'écrit dans un texte ; un sigle (« SAS », « TVA ») reste tel quel. Un titre réduit à un
    /// mot du français (« Audience ») n'est pas un terme.
    static func contextTerms(for recording: Recording) -> [String] {
        var terms: [String] = []
        let title = (recording.sourceTitle ?? recording.title).trimmingCharacters(in: .whitespaces)
        if !title.isEmpty, !title.hasPrefix("Réunion du "), title != "Réunion de test" {
            let words = title.split(separator: " ").map { word -> String in
                let text = String(word)
                let vowels = text.lowercased().filter { "aeiouyàâéèêëîïôûùü".contains($0) }.count
                guard text.count >= 5, vowels >= 2, text == text.uppercased(), text != text.lowercased() else { return text }
                return text.prefix(1) + text.dropFirst().lowercased()
            }
            let term = words.joined(separator: " ")
            if words.count > 1 || !Cleaner.isFrenchWord(term.lowercased()) { terms.append(term) }
        }
        for attendee in recording.attendees ?? [] where !attendee.isMe {
            let name = attendee.name.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !name.contains("@"), !terms.contains(name) { terms.append(name) }
        }
        return terms
    }

    static func datedTitle(_ date: Date) -> String {
        "Réunion du \(date.formatted(.dateTime.day().month(.twoDigits).year())) à \(date.formatted(date: .omitted, time: .shortened))"
    }

    /// Au lancement (modèles chargés) : reprend les réunions dont une copie de sûreté est restée sur le disque,
    /// interrompues pendant l'enregistrement (pas de fiche : on la crée) ou pendant le traitement (la fiche est
    /// encore « en cours »). Une fiche aboutie dont les fichiers traînent est simplement nettoyée.
    /// Renvoie les identifiants des réunions reprises.
    static func resumeInterrupted(transcriber: Transcriber) async -> [UUID] {
        let store = RecordingStore.shared
        var resumed: [UUID] = []
        // Une transcription en ligne laissée par l'arrêt est supprimée du service avant tout nouvel envoi.
        await PendingDeletions.sweep()
        for id in AudioSpool.interrupted() {
            let existing = await MainActor.run { store.recording(id) }
            if let existing, existing.progress == nil {
                AudioSpool.delete(id)
                continue
            }
            let mic = (try? AudioFile.load(AudioSpool.url(id: id, track: .mic))) ?? []
            let system = (try? AudioFile.load(AudioSpool.url(id: id, track: .system))) ?? []
            guard mic.count > 16_000 * 2 else {
                print("[réunion] copie de sûreté \(id) vide ou illisible")
                AudioSpool.delete(id)
                await MainActor.run {
                    store.update(id) {
                        $0.progress = nil
                        if $0.text.isEmpty { $0.processingError = "L'audio de la réunion n'a pas pu être relu après l'arrêt de Murmure." }
                    }
                }
                continue
            }
            let tracks = MeetingAudio(mic: mic, system: system)
            let audio = tracks.mixed
            let micShare = tracks.hasSystemAudio ? tracks.micShareByFrame() : nil
            let placeholder: String?
            if let existing {
                // Un titre daté ou celui du rendez-vous (pas celui de l'utilisateur) reste à remplacer par un titre généré.
                placeholder = existing.title.hasPrefix("Réunion du ") || existing.title == existing.sourceTitle ? existing.title : nil
                await MainActor.run { store.update(id) { $0.progress = "Reprise…"; $0.processingError = nil } }
            } else {
                let title = datedTitle(AudioSpool.startDate(id) ?? Date())
                placeholder = title
                await MainActor.run {
                    _ = store.add(text: "", rawText: "", duration: Double(audio.count) / 16_000, appName: nil,
                                  kind: .meeting, title: title, progress: "Reprise…", id: id)
                    // Arrêt brutal pendant l'enregistrement : on ne sait plus si « Garder sur ce Mac » avait été
                    // choisi. Dans le doute, la réunion reste sur ce Mac.
                    store.update(id) { $0.keepLocal = true }
                }
            }
            print("[réunion] reprise de \(id) après un arrêt brutal (\(Int(Double(audio.count) / 16_000 / 60)) min)")
            await process(id: id, audio: audio, placeholder: placeholder, transcriber: transcriber, micShare: micShare)
            resumed.append(id)
        }
        return resumed
    }

    /// Importe un enregistrement (dictaphone, mémo vocal, audience) et le traite comme une réunion : lecture du
    /// fichier en arrière-plan, puis la même chaîne que l'arrêt d'une réunion. Le fichier n'est ni copié ni modifié ;
    /// la fiche porte la date du fichier et son nom, remplacé par un titre généré.
    @discardableResult
    func importFile(_ url: URL) -> UUID {
        let name = url.deletingPathExtension().lastPathComponent
        let id = RecordingStore.shared.add(text: "", rawText: "", duration: 0, appName: nil, kind: .meeting,
                                           title: name, progress: "Lecture du fichier…", date: AudioFile.creationDate(url))
        RecordingStore.shared.update(id) { $0.sourceTitle = name }
        state.openRecording = id
        let transcriber = transcriber
        Task.detached(priority: .utility) {
            let audio: [Float]
            do { audio = try AudioFile.load(url) } catch {
                await MainActor.run {
                    RecordingStore.shared.update(id) {
                        $0.progress = nil
                        $0.title += " (import impossible)"
                        $0.processingError = "Lecture impossible : \(error.localizedDescription)"
                    }
                }
                return
            }
            await MainActor.run {
                RecordingStore.shared.update(id) {
                    $0.duration = Double(audio.count) / 16_000
                    $0.progress = "Transcription…"
                }
            }
            await Self.process(id: id, audio: audio, placeholder: name, transcriber: transcriber, allowOnline: Settings.onlineImports)
        }
        return id
    }

    /// `placeholder` : titre provisoire à remplacer par un titre généré (nil pour garder le titre actuel).
    /// À la fin (synthèse faite ou non), la copie de sûreté audio est supprimée.
    /// `allowOnline` : faux pour un enregistrement importé, sauf réglage contraire (il part dès sa lecture, sans cadenas).
    static func process(id: UUID, audio: [Float], placeholder: String?, transcriber: Transcriber,
                        micShare: ((Int, Int) -> Float)? = nil, allowOnline: Bool = true) async {
        let store = RecordingStore.shared
        defer { AudioSpool.delete(id) }
        // Avancement affiché dans la fiche et dans la liste de l'accueil.
        let debug = ProcessInfo.processInfo.environment["MURMURE_DEBUG"] != nil
        let progress: Transcriber.Progress = { label in
            if debug { print("[réunion] \(label)") }
            Task { @MainActor in store.setProgress(id, label) }
        }

        // 1. Qui parle, et ce qui est dit. Un échec est journalisé et gardé dans la fiche : un texte vide
        // ne doit plus rester « Sans contenu » sans explication.
        var voices: Transcriber.SpeakerTurns?
        var problem: String?
        let context = await MainActor.run { store.recording(id).map(contextTerms) ?? [] }
        if debug, !context.isEmpty { print("[réunion] termes du contexte : \(context.joined(separator: ", "))") }
        // En ligne si le réglage le demande et que la réunion peut quitter le Mac ; sinon, ou en cas d'échec, sur ce Mac.
        // Le droit d'envoyer est relu juste avant l'envoi, avant la création et à chaque sondage : un cadenas, un
        // dossier « Jamais en ligne », la corbeille ou « Rester hors ligne » choisis entre-temps arrêtent tout.
        @Sendable func mayGoOnline() async -> Bool {
            await MainActor.run {
                guard allowOnline, !Settings.stayOffline, let recording = store.recording(id) else { return false }
                return !store.isLocalOnly(recording) && !recording.isTrashed
            }
        }
        var transcribedBy = "local"
        var onlineFailure: String?
        /// Texte d'une réunion à une seule voix transcrite en ligne (pas de tours de parole, comme sur ce Mac).
        var singleVoice: String?
        if OnlineTranscription.isChosen, !OnlineTranscription.hasKey, await mayGoOnline() {
            onlineFailure = OnlineTranscription.Failure.noKey.errorDescription
        }
        if OnlineTranscription.isUsable, await mayGoOnline() {
            defer { Task.detached { await PendingDeletions.sweep() } }
            do {
                // Le service ne donne pas d'empreintes de voix : elles sont calculées sur ce Mac (quelques secondes).
                let local = Settings.recognizeVoices ? try? await transcriber.voices(audio) : nil
                let online = try await OnlineTranscription.turns(audio, micShare: micShare, context: context, recording: id,
                                                                 local: local, stillAllowed: mayGoOnline, progress: progress)
                if Set(online.turns.map(\.speaker)).count >= 2 {
                    voices = online
                } else {
                    singleVoice = online.turns.map(\.text).joined(separator: " ")
                }
                transcribedBy = "online"
            } catch {
                print("[réunion] transcription en ligne impossible, reprise sur ce Mac : \(error.localizedDescription)")
                onlineFailure = error.localizedDescription
            }
        }
        if transcribedBy == "local" {
            do {
                voices = try await transcriber.speakerTurns(audio, micShare: micShare, context: context, progress: progress)
            } catch {
                print("[réunion] distinction des voix impossible : \(error)")
                problem = "Distinction des voix impossible : \(error.localizedDescription)"
                voices = nil
            }
        }
        let by = transcribedBy, failedOnline = onlineFailure
        await MainActor.run {
            store.update(id) {
                $0.transcribedBy = by
                $0.onlineFailure = failedOnline
            }
        }
        let turns = voices?.turns
        let own = voices?.own
        let prints = voices?.prints
        let raw: String
        if let turns {
            raw = turns.map(\.text).joined(separator: " ")
        } else if let singleVoice {
            raw = singleVoice
        } else {
            do {
                raw = try await transcriber.transcribeLong(audio, context: context, progress: progress)
            } catch {
                print("[réunion] transcription impossible : \(error)")
                problem = "Transcription impossible : \(error.localizedDescription)"
                raw = ""
            }
        }
        let text = Cleaner.applyCommands(raw)
        let failure = problem ?? (text.isEmpty ? "Aucune parole reconnue : micro muet, coupé ou sans autorisation ?" : nil)
        await MainActor.run {
            store.update(id) {
                $0.turns = turns
                $0.text = text
                $0.rawText = raw
                $0.progress = text.isEmpty ? nil : "Synthèse…"
                $0.processingError = text.isEmpty ? failure : nil
            }
            if let own {
                store.setSpeakerName(id, speaker: own, name: "Moi")
                store.update(id) { $0.ownSpeaker = own } // gardé même si « Moi » est renommé ensuite
            }
            // Voix reconnues d'une réunion à l'autre : nommées avant le compte rendu, qui reprend leurs noms.
            if let prints, turns != nil {
                VoiceBook.shared.remember(id, prints: prints)
                if let own { VoiceBook.shared.learnOwnFromMicrophone(id, speaker: own) }
                let named = VoiceBook.shared.recognize(id)
                if debug, !named.isEmpty {
                    print("[réunion] voix reconnues : " + named.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }.joined(separator: ", "))
                }
            }
        }
        guard !text.isEmpty else { return }

        // 2. Compte rendu et titre, si le modèle de langage est disponible (sur le Mac pour un dossier « jamais en ligne »).
        let localOnly = await MainActor.run { store.recording(id).map { store.isLocalOnly($0) } ?? false }
        guard Cleaner.isReady(localOnly: localOnly), let recording = await MainActor.run(body: { store.recording(id) }) else {
            await MainActor.run {
                store.update(id) { $0.progress = nil }
                Notifier.meetingReady(id)
            }
            return
        }
        do {
            try await Cleaner.$localOnly.withValue(localOnly) {
                let summary = try await Summarizer.generate(transcript: recording.transcript, participants: recording.participantNames,
                                                            template: Settings.meetingTemplate, notes: recording.userNotes, progress: progress)
                let title = placeholder == nil ? nil : await Cleaner.makeMeetingTitle(summary: summary, hint: recording.sourceTitle)
                await MainActor.run {
                    store.addSummary(id, Summary(template: Settings.meetingTemplate.rawValue, text: summary, date: Date()))
                    // Point bleu jusqu'à l'ouverture de la fiche (la fiche ouverte au premier plan le retire aussitôt).
                    store.setSummaryUnread(id, true)
                    if let title, let placeholder { store.setGeneratedTitle(id, title, replacing: placeholder) }
                    store.update(id) { $0.processingError = nil }
                    Automations.summaryReady(id, localOnly: localOnly)
                }
            }
        } catch {
            // Gardé dans la fiche : l'onglet Synthèse le dit, et « Rédiger un compte rendu » reste possible.
            print("[réunion] synthèse impossible : \(error.localizedDescription)")
            await MainActor.run { store.update(id) { $0.processingError = error.localizedDescription } }
        }
        await MainActor.run {
            store.update(id) { $0.progress = nil }
            Notifier.meetingReady(id)
        }
    }
}

/// Les deux pistes d'une réunion : micro (la pièce) et son de l'ordinateur (la visio).
struct MeetingAudio {
    let mic: [Float]
    let system: [Float]
    let micGain: Float
    let systemGain: Float
    /// Écho des haut-parleurs repéré au micro (visio sans casque), retiré du mélange ; nil avec un casque.
    let echo: EchoGate.Analysis?

    init(mic: [Float], system: [Float]) {
        self.mic = mic
        self.system = system
        micGain = Self.gain(mic)
        systemGain = Self.gain(system)
        echo = Self.speechLevel(system) > 0.002 ? EchoGate.analyze(mic: mic, system: system) : nil
    }

    /// Le son de l'ordinateur contient-il quelque chose (visio en cours, autorisation accordée) ?
    var hasSystemAudio: Bool { Self.speechLevel(system) > 0.002 }

    /// Mélange des deux pistes, chacune ramenée à un niveau de parole comparable, sans saturation.
    var mixed: [Float] {
        guard hasSystemAudio else { return mic }
        var result = [Float](repeating: 0, count: max(mic.count, system.count))
        if let echo {
            for i in mic.indices { result[i] = mic[i] * micGain * echo.weight(at: i) }
        } else {
            for i in mic.indices { result[i] = mic[i] * micGain }
        }
        for i in system.indices { result[i] += system[i] * systemGain }
        let peak = result.reduce(0) { max($0, abs($1)) }
        if peak > 0.98 {
            // Sur place : pas de seconde copie de 460 Mo pour une réunion de 2 h.
            let factor = 0.98 / peak
            for i in result.indices { result[i] *= factor }
        }
        return result
    }

    /// Part de l'énergie venue du micro entre deux échantillons (0 : tout vient de l'ordinateur), calculée
    /// sur des énergies par tranche de 50 ms préparées une fois : la fonction renvoyée ne retient pas les pistes.
    func micShareByFrame() -> (Int, Int) -> Float {
        let frame = 800
        func energies(_ track: [Float], _ gain: Float, echo: EchoGate.Analysis? = nil) -> [Float] {
            var result: [Float] = []
            result.reserveCapacity(track.count / frame + 1)
            var start = 0
            while start < track.count {
                let end = min(start + frame, track.count)
                var total: Float = 0
                for i in stride(from: start, to: end, by: 2) {
                    // L'écho retiré du mélange ne compte pas non plus comme parole au micro.
                    let weight = echo?.weight(at: i) ?? 1
                    total += track[i] * track[i] * weight * weight
                }
                result.append(total * gain * gain)
                start = end
            }
            return result
        }
        let fromMic = energies(mic, micGain, echo: echo), fromSystem = energies(system, systemGain)
        return { from, to in
            let first = max(0, from / frame), last = max(first + 1, (to + frame - 1) / frame)
            var mic: Float = 0, system: Float = 0
            for i in first..<last {
                if i < fromMic.count { mic += fromMic[i] }
                if i < fromSystem.count { system += fromSystem[i] }
            }
            return mic / max(mic + system, 1e-9)
        }
    }

    /// Somme simple pour l'aperçu en direct, où seule l'intelligibilité compte.
    static func sum(_ a: [Float], _ b: [Float]) -> [Float] {
        guard !b.isEmpty else { return a }
        var result = a.count >= b.count ? a : b
        for (i, x) in (a.count >= b.count ? b : a).enumerated() { result[i] += x }
        return result
    }

    /// Niveau de la parole : 90e centile de l'énergie par tranches de 50 ms (insensible aux silences).
    private static func speechLevel(_ track: [Float]) -> Float {
        let frame = 800
        guard track.count >= frame else { return 0 }
        var levels: [Float] = []
        for start in stride(from: 0, to: track.count - frame, by: frame) {
            var total: Float = 0
            for i in start..<start + frame { total += track[i] * track[i] }
            levels.append(sqrt(total / Float(frame)))
        }
        levels.sort()
        return levels[levels.count * 9 / 10]
    }

    private static func gain(_ track: [Float]) -> Float {
        let level = speechLevel(track)
        return level > 0 ? min(max(0.1 / level, 0.25), 8) : 1
    }
}

/// Fin probable d'une réunion : plus personne ne parle, ni au micro ni dans le son de l'ordinateur.
/// L'audio reçu (par passages de 10 s pendant la réunion) est découpé en tranches de 30 ms ; le seuil de parole
/// est pris entre le fond et les voix, comme `SpeechLevels.threshold` : à mi-chemin, entre 8 et 12 dB au-dessus
/// du fond. Le niveau des voix est lu sur les 30 dernières minutes, le fond sur la dernière minute seulement : un fond
/// qui change (climatisation, souffle d'une visio, salle quittée) est appris en moins d’une minute, au lieu
/// de passer pour de la parole jusqu'à ce qu'il occupe un dixième de la demi-heure.
/// Un passage compte comme parlé s'il a au moins 1 s de tranches au-dessus du seuil, dont 0,24 s d'affilée :
/// un clic, une porte, une toux ou un « oui » isolé ne relancent pas le compte (« quasiment plus de son »).
struct QuietMeter {
    static let rate = 16_000
    private static let frame = 480
    /// 30 min de tranches de 30 ms.
    private static let kept = 60_000
    /// 1 min de tranches de 30 ms.
    private static let recent = 2_000
    private var history: [Float] = []

    /// Seuil de parole : fond (dixième centile de la dernière minute) et voix (95e centile de la demi-heure).
    private var threshold: Float {
        let all = history.sorted()
        let latest = history.suffix(Self.recent).sorted()
        let floor = latest[latest.count / 10]
        let voice = all[Int(Double(all.count - 1) * 0.95)]
        return max(0.003, max(floor * 2.5, min(floor * 4, (floor * voice).squareRoot())))
    }
    /// Secondes d'audio reçues depuis le dernier passage parlé (depuis le début, si personne n'a encore parlé).
    private(set) var quietSeconds: Double = 0

    /// Ajoute un passage ; renvoie vrai s'il contient de la parole.
    @discardableResult
    mutating func feed(_ audio: [Float]) -> Bool {
        let levels = SpeechLevels.levels(audio, frame: Self.frame)
        guard !levels.isEmpty else { return false }
        history.append(contentsOf: levels)
        if history.count > Self.kept { history.removeFirst(history.count - Self.kept) }
        let threshold = self.threshold
        let voiced = levels.reduce(0) { $0 + ($1 > threshold ? 1 : 0) }
        let speech = voiced * Self.frame >= Self.rate && SpeechLevels.hasSpeech(levels, threshold: threshold, run: 8)
        quietSeconds = speech ? 0 : quietSeconds + Double(audio.count) / Double(Self.rate)
        return speech
    }
}
