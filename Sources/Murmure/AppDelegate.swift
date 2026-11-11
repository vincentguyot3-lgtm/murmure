import AppKit
import AVFoundation
import Carbon.HIToolbox
import Combine
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum State: Equatable { case idle, recording(locked: Bool), processing }

    private var state: State = .idle { didSet { updateIcon() } }
    private let recorder = AudioRecorder()
    let transcriber = Transcriber()
    private(set) lazy var meetings = MeetingController(transcriber: transcriber)
    /// Dictée transcrite pendant la parole : texte définitif au fil des pauses, et aperçu de la pastille.
    private lazy var progressive = ProgressiveDictation(transcriber: transcriber) { [recorder] in recorder.capturedAudio(from: $0) }
    /// Relecture par Claude demandée dès qu'on se tait, pour qu'elle soit prête au relâchement.
    private let ahead = ReviewAhead()
    /// Accès pour l'interface (bouton « Nouvelle réunion »).
    static private(set) weak var shared: AppDelegate?
    private let hotkey = HotkeyMonitor()
    private let overlay = Overlay()
    /// Capsule toujours présente au bord de l'écran : dictée et réunion d'un clic.
    private let floating = FloatingButton()
    /// Prévient si rien n'est capté dans les 2 premières secondes d'une dictée ou d'une réunion.
    private let silence = SilenceWatch()
    private let appState = AppState.shared
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var targetApp: String?
    private let meetingDetector = MeetingDetector()
    private let meetingPrompt = MeetingPrompt()
    /// Texte autour du curseur, lu pendant que l'on parle.
    private var fieldContext: Task<FieldContext?, Never>?
    /// Dictée lancée avec Maj : c'est une consigne pour réécrire le texte sélectionné.
    private var commandMode = false
    private var subscriptions = Set<AnyCancellable>()
    private var housekeeping: Timer?
    private var ticks = 0
    /// Rendez-vous déjà rappelés dans le bouton flottant (une fois chacun), et ceux dont le rappel a eu une
    /// réponse (Rejoindre, Enregistrer, fermer) : la proposition au début du rendez-vous ne revient pas.
    private var remindedEvents = Set<String>()
    private var answeredReminders = Set<String>()
    /// Purge des dictées expirées (réglage « Garder les dictées dans l'historique »), toutes les dix minutes.
    private var expiryPurge: Timer?
    /// Texte de la dernière dictée, pour « Recoller » et « Copier la dernière dictée » (⌃⌥⌘V, ⌃⌥⌘C) :
    /// gardé ici, indépendamment de l'historique, où la dictée n'entre pas forcément.
    private var lastDictation: String?

    // MARK: - Lancement

    func applicationDidFinishLaunching(_ notification: Notification) {
        Appearance.apply()
        OuvertureAuDemarrage.shared.actualiser()
        if Notifier.isAvailable { UNUserNotificationCenter.current().delegate = self }
        RecordingStore.shared.purgeTrash()
        RecordingStore.shared.purgeExpired()
        RecordingStore.shared.clearInterruptedProcessing()
        // Les utilisateurs qui ont déjà un historique ne revoient pas l'accueil.
        if !Settings.onboarded, !RecordingStore.shared.recordings.isEmpty { Settings.onboarded = true }
        Self.shared = self
        NSApp.mainMenu = makeMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        recorder.onLevel = { [weak self] level in
            self?.overlay.model.level = level
            self?.floating.model.level = level
            self?.silence.note(level)
        }
        recorder.onFailure = { [weak self] message in self?.overlay.flash(message, seconds: 5, error: true) }
        meetings.onLevel = { [weak self] level in self?.silence.note(level) }
        meetings.onQuiet = { [weak self] seconds in self?.meetingWentQuiet(seconds) }
        meetings.onWarning = { [weak self] message in self?.overlay.flash(message, seconds: 5, error: true) }
        hotkey.onEvent = { [weak self] event in self?.handle(event) }
        hotkey.start()

        floating.onDictate = { [weak self] in self?.toggleDictationFromButton() }
        floating.onMeeting = { [weak self] in self?.toggleMeetingFromButton() }
        floating.onOpen = { [weak self] in self?.showWindow() }
        floating.onMessage = { [weak self] message in self?.overlay.flash(message, seconds: 3) }
        floating.onNotice = { [weak self] action in
            guard let self else { return }
            switch action {
            case .record: self.meetingPrompt.record()
            case .ignore: self.meetingPrompt.dismiss()
            case .stop: if self.meetings.isRecording { self.stopMeeting() }
            case .keepRecording: self.quietOfferAfter = self.quietSeconds + Self.quietDelayAfterKeep
            case .open(let id):
                self.showWindow()
                self.appState.openRecording = id
            case .close: break
            case .join(let event, let record):
                self.answeredReminders.insert(event.id)
                if let url = event.joinURL { NSWorkspace.shared.open(url) }
                if record {
                    self.startMeeting(event: event, detail: [event.service, event.title].compactMap { $0 }.joined(separator: " · "))
                }
            case .schedule(let event):
                self.scheduleMeeting(event)
                if let start = event.start {
                    self.overlay.flash("Enregistrement programmé à \(start.formatted(date: .omitted, time: .shortened))", seconds: 2)
                }
            case .unschedule:
                self.cancelScheduledMeeting()
                self.overlay.flash("Enregistrement programmé annulé", seconds: 2)
            case .dismissReminder(let event): self.answeredReminders.insert(event.id)
            case .allowCalendar: Connectors.askCalendarAccess()
            case .openApp: self.showWindow()
            }
        }
        floating.refresh()

        appState.$modelStatus
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateIcon() } }
            .store(in: &subscriptions)
        // Une réunion peut s'arrêter ailleurs (page En direct, fin programmée) : le bouton flottant suit.
        appState.$meetingStartedAt
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateIcon() } }
            .store(in: &subscriptions)

        NameDirectory.shared.start()

        housekeeping = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        expiryPurge = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in RecordingStore.shared.purgeExpired() }

        // Appel, visio ou rendez-vous qui commence : une carte propose de l'enregistrer.
        meetingDetector.isBusy = { [weak self] in
            guard let self else { return true }
            return self.state != .idle || self.meetings.isRecording
        }
        meetingDetector.scheduledEventID = { [weak self] in self?.appState.scheduledMeeting?.id }
        meetingDetector.skipsEvent = { [weak self] id in
            guard let self else { return false }
            return self.answeredReminders.contains(id) || self.floating.showsReminder(for: id)
        }
        meetingDetector.onDetected = { [weak self] proposal in self?.meetingPrompt.show(proposal) }
        meetingDetector.onEnded = { [weak self] source in self?.meetingPrompt.end(source) }
        // Accepté dans la capsule ou dans la carte, l'enregistrement démarre et la page « En direct » s'ouvre
        // derrière la visio, sans la recouvrir : la capsule le confirme.
        meetingPrompt.notch = floating
        floating.pendingProposal = { [weak self] in self?.meetingPrompt.pending }
        floating.onHidden = { [weak self] in self?.meetingPrompt.reroute() }
        meetingPrompt.onRecord = { [weak self] proposal in
            guard let self else { return }
            let event: CalendarEvent? = if case .appointment(let event) = proposal { event } else { nil }
            self.startMeeting(event: event, detail: proposal.recordingDetail)
        }
        meetingDetector.start()

        CorrectionWatcher.shared.onLearned = { [weak self] word in
            self?.overlay.flash("Appris : « \(word) » · ajouté au dictionnaire", seconds: 2.5)
        }
        CorrectionWatcher.shared.onForgotten = { [weak self] rule in
            self?.overlay.flash("« \(rule.from) » ne deviendra plus « \(rule.to) »", seconds: 2.5)
        }

        // ⌃⌥⌘V recolle la dernière dictée là où est le curseur, ⌃⌥⌘C la copie (⌃⌘V reste à Word).
        GlobalShortcuts.shared.register(keyCode: kVK_ANSI_V, modifiers: cmdKey | optionKey | controlKey) { [weak self] in
            self?.reuseLastDictation(paste: true)
        }
        GlobalShortcuts.shared.register(keyCode: kVK_ANSI_C, modifiers: cmdKey | optionKey | controlKey) { [weak self] in
            self?.reuseLastDictation(paste: false)
        }

        // Les applications Electron (Slack, Teams, Notion…) n'ouvrent leur texte à l'accessibilité qu'à la
        // demande : on le leur demande dès qu'elles passent au premier plan, avant la première dictée.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .sink { app in if Settings.fieldContext { FieldContext.prepare(app) } }
            .store(in: &subscriptions)

        // Au premier lancement, c'est l'accueil guidé qui demande les autorisations, en les expliquant.
        if Settings.onboarded {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            if !Paster.hasAccessibility { Paster.requestAccessibility() }
        }

        showWindow()
        LocalLLM.killOrphans()
        Self.startLocalLLM()

        Task {
            do {
                try await transcriber.load()
                await MainActor.run { self.appState.modelStatus = .ready }
            } catch {
                await MainActor.run { self.appState.modelStatus = .failed(error.localizedDescription) }
                return
            }
            // Transcription en ligne : fichiers temporaires et suppressions laissés par un arrêt brutal.
            OnlineTranscription.purgeTemporaryFiles()
            if !PendingDeletions.isEmpty { Task.detached { await PendingDeletions.sweep() } }
            // Réunions interrompues par un arrêt brutal : leur copie de sûreté est relue et le traitement reprend,
            // une fois le modèle de langage prêt lui aussi (deux minutes au plus) pour que la synthèse suive.
            guard !AudioSpool.interrupted().isEmpty else { return }
            for _ in 0..<120 where await MainActor.run(body: { self.appState.llmStatus == .loading }) {
                try? await Task.sleep(for: .seconds(1))
            }
            let resumed = await MeetingController.resumeInterrupted(transcriber: self.transcriber)
            if !resumed.isEmpty { print("[réunion] \(resumed.count) réunion(s) reprise(s)") }
        }
    }

    /// Une réunion en cours d'enregistrement ou de traitement vit en mémoire : quitter la perdrait.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if meetings.isRecording {
            showWindow()
            overlay.flash("Réunion en cours : arrêtez-la (ou annulez-la) avant de quitter", seconds: 3)
            return .terminateCancel
        }
        let processing = RecordingStore.shared.recordings.filter { $0.progress != nil && !$0.isTrashed }
        guard !processing.isEmpty else { return .terminateNow }
        showWindow()
        let what = processing.count == 1 ? "La réunion « \(processing[0].title) » est encore en traitement" : "\(processing.count) réunions sont encore en traitement"
        Modals.shared.confirm("Quitter maintenant ?", message: "\(what) (transcription ou compte rendu). Quitter arrête le traitement, qui reprendra depuis le début au prochain lancement.",
                              confirm: "Quitter quand même", cancel: { NSApp.reply(toApplicationShouldTerminate: false) }) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        SoundMute.end()
        RecordingStore.shared.flush()
        Lexicon.shared.flush()
        LocalLLM.shared.stop()
    }

    /// (Re)démarre le modèle local si c'est le moteur choisi (ou le relais de Claude sans connexion) ;
    /// l'arrête sinon pour libérer la mémoire.
    static func startLocalLLM() {
        guard Cleaner.keepsLocalModel else {
            LocalLLM.shared.stop()
            return
        }
        AppState.shared.llmStatus = .loading
        let model = Settings.localModel
        Task {
            do {
                // Premier lancement, ou modèle choisi absent : le moteur et le modèle sont d'abord téléchargés.
                try await LocalLLMInstaller.shared.install(model: model)
                // Un autre modèle ou un autre moteur a été choisi pendant le téléchargement : l'appel suivant s'en charge.
                guard model == Settings.localModel, Cleaner.keepsLocalModel else { return }
                try await LocalLLM.shared.start(model: model)
                await Cleaner.warmUp()
                await MainActor.run { AppState.shared.llmStatus = .ready }
            } catch {
                guard model == Settings.localModel else { return }
                await MainActor.run { AppState.shared.llmStatus = .failed(error.localizedDescription) }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    /// Tâches périodiques : détection de l'autorisation Accessibilité.
    private func tick() {
        ticks += 1
        // L'agenda change peu : un coup d'œil toutes les 20 s suffit pour rappeler un rendez-vous 2 min avant.
        if ticks % 10 == 0 { remindUpcoming() }
        let trusted = Paster.hasAccessibility
        if trusted != appState.accessibilityGranted {
            appState.accessibilityGranted = trusted
            // Les écouteurs clavier posés avant l'autorisation ne reçoivent rien : on les réinstalle.
            if trusted { hotkey.stop(); hotkey.start() }
        }
    }

    /// Deux minutes avant un rendez-vous, le bouton flottant se déplie de lui-même pour le rappeler.
    /// Un rendez-vous déjà programmé n'est rappelé que s'il a une visio à rejoindre.
    private func remindUpcoming() {
        guard Settings.remindAppointments, floating.isShown, state == .idle, !meetings.isRecording else { return }
        let scheduled = appState.scheduledMeeting?.id
        guard let event = Connectors.upcomingEvents().first(where: {
            !remindedEvents.contains($0.id) && ($0.id != scheduled || $0.joinURL != nil)
        }) else { return }
        remindedEvents.insert(event.id)
        // Le rappel reste jusqu'à 5 min après le début : il tient lieu de la proposition d'enregistrer.
        let until = (event.start ?? Date()).addingTimeInterval(300).timeIntervalSinceNow
        floating.notify(.upcoming(event), seconds: max(30, until))
    }

    // MARK: - Raccourci

    private func handle(_ event: HotkeyMonitor.Event) {
        switch (event, state) {
        case (.pressed, .idle) where meetings.isRecording:
            overlay.flash("Réunion en cours : la dictée reprendra après l'arrêt")
        case (.pressed, .idle):
            guard appState.modelStatus == .ready else {
                overlay.flash("Modèle en cours de chargement, patientez…")
                return
            }
            startRecording()
        case (.pressed, .recording(locked: true)):
            finishRecording()
        case (.released(let held), .recording(locked: false)):
            if held < 0.35 {
                state = .recording(locked: true)
                overlay.show(.locked)
            } else {
                finishRecording()
            }
        case (.otherKey, .recording(locked: false)):
            // Touche + lettre juste après l'appui : c'est une combinaison (Option + e), pas une dictée.
            // Plus tard, une touche effleurée ne doit pas jeter deux minutes de parole.
            if hotkey.heldSoFar < 2 { cancelRecording(message: nil) }
        case (.escape, .recording):
            cancelRecording(message: "Dictée annulée")
        default:
            break
        }
    }

    /// `command` : consigne de réécriture (Maj tenue à l'appui) ; le bouton flottant lance toujours une dictée.
    private func startRecording(command: Bool? = nil) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            overlay.flash("Autorisez le micro : Réglages Système › Confidentialité › Micro", error: true)
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return
        }
        do {
            CorrectionWatcher.shared.flush()
            let front = NSWorkspace.shared.frontmostApplication
            targetApp = front?.localizedName
            fieldContext = nil
            commandMode = command ?? hotkey.shiftAtPress
            // Le mode commande lit toujours le champ : il lui faut la sélection.
            if Settings.fieldContext || commandMode, let front {
                fieldContext = Task { await FieldContext.capture(front) }
            }
            try recorder.start()
            state = .recording(locked: false)
            overlay.show(commandMode ? .instruction : .listening)
            silence.start { [weak self] in self?.warnSilentMic() }
            ahead.reset()
            // Une consigne (mode commande) n'est pas relue : rien à anticiper.
            let context = fieldContext, ahead = ahead
            progressive.start(context: context, onPause: commandMode ? nil : { await ahead.announce($0, context: context) })
            Feedback.start()
            // Après le signal de début, pour qu'il reste audible.
            DispatchQueue.main.asyncAfter(deadline: .now() + (Settings.dictationSounds ? 0.3 : 0)) {
                if case .recording = self.state { SoundMute.begin() }
            }
        } catch {
            overlay.flash("Micro indisponible : \(error.localizedDescription)", error: true)
        }
    }

    /// Clic sur le bouton flottant : dictée mains libres, comme une touche effleurée ; un second clic la termine.
    private func toggleDictationFromButton() {
        switch state {
        case .idle where meetings.isRecording:
            overlay.flash("Réunion en cours : la dictée reprendra après l'arrêt")
        case .idle:
            guard appState.modelStatus == .ready else {
                overlay.flash("Modèle en cours de chargement, patientez…")
                return
            }
            startRecording(command: false)
            guard case .recording = state else { return }
            state = .recording(locked: true)
            overlay.show(.locked)
        case .recording:
            finishRecording()
        case .processing:
            break
        }
    }

    private func toggleMeetingFromButton() {
        if meetings.isRecording {
            stopMeeting()
        } else if state == .idle {
            startMeeting()
        }
    }

    /// « Aucun son capté » : dit dans la pastille sans interrompre ; pendant une dictée, la pastille reprend
    /// ensuite son état (à l'écoute, consigne, verrouillée) si l'on parle encore.
    private func warnSilentMic() {
        let phase = overlay.model.phase
        overlay.flash("Aucun son capté : vérifiez le micro", seconds: 2.5, error: true)
        guard case .recording = state else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
            guard let self, case .recording = self.state, case .message = self.overlay.model.phase else { return }
            self.overlay.show(phase)
        }
    }

    private func cancelRecording(message: String?) {
        silence.stop()
        progressive.cancel()
        ahead.cancel()
        SoundMute.end()
        _ = recorder.stop()
        fieldContext = nil
        state = .idle
        if let message { overlay.flash(message, seconds: 1.2) } else { overlay.hide() }
    }

    private func finishRecording() {
        silence.stop()
        SoundMute.end()
        Feedback.stop()
        state = .processing
        overlay.show(.transcribing)
        // Le micro livre le son par paquets de 0,1 s et la dernière syllabe traîne souvent après le relâchement :
        // on écoute encore un quart de seconde pour ne pas la couper. Si l'on s'était déjà tu, le dernier
        // paquet suffit.
        let quiet = ProgressiveDictation.endsInSilence(recorder.recentAudio(16_000 * 3 / 10),
                                                       reference: recorder.recentAudio(16_000 * 10))
        DispatchQueue.main.asyncAfter(deadline: .now() + (quiet ? 0.1 : 0.25)) { self.completeRecording() }
    }

    private func completeRecording() {
        let audio = recorder.stop()
        guard audio.count > 16_000 * 4 / 10 else { // moins de 0,4 s : ignoré
            progressive.cancel()
            ahead.cancel()
            state = .idle
            overlay.hide()
            return
        }
        state = .processing
        overlay.show(.transcribing)
        let appName = targetApp
        let contextTask = fieldContext
        fieldContext = nil
        let isCommand = commandMode
        commandMode = false

        Task {
            // Lu pendant la parole : en pratique déjà prêt au relâchement de la touche.
            let context = await contextTask?.value.flatMap { $0.isEmpty ? nil : $0 }
            let terms = context?.terms ?? []
            if ProcessInfo.processInfo.environment["MURMURE_DEBUG"] != nil, let context {
                print("[contexte] \(context.bundleID ?? "?") · « \(context.windowTitle) » · \(context.screen.count) textes à l'écran · \(context.before.count) car. avant, \(context.selected.count) sélectionnés, \(context.after.count) après · termes : \(terms.prefix(12).joined(separator: ", "))")
            }
            let raw: String
            do {
                // Une longue dictée est déjà en partie transcrite : il ne reste que la fin.
                raw = try await self.progressive.finish(audio, context: contextTask)
            } catch {
                await MainActor.run {
                    self.state = .idle
                    self.overlay.flash("Erreur de transcription : \(error.localizedDescription)", error: true)
                }
                return
            }

            if isCommand {
                self.ahead.cancel()
                await self.rewriteSelection(context, instruction: Cleaner.applyCommands(raw), duration: Double(audio.count) / 16_000, appName: appName)
                return
            }

            // Commandes, extraits, noms du contexte : exactement comme pour la relecture anticipée.
            let prepared = await Cleaner.prepare(raw, context: context)
            let pressReturn = prepared.pressReturn
            var text = prepared.text
            if prepared.review {
                await MainActor.run { self.overlay.show(.cleaning) }
                // Déjà relue si l'on s'est tu avant de relâcher, sans reparler ensuite.
                text = await self.ahead.review(text, context: context)
            } else {
                self.ahead.cancel()
            }

            let result = text
            // Le texte collé s'accorde à ses voisins ; l'historique garde la phrase complète.
            let pasted = context?.fit(result, properNouns: Set(terms + Settings.vocabulary())) ?? result
            await MainActor.run {
                self.state = .idle
                guard !result.isEmpty else {
                    // « Entrée » dit seul : on envoie ce qui est déjà dans le champ.
                    if pressReturn, Settings.autoPaste, Paster.hasAccessibility {
                        self.overlay.hide()
                        Paster.pressReturn()
                    } else {
                        self.overlay.flash("Aucune parole détectée", seconds: 1.5)
                    }
                    return
                }
                self.overlay.hide()
                if Settings.autoPaste, Paster.hasAccessibility {
                    Paster.paste(pasted, pressReturn: pressReturn) { pastedHere in
                        if !pastedHere { self.overlay.flash("Aucun champ n'a reçu le texte · il est copié, ⌘V pour coller", seconds: 3) }
                        // Relu plus tard : les mots que l'utilisateur corrige enrichissent le dictionnaire.
                        if pastedHere, let context { CorrectionWatcher.shared.watch(context, pasted: pasted) }
                    }
                } else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result, forType: .string)
                    if Settings.autoPaste {
                        self.overlay.flash("Texte copié : autorisez Murmure dans Accessibilité pour le coller directement", seconds: 4)
                    } else {
                        self.overlay.flash("Texte copié · ⌘V pour coller", seconds: 1.8)
                    }
                }
                self.lastDictation = result
                // Lexique : ce que chaque correction a rectifié, et les passages qui reviennent.
                Lexicon.shared.countUses(raw: raw, final: result)
                RecurringPassages.note(result)
                // « Jamais » : la dictée est collée mais n'entre pas dans l'historique (ni son audio).
                let retention = Settings.dictationRetention
                guard retention != .never else { return }
                let id = RecordingStore.shared.add(text: result, rawText: raw, duration: Double(audio.count) / 16_000,
                                                   appName: appName, expiresAt: retention.expiry())
                if Settings.keepAudio { AudioArchive.save(audio, id: id) }
                // Titre et distinction des voix en arrière-plan : le texte est déjà collé,
                // l'historique se complète ensuite.
                Task.detached(priority: .utility) {
                    if let title = await Cleaner.makeTitle(result) {
                        await MainActor.run { RecordingStore.shared.setGeneratedTitle(id, title) }
                    }
                    if audio.count > 16_000 * 3, let turns = try? await self.transcriber.speakerTurns(audio) {
                        await MainActor.run { RecordingStore.shared.setTurns(id, turns) }
                    }
                }
            }
        }
    }

    /// Mode commande : la consigne dictée (« plus formel », « en courriel au client ») est appliquée par le
    /// modèle local au texte sélectionné, qui est remplacé sur place. Sans sélection, la consigne est copiée.
    private func rewriteSelection(_ context: FieldContext?, instruction: String, duration: Double, appName: String?) async {
        guard !instruction.isEmpty else {
            await MainActor.run { self.state = .idle; self.overlay.flash("Aucune consigne entendue", seconds: 1.5) }
            return
        }
        guard let selection = context?.selected, !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await MainActor.run {
                self.state = .idle
                Paster.copy(instruction)
                self.overlay.flash("Aucun texte sélectionné : la consigne est copiée", seconds: 2.5)
            }
            return
        }
        guard Cleaner.isReady else {
            await MainActor.run { self.state = .idle; self.overlay.flash(Cleaner.notReadyReason, seconds: 2.5) }
            return
        }
        await MainActor.run { self.overlay.show(.rewriting) }
        let rewritten = (try? await Cleaner.rework(selection, instruction: instruction))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        await MainActor.run {
            self.state = .idle
            guard !rewritten.isEmpty else {
                self.overlay.flash("La réécriture a échoué : le texte est inchangé", seconds: 2.5, error: true)
                return
            }
            self.overlay.hide()
            // La sélection est toujours active dans l'application : le collage la remplace.
            Paster.paste(rewritten) { pastedHere in
                if !pastedHere { self.overlay.flash("Texte réécrit copié · ⌘V pour coller", seconds: 3) }
            }
            self.lastDictation = rewritten
            let retention = Settings.dictationRetention
            guard retention != .never else { return }
            _ = RecordingStore.shared.add(text: rewritten, rawText: "Consigne : \(instruction)\n\n\(selection)",
                                          duration: duration, appName: appName, expiresAt: retention.expiry())
        }
    }

    /// Texte de la dernière dictée : celle de cette session, sinon la plus récente de l'historique.
    private var lastDictationText: String? {
        lastDictation ?? RecordingStore.shared.recordings.first(where: { !$0.isMeeting && !$0.isTrashed && !$0.text.isEmpty })?.text
    }

    /// Recolle (ou copie) la dernière dictée : utile quand le curseur n'était pas dans un champ.
    private func reuseLastDictation(paste: Bool) {
        guard state == .idle else { return }
        guard let last = lastDictationText else {
            overlay.flash("Aucune dictée à reprendre", seconds: 1.5)
            return
        }
        if paste, Paster.hasAccessibility {
            Paster.paste(last) { pastedHere in
                if !pastedHere { self.overlay.flash("Aucun champ n'a reçu le texte · il est copié, ⌘V pour coller", seconds: 3) }
            }
        } else {
            Paster.copy(last)
            overlay.flash("Dernière dictée copiée", seconds: 1.5)
        }
    }

    // MARK: - Fenêtre principale

    @objc func showWindow() {
        makeWindowIfNeeded()
        NSApp.activate()
        guard let window else { return }
        if window.isVisible { window.makeKeyAndOrderFront(nil) } else { WindowMotion.open(window) }
    }

    /// Ouvre la fenêtre principale sans faire passer Murmure au premier plan : si une autre application est
    /// active (la visio, le traitement de texte), la fenêtre se range derrière elle et ne prend pas le clavier.
    /// Si Murmure est déjà au premier plan, c'est l'ouverture ordinaire.
    func showWindowInBackground() {
        guard !NSApp.isActive else { showWindow(); return }
        makeWindowIfNeeded()
        guard let window, !window.isVisible else { return }
        window.alphaValue = 1
        window.orderBack(nil)
    }

    private func makeWindowIfNeeded() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1200, height: 740),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Murmure"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 1060, height: 600)
            window.contentView = NSHostingView(rootView: MainView())
            window.center()
            window.setFrameAutosaveName("MurmureMainWindow")
            window.delegate = self
            self.window = window
        }
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "À propos de Murmure", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(shortcut("Réglages…", #selector(openSettings), ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Masquer Murmure", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quitter Murmure", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu, title: "Murmure"))

        let file = NSMenu(title: "Fichier")
        file.addItem(shortcut("Nouvelle réunion", #selector(newMeeting), "n"))
        file.addItem(shortcut("Importer un enregistrement…", #selector(chooseRecordingToImport), "o"))
        file.addItem(.separator())
        file.addItem(shortcut("Rechercher", #selector(openSearch), "f"))
        file.addItem(shortcut("Aller à…", #selector(openPalette), "k"))
        main.addItem(submenu(file, title: "Fichier"))

        let edit = NSMenu(title: "Édition")
        edit.addItem(withTitle: "Annuler", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Rétablir", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Couper", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit, title: "Édition"))

        let go = NSMenu(title: "Aller")
        go.addItem(shortcut("Vos Murmures", #selector(goHome), "1"))
        go.addItem(shortcut("Réunions", #selector(goMeetings), "2"))
        go.addItem(shortcut("Dictées", #selector(goDictations), "3"))
        go.addItem(shortcut("Corbeille", #selector(goTrash), "4"))
        go.addItem(shortcut("Lexique", #selector(goLexicon), "5"))
        main.addItem(submenu(go, title: "Aller"))

        let windowMenu = NSMenu(title: "Fenêtre")
        windowMenu.addItem(withTitle: "Fermer", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Réduire", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenu(windowMenu, title: "Fenêtre"))
        NSApp.windowsMenu = windowMenu

        return main
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func shortcut(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Commandes de la fenêtre (⌘N, ⌘F, ⌘K, ⌘1…)

    private func send(_ command: AppCommand) {
        showWindow()
        appState.commands.send(command)
    }

    @objc private func newMeeting() { startMeeting() }
    @objc private func openSearch() { send(.search) }
    @objc private func openPalette() { send(.palette) }
    @objc private func goHome() { send(.go(.all)) }
    @objc private func goMeetings() { send(.go(.meetings)) }
    @objc private func goDictations() { send(.go(.dictations)) }
    @objc private func goTrash() { send(.go(.trash)) }
    @objc private func goLexicon() { send(.go(.lexicon)) }
    @objc private func openSettings() { send(.settings) }

    /// Carte « À propos » dessinée par l'app, dans la fenêtre principale.
    @objc private func showAbout() {
        showWindow()
        Modals.shared.aboutShown = true
    }

    // MARK: - Barre des menus

    private func updateIcon() {
        updateFloatingButton()
        let symbol: String
        switch (appState.modelStatus, state) {
        case (.loading, _): symbol = "arrow.down.circle"
        case (.failed, _): symbol = "exclamationmark.triangle"
        case (_, .recording): symbol = "mic.fill"
        case (_, .processing): symbol = "waveform"
        case (_, .idle) where appState.meetingStartedAt != nil: symbol = "record.circle"
        case (_, .idle):
            statusItem?.button?.image = Self.logoImage
            return
        }
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Murmure")
    }

    private func updateFloatingButton() {
        let mode: FloatingButtonModel.Mode
        switch state {
        case .recording: mode = .dictating
        case .processing: mode = .processing
        case .idle: mode = meetings.isRecording ? .meeting : .idle
        }
        floating.model.meetingStartedAt = appState.meetingStartedAt
        if floating.model.mode != mode { floating.model.mode = mode }
    }

    /// Logo de la barre des menus au repos : le M en onde, en image « modèle » (s'adapte au thème).
    private static let logoImage: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 16), flipped: true) { rect in
            let glyph = CGRect(x: 2, y: 4.5, width: 16, height: 6.4)
            let path = NSBezierPath(cgPath: LogoShape().path(in: glyph).cgPath)
            path.lineWidth = 2
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Murmure"
        return image
    }()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status: String
        switch appState.modelStatus {
        case .loading: status = "Chargement du modèle de transcription…"
        case .failed(let reason): status = "Erreur : \(reason)"
        case .ready: status = "Prêt · maintenez \(Settings.dictationKey.label) pour dicter"
        }
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())

        menu.addItem(item("Ouvrir Murmure", #selector(showWindow)))
        if meetings.isRecording {
            menu.addItem(item("Arrêter la réunion", #selector(stopMeeting)))
        } else {
            menu.addItem(item("Nouvelle réunion", #selector(newMeeting)))
        }

        if let scheduled = appState.scheduledMeeting, let start = scheduled.start {
            menu.addItem(item("Programmée à \(start.formatted(date: .omitted, time: .shortened)) : « \(scheduled.title) » · Annuler",
                              #selector(cancelScheduledMeetingFromMenu)))
        }

        // Avec Claude ou la transcription des réunions en ligne : couper tout envoi d'un clic (ce Mac prend le relais).
        if Cleaner.chosen == .claude || OnlineTranscription.isChosen {
            let offline = item("Rester hors ligne (rien ne quitte ce Mac)", #selector(toggleStayOffline))
            offline.state = Settings.stayOffline ? .on : .off
            menu.addItem(offline)
        }

        let button = item("Afficher le bouton flottant", #selector(toggleFloatingButton))
        button.state = Settings.floatingButton ? .on : .off
        menu.addItem(button)

        if let last = lastDictationText {
            let preview = last.count > 50 ? String(last.prefix(50)) + "…" : last
            menu.addItem(item("Copier la dernière dictée : « \(preview) »", #selector(copyLast)))
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quitter Murmure", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func cancelScheduledMeetingFromMenu() { cancelScheduledMeeting() }

    @objc private func toggleFloatingButton() { Settings.floatingButton.toggle() }

    func resetFloatingButton() { floating.resetPosition() }

    @objc private func toggleStayOffline() {
        Settings.stayOffline.toggle()
        overlay.flash(Settings.stayOffline ? "Hors ligne : tout se fait sur ce Mac" : "Les services en ligne sont de nouveau utilisés", seconds: 2)
    }

    // MARK: - Réunions

    @objc func startMeeting() { startMeeting(event: nil) }

    /// `event` : rendez-vous imposé (enregistrement programmé à l'heure) ; sinon celui en cours dans l'agenda.
    /// La page « En direct » s'ouvre toujours, mais derrière l'application active : la réunion ne fait pas passer
    /// Murmure au premier plan. `detail` : ce que la capsule dit de la réunion qui démarre.
    func startMeeting(event: CalendarEvent?, detail: String? = nil) {
        guard appState.modelStatus == .ready else {
            overlay.flash("Modèle en cours de chargement, patientez…")
            return
        }
        guard state == .idle else { return }
        meetingPrompt.hide()
        do {
            quietOfferAfter = Self.quietDelay
            quietSeconds = 0
            try meetings.start(event: event)
            silence.start { [weak self] in self?.warnSilentMic() }
            Notifier.requestPermission()
            Feedback.start()
            updateIcon()
            floating.notify(.recording(detail: detail ?? event?.title ?? "Retranscrit sur ce Mac"), seconds: 4)
            showWindowInBackground() // la page « En direct », même si la réunion part de la barre des menus
        } catch {
            overlay.flash("Micro indisponible : \(error.localizedDescription)", error: true)
        }
    }

    @objc func stopMeeting() {
        let wasRecording = meetings.isRecording
        silence.stop()
        Feedback.stop()
        let id = meetings.stop()
        updateIcon()
        // La proposition de terminer attend une réponse et ne céderait pas la place : arrêtée ailleurs (fenêtre,
        // barre des menus, raccourci), la réunion la retire d'abord.
        if case .quiet = floating.model.notice { floating.collapse() }
        // La capsule dit que la réunion est gardée, puis que son compte rendu est prêt.
        if let id {
            floating.follow(id)
        } else if wasRecording {
            floating.notify(.message("Réunion trop courte", detail: "Moins de 2 secondes : rien n'a été gardé"), seconds: 3)
        }
    }

    // MARK: Réunion où plus personne ne parle

    /// Silence au-delà duquel la capsule propose de terminer la réunion.
    private static let quietDelay: TimeInterval = 180
    /// Après « Continuer », le silence doit durer encore 10 min avant que la capsule le repropose.
    private static let quietDelayAfterKeep: TimeInterval = 600
    private var quietOfferAfter = AppDelegate.quietDelay
    /// Dernière mesure de `MeetingController.onQuiet`.
    private var quietSeconds: TimeInterval = 0

    /// Toutes les 10 s pendant une réunion. Après 3 min sans parole (micro et son de l'ordinateur), la capsule se
    /// déplie : « Plus personne ne parle · Continuer · Terminer ». La réunion n'est jamais arrêtée sans réponse ;
    /// si l'on reparle, la carte se replie d'elle-même et le compte repart de zéro.
    private func meetingWentQuiet(_ seconds: TimeInterval) {
        quietSeconds = seconds
        if seconds == 0 {
            quietOfferAfter = Self.quietDelay
            if case .quiet = floating.model.notice { floating.collapse() }
            return
        }
        guard Settings.offerToEndQuietMeetings, floating.isShown, meetings.isRecording, seconds >= quietOfferAfter else { return }
        if case .quiet = floating.model.notice { return }
        floating.notify(.quiet(since: Date().addingTimeInterval(-seconds)), seconds: nil)
    }

    /// « Enregistrer à l'heure » : la réunion démarre d'elle-même au début du rendez-vous, avec son titre et
    /// ses invités. Un seul enregistrement programmé à la fois ; annulable depuis l'accueil ou la barre des menus.
    private var scheduledTimer: Timer?

    func scheduleMeeting(_ event: CalendarEvent) {
        guard let start = event.start else { return }
        cancelScheduledMeeting()
        appState.scheduledMeeting = event
        let timer = Timer(fire: max(start, Date()), interval: 0, repeats: false) { [weak self] _ in self?.fireScheduledMeeting() }
        RunLoop.main.add(timer, forMode: .common)
        scheduledTimer = timer
    }

    func cancelScheduledMeeting() {
        scheduledTimer?.invalidate()
        scheduledTimer = nil
        appState.scheduledMeeting = nil
    }

    private func fireScheduledMeeting() {
        guard let event = appState.scheduledMeeting else { return }
        cancelScheduledMeeting()
        guard !meetings.isRecording else { return }
        if state != .idle {
            // Une dictée est en cours : la réunion attend sa fin plutôt que de la couper.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.appState.scheduledMeeting = event
                self?.fireScheduledMeeting()
            }
            return
        }
        startMeeting(event: event)
    }

    /// « Importer un enregistrement… » : un fichier audio (dictaphone, mémo vocal, audience) traité comme une réunion.
    @objc func chooseRecordingToImport() {
        let panel = NSOpenPanel()
        panel.title = "Importer un enregistrement"
        panel.message = "Le fichier est transcrit sur ce Mac et traité comme une réunion ; il n'est ni copié ni modifié."
        panel.prompt = "Importer"
        panel.allowedContentTypes = AudioFile.types
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        showWindow()
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.importRecordings(panel.urls)
        }
    }

    /// Fichiers déposés sur la fenêtre ou choisis dans le dialogue ; ceux d'un autre format sont ignorés.
    func importRecordings(_ urls: [URL]) {
        let accepted = urls.filter(AudioFile.isSupported)
        guard !accepted.isEmpty else {
            overlay.flash("Formats acceptés : wav, m4a, mp3, aiff", seconds: 2.5, error: true)
            return
        }
        guard appState.modelStatus == .ready else {
            overlay.flash("Modèle en cours de chargement, patientez…")
            return
        }
        showWindow()
        for url in accepted { meetings.importFile(url) }
    }

    func cancelMeeting() {
        silence.stop()
        meetings.cancel()
        updateIcon()
        // « Enregistrement en cours » ou « Plus personne ne parle » ne doivent pas survivre à l'abandon.
        switch floating.model.notice {
        case .recording, .quiet: floating.collapse()
        default: break
        }
    }

    @objc private func copyLast() {
        guard let last = lastDictationText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(last, forType: .string)
    }
}

extension AppDelegate: NSWindowDelegate {
    /// Fermeture en fondu ; la fenêtre est seulement masquée (Murmure reste actif).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        WindowMotion.close(sender)
        return false
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Clic sur la notification : ouvre la fiche de la réunion.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let value = response.notification.request.content.userInfo["recording"] as? String, let id = UUID(uuidString: value) {
            DispatchQueue.main.async {
                self.showWindow()
                self.appState.openRecording = id
            }
        }
        completionHandler()
    }

    /// Pas de bannière si Murmure est déjà au premier plan, ni quand la capsule du bouton flottant vient
    /// d'annoncer le compte rendu : la notification reste seulement dans le centre de notifications.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let recording = (notification.request.content.userInfo["recording"] as? String).flatMap(UUID.init(uuidString:))
        DispatchQueue.main.async {
            if NSApp.isActive {
                completionHandler([])
            } else if let recording, self.floating.hasAnnounced(recording) {
                completionHandler([.list])
            } else {
                completionHandler([.banner, .sound])
            }
        }
    }
}
