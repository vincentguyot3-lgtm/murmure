import AppKit
import Foundation

/// Essais du contexte du curseur, en ligne de commande.
/// - `Murmure --contexte 5` : lit le champ actif de l'application au premier plan après 5 s.
/// - `Murmure --test-collage` : vérifie l'accord du texte collé et la correction des noms sur des cas types.
/// - `Murmure --bench-contexte dossier` : triplets nom.aiff / nom.txt / nom.ctx (texte avant le curseur),
///   et facultativement nom.ecran (titre de la fenêtre puis textes visibles, une ligne chacun) ;
///   compare la transcription sans contexte, avec les termes du champ, puis avec la fin du texte en amorce.
enum BenchContext {
    static func capture(after delay: Double) async {
        print("Placez le curseur dans un champ de texte : lecture dans \(Int(delay)) s…")
        try? await Task.sleep(for: .seconds(delay))
        guard let app = NSWorkspace.shared.frontmostApplication else { return print("Aucune application active") }
        FieldContext.prepare(app)
        let start = Date()
        guard let context = await FieldContext.capture(app) else {
            return print("\(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?")) : aucun champ lisible")
        }
        print("\(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?")) · lu en \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        print("fenêtre : « \(context.windowTitle) » · \(context.screen.count) textes visibles\(context.fieldRead ? "" : " · champ illisible")")
        print("avant : \(context.before.count) car. · sélection : \(context.selected.count) · après : \(context.after.count)")
        print("… \(context.before.suffix(160))▮\(context.selected)▮\(context.after.prefix(160)) …")
        print("termes : \(context.terms.joined(separator: ", "))")
        print("amorce : \(context.promptTail(characters: 400))")
        print("collage de « Il a été convenu. » : «\(context.fit("Il a été convenu.", properNouns: []))»")
    }

    @MainActor
    static func selfTest() {
        func field(_ before: String, _ after: String = "", app: String? = nil) -> FieldContext {
            FieldContext(bundleID: app, before: before, selected: "", after: after)
        }
        let fits: [(FieldContext, String, String)] = [
            (field(""), "Bonjour Madame.", "Bonjour Madame."),
            (field("Je vous confirme que"), "La société a payé.", " la société a payé."),
            (field("Je vous confirme que "), "La société a payé.", "la société a payé."),
            (field("Fin de phrase. "), "Nouvelle phrase.", "Nouvelle phrase."),
            (field("Fin de phrase."), "Nouvelle phrase.", " Nouvelle phrase."),
            (field("Nous avons écrit à", " pour lui demander"), "Maître Durand.", " Maître Durand"),
            (field("selon l'article", ", le bail"), "L145-41 du Code de commerce.", " L145-41 du Code de commerce"),
            (field("le dossier ", " est clos"), "La SCI Kervoalen.", "la SCI Kervoalen"),
            (field("la société ", "reste"), "Kervoalen Invest.", "Kervoalen Invest "),
            (field("", "", app: "net.whatsapp.WhatsApp"), "Je te rappelle demain.", "Je te rappelle demain"),
            (field("", "", app: "net.whatsapp.WhatsApp"), "Tu es libre demain ?", "Tu es libre demain ?"),
            (field("Bonjour. ", "", app: "com.tinyspeck.slackmacgap"), "Je te rappelle demain.", "Je te rappelle demain."),
            (field("Il a dit «"), "Je refuse.", "\u{00A0}Je refuse."),
            (field("", "", app: "com.apple.mail"), "Cher Confrère, je reviens vers vous.", "Cher Confrère,\n\nJe reviens vers vous."),
            (field("Cher Confrère,\n\n", "", app: "com.apple.mail"), "Madame Durand, que je représente, conteste.", "Madame Durand, que je représente, conteste."),
        ]
        var failures = 0
        for (context, input, expected) in fits {
            let output = context.fit(input, properNouns: ["Kervoalen"])
            let ok = output == expected
            if !ok { failures += 1 }
            print("\(ok ? "ok " : "ÉCHEC") collage «\(context.lineBefore)▮\(context.lineAfter)» + «\(input)» → «\(output)»\(ok ? "" : " (attendu «\(expected)»)")")
        }
        let terms = ["Lefebvre", "Baligaux", "Kervoalen", "Durand", "Martine", "Laurence", "URSSAF"]
        let corrections: [(String, String)] = [
            ("J'ai écrit à Maître Lefèvre hier.", "J'ai écrit à Maître Lefebvre hier."),
            ("Maître Baligo plaidera.", "Maître Baligaux plaidera."),
            ("La société Kervoa Len conteste.", "La société Kervoalen conteste."),
            ("Monsieur Durant a signé.", "Monsieur Durand a signé."),
            ("Il a travaillé durant trois ans.", "Il a travaillé durant trois ans."),
            ("Martin est absent.", "Martin est absent."),
            ("Laurent viendra.", "Laurent viendra."),
            ("Le redressement de l'urssaf.", "Le redressement de l'URSSAF."),
            ("La mer est calme.", "La mer est calme."),
        ]
        for (input, expected) in corrections {
            let output = Cleaner.applyContextTerms(input, terms: terms)
            let ok = output == expected
            if !ok { failures += 1 }
            print("\(ok ? "ok " : "ÉCHEC") noms «\(input)» → «\(output)»\(ok ? "" : " (attendu «\(expected)»)")")
        }
        let notable = field("Le Tribunal a statué. Maître Varna représente la société NOVIP Services contre Monsieur Ozet. Nous contestons.").terms
        print("termes repérés : \(notable.joined(separator: ", "))")
        var window = FieldContext(bundleID: nil, before: "", selected: "", after: "", fieldRead: false)
        window.windowTitle = "AXO E-CAR - Réclamation contentieuse - Kerdraon Fabrications.docx"
        window.screen = ["Fichier", "Accueil", "Objet : dossier Morvan contre Breizh Logistique", "Breizh Logistique", "De : Maître Le Floc'h"]
        let screenTerms = window.terms
        for expected in ["AXO", "E-CAR", "Kerdraon", "Fabrications", "Morvan", "Breizh", "Logistique"] where !screenTerms.contains(expected) {
            failures += 1
            print("ÉCHEC terme d'écran manquant : \(expected)")
        }
        for unexpected in ["Réclamation", "Fichier", "Accueil", "Objet"] where screenTerms.contains(unexpected) {
            failures += 1
            print("ÉCHEC terme d'écran en trop : \(unexpected)")
        }
        print("termes de l'écran : \(screenTerms.joined(separator: ", "))")
        if window.fit("Bonjour.", properNouns: []) != "Bonjour." { failures += 1; print("ÉCHEC collage accordé sans champ lu") }
        let learned: [(String, String, [String])] = [
            ("J'ai écrit à Maître Lefèvre hier matin.", "Bonjour. J'ai écrit à Maître Lefebvre hier matin. Suite", ["Lefèvre→Lefebvre (nom)"]),
            ("La société Kervoa Len conteste le congé.", "La société Kervoalen conteste le congé.", ["Kervoa Len→Kervoalen (nom)"]),
            ("Rendez-vous vendredi à dix heures.", "Rendez-vous lundi à dix heures.", []),
            ("Il faut relancer le greffe demain.", "Merci de bien vouloir nous transmettre les pièces.", []),
            ("Le redressement de l'urssaf est contesté.", "Le redressement de l'URSSAF est contesté.", []),
            // Majuscule de début de phrase : pas un nom, donc jamais appris d'emblée.
            ("Bonjour. Il faut relancer le greffe.", "Bonjour. Ils faut relancer le greffe.", ["Il→Ils"]),
            ("Nous demandons le kébis de la société.", "Nous demandons le Kbis de la société.", ["kébis→Kbis"]),
            // Expressions : plusieurs mots remplacés par plusieurs mots.
            ("Le cabinet de Jean Pierre Durant a écrit.", "Le cabinet de Jean-Pierre Durand a écrit.", ["Jean Pierre Durant→Jean-Pierre Durand (nom)"]),
            ("Rendez-vous chez Trezzodelacq demain.", "Rendez-vous chez Trezzo Delacq demain.", ["Trezzodelacq→Trezzo Delacq (nom)"]),
            ("Il faut relancer le greffe demain.", "Il faut appeler la cour demain.", []),
        ]
        for (pasted, now, expected) in learned {
            let output = CorrectionWatcher.corrections(pasted: pasted, now: now).map(\.description)
            let ok = output == expected
            if !ok { failures += 1 }
            print("\(ok ? "ok " : "ÉCHEC") apprentissage «\(pasted)» → «\(now)» : \(output)\(ok ? "" : " (attendu \(expected))")")
        }
        let enters: [(String, String, Bool)] = [
            ("Peux-tu relire ce paragraphe ? Appuie sur entrée.", "Peux-tu relire ce paragraphe ?", true),
            ("Je te rappelle demain, appuie sur Entrée", "Je te rappelle demain", true),
            ("D'accord pour demain. Entrée.", "D'accord pour demain.", true),
            ("Entrée.", "", true),
            ("Rendez-vous devant l'entrée.", "Rendez-vous devant l'entrée.", false),
            ("Il a réservé une entrée.", "Il a réservé une entrée.", false),
            ("La date d'entrée dans les lieux.", "La date d'entrée dans les lieux.", false),
        ]
        for (input, expected, enter) in enters {
            let output = Cleaner.takeEnterCommand(input)
            let ok = output.text == expected && output.pressReturn == enter
            if !ok { failures += 1 }
            print("\(ok ? "ok " : "ÉCHEC") entrée «\(input)» → «\(output.text)»\(output.pressReturn ? " + Entrée" : "")\(ok ? "" : " (attendu «\(expected)»\(enter ? " + Entrée" : ""))")")
        }
        let joins: [(String, String, String)] = [
            ("Nous contestons ce congé.", "qui n'est pas motivé.", "Nous contestons ce congé qui n'est pas motivé."),
            ("Nous contestons ce congé.", "Le bail est renouvelé.", "Nous contestons ce congé. Le bail est renouvelé."),
            ("Et puis...", "voilà.", "Et puis... voilà."),
        ]
        for (first, second, expected) in joins {
            let output = ProgressiveDictation.join(first, second)
            if output != expected { failures += 1 }
            print("\(output == expected ? "ok " : "ÉCHEC") jonction «\(first)» + «\(second)» → «\(output)»")
        }
        print(failures == 0 ? "Tous les cas passent." : "\(failures) échec(s).")
    }

    static func run(directory: String) async throws {
        let dir = URL(fileURLWithPath: directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory)
            .filter { $0.hasSuffix(".ctx") }.map { String($0.dropLast(4)) }.sorted()
        let transcriber = Transcriber()
        try await transcriber.load()
        print("Plafond d'amorce : \(Transcriber.maxPromptTokens) jetons (MURMURE_PROMPT_TOKENS)")
        let configs = ["sans contexte", "termes", "termes + fin", "termes + fin + noms"]
        var totals = [String: (errors: Int, words: Int, names: Int, found: Int, time: Double)]()
        for name in names {
            let reference = try String(contentsOf: dir.appendingPathComponent(name + ".txt"), encoding: .utf8)
            let before = try String(contentsOf: dir.appendingPathComponent(name + ".ctx"), encoding: .utf8)
            let audio = try loadAudio(dir.appendingPathComponent(name + ".aiff").path)
            var context = FieldContext(bundleID: nil, before: before, selected: "", after: "")
            // Facultatif : nom.ecran, première ligne = titre de la fenêtre, suivantes = textes visibles.
            if let screen = try? String(contentsOf: dir.appendingPathComponent(name + ".ecran"), encoding: .utf8) {
                let lines = screen.components(separatedBy: .newlines).filter { !$0.isEmpty }
                context.windowTitle = lines.first ?? ""
                context.screen = Array(lines.dropFirst())
            }
            let terms = context.terms
            // Noms du contexte que la phrase dictée contient : ceux qu'il faut retrouver à l'identique.
            let expected = terms.filter { reference.contains($0) }
            print("\n— \(name) (\(String(format: "%.1f", Double(audio.count) / 16_000)) s) · noms attendus : \(expected.joined(separator: ", "))")
            _ = try await transcriber.transcribe(audio) // chauffe
            for config in configs {
                let hint: Transcriber.Hint
                switch config {
                case "sans contexte": hint = Transcriber.Hint()
                case "termes": hint = Transcriber.Hint(terms: terms)
                default: hint = Transcriber.Hint(terms: terms, tail: context.promptTail(characters: 400))
                }
                let start = Date()
                var text = try await transcriber.transcribe(audio, hint: hint)
                if config.hasSuffix("noms") {
                    let raw = text
                    text = await MainActor.run { Cleaner.applyContextTerms(raw, terms: terms) }
                }
                let time = Date().timeIntervalSince(start)
                let (errors, count) = BenchASR.wordErrors(reference: reference, hypothesis: text)
                let found = expected.filter { text.contains($0) }.count
                var total = totals[config] ?? (0, 0, 0, 0, 0)
                total.errors += errors; total.words += count; total.names += expected.count; total.found += found; total.time += time
                totals[config] = total
                print(String(format: "  %-22@ %5.1f %% · noms %d/%d · %.2f s · %@", config as NSString,
                             100 * Double(errors) / Double(max(count, 1)), found, expected.count, time, text))
            }
        }
        print("\n##### Total")
        for config in configs {
            guard let t = totals[config] else { continue }
            print(String(format: "  %-22@ %5.1f %% de mots faux · noms %d/%d · %.2f s en tout", config as NSString,
                         100 * Double(t.errors) / Double(max(t.words, 1)), t.found, t.names, t.time))
        }
    }
}
