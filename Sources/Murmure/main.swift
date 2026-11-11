import AppKit
import AVFoundation
import EventKit
import SwiftUI

/// Exécute un travail asynchrone depuis le fil principal en mode ligne de commande.
/// Fait tourner la boucle principale (et non un sémaphore) pour que `MainActor` reste utilisable.
func runBlocking(_ work: @escaping () async throws -> Void) -> Never {
    var done = false
    Task {
        do { try await work() } catch { print("Erreur : \(error)") }
        done = true
    }
    while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    // Les écritures de l'historique sont regroupées : on vide ce qui attend avant de quitter.
    RecordingStore.shared.flush()
    exit(0)
}

func seconds(since start: Date) -> String { String(format: "%.1f s", Date().timeIntervalSince(start)) }

/// MURMURE_NOTES=fichier.txt : notes « prises pendant la réunion » données au modèle par `--meeting` et `--synthese`.
let notesFromEnvironment: String? = ProcessInfo.processInfo.environment["MURMURE_NOTES"]
    .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    .flatMap { $0.isEmpty ? nil : $0 }

// Serveur MCP : `Murmure --mcp` sert l'historique à Claude sur l'entrée et la sortie standard (déclaré auprès
// de Claude Code et de l'app Claude par Réglages › Connecteurs › « Relier à Claude »).
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--mcp" { MCPServer.serve() }

// `Murmure --relier-claude` / `--delier-claude` : même chose que le bouton des Réglages, puis l'état.
if CommandLine.arguments.count == 2, ["--relier-claude", "--delier-claude"].contains(CommandLine.arguments[1]) {
    do {
        try ClaudeCode.register(CommandLine.arguments[1] == "--relier-claude")
    } catch {
        print("Erreur : \(error.localizedDescription)")
    }
    let state = ClaudeCode.registration()
    print(state.any ? "Relié : \(state.summary)\(state.stale ? " (autre binaire : à mettre à jour)" : "")" : "Non relié")
    print("Binaire : \(ClaudeCode.executable)")
    exit(0)
}

// Mode test : `Murmure --test fichier.wav` transcrit un fichier puis affiche le brut et le texte mis en forme.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--test" {
    let audio = try loadAudio(CommandLine.arguments[2])
    runBlocking {
        let transcriber = Transcriber()
        var start = Date()
        try await transcriber.load()
        if Cleaner.engine == .local {
            try await LocalLLM.shared.start(model: Settings.localModel)
            await Cleaner.warmUp()
        }
        print("Modèles chargés en \(seconds(since: start))")
        start = Date()
        let raw = try await transcriber.transcribe(audio)
        print("BRUT (\(seconds(since: start))) : \(raw)")
        start = Date()
        let cleaned = await Cleaner.clean(Cleaner.applyCommands(raw))
        print("NETTOYÉ (\(seconds(since: start))) : \(cleaned)")
        start = Date()
        let title = await Cleaner.makeTitle(cleaned)
        print("TITRE (\(seconds(since: start))) : \(title ?? "–")")
        start = Date()
        let turns = try await transcriber.speakerTurns(audio)
        if let turns {
            print("INTERLOCUTEURS (\(seconds(since: start))) :")
            for turn in turns { print("  Interlocuteur \(turn.speaker) : \(turn.text)") }
        } else {
            print("INTERLOCUTEURS (\(seconds(since: start))) : une seule voix")
        }
        // MURMURE_SAVE=1 : ajoute le résultat à l'historique (le fil principal attend : pas de MainActor ici).
        if ProcessInfo.processInfo.environment["MURMURE_SAVE"] != nil {
            let id = RecordingStore.shared.add(text: cleaned, rawText: raw, duration: Double(audio.count) / 16_000, appName: nil)
            if let title { RecordingStore.shared.setGeneratedTitle(id, title) }
            if let turns { RecordingStore.shared.setTurns(id, turns) }
            try await Task.sleep(for: .milliseconds(500)) // laisse l'écriture du fichier se terminer
        }
        LocalLLM.shared.stop()
    }
}

// Aperçu de la mise en page d'une synthèse : `Murmure --apercu-synthese fichier.md préfixe` → préfixe-clair.png et préfixe-sombre.png.
if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--apercu-synthese" {
    MainActor.assumeIsolated {
        let markdown = (try? String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)) ?? ""
        for (name, scheme) in [("clair", ColorScheme.light), ("sombre", .dark)] {
            let view = SummaryView(markdown: markdown, animated: false).padding(24).frame(width: 640).background(Theme.bg).environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[3] + "-\(name).png"))
            }
        }
    }
    exit(0)
}

// Aperçu des Réglages : `Murmure --apercu-reglages préfixe` → une image par panneau et par sous-page (préfixe-general.png…).
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--apercu-reglages" {
    MainActor.assumeIsolated {
        let pages: [(String, SettingsView.Pane, SettingsView.Subpage?)] = [
            ("general", .general, nil), ("connecteurs", .connectors, nil), ("affichage", .display, nil),
            ("accessibilite", .accessibility, nil), ("transcription", .transcription, nil), ("avance", .advanced, nil),
            ("modele", .transcription, .model), ("agenda", .connectors, .calendar), ("pastille", .display, .pill),
            ("claude-code", .connectors, .claudeCode), ("notion", .connectors, .notion), ("todoist", .connectors, .todoist),
            ("voix", .transcription, .voices), ("annuaire", .transcription, .names),
        ]
        // MURMURE_APERCU_RECHERCHE=micro : ajoute une image des résultats de « Rechercher un réglage ».
        let search = ProcessInfo.processInfo.environment["MURMURE_APERCU_RECHERCHE"] ?? ""
        // MURMURE_APERCU_HAUTEUR=1800 : image plus haute pour les panneaux longs (Connecteurs).
        let height = Double(ProcessInfo.processInfo.environment["MURMURE_APERCU_HAUTEUR"] ?? "") ?? 900
        for (name, pane, subpage) in pages + (search.isEmpty ? [] : [("recherche", .general, nil)]) {
            UserDefaults.standard.set(pane.rawValue, forKey: "settingsPane")
            for (suffix, scheme) in [("", ColorScheme.light), ("-sombre", .dark)] {
                let view = SettingsView(subpage: subpage, scrolls: false, search: name == "recherche" ? search : "")
                    .frame(width: 880, height: height, alignment: .top)
                    .background(Theme.bg).foregroundStyle(Theme.fg).environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[2] + "-\(name)\(suffix).png"))
                }
            }
        }
    }
    exit(0)
}

// Aperçu de la personnalisation du premier lancement : `Murmure --apercu-bienvenue préfixe` → une image par écran
// (préfixe-1.png… préfixe-7.png), en clair et en sombre, avec des choix d'exemple. Ne lit ni n'écrit aucun réglage.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--apercu-bienvenue" {
    MainActor.assumeIsolated {
        StaticPreview.active = true
        for step in 0..<7 {
            for (suffix, scheme) in [("", ColorScheme.light), ("-sombre", .dark)] {
                let view = Onboarding(previewStep: step)
                    .frame(width: 1200, height: 760)
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[2] + "-\(step + 1)\(suffix).png"))
                }
            }
        }
    }
    exit(0)
}

// Aperçu du bouton flottant : `Murmure --apercu-bouton préfixe` → préfixe.png, chaque état côte à côte sur fond clair
// puis sombre (repos, survol du micro, survol de la réunion, dictée, transcription, réunion, réunion survolée).
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--apercu-bouton" {
    MainActor.assumeIsolated {
        StaticPreview.active = true
        let states: [(FloatingButtonModel.Mode, FloatingButtonModel.Half?)] = [
            (.idle, nil), (.idle, .top), (.idle, .bottom), (.dictating, nil), (.processing, nil), (.meeting, nil), (.meeting, .bottom),
        ]
        let row = { (background: Color) in
            HStack(spacing: 12) {
                ForEach(states.indices, id: \.self) { i in
                    let model = FloatingButtonModel()
                    let _ = (model.mode = states[i].0, model.hovered = states[i].1, model.level = 0.7,
                             model.meetingStartedAt = Date().addingTimeInterval(-754))
                    FloatingButtonView(model: model, scale: 1).frame(width: 40, height: 104)
                }
            }
            .padding(16)
            .background(background)
        }
        let view = VStack(spacing: 0) { row(Color(white: 0.93)); row(Color(white: 0.12)) }
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[2] + ".png"))
        }
    }
    exit(0)
}

// Aperçu de la capsule dépliée : `Murmure --apercu-encoche préfixe` → préfixe.png, chaque annonce telle que la
// capsule la déplie depuis le bord droit (agenda du jour et rappel avant un rendez-vous, sur un agenda d'exemple, proposition, enregistrement en cours, réunion enregistrée, compte rendu
// prêt, message), puis depuis le bord gauche. « Enregistrée » et « prête » montrent la dernière réunion de l'historique.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--apercu-encoche" {
    MainActor.assumeIsolated {
        StaticPreview.active = true
        let meeting = RecordingStore.shared.recordings.first { $0.kind == .meeting }?.id ?? UUID()
        // Agenda d'exemple : un rendez-vous dans 2 min avec visio, puis l'après-midi.
        let now = Date()
        func sample(_ title: String, in minutes: Double, hours: Double = 1, guests: Int, service: String? = nil,
                    location: String? = nil, color: Color) -> CalendarEvent {
            let start = now.addingTimeInterval(minutes * 60)
            return CalendarEvent(id: title, title: title,
                                 attendees: (0..<guests).map { Attendee(name: "Invité \($0 + 1)", email: nil, isMe: false) },
                                 start: start, end: start.addingTimeInterval(hours * 3600), location: location, service: service,
                                 origin: CalendarOrigin(title: "Calendrier", account: nil, color: color),
                                 joinURL: service == nil ? nil : URL(string: "https://teams.microsoft.com/l/meetup-join/exemple"))
        }
        let soon = sample("Point Dupont c/ Martin", in: 2, guests: 3, service: "Teams", color: .blue)
        Agenda.shared.sample = [
            soon, sample("RDV Lefèvre – succession", in: 95, guests: 1, location: "Cabinet", color: .orange),
            sample("Relecture pacte Kervoalen", in: 180, hours: 0.5, guests: 0, color: .green),
        ]
        let notices: [FloatingButtonModel.Notice] = [
            .agenda, .upcoming(soon),
            .proposal(.visio("Teams")), .recording(detail: "Teams · retranscrit sur ce Mac"),
            .quiet(since: now.addingTimeInterval(-200)), .saved(meeting), .ready(meeting), .message("Réunion trop courte", detail: "Moins de 2 secondes : rien n'a été gardé"),
        ]
        let column = { (opensLeft: Bool) in
            VStack(alignment: opensLeft ? .trailing : .leading, spacing: 10) {
                ForEach(notices.indices, id: \.self) { i in
                    let model = FloatingButtonModel()
                    let _ = (model.notice = notices[i], model.opensLeft = opensLeft)
                    FloatingButtonView(model: model, scale: 1)
                        .frame(width: notices[i] == .agenda ? 372 : 346,
                               height: max(104, NSHostingView(rootView: NoticeCard(notice: notices[i], scale: 1)).fittingSize.height))
                }
            }
            .padding(16)
        }
        let view = HStack(spacing: 0) { column(true).background(Color(white: 0.93)); column(false).background(Color(white: 0.12)) }
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[2] + ".png"))
        }
    }
    exit(0)
}

// Aperçu de la carte de proposition : `Murmure --apercu-proposition préfixe` → préfixe.png, appel, visio et rendez-vous.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--apercu-proposition" {
    MainActor.assumeIsolated {
        StaticPreview.active = true
        let event = CalendarEvent(title: "Rendez-vous M. Lefèvre – succession", attendees: [Attendee(name: "Paul Lefèvre", email: nil, isMe: false)],
                                  start: Calendar.current.date(bySettingHour: 14, minute: 30, second: 0, of: Date()),
                                  end: nil, location: "Cabinet", service: nil)
        let proposals: [MeetingProposal] = [.call, .visio("Teams"), .appointment(event)]
        let view = VStack(spacing: 12) {
            ForEach(proposals.indices, id: \.self) { MeetingPromptView(proposal: proposals[$0]) }
        }
        .padding(20)
        .background(Color(white: 0.75))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[2] + ".png"))
        }
    }
    exit(0)
}

// Aperçu de l'accueil : `Murmure --apercu-accueil préfixe` → le panneau gauche et chaque page (accueil et ses onglets
// Réunions et Dictées, Aujourd'hui, Épinglés, un dossier, la corbeille, Cette semaine, Extraits, Réglages › Général),
// en clair et en sombre, avec des données d'exemple ; puis l'accueil en contraste renforcé, avec des filtres appliqués
// (préfixe-filtres-…), avec des lignes cochées sur l'onglet Réunions (préfixe-selection-…, en contraste renforcé
// aussi), et la page En direct (préfixe-direct-…).
// À lancer avec MURMURE_SUPPORT_DIR sur un dossier vide : les exemples y sont écrits, jamais dans les vraies données.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--apercu-accueil" {
    guard ProcessInfo.processInfo.environment["MURMURE_SUPPORT_DIR"] != nil else {
        print("Définissez MURMURE_SUPPORT_DIR (dossier vide) : l'aperçu ajoute des données d'exemple à l'historique.")
        exit(2)
    }
    MainActor.assumeIsolated {
        StaticPreview.active = true
        let store = RecordingStore.shared
        let now = Date()
        func at(_ daysAgo: Int, _ hour: Int) -> Date {
            let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!
            return Calendar.current.date(bySettingHour: hour, minute: 15, second: 0, of: day)!
        }
        let dupont = store.createFolder("Dupont c/ Martin")
        store.setFolderExportPath(dupont.id, Settings.supportDir.appendingPathComponent("Affaire Dupont").path)
        let kervoalen = store.createFolder("Kervoalen Invest")
        store.createFolder("Cabinet")
        // Lexique : deux raccourcis, des corrections retenues et une saisie à la main, un passage proposé.
        let lexicon = Lexicon.shared
        lexicon.snippets = [
            Replacement(from: "formule confraternelle", to: "Je vous prie de croire, Cher Confrère, en l'assurance de mes sentiments dévoués."),
            Replacement(from: "coordonnées du cabinet", to: "Trezzo Delacq\nAvocats associés"),
        ]
        lexicon.replacements = [
            Replacement(from: "Lefèvre", to: "Lefebvre", learned: true, uses: 12, learnedAt: at(4, 10)),
            Replacement(from: "Jean Pierre Durant", to: "Jean-Pierre Durand", learned: true, uses: 3, learnedAt: at(1, 15)),
            Replacement(from: "kébis", to: "Kbis", learned: true, uses: 0, learnedAt: now),
            Replacement(from: "GBI", to: "Kbis", uses: 5),
        ]
        lexicon.suggestions = ["Je vous remercie de bien vouloir me communiquer les pièces annoncées dans vos dernières écritures."]
        let samples: [(String, String, Int, Int, Bool, String?, UUID?)] = [
            ("Point d'étape avec Mme Dupont sur la procédure", "La cliente confirme vouloir assigner avant la fin du mois. Les pièces sont réunies.", 0, 9, true, nil, dupont.id),
            ("Conclusions en réponse, partie sur la prescription", "Sur la prescription, il convient de rappeler que le délai court à compter de la connaissance du dommage.", 0, 11, false, "Word", dupont.id),
            ("Courriel au confrère Lefebvre", "Cher Confrère, je reviens vers vous au sujet de la date d'audience proposée.", 0, 14, false, "Mail", nil),
            ("Note interne sur le pacte d'associés Kervoalen", "Le pacte prévoit une clause de sortie conjointe dont la rédaction mérite d'être resserrée.", 1, 16, false, "Word", kervoalen.id),
            ("Réunion Kervoalen Invest · levée de fonds", "Tour de table sur les modalités de la levée de fonds et le calendrier.", 1, 10, true, nil, kervoalen.id),
            ("Message à Baptiste sur l'audience de jeudi", "Peux-tu confirmer que l'audience de jeudi est bien maintenue à 14 h ?", 2, 18, false, "Slack", nil),
            ("Mise en demeure SCI Les Tilleuls", "Nous vous mettons en demeure de régler la somme de 7 000 euros sous huitaine.", 3, 9, false, "Word", nil),
            ("Entretien d'embauche collaborateur", "Échange sur le parcours du candidat et ses attentes.", 9, 15, true, nil, nil),
            ("Observations sur le projet de protocole", "Le projet appelle trois observations sur la clause de confidentialité.", 40, 11, false, "Outlook", dupont.id),
        ]
        var ids: [UUID] = []
        for (index, sample) in samples.enumerated() {
            let (title, text, daysAgo, hour, meeting, app, folder) = sample
            let id = store.add(text: text, rawText: text, duration: meeting ? 2_700 : 95, appName: app,
                               kind: meeting ? .meeting : .dictation, title: title, date: at(daysAgo, hour))
            if let folder { store.setFolder(id, folder) }
            if meeting, index != 7 { store.addSummary(id, Summary(template: "Synthèse de réunion", text: "## Objet\n\(text)", date: at(daysAgo, hour))) }
            if index == 0 || index == 6 { store.setPinned(id, true) }
            ids.append(id)
        }
        // Deux comptes rendus pas encore ouverts : point bleu sur la ligne, nombre bleu dans le panneau.
        store.setSummaryUnread(ids[0], true)
        store.setSummaryUnread(ids[4], true)
        // Une réunion à deux voix (sous-titre « 2 interlocuteurs »), une archivée, deux à la corbeille.
        store.setTurns(ids[7], [Turn(speaker: 1, text: "Parlez-moi de votre parcours."), Turn(speaker: 2, text: "J'ai commencé en contentieux.")])
        let archivedID = store.add(text: "Ancienne note sur le bail commercial.", rawText: "Ancienne note sur le bail commercial.", duration: 60,
                                   appName: "Word", kind: .dictation, title: "Note sur le bail commercial Kervoalen", date: at(20, 10))
        store.setFolder(archivedID, kervoalen.id)
        store.setArchived(archivedID, true)
        for (title, daysAgo) in [("Brouillon de courriel à l'expert", 2), ("Essai de dictée", 5)] {
            let id = store.add(text: title, rawText: title, duration: 20, appName: "Mail", kind: .dictation, title: title, date: at(daysAgo, 12))
            store.trash(id)
        }
        let outlook = CalendarOrigin(title: "Calendrier", account: "Outlook", color: .blue)
        let google = CalendarOrigin(title: "Cabinet", account: "Google", color: .green)
        func event(_ title: String, _ hour: Int, _ minute: Int, guests: Int, service: String? = nil, location: String? = nil,
                   origin: CalendarOrigin) -> CalendarEvent {
            let start = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: now)!
            return CalendarEvent(title: title, attendees: (0..<guests).map { Attendee(name: "Invité \($0 + 1)", email: nil, isMe: false) },
                                 start: start, end: start.addingTimeInterval(3600), location: location, service: service, origin: origin)
        }
        // Rendez-vous placés par rapport à l'heure de l'aperçu : « dans 12 min » en bleu, puis plus tard, et un de trop
        // pour l'agenda du panneau (« et 1 autre »).
        func later(_ title: String, _ minutes: Double, guests: Int, service: String? = nil, location: String? = nil,
                   origin: CalendarOrigin) -> CalendarEvent {
            let start = now.addingTimeInterval(minutes * 60)
            return CalendarEvent(title: title, attendees: (0..<guests).map { Attendee(name: "Invité \($0 + 1)", email: nil, isMe: false) },
                                 start: start, end: start.addingTimeInterval(3600), location: location, service: service, origin: origin)
        }
        Agenda.shared.sample = [
            event("Audience de plaidoirie", 0, 30, guests: 0, location: "Tribunal judiciaire d'Aix-en-Provence", origin: outlook),
            later("Point client Kervoalen Invest", 12, guests: 3, service: "Google Meet", origin: google),
            later("Comité de direction", 95, guests: 5, service: "Teams", origin: outlook),
            later("Appel Me Lefebvre", 180, guests: 1, location: "Téléphone", origin: outlook),
            later("Préparation audience Dupont", 240, guests: 0, origin: google),
        ]
        let pages: [(String, Route)] = [
            ("accueil", .list(.all)), ("reunions", .list(.meetings)), ("dictees", .list(.dictations)),
            ("aujourdhui", .list(.today)), ("epingles", .list(.pinned)), ("dossier", .list(.folder(dupont.id))),
            ("corbeille", .list(.trash)), ("semaine", .week), ("lexique", .list(.lexicon)), ("reglages", .settings),
        ]
        @MainActor func render(_ view: some View, _ name: String, _ scheme: ColorScheme) {
            let framed = view.frame(width: 1200, height: 760, alignment: .top).environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: framed)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[2] + "-\(name).png"))
            }
        }
        // Le panneau Général (prénom) pour l'image des Réglages, sans toucher au panneau choisi par l'utilisateur.
        let previousPane = UserDefaults.standard.string(forKey: "settingsPane")
        UserDefaults.standard.set(SettingsView.Pane.general.rawValue, forKey: "settingsPane")
        defer { UserDefaults.standard.set(previousPane, forKey: "settingsPane") }
        for (name, route) in pages {
            for (suffix, scheme) in [("", ColorScheme.light), ("-sombre", .dark)] {
                render(WindowPreview(route: route), name + suffix, scheme)
            }
        }
        // Lexique, sous le bandeau : les trois listes (raccourcis, corrections, vocabulaire).
        for (suffix, scheme) in [("clair", ColorScheme.light), ("sombre", .dark)] {
            render(ShortcutsView(showsIntro: false).padding(.top, 36).colonne().background(Theme.bg).foregroundStyle(Theme.fg),
                   "lexique-listes-\(suffix)", scheme)
        }
        for (suffix, scheme) in [("clair", ColorScheme.light), ("sombre", .dark)] {
            render(WindowPreview(route: .list(.all), archived: true, folder: kervoalen.id), "filtres-\(suffix)", scheme)
        }
        // Sélection sur l'onglet Réunions : la liste tient dans le cadre, et la barre flottante du bas avec elle.
        let selected: Set<UUID> = [ids[0], ids[4]]
        for (suffix, scheme) in [("clair", ColorScheme.light), ("sombre", .dark)] {
            render(WindowPreview(route: .list(.meetings), selection: selected), "selection-\(suffix)", scheme)
        }
        let previousContrast = UserDefaults.standard.object(forKey: "highContrast")
        UserDefaults.standard.set(true, forKey: "highContrast")
        render(WindowPreview(route: .list(.all)), "contraste", .light)
        render(WindowPreview(route: .list(.all)), "contraste-sombre", .dark)
        render(WindowPreview(route: .list(.meetings), selection: selected), "selection-contraste", .light)
        render(WindowPreview(route: .list(.meetings), selection: selected), "selection-contraste-sombre", .dark)
        UserDefaults.standard.set(previousContrast, forKey: "highContrast")

        // Page En direct : une réunion commencée il y a douze minutes, texte figé et fin provisoire, une note.
        let live = AppState.shared
        live.meetingStartedAt = now.addingTimeInterval(-754)
        live.liveText = """
        Bonjour à tous, merci d'être là. L'objet de la réunion est de faire le point sur la levée de fonds de Kervoalen Invest avant la signature du pacte. \
        Nous avons reçu ce matin la dernière version de la lettre d'intention. Les investisseurs acceptent la valorisation, mais ils demandent une clause de sortie conjointe plus large. \
        C'est-à-dire qu'ils veulent pouvoir sortir dans les mêmes conditions que les fondateurs, à tout moment ? \
        Exactement, et c'est le point à négocier. Je propose qu'on limite la clause aux cessions de plus de cinquante pour cent du capital. \
        Pour la clause de non-concurrence, la durée de cinq ans paraît excessive au regard de la jurisprudence. Il faudrait la ramener à deux ans, avec une zone géographique précise, sinon elle risque d'être réputée non écrite. \
        Très bien. Et le calendrier ?
        """
        live.livePending = "On vise une signature avant la fin du mois, si les"
        live.liveNotes = "Clause de sortie conjointe : limiter aux cessions > 50 %.\nNon-concurrence : 2 ans."
        render(WindowPreview(route: .live), "direct-clair", .light)
        render(WindowPreview(route: .live), "direct-sombre", .dark)
        live.meetingStartedAt = nil
        live.liveText = ""
        live.livePending = ""
        live.liveNotes = ""
        store.flush()
    }
    exit(0)
}

// Aperçu de la fiche d'une réunion, onglet Transcription : `Murmure --apercu-fiche préfixe` → préfixe-clair.png,
// -sombre, -contraste, -contraste-sombre (trois voix dont « moi », une voix sans nom, un long monologue), les mêmes avec un terme
// cherché (préfixe-recherche-…), et une réunion à une seule voix (préfixe-une-voix-…). Puis les autres onglets :
// préfixe-synthese-…, -question-… (réponse de « Demander à Murmure »), -notes-…, -proposition-…, et une dictée (-dictee-…) ;
// enfin la barre du bas comme si le modèle était prêt (-demander-…, -modifier-clair) et le texte brut surligné (-dictee-brut-clair).
// À lancer avec MURMURE_SUPPORT_DIR sur un dossier vide : les exemples y sont écrits, jamais dans les vraies données.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--apercu-fiche" {
    guard ProcessInfo.processInfo.environment["MURMURE_SUPPORT_DIR"] != nil else {
        print("Définissez MURMURE_SUPPORT_DIR (dossier vide) : l'aperçu ajoute des données d'exemple à l'historique.")
        exit(2)
    }
    MainActor.assumeIsolated {
        StaticPreview.active = true
        let store = RecordingStore.shared
        let date = Calendar.current.date(bySettingHour: 9, minute: 15, second: 0, of: Date())!
        let dupont = store.createFolder("Dupont c/ Martin")
        // Voix 1 : la cliente, qui parle la première ; voix 2 : moi ; voix 3 : son mari, pas encore nommé.
        let turns = [
            Turn(speaker: 1, text: "Allô ? Oui, bonjour Maître."),
            Turn(speaker: 2, text: "Bonjour Madame Dupont, vous m'entendez bien ?"),
            Turn(speaker: 1, text: "Oui, très bien. Mon mari est à côté de moi, il écoutera surtout."),
            Turn(speaker: 2, text: "Parfait. Je voulais faire le point avec vous avant d'assigner. Nous avons reçu hier le dernier courrier de Maître Lefebvre, qui conteste toujours la date de connaissance du dommage. Leur argument repose sur le rapport d'expertise amiable de mars 2021, qu'ils présentent comme le point de départ de tout. Or ce rapport ne mentionnait pas les infiltrations du sous-sol, qui ne sont apparues qu'en janvier 2023, après les fortes pluies. C'est cette date qui fait courir le délai de prescription de cinq ans, et c'est ce que nous soutiendrons. M. Martin le sait très bien, puisque c'est lui qui a fait venir le plombier à ce moment-là. J'ajoute que le juge de la mise en état sera sensible à la chronologie : il faudra la présenter simplement, pièce par pièce, sans laisser de trou entre le rapport amiable et les premières factures. Si un trou apparaît, c'est là que la partie adverse placera son argument."),
            Turn(speaker: 3, text: "C'est-à-dire qu'ils disent qu'on savait depuis 2021 ?"),
            Turn(speaker: 2, text: "Exactement, et c'est ce que nous contestons."),
            Turn(speaker: 1, text: "Donc on est dans les temps pour la prescription. Et pour les factures du plombier, vous les avez toutes ?"),
            Turn(speaker: 2, text: "Il me manque celle de février. Si vous me l'envoyez cette semaine, j'assigne avant la fin du mois."),
        ]
        let meeting = store.add(text: turns.map(\.text).joined(separator: " "), rawText: turns.map(\.text).joined(separator: " "),
                                duration: 2_700, appName: nil, kind: .meeting,
                                title: "Point d'étape avec Mme Dupont sur la procédure", date: date)
        store.setTurns(meeting, turns)
        store.setFolder(meeting, dupont.id)
        store.setSpeakerName(meeting, speaker: 1, name: "Mme Dupont")
        store.setOwnSpeaker(meeting, 2)
        // Mme Dupont reconnue d'après une réunion précédente : mention « voix reconnue, à confirmer ».
        store.update(meeting) { $0.recognizedSpeakers = ["1": 0.71] }
        // Réunion à une seule voix : pas de tours de parole, le texte seul.
        let alone = """
        Note pour le dossier Kervoalen. Le pacte d'associés prévoit une clause de sortie conjointe dont la rédaction mérite d'être resserrée.
        Il faudra aussi vérifier la clause de non-concurrence : sa durée de cinq ans paraît excessive au regard de la jurisprudence.
        """
        let single = store.add(text: alone, rawText: alone, duration: 240, appName: nil, kind: .meeting,
                               title: "Note dictée sur le pacte Kervoalen", date: date.addingTimeInterval(-86_400))

        // Synthèse, notes et réponse de « Demander à Murmure » sur la même réunion.
        store.addSummary(meeting, Summary(template: SummaryTemplate.client.rawValue, text: """
        ## En bref
        Point d'étape avant l'assignation de M. Martin : la prescription n'est pas acquise, la date à retenir est janvier 2023.
        ## Points abordés
        - Le courrier de Maître Lefebvre fait partir le délai du rapport amiable de mars 2021.
        - Les infiltrations du sous-sol ne sont apparues qu'en janvier 2023 : c'est cette date qui fait courir le délai de cinq ans.
        - La chronologie sera présentée pièce par pièce au juge de la mise en état.
        ## Prochaines étapes
        - Mme Dupont : envoyer la facture du plombier de février, cette semaine.
        - Moi : assigner avant la fin du mois.
        """, date: date.addingTimeInterval(3_000)))
        store.setNotes(meeting, "Facture de février manquante.\nRappeler M. Martin : témoin de l'intervention du plombier ?")
        let answer = (question: "Quelles pièces manquent encore ?",
                      answer: Summarizer.Answer(text: "Il manque la facture du plombier de février. Mme Dupont doit l'envoyer cette semaine ; l'assignation suivra avant la fin du mois.",
                                                excerpt: "Il me manque celle de février. Si vous me l'envoyez cette semaine, j'assigne avant la fin du mois."))
        // Dictée mise en forme (onglet Texte seul, lien « Voir le texte brut »).
        let raw = "alors note pour le confrère lefebvre euh nous contestons la date de connaissance du dommage retenue dans votre courrier"
        let dictation = store.add(text: "Note pour le confrère Lefebvre : nous contestons la date de connaissance du dommage retenue dans votre courrier.",
                                  rawText: raw, duration: 42, appName: "Word", kind: .dictation,
                                  title: "Note pour le confrère Lefebvre", date: date.addingTimeInterval(7_200))
        store.setFolder(dictation, dupont.id)

        let previousContrast = UserDefaults.standard.object(forKey: "highContrast")
        defer { UserDefaults.standard.set(previousContrast, forKey: "highContrast") }
        // Autres onglets : (nom, fiche, onglet, apparence, contraste renforcé, réponse affichée).
        let tabs: [(String, UUID, RecordingDetail.Tab, ColorScheme, Bool, Bool)] = [
            ("synthese-clair", meeting, .summary, .light, false, false), ("synthese-sombre", meeting, .summary, .dark, false, false),
            ("synthese-contraste", meeting, .summary, .light, true, false),
            ("question-clair", meeting, .summary, .light, false, true), ("question-sombre", meeting, .notes, .dark, false, true),
            ("notes-clair", meeting, .notes, .light, false, false), ("notes-sombre", meeting, .notes, .dark, false, false),
            ("proposition-clair", meeting, .proposal, .light, false, false), ("proposition-sombre", meeting, .proposal, .dark, false, false),
            ("dictee-clair", dictation, .text, .light, false, false), ("dictee-sombre", dictation, .text, .dark, false, false),
            ("une-voix-synthese-clair", single, .summary, .light, false, false),
        ]
        for (name, id, tab, scheme, contrast, asked) in tabs {
            UserDefaults.standard.set(contrast, forKey: "highContrast")
            AppState.shared.highlight = ""
            let view = RecordingDetail(id: id, onBack: {}, tab: tab, answer: asked ? answer : nil)
                .frame(width: 980, height: 900, alignment: .top)
                .background(Theme.bg).foregroundStyle(Theme.fg).environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[2] + "-\(name).png"))
            }
        }

        // Barre du bas dessinée comme si le modèle était prêt (son état normal) : question, modification de la synthèse ;
        // puis une dictée dont le terme cherché ne se trouve que dans le texte brut (qui s'ouvre d'emblée, surligné).
        let extras: [(String, UUID, RecordingDetail.Tab, ColorScheme, Bool, String)] = [
            ("demander-clair", meeting, .notes, .light, false, ""), ("demander-sombre", meeting, .notes, .dark, false, ""),
            ("modifier-clair", meeting, .summary, .light, true, ""),
            ("dictee-brut-clair", dictation, .text, .light, false, "euh"),
        ]
        StaticPreview.modelePret = true
        UserDefaults.standard.set(false, forKey: "highContrast")
        for (name, id, tab, scheme, edits, query) in extras {
            AppState.shared.highlight = query
            let view = RecordingDetail(id: id, onBack: {}, tab: tab, editsSummary: edits)
                .frame(width: 980, height: 900, alignment: .top)
                .background(Theme.bg).foregroundStyle(Theme.fg).environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[2] + "-\(name).png"))
            }
        }
        StaticPreview.modelePret = false

        let variants: [(String, UUID, String, ColorScheme, Bool)] = [
            ("clair", meeting, "", .light, false), ("sombre", meeting, "", .dark, false), ("contraste", meeting, "", .light, true),
            ("recherche-clair", meeting, "prescription", .light, false), ("recherche-sombre", meeting, "prescription", .dark, false),
            ("recherche-contraste", meeting, "prescription", .light, true),
            ("contraste-sombre", meeting, "", .dark, true), ("recherche-contraste-sombre", meeting, "prescription", .dark, true),
            ("une-voix-clair", single, "", .light, false), ("une-voix-sombre", single, "", .dark, false),
        ]
        for (name, id, query, scheme, contrast) in variants {
            UserDefaults.standard.set(contrast, forKey: "highContrast")
            AppState.shared.highlight = query
            let view = RecordingDetail(id: id, onBack: {}, tab: .transcript)
                .frame(width: 980, height: 1_250, alignment: .top)
                .background(Theme.bg).foregroundStyle(Theme.fg).environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[2] + "-\(name).png"))
            }
        }
        AppState.shared.highlight = ""
        store.flush()
    }
    exit(0)
}

// Distinction des voix seule : `Murmure --voix fichier` (avec MURMURE_DEBUG=1 pour le détail).
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--voix" {
    let audio = try loadAudio(CommandLine.arguments[2])
    runBlocking {
        let transcriber = Transcriber()
        try await transcriber.load()
        guard let turns = try await transcriber.speakerTurns(audio) else { print("Une seule voix"); return }
        print("\(Set(turns.map(\.speaker)).count) interlocuteurs")
        for turn in turns { print("  Interlocuteur \(turn.speaker) : \(turn.text.prefix(70))") }
    }
}

// Réunion : `Murmure --meeting fichier.wav` déroule le traitement complet et l'ajoute à l'historique,
// en passant par la copie de sûreté comme une vraie réunion (interrompre le processus puis `--reprise` la rejoue).
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--meeting" {
    let audio = try loadAudio(CommandLine.arguments[2])
    runBlocking {
        let transcriber = Transcriber()
        var start = Date()
        try await transcriber.load()
        try await LocalLLM.shared.start(model: Settings.localModel)
        print("Modèles chargés en \(seconds(since: start))")
        start = Date()
        let id = await MainActor.run {
            RecordingStore.shared.add(text: "", rawText: "", duration: Double(audio.count) / 16_000, appName: nil,
                                      kind: .meeting, title: "Réunion de test", progress: "Transcription…")
        }
        let spool = AudioSpool(id: id, track: .mic)
        spool.append(audio)
        spool.close()
        if let notesFromEnvironment { await MainActor.run { RecordingStore.shared.setNotes(id, notesFromEnvironment) } }
        await MeetingController.process(id: id, audio: audio, placeholder: "Réunion de test", transcriber: transcriber)
        let recording = await MainActor.run { RecordingStore.shared.recording(id) }
        print("Traitée en \(seconds(since: start)) pour \(formatDuration(Double(audio.count) / 16_000)) d'audio")
        print("TITRE : \(recording?.title ?? "–")")
        print("TRANSCRIPTION :\n\(recording?.transcript ?? "–")")
        if let notes = recording?.userNotes { print("NOTES :\n\(notes)") }
        print("SYNTHÈSE :\n\(recording?.summaries?.last?.text ?? "–")")
        if ProcessInfo.processInfo.environment["MURMURE_SAVE"] == nil { await MainActor.run { RecordingStore.shared.delete(id) } }
        try await Task.sleep(for: .milliseconds(300))
        LocalLLM.shared.stop()
    }
}

// Fin de réunion silencieuse : `Murmure --essai-silence fichier…` passe chaque fichier dans `QuietMeter` par
// passages de 10 s, comme pendant une réunion, et dit où la capsule proposerait de terminer (3 min sans parole).
// MURMURE_SILENCE_FIN=240 ajoute 240 s de fond à la fin (les 2 s les plus calmes du fichier, en boucle), pour
// simuler des participants partis sans arrêter l'enregistrement.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--essai-silence" {
    let rate = QuietMeter.rate
    let tail = Double(ProcessInfo.processInfo.environment["MURMURE_SILENCE_FIN"] ?? "") ?? 0
    func clock(_ seconds: Double) -> String { String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
    for path in CommandLine.arguments.dropFirst(2) {
        guard var audio = try? AudioFile.load(URL(fileURLWithPath: path)), audio.count > 2 * rate else {
            print("\(path) : illisible ou trop court"); continue
        }
        if tail > 0 {
            // Fond pris dans MURMURE_SILENCE_FOND (un autre fichier) si le fichier n'a aucune pause de 2 s (voix de synthèse).
            let source = ProcessInfo.processInfo.environment["MURMURE_SILENCE_FOND"]
                .flatMap { try? AudioFile.load(URL(fileURLWithPath: $0)) } ?? audio
            var quietest = 0, lowest = Float.greatestFiniteMagnitude
            for start in stride(from: 0, to: source.count - 2 * rate, by: rate / 2) {
                var energy: Float = 0
                for i in stride(from: start, to: start + 2 * rate, by: 4) { energy += source[i] * source[i] }
                if energy < lowest { lowest = energy; quietest = start }
            }
            let background = Array(source[quietest..<quietest + 2 * rate])
            for _ in 0..<Int(tail / 2) { audio.append(contentsOf: background) }
        }
        var meter = QuietMeter()
        var spoken = 0, passes = 0, longest = 0.0
        var offers: [Double] = []
        for start in stride(from: 0, to: audio.count, by: 10 * rate) {
            if meter.feed(Array(audio[start..<min(start + 10 * rate, audio.count)])) { spoken += 1 }
            passes += 1
            longest = max(longest, meter.quietSeconds)
            let end = Double(min(start + 10 * rate, audio.count)) / Double(rate)
            // Proposée une fois par silence, dès qu'il atteint 3 min.
            if meter.quietSeconds >= 180, offers.last.map({ end - $0 > meter.quietSeconds }) ?? true { offers.append(end) }
        }
        let duration = Double(audio.count) / Double(rate)
        print("\((path as NSString).lastPathComponent) : \(clock(duration)), \(spoken)/\(passes) passages parlés, plus long silence \(clock(longest))"
              + (offers.isEmpty ? ", pas de proposition" : ", proposition à " + offers.map(clock).joined(separator: ", ")))
    }
    exit(0)
}

// Import : `Murmure --import fichier.m4a` suit le chemin de « Importer un enregistrement… » (lecture du fichier
// en arrière-plan, fiche datée du fichier, traitement de réunion) et affiche la fiche obtenue.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--import" {
    runBlocking {
        let transcriber = Transcriber()
        try await transcriber.load()
        try await LocalLLM.shared.start(model: Settings.localModel)
        let start = Date()
        let id = await MainActor.run { MeetingController(transcriber: transcriber).importFile(URL(fileURLWithPath: CommandLine.arguments[2])) }
        while await MainActor.run(body: { RecordingStore.shared.recording(id)?.progress != nil }) { try await Task.sleep(for: .milliseconds(200)) }
        let recording = await MainActor.run { RecordingStore.shared.recording(id) }
        print("Importée en \(seconds(since: start)) · \(formatDuration(recording?.duration ?? 0)) · datée du \(recording?.date.formatted(date: .abbreviated, time: .shortened) ?? "–")")
        print("TITRE : \(recording?.title ?? "–")")
        if let failure = recording?.processingError { print("ERREUR : \(failure)") }
        print("TRANSCRIPTION :\n\(recording?.transcript ?? "–")")
        print("SYNTHÈSE :\n\(recording?.summaries?.last?.text ?? "–")")
        if ProcessInfo.processInfo.environment["MURMURE_SAVE"] == nil { await MainActor.run { RecordingStore.shared.delete(id) } }
        try await Task.sleep(for: .milliseconds(300))
        LocalLLM.shared.stop()
    }
}

// Reprise : `Murmure --reprise` relit les copies de sûreté `en-cours-*` laissées par un arrêt brutal
// et termine le traitement des réunions correspondantes, comme l'application au lancement.
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--reprise" {
    runBlocking {
        let pending = AudioSpool.interrupted()
        guard !pending.isEmpty else { print("Aucune réunion à reprendre"); return }
        print("\(pending.count) réunion(s) à reprendre")
        let transcriber = Transcriber()
        try await transcriber.load()
        try await LocalLLM.shared.start(model: Settings.localModel)
        let start = Date()
        let resumed = await MeetingController.resumeInterrupted(transcriber: transcriber)
        for id in resumed {
            let recording = await MainActor.run { RecordingStore.shared.recording(id) }
            print("TITRE : \(recording?.title ?? "–")")
            print("STATUT : \(recording?.status.rawValue ?? "–") · \(recording?.wordCount ?? 0) mots")
            print("SYNTHÈSE :\n\(recording?.summaries?.last?.text.prefix(600) ?? "–")")
        }
        print("Reprise en \(seconds(since: start))")
        try await Task.sleep(for: .milliseconds(300))
        LocalLLM.shared.stop()
    }
}

// Synthèse seule : `Murmure --synthese transcription.txt` rédige le compte rendu d'une transcription
// (un tour de parole par ligne, « Interlocuteur 1 : … »), pour éprouver le découpage sur de longues réunions.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--synthese" {
    guard let transcript = try? String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8) else {
        print("Fichier illisible : \(CommandLine.arguments[2])"); exit(1)
    }
    runBlocking {
        var start = Date()
        if Cleaner.engine == .local { try await LocalLLM.shared.start(model: Settings.localModel) }
        print("Moteur \(Cleaner.engine.rawValue) prêt en \(seconds(since: start)) · \(transcript.count) caractères, \(transcript.split(whereSeparator: \.isWhitespace).count) mots")
        start = Date()
        do {
            let summary = try await Summarizer.generate(transcript: transcript, participants: [], template: .meeting, notes: notesFromEnvironment)
            print("SYNTHÈSE (\(seconds(since: start))) :\n\(summary)")
        } catch {
            print("ÉCHEC (\(seconds(since: start))) : \(error)")
        }
        LocalLLM.shared.stop()
    }
}

// Titre de réunion : `Murmure --titre-reunion compte-rendu.md "Titre du rendez-vous"` affiche le titre que la
// réunion recevrait à la fin (le second argument, facultatif, est le titre d'origine).
if (3...4).contains(CommandLine.arguments.count), CommandLine.arguments[1] == "--titre-reunion" {
    guard let summary = try? String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8) else {
        print("Fichier illisible : \(CommandLine.arguments[2])"); exit(1)
    }
    runBlocking {
        if Cleaner.engine == .local { try await LocalLLM.shared.start(model: Settings.localModel) }
        let hint = CommandLine.arguments.count == 4 ? CommandLine.arguments[3] : nil
        print(await Cleaner.makeMeetingTitle(summary: summary, hint: hint) ?? "(aucun titre)")
        LocalLLM.shared.stop()
    }
}

// Question à la réunion : `Murmure --question transcription.txt "Quels engagements ont été pris ?"`.
if (4...5).contains(CommandLine.arguments.count), CommandLine.arguments[1] == "--question" {
    guard let transcript = try? String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8) else {
        print("Fichier illisible : \(CommandLine.arguments[2])"); exit(1)
    }
    runBlocking {
        if Cleaner.engine == .local { try await LocalLLM.shared.start(model: Settings.localModel) }
        let start = Date()
        // Cinquième argument facultatif : le compte rendu, donné au modèle comme dans la fiche.
        let summary = CommandLine.arguments.count == 5 ? try? String(contentsOfFile: CommandLine.arguments[4], encoding: .utf8) : nil
        let answer = try await Summarizer.answer(CommandLine.arguments[3], transcript: transcript, summary: summary)
        print("RÉPONSE (\(seconds(since: start))) :\n\(answer.text)")
        print("EXTRAIT :\n\(answer.excerpt ?? "aucun")")
        LocalLLM.shared.stop()
    }
}

// Essai de la relecture par Claude : `MURMURE_CLAUDE_KEY=sk-… Murmure --essai-claude [fichier.txt]` relit des
// dictées types (ou chaque ligne du fichier) avec un contexte de document, et chronomètre. `MURMURE_CLAUDE_URL`
// remplace l'API par un serveur local d'essai (tools/faux-claude.py).
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--essai-claude" {
    Cleaner.override = .claude
    let defaults = [
        "Envoyez le courrier à Maître Durand, non pardon, à Maître Lefèvre demain matin.",
        "La société Kervoa Len Invest a été assigné devant le tribunal de commerce de Nanterre, de Versailles pardon, le 12 mars.",
        "Je, je vous confirme que notre client accepte la proposition d'accord, enfin non, il l'accepte sous réserve de la clause de confidentialité.",
        "Nous sollicitons la condamnation de la partie adverse à nous verser la somme de 5 000 euros, enfin 7 000 euros, au titre de l'article 700 du Code de procédure civile.",
    ]
    let samples = CommandLine.arguments.count == 3
        ? ((try? String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)) ?? "").components(separatedBy: "\n").filter { !$0.isEmpty }
        : defaults
    let context = FieldContext(bundleID: "com.microsoft.Word",
                               before: "Par acte du 3 février 2026, la société Kervoalen Invest a assigné la SCI Les Tilleuls devant le tribunal de commerce de Versailles. Maître Lefebvre, conseil de la demanderesse, expose ce qui suit.",
                               selected: "", after: "", windowTitle: "Conclusions Kervoalen Invest c. SCI Les Tilleuls.docx")
    runBlocking {
        print("Modèle dictée : \(ClaudeAPI.name(of: Settings.claudeDictationModel)) · clé \(ClaudeAPI.maskedKey ?? "absente")")
        var total = 0.0
        for sample in samples {
            let start = Date()
            let cleaned = await Cleaner.clean(Cleaner.applyCommands(sample), context: context)
            total += Date().timeIntervalSince(start)
            print("[\(seconds(since: start))] \(cleaned)")
        }
        print(String(format: "moyenne : %.2f s · %d jetons lus, %d écrits", total / Double(max(samples.count, 1)),
                     ClaudeAPI.shared.tokensIn, ClaudeAPI.shared.tokensOut))
    }
}

// Micros : `Murmure --micros` liste les entrées, signale le Bluetooth et dit lequel la prochaine capture prendra,
// sans ouvrir aucun micro.
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--micros" {
    let system = Microphones.systemDefault()
    for device in Microphones.all() {
        let marks = [device.id == system?.id ? "entrée du système" : nil, Microphones.isBluetooth(device.id) ? "Bluetooth" : nil].compactMap { $0 }
        print("  \(device.name)" + (marks.isEmpty ? "" : " (\(marks.joined(separator: ", ")))"))
    }
    print("Prochaine capture : \(Microphones.currentName)")
    exit(0)
}

// Banc d'essai : `Murmure --bench-llm` compare les modèles locaux installés sur des dictées types.
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--bench-llm" {
    let samples = [
        "Bonjour, alors je voudrais préparer une mise en demeure pour la société Martin, non pardon, la société Dupont, sur le fondement de l'article 1231-1 du Code civil, avec une injonction de payer sous huitaine.",
        "Maître, je, je vous confirme que notre client accepte la proposition d'accord, enfin non, il l'accepte sous réserve de la clause de confidentialité.",
        "Le délai d'appel est de un mois, non, plutôt quinze jours à compter de la signification du jugement.",
        "Il faudrait, il faudrait relancer le greffe du tribunal judiciaire de Lille, de Douai pardon, pour obtenir la date d'audience.",
        "Pouvez-vous non plutôt peux-tu me rédiger une assignation en référé contre la SCI Les Tilleuls ?",
        "Nous sollicitons la condamnation de la partie adverse à nous verser la somme de 5 000 euros, enfin 7 000 euros, au titre de l'article 700 du Code de procédure civile.",
    ]
    runBlocking {
        for model in LocalLLM.installedModels {
            print("\n===== \(model.name) =====")
            var start = Date()
            try await LocalLLM.shared.start(model: model.file)
            await Cleaner.warmUp()
            print("chargé en \(seconds(since: start))")
            var total = 0.0
            for sample in samples {
                start = Date()
                let cleaned = await Cleaner.clean(sample)
                total += Date().timeIntervalSince(start)
                print("[\(seconds(since: start))] \(cleaned)")
            }
            print(String(format: "moyenne : %.2f s", total / Double(samples.count)))
            LocalLLM.shared.stop()
        }
    }
}

// Resynchronisation : `Murmure --resync` recopie en Markdown tout ce qui est rangé dans un dossier lié
// (à lancer Murmure fermé : l'application garde l'historique en mémoire).
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--resync" {
    runBlocking {
        await MainActor.run { Exporter.syncAll() }
        try await Task.sleep(for: .seconds(1.2)) // laisse passer le regroupement des écritures
        Exporter.flush()
        let exported = await MainActor.run { RecordingStore.shared.recordings.compactMap(\.exportedPath) }
        print("\(exported.count) fichier(s) :")
        exported.forEach { print("  \($0)") }
        try await Task.sleep(for: .milliseconds(300))
    }
}

// Essai de capture : `Murmure --record-system secondes préfixe` enregistre le micro et le son de l'ordinateur
// dans préfixe-micro.wav et préfixe-ordinateur.wav. À lancer par `open -n Murmure.app --args …` pour que
// l'autorisation macOS soit celle de Murmure.
if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--record-system", let duration = Double(CommandLine.arguments[2]) {
    let prefix = CommandLine.arguments[3]
    runBlocking {
        var report = ""
        let mic = AudioRecorder(), system = SystemAudioRecorder()
        let started = Date()
        try mic.start()
        do { try system.start(alignedWith: started) } catch { report += "Son de l'ordinateur : \(error.localizedDescription)\n" }
        try await Task.sleep(for: .seconds(duration))
        report += String(format: "Mise en place du son de l'ordinateur : %.2f s (comblée par du silence)\n", system.startDelay)
        let tracks = [("micro", mic.stop()), ("ordinateur", system.stop())]
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        for (name, samples) in tracks {
            let peak = samples.reduce(0) { max($0, abs($1)) }
            report += String(format: "%@ : %.1f s, crête %.3f\n", name, Double(samples.count) / 16_000, peak)
            guard !samples.isEmpty else { continue }
            let buffer = BenchASR.pcmBuffer(samples, format: format)
            let file = try AVAudioFile(forWriting: URL(fileURLWithPath: "\(prefix)-\(name).wav"), settings: format.settings)
            try file.write(from: buffer)
        }
        try report.write(toFile: prefix + ".txt", atomically: true, encoding: .utf8)
    }
}

// Réunion à deux pistes : `Murmure --meeting-tracks micro.wav ordinateur.wav` mélange les pistes, distingue
// les voix et indique laquelle est reconnue comme « Moi », sans rien ajouter à l'historique.
if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--meeting-tracks" {
    let tracks = MeetingAudio(mic: try loadAudio(CommandLine.arguments[2]), system: try loadAudio(CommandLine.arguments[3]))
    runBlocking {
        let transcriber = Transcriber()
        try await transcriber.load()
        print(String(format: "Gains : micro ×%.2f, ordinateur ×%.2f", tracks.micGain, tracks.systemGain))
        if let echo = tracks.echo {
            print(String(format: "Écho des haut-parleurs : %d ms, corrélation %.2f, micro retiré sur %.0f %% des passages de l'ordinateur",
                         echo.delayMs, echo.correlation, 100 * echo.removed))
        }
        let start = Date()
        guard let voices = try await transcriber.speakerTurns(tracks.mixed, micShare: tracks.micShareByFrame()) else {
            print("Une seule voix"); return
        }
        print("Traitée en \(seconds(since: start)) ; « Moi » = interlocuteur \(voices.own.map(String.init) ?? "non reconnu")")
        for turn in voices.turns { print("  \(turn.speaker == voices.own ? "Moi" : "Interlocuteur \(turn.speaker)") : \(turn.text)") }
    }
}

// Banc d'essai de la transcription : `Murmure --bench-asr dossier` (paires nom.aiff / nom.txt).
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--bench-asr" {
    runBlocking { try await BenchASR.run(directory: CommandLine.arguments[2]) }
}

// Banc d'essai des réunions : `Murmure --bench-reunion dossier` (reunion.wav + reunion.json de tools/corpus-reunion.py).
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--bench-reunion" {
    runBlocking { try await BenchMeeting.run(directory: CommandLine.arguments[2]) }
}

// Banc d'essai de la reconnaissance des voix d'une réunion à l'autre : `Murmure --bench-voix fichier…`.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--bench-voix" {
    runBlocking { try await BenchVoices.run(paths: Array(CommandLine.arguments.dropFirst(2))) }
}
// Essai de bout en bout (dossier de données temporaire obligatoire) : `MURMURE_SUPPORT_DIR=… Murmure --test-voix fichier [nom]`.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--test-voix" {
    runBlocking { try await BenchVoices.selfTest(path: CommandLine.arguments[2], name: CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "Témoin") }
}

// Banc d'essai sur les vraies dictées dont l'audio a été gardé : `Murmure --bench-real`.
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--bench-real" {
    runBlocking { try await BenchASR.runReal() }
}

// Contexte du curseur : lecture d'un champ réel, cas types du collage, banc d'essai de l'amorce.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--contexte", let delay = Double(CommandLine.arguments[2]) {
    runBlocking { await BenchContext.capture(after: delay) }
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--test-collage" {
    runBlocking { await MainActor.run { BenchContext.selfTest() } }
}
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--bench-contexte" {
    runBlocking { try await BenchContext.run(directory: CommandLine.arguments[2]) }
}

// Dictée en flux : `Murmure --bench-flux fichier…` rejoue chaque audio en temps réel, comme dit au micro,
// relâche la touche 0,3 s après la fin, et mesure l'attente jusqu'au texte, contre une transcription d'un bloc.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--bench-flux" {
    runBlocking {
        let transcriber = Transcriber()
        try await transcriber.load()
        for path in CommandLine.arguments.dropFirst(2) {
            // MURMURE_RELACHE : secondes de silence entre la fin de la parole et le relâchement (0,3 par défaut).
            let release = ProcessInfo.processInfo.environment["MURMURE_RELACHE"].flatMap(Double.init) ?? 0.3
            let audio = try loadAudio(path) + [Float](repeating: 0, count: Int(16_000 * release))
            var start = Date()
            let whole = try await transcriber.transcribe(audio)
            let wholeTime = Date().timeIntervalSince(start)
            let began = Date()
            let flux = ProgressiveDictation(transcriber: transcriber) { index in
                let available = min(audio.count, Int(Date().timeIntervalSince(began) * 16_000))
                return index < available ? Array(audio[index..<available]) : []
            }
            flux.start(context: nil)
            try await Task.sleep(for: .seconds(Double(audio.count) / 16_000))
            start = Date()
            let streamed = try await flux.finish(audio, context: nil)
            let streamedTime = Date().timeIntervalSince(start)
            print(String(format: "%@ · %.1f s de parole · d'un bloc %.2f s · en flux %.2f s après le relâchement",
                         URL(fileURLWithPath: path).lastPathComponent, Double(audio.count) / 16_000, wholeTime, streamedTime))
            print("  bloc : \(whole)")
            print("  flux : \(streamed)")
        }
    }
}

// Relecture anticipée : `Murmure --bench-relecture dossier` rejoue des dictées de synthèse (tools/corpus-relecture.sh)
// et compare l'attente après le relâchement, relecture par Claude après coup ou demandée dès qu'on se tait.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--bench-relecture" {
    runBlocking { try await BenchReview.run(directory: CommandLine.arguments[2]) }
}

// Annuaire des noms : `Murmure --bench-noms dossier` (tools/corpus-noms.sh) compare la relecture des noms sans et avec
// l'annuaire ; `Murmure --noms annuaire.txt texte` montre les noms rapprochés d'un texte.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--bench-noms" {
    runBlocking { try await BenchNames.run(directory: CommandLine.arguments[2]) }
}
if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--noms" {
    do { try BenchNames.show(annuaire: CommandLine.arguments[2], text: CommandLine.arguments[3]) } catch { print(error) }
    exit(0)
}

// Expiration des dictées : `MURMURE_SUPPORT_DIR=dossier-vide Murmure --test-expiration` crée des dictées fictives
// (expirée, à venir, rangée, ancienne sans champ, réunion) et vérifie la purge, le rangement et « Garder ».
// Jamais sur les données réelles : l'application garde l'historique en mémoire et réécrirait le fichier.
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--test-expiration" {
    guard let dir = ProcessInfo.processInfo.environment["MURMURE_SUPPORT_DIR"], !dir.isEmpty else {
        print("ÉCHEC : MURMURE_SUPPORT_DIR doit pointer vers un dossier temporaire vide"); exit(1)
    }
    let support = URL(fileURLWithPath: dir, isDirectory: true)
    let index = support.appendingPathComponent("historique.json")
    guard !FileManager.default.fileExists(atPath: index.path) else {
        print("ÉCHEC : \(dir) contient déjà un historique, choisissez un dossier vide"); exit(1)
    }
    var failures: [String] = []
    func check(_ condition: Bool, _ label: String) {
        print((condition ? "  ok     " : "  ÉCHEC  ") + label)
        if !condition { failures.append(label) }
    }
    let now = Date()
    // Un historique « d'avant » : la dictée n'a pas de champ expiresAt, elle ne doit jamais expirer.
    let oldID = UUID()
    let old = """
    [{"id":"\(oldID.uuidString)","date":"2026-01-10T09:00:00Z","title":"Ancienne dictée","text":"Texte d'avant la version","rawText":"texte d'avant la version","duration":4}]
    """
    try old.write(to: index, atomically: true, encoding: .utf8)
    let store = RecordingStore.shared
    check(store.recording(oldID)?.expiresAt == nil && store.recording(oldID)?.text == "Texte d'avant la version",
          "ancien historique relu, sans expiration")

    let retention = Settings.DictationRetention.self
    check(retention.day.expiry(from: now) == now.addingTimeInterval(24 * 3600) && retention.always.expiry() == nil && retention.never.expiry() == nil,
          "délais : 24 heures → +24 h, Toujours et Jamais → aucune date")

    let expired = store.add(text: "Dictée expirée", rawText: "", duration: 3, appName: nil, expiresAt: now.addingTimeInterval(-3600))
    let upcoming = store.add(text: "Dictée à venir", rawText: "", duration: 3, appName: nil, expiresAt: now.addingTimeInterval(3 * 3600))
    let filed = store.add(text: "Dictée rangée", rawText: "", duration: 3, appName: nil, expiresAt: now.addingTimeInterval(-3600))
    let kept = store.add(text: "Dictée gardée", rawText: "", duration: 3, appName: nil, expiresAt: now.addingTimeInterval(-3600))
    let meeting = store.add(text: "Réunion", rawText: "", duration: 60, appName: nil, kind: .meeting, title: "Réunion",
                            expiresAt: now.addingTimeInterval(-3600))
    check(store.recording(meeting)?.expiresAt == nil, "une réunion n'a jamais d'expiration")
    check(store.recording(upcoming)?.expiresIn == "dans 3 h", "« expire dans 3 h » pour une dictée à venir")
    check(store.recording(expired)?.isExpired == true && store.recording(upcoming)?.isExpired == false, "isExpired")

    // Ranger, c'est garder ; la sortir du dossier ne remet pas d'expiration.
    let folder = store.createFolder("Affaire test")
    store.setFolder(filed, folder.id)
    check(store.recording(filed)?.expiresAt == nil, "rangée dans un dossier → plus d'expiration")
    store.setFolder(filed, nil)
    check(store.recording(filed)?.expiresAt == nil, "sortie du dossier → toujours gardée")
    store.keep(kept)
    check(store.recording(kept)?.expiresAt == nil, "« Garder » retire l'expiration")

    // Audio gardé de la dictée expirée : retiré avec elle.
    let audio = Settings.audioDir.appendingPathComponent("\(expired.uuidString).wav")
    try Data("bidon".utf8).write(to: audio)

    let purged = store.purgeExpired(now: now)
    check(purged == 1, "purge : 1 dictée supprimée (\(purged))")
    check(store.recording(expired) == nil, "la dictée expirée a disparu")
    check(!FileManager.default.fileExists(atPath: audio.path), "son audio gardé a été retiré")
    check([upcoming, filed, kept, meeting, oldID].allSatisfy { store.recording($0) != nil }, "les autres sont toujours là")
    check(store.recordings.filter(\.isTrashed).isEmpty, "rien n'est passé par la corbeille")

    // Le fichier écrit se relit avec les dates d'expiration.
    store.flush()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let reread = (try? decoder.decode([Recording].self, from: Data(contentsOf: index))) ?? []
    check(reread.count == 5 && reread.first { $0.id == upcoming }?.expiresAt != nil && reread.first { $0.id == oldID }?.expiresAt == nil,
          "historique.json relu : 5 fiches, expiration conservée pour la dictée à venir seulement")

    print(failures.isEmpty ? "OK" : "ÉCHEC : \(failures.count) vérification(s)")
    exit(failures.isEmpty ? 0 : 1)
}

// Agendas vus par Murmure : `Murmure --agendas` liste comptes, agendas (✓ pris en compte) et rendez-vous du jour.
// Lecture seule. L'autorisation Calendriers est celle du processus qui lance la commande (Terminal…).
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--agendas" {
    let semaphore = DispatchSemaphore(value: 0)
    if !Connectors.calendarAuthorized {
        Connectors.eventStore.requestFullAccessToEvents { _, _ in semaphore.signal() }
        semaphore.wait()
    }
    guard Connectors.calendarAuthorized else {
        print("Calendriers non autorisé pour ce processus (Réglages Système › Confidentialité et sécurité › Calendriers).")
        exit(1)
    }
    for source in Connectors.eventStore.sources {
        let calendars = source.calendars(for: .event)
        print("source « \(source.title) » type \(source.sourceType.rawValue) · \(calendars.count) agenda(s)")
    }
    for account in Connectors.calendarAccounts {
        print("\n\(account.label)")
        for calendar in account.calendars { print("  \(calendar.included ? "✓" : "·") \(calendar.title)") }
    }
    print("\nAujourd'hui :")
    let today = Connectors.todayEvents()
    if today.isEmpty { print("  (aucun rendez-vous dans les agendas cochés)") }
    for event in today {
        let hour = event.start?.formatted(date: .omitted, time: .shortened) ?? "?"
        print("  \(hour)  \(event.title)  [\(event.origin?.label ?? "?")]  \(event.guestCount) invité(s)")
    }
    exit(0)
}

// Fusion des doublons d'agenda et reconnaissance des liens d'abonnement : `Murmure --test-agenda`, sans accès à l'agenda.
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--test-agenda" {
    var failures: [String] = []
    func check(_ condition: Bool, _ label: String) {
        print((condition ? "  ok     " : "  ÉCHEC  ") + label)
        if !condition { failures.append(label) }
    }
    let nine = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
    let alice = Attendee(name: "Alice Martin", email: "alice@exemple.fr", isMe: false)
    let bob = Attendee(name: "Bob", email: nil, isMe: false)
    let outlook = CalendarEvent(id: "o", title: "Point client", attendees: [alice], start: nine, end: nine.addingTimeInterval(3600),
                                service: "Teams", origin: CalendarOrigin(title: "Calendrier", account: "Outlook", color: .blue))
    let google = CalendarEvent(id: "g", title: "point CLIENT ", attendees: [Attendee(name: "alice", email: "ALICE@exemple.fr", isMe: false), bob],
                               start: nine.addingTimeInterval(20), end: nine.addingTimeInterval(3610), location: "Cabinet",
                               origin: CalendarOrigin(title: "Cabinet", account: "Google", color: .green))
    let other = CalendarEvent(id: "x", title: "Point client", attendees: [], start: nine.addingTimeInterval(1800), end: nine.addingTimeInterval(5400))
    let result = Connectors.merged([outlook, google, other])
    check(result.count == 2, "deux rendez-vous restent (doublon fusionné, homonyme à une autre heure gardé)")
    check(result.first?.id == "g", "le plus riche est gardé (2 invités contre 1)")
    check(result.first?.attendees.count == 2, "Alice n'est comptée qu'une fois (même adresse, casse différente)")
    check(result.first?.service == "Teams", "le service de visio de l'autre agenda est repris")
    check(result.first?.location == "Cabinet", "le lieu est gardé")
    check(result.first?.origin?.account == "Google", "l'agenda d'origine est celui du rendez-vous gardé")
    check(Connectors.merged([outlook, outlook]).count == 1, "deux fois le même rendez-vous → un seul")
    check(Connectors.merged([]).isEmpty, "rien ne donne rien")
    let secret = Connectors.subscriptionURL(from: "  https://calendar.google.com/calendar/ical/vg%40exemple.fr/private-abc/basic.ics\n")
    check(secret?.absoluteString == "webcals://calendar.google.com/calendar/ical/vg%40exemple.fr/private-abc/basic.ics",
          "lien https de Google → webcals, espaces retirés")
    check(Connectors.subscriptionURL(from: "webcal://exemple.fr/feries.ics")?.scheme == "webcal", "lien webcal gardé tel quel")
    check(Connectors.subscriptionURL(from: "http://exemple.fr/agenda.ics")?.scheme == "webcal", "lien http → webcal")
    check(Connectors.subscriptionURL(from: "pas un lien") == nil && Connectors.subscriptionURL(from: "mailto:x@y.fr") == nil
          && Connectors.subscriptionURL(from: "") == nil, "texte, mailto ou vide : refusés")
    let mail = Summarizer.splitSubject("Objet : Monsieur DURAND - Proposition d'accompagnement\n\nCher Monsieur,\n\nÀ la suite de notre entretien…")
    check(mail.subject == "Monsieur DURAND - Proposition d'accompagnement" && mail.body.hasPrefix("Cher Monsieur,"),
          "proposition : l'objet est séparé du corps du mail")
    check(Summarizer.splitSubject("Cher Monsieur,\n\nTexte.").subject == nil, "proposition sans ligne « Objet » : tout est corps")
    check(Connectors.MailApp.preferred == (Connectors.MailApp.outlookInstalled ? .outlook : .system),
          "messagerie par défaut : l'application Outlook si elle est installée")
    print(failures.isEmpty ? "Tout est bon." : "\(failures.count) échec(s).")
    exit(failures.isEmpty ? 0 : 1)
}

// `Murmure --installation [modèle.gguf]` : télécharge le moteur et le modèle s'ils manquent (comme au premier
// lancement), puis lance le serveur et met une phrase en forme. Avec MURMURE_SUPPORT_DIR, dans un dossier vierge.
if (2...3).contains(CommandLine.arguments.count), CommandLine.arguments[1] == "--installation" {
    let model = CommandLine.arguments.count == 3 ? CommandLine.arguments[2] : Settings.localModel
    runBlocking {
        var start = Date()
        let progress = Task { @MainActor in
            while !Task.isCancelled {
                if let summary = LocalLLMInstaller.shared.summary { print("  \(summary)") }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        defer { progress.cancel() }
        try await LocalLLMInstaller.shared.install(model: model)
        print("Installé en \(seconds(since: start)) : \(LocalLLM.serverBinary?.path ?? "moteur introuvable")")
        start = Date()
        try await LocalLLM.shared.start(model: model)
        print("Serveur démarré en \(seconds(since: start))")
        let text = "Il faudrait, il faudrait relancer le greffe de Lille, de Douai pardon, pour la date d'audience."
        print(try await LocalLLM.shared.complete(system: "Corrige cette dictée : retire les répétitions et les autocorrections. Réponds par le texte seul.", user: text, maxTokens: 200))
        LocalLLM.shared.stop()
    }
}

// Un mode de ligne de commande mal orthographié ou incomplet ne doit pas lancer l'interface (hors paquet,
// elle plante sur le centre de notifications) : on le dit et on s'arrête.
if CommandLine.arguments.count > 1, CommandLine.arguments[1].hasPrefix("--") {
    print("Mode inconnu ou arguments manquants : \(CommandLine.arguments.dropFirst().joined(separator: " "))")
    print("Modes : --test f.wav · --meeting f.wav · --import f.m4a · --synthese transcription.txt · --question transcription.txt \"…\" [synthèse.md] · --reprise · --meeting-tracks micro.wav ordinateur.wav · --voix f · --bench-llm · --bench-asr dossier · --bench-real · --bench-flux f… · --bench-relecture dossier · --bench-noms dossier · --noms annuaire.txt texte · --bench-contexte dossier · --contexte s · --test-collage · --record-system s préfixe · --resync · --apercu-synthese f.md préfixe · --apercu-reglages préfixe · --apercu-accueil préfixe · --apercu-fiche préfixe · --apercu-bienvenue préfixe · --test-expiration · --agendas · --test-agenda · --installation [modèle.gguf]")
    exit(2)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

