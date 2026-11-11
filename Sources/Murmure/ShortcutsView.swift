import SwiftUI

/// Lexique (entrée du panneau gauche) : tout ce qu'on apprend à Murmure, réuni sur une page.
/// - un bandeau qui présente les raccourcis (refermable) ;
/// - un champ unique « Ajouter un mot » : « Baligaux » devient un mot du vocabulaire, « GBI → Kbis » une correction ;
/// - Vos raccourcis : une phrase dite seule, remplacée par un texte enregistré ; à la suite, les passages revenus
///   trois fois dans les dictées, proposés comme raccourcis (voir `RecurringPassages`) ;
/// - Corrections : saisies à la main ou retenues de vos retouches (voir `CorrectionWatcher`), avec leur usage ;
/// - Votre vocabulaire : les mots rares qui aident Whisper à entendre juste.
/// La recherche de la page filtre les trois listes.
struct ShortcutsView: View {
    /// Recherche de l'accueil, déjà appliquée (avec son anti-rebond).
    var query = ""
    /// Faux pour l'aperçu en ligne de commande des listes, sous le bandeau.
    var showsIntro = true
    @ObservedObject private var lexicon = Lexicon.shared
    @AppStorage("shortcutsIntroHidden") private var introHidden = false
    @State private var entry = ""
    @FocusState private var focus: Field?

    enum Field: Hashable {
        case entry, trigger(UUID), text(UUID), from(UUID), to(UUID)

        var ruleID: UUID? {
            switch self {
            case .trigger(let id), .text(let id), .from(let id), .to(let id): return id
            case .entry: return nil
            }
        }
    }

    private var folded: String { foldedForSearch(query.trimmingCharacters(in: .whitespaces)) }

    private func shown(_ rules: [Replacement]) -> [Replacement] {
        guard !folded.isEmpty else { return rules }
        return rules.filter { foldedForSearch($0.from + " " + $0.to).contains(folded) }
    }

    private var shownTerms: [String] {
        guard !folded.isEmpty else { return lexicon.terms }
        return lexicon.terms.filter { foldedForSearch($0).contains(folded) }
    }

    private var shownSuggestions: [String] {
        guard !folded.isEmpty else { return lexicon.suggestions }
        return lexicon.suggestions.filter { foldedForSearch($0).contains(folded) }
    }

    /// Les corrections retenues de vos retouches d'abord, les plus utiles en tête ; puis celles saisies à la main.
    private var corrections: [Replacement] {
        let learned = lexicon.replacements.filter { $0.learned == true }.sorted { ($0.uses ?? 0) > ($1.uses ?? 0) }
        return shown(learned + lexicon.replacements.filter { $0.learned != true })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            if showsIntro, !introHidden, folded.isEmpty {
                intro.transition(.opacity)
            }
            addField
            snippetsSection
            correctionsSection
            vocabularySection
        }
        .animation(Motion.quick, value: introHidden)
        // Une ligne laissée entièrement vide disparaît quand on la quitte.
        .onChange(of: focus) { old, new in
            guard let left = old?.ruleID, left != new?.ruleID else { return }
            func empty(_ rule: Replacement) -> Bool {
                rule.id == left && rule.from.trimmingCharacters(in: .whitespaces).isEmpty && rule.to.trimmingCharacters(in: .whitespaces).isEmpty
            }
            withAnimation(Motion.quick) {
                lexicon.snippets.removeAll(where: empty)
                lexicon.replacements.removeAll(where: empty)
            }
        }
    }

    // MARK: Bandeau

    /// Exemples du bandeau : vos premiers raccourcis, ou des formules du métier tant qu'il n'y en a pas.
    private var examples: [(String, String)] {
        let own = lexicon.snippets.filter { !$0.from.isEmpty && !$0.to.isEmpty }.prefix(3).map { ($0.from, $0.to) }
        if !own.isEmpty { return Array(own) }
        return [
            ("formule confraternelle", "Je vous prie de croire, Cher Confrère, en l'assurance de mes sentiments dévoués."),
            ("demande de pièces", "Je vous remercie de bien vouloir me communiquer les pièces suivantes…"),
            ("pièces jointes", "Vous trouverez ci-joint les pièces annoncées, dont je vous souhaite bonne réception."),
        ]
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Ce que vous n'avez plus à écrire.")
                .font(.titre(24))
                .tracking(-0.2)
            Text("Quelques mots dits, et le texte entier prend sa place : une formule, une adresse, une signature.")
                .font(.ui(13))
                .foregroundStyle(Theme.muted)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(examples, id: \.0) { trigger, text in
                    HStack(spacing: 10) {
                        Text("« \(trigger) »")
                            .italic()
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.bg))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line))
                        Image(systemName: "arrow.right").font(.ui(10)).foregroundStyle(Theme.muted)
                        Text(text.replacingOccurrences(of: "\n", with: " "))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.bg))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line))
                    }
                    .font(.ui(12))
                }
            }
            .padding(.top, 18)
            Button("Créer un raccourci") { addSnippet() }
                .buttonStyle(OutlineButtonStyle())
                .keyboardFocusRing()
                .padding(.top, 20)
        }
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.soft))
        .overlay(alignment: .topTrailing) {
            Button { introHidden = true } label: {
                Image(systemName: "xmark")
                    .font(.ui(10, weight: .bold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.muted)
            .keyboardFocusRing(radius: 5, inset: -2)
            .help("Masquer cette présentation")
            .padding(12)
        }
    }

    // MARK: Ajouter un mot

    /// « GBI → Kbis » (ou « GBI -> Kbis ») : une correction ; sinon un mot du vocabulaire.
    private var addField: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").font(.ui(11)).foregroundStyle(Theme.muted)
            if StaticPreview.active {
                Text("Ajouter un mot, ou une correction : GBI → Kbis").foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("Ajouter un mot, ou une correction : GBI → Kbis", text: $entry)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .entry)
                    .onSubmit(addEntry)
            }
            if !entry.isEmpty {
                Text("Entrée").font(.ui(11)).foregroundStyle(Theme.muted)
            }
        }
        .font(.ui(13))
        .padding(.horizontal, 12)
        .frame(height: 36 * Settings.uiScale)
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(focus == .entry ? Theme.fg : Theme.line))
    }

    private func addEntry() {
        let text = entry.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let parts = text.replacingOccurrences(of: "->", with: "→").components(separatedBy: "→")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
            let known = lexicon.replacements.contains { $0.from.caseInsensitiveCompare(parts[0]) == .orderedSame && $0.to == parts[1] }
            if !known {
                withAnimation(Motion.quick) { lexicon.replacements.append(Replacement(from: parts[0], to: parts[1])) }
            }
            Toasts.shared.show("« \(parts[0]) » deviendra « \(parts[1]) »")
        } else if parts.count == 1 {
            if !lexicon.terms.contains(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) {
                withAnimation(Motion.quick) { lexicon.terms.append(text) }
            }
            Toasts.shared.show("« \(text) » rejoint votre vocabulaire")
        } else {
            return
        }
        entry = ""
    }

    // MARK: Vos raccourcis

    private var snippetsSection: some View {
        let snippets = shown(lexicon.snippets)
        return ShortcutSection(title: "Vos raccourcis", count: lexicon.snippets.count,
                       footer: "Dites la phrase seule, Murmure colle le texte enregistré, tel quel, sur plusieurs lignes si besoin. Une phrase qui ne fait que contenir ces mots n'est pas touchée.") {
            ForEach(snippets) { snippet in
                if let binding = binding(for: snippet.id, in: \.snippets) { snippetRow(binding) }
            }
            ForEach(shownSuggestions, id: \.self) { passage in
                suggestionRow(passage)
            }
            if folded.isEmpty {
                AddRow(title: "Créer un raccourci") { addSnippet() }
            } else if snippets.isEmpty, shownSuggestions.isEmpty {
                EmptyRow(text: "Aucun raccourci ne correspond.")
            }
        }
        .animation(Motion.quick, value: lexicon.snippets.map(\.id))
        .animation(Motion.quick, value: lexicon.suggestions)
    }

    private func addSnippet(text: String = "") {
        let snippet = Replacement(from: "", to: text)
        withAnimation(Motion.quick) { lexicon.snippets.append(snippet) }
        DispatchQueue.main.async { focus = .trigger(snippet.id) }
    }

    private func snippetRow(_ snippet: Binding<Replacement>) -> some View {
        let id = snippet.wrappedValue.id
        let active = focus?.ruleID == id
        return Row(active: active) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                field("Phrase à dire", snippet.from, .trigger(id))
                    .frame(width: 190 * Settings.uiScale, alignment: .leading)
                Image(systemName: "arrow.right").font(.ui(10)).foregroundStyle(Theme.muted)
                field("Texte collé", snippet.to, .text(id), vertical: true, expanded: active)
                RemoveButton(help: "Supprimer ce raccourci") {
                    withAnimation(Motion.quick) { lexicon.snippets.removeAll { $0.id == id } }
                }
            }
        }
    }

    /// Passage revenu trois fois : proposé, jamais créé sans vous.
    private func suggestionRow(_ passage: String) -> some View {
        Row(active: false) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("« \(passage) »")
                        .italic()
                        .lineLimit(2)
                        .truncationMode(.tail)
                    Text("Revenu \(RecurringPassages.threshold) fois dans vos dictées")
                        .font(.ui(11))
                        .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 8)
                Button("En faire un raccourci") {
                    withAnimation(Motion.quick) { lexicon.suggestions.removeAll { $0 == passage } }
                    addSnippet(text: passage)
                }
                .buttonStyle(OutlineButtonStyle())
                .keyboardFocusRing()
                RemoveButton(help: "Ne plus le proposer") {
                    withAnimation(Motion.quick) { RecurringPassages.dismiss(passage) }
                }
            }
        }
    }

    // MARK: Corrections

    private var correctionsSection: some View {
        let rules = corrections
        return ShortcutSection(title: "Corrections", count: lexicon.replacements.count,
                       footer: "Murmure retient aussi les noms et les expressions que vous rectifiez après une dictée, et les écrit juste les fois suivantes. Défaire deux fois une correction suffit à la lui faire oublier.") {
            ForEach(rules) { rule in
                if let binding = binding(for: rule.id, in: \.replacements) { correctionRow(binding) }
            }
            if rules.isEmpty {
                EmptyRow(text: folded.isEmpty ? "Aucune correction pour l'instant." : "Aucune correction ne correspond.")
            }
            if folded.isEmpty {
                AddRow(title: "Ajouter une correction") {
                    let rule = Replacement(from: "", to: "")
                    withAnimation(Motion.quick) { lexicon.replacements.append(rule) }
                    DispatchQueue.main.async { focus = .from(rule.id) }
                }
            }
        }
        .animation(Motion.quick, value: lexicon.replacements.map(\.id))
    }

    /// « retenue le 2 novembre · 12 fois » : d'où vient la correction, et combien de fois elle a servi.
    private func usage(_ rule: Replacement) -> String? {
        var parts: [String] = []
        if rule.learned == true {
            if let date = rule.learnedAt {
                parts.append("retenue le \(date.formatted(.dateTime.day().month(.wide)))")
            } else {
                parts.append("retenue")
            }
        }
        if let uses = rule.uses, uses > 0 { parts.append(uses == 1 ? "1 fois" : "\(uses) fois") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func correctionRow(_ rule: Binding<Replacement>) -> some View {
        let id = rule.wrappedValue.id
        let learned = rule.wrappedValue.learned == true
        return Row(active: focus?.ruleID == id) {
            HStack(spacing: 10) {
                field("Entendu", rule.from, .from(id))
                    .frame(width: 190 * Settings.uiScale, alignment: .leading)
                Image(systemName: "arrow.right").font(.ui(10)).foregroundStyle(Theme.muted)
                field("Écrit", rule.to, .to(id))
                if let usage = usage(rule.wrappedValue) {
                    Text(usage)
                        .font(.ui(11))
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .help(learned ? "Retenue de l'une de vos retouches, et appliquée depuis à chaque dictée." : "Nombre de dictées où elle a servi.")
                }
                RemoveButton(help: learned ? "Oublier cette correction" : "Supprimer cette correction") {
                    withAnimation(Motion.quick) { lexicon.replacements.removeAll { $0.id == id } }
                }
            }
        }
    }

    // MARK: Vocabulaire

    private var vocabularySection: some View {
        let terms = shownTerms
        return ShortcutSection(title: "Votre vocabulaire", count: lexicon.terms.count,
                       footer: "Un mot du vocabulaire aide Murmure à l'entendre juste, dans n'importe quelle phrase, sans rien remplacer. Un raccourci, lui, remplace une phrase dite seule par le texte enregistré.") {
            if terms.isEmpty {
                EmptyRow(text: folded.isEmpty ? "Ajoutez un nom rare par le champ ci-dessus." : "Aucun mot ne correspond.")
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(terms, id: \.self) { term in
                        TermChip(term: term) {
                            withAnimation(Motion.quick) { lexicon.terms.removeAll { $0 == term } }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(Motion.quick, value: lexicon.terms)
    }

    // MARK: Outils

    /// Champ d'une ligne ; dans l'aperçu en ligne de commande, son texte (`ImageRenderer` ne dessine pas les champs).
    @ViewBuilder
    private func field(_ placeholder: String, _ text: Binding<String>, _ field: Field,
                       vertical: Bool = false, expanded: Bool = false) -> some View {
        if StaticPreview.active {
            Text(text.wrappedValue.isEmpty ? placeholder : text.wrappedValue.replacingOccurrences(of: "\n", with: " "))
                .foregroundStyle(text.wrappedValue.isEmpty ? Theme.muted : Theme.fg)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if vertical {
            TextField(placeholder, text: text, axis: .vertical)
                .textFieldStyle(.plain)
                .focused($focus, equals: field)
                .lineLimit(expanded ? 1...8 : 1...1)
        } else {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .focused($focus, equals: field)
        }
    }

    /// Binding par identifiant, jamais par indice : une ligne supprimée pendant que son champ a le focus ferait
    /// planter un binding `$tableau[i]` (indice hors limites) ; celui-ci renvoie une valeur vide.
    private func binding(for id: UUID, in list: ReferenceWritableKeyPath<Lexicon, [Replacement]>) -> Binding<Replacement>? {
        let lexicon = self.lexicon
        guard lexicon[keyPath: list].contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { lexicon[keyPath: list].first { $0.id == id } ?? Replacement(from: "", to: "") },
            set: { new in
                if let index = lexicon[keyPath: list].firstIndex(where: { $0.id == id }) { lexicon[keyPath: list][index] = new }
            }
        )
    }
}

// MARK: - Éléments

/// Titre et nombre, cadre arrondi des lignes, note en dessous : la même tenue que les sections des Réglages,
/// avec un titre un peu plus présent puisqu'il ouvre une partie de l'accueil.
private struct ShortcutSection<Content: View>: View {
    let title: String
    let count: Int
    let footer: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(title).font(.ui(13, weight: .medium))
                if count > 0 {
                    Text("\(count)").font(.ui(12)).monospacedDigit().foregroundStyle(Theme.muted)
                        .contentTransition(.numericText())
                }
            }
            VStack(spacing: 0) { content }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
            Text(footer)
                .font(.ui(11))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Ligne d'une liste : la ligne en cours d'édition se détache sur un fond doux.
private struct Row<Content: View>: View {
    let active: Bool
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.ui(13))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(active ? Theme.soft : Color.clear)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            .transition(.opacity)
    }
}

private struct AddRow: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "plus")
                .font(.ui(12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.muted)
        .keyboardFocusRing(radius: 6, inset: 2)
    }
}

private struct EmptyRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.ui(12))
            .foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

/// Croix de suppression : petite à l'œil, mais une cible de 20 pt.
private struct RemoveButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.ui(10, weight: .bold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.muted)
        .keyboardFocusRing(radius: 4, inset: -2)
        .help(help)
    }
}

/// Mot du vocabulaire en étiquette au trait ; la croix n'apparaît qu'au survol.
private struct TermChip: View {
    let term: String
    let remove: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 4) {
            Text(term).font(.ui(12))
            Button(action: remove) {
                Image(systemName: "xmark").font(.ui(8, weight: .bold))
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.muted)
            .opacity(hover ? 1 : 0)
            .help("Retirer « \(term) » du vocabulaire")
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .overlay(Capsule().strokeBorder(Theme.line))
        .onHover { hover = $0 }
    }
}
