import SwiftUI

/// Page « En direct » : ce qui est en train d'être dit pendant une réunion, à quelques secondes près, en bulles comme
/// la transcription de la fiche, dans la colonne commune ; sans noms, puisque les voix ne sont distinguées qu'à l'arrêt.
/// À droite, hors de la colonne, les notes de la réunion.
struct LiveView: View {
    /// Faux pour l'aperçu en ligne de commande, où un `ScrollView` resterait vide.
    var scrolls = true
    @ObservedObject private var state = AppState.shared
    /// Le défilement suit la fin du texte ; remonter le suspend, la flèche ↓ le reprend.
    @State private var follows = true
    /// Première bulle affichée, figée tant que l'utilisateur relit plus haut : la fenêtre glissante ne retire pas de
    /// bulle au-dessus de sa lecture (le passage lu sauterait vers le haut à chaque coupe). Nil quand le suivi est actif.
    @State private var heldFirst: Int?
    @State private var cache = LiveCache()

    private var isEmpty: Bool { state.liveText.isEmpty && state.livePending.isEmpty }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    Text("Réunion en cours")
                        .font(.titre(30))
                        .tracking(-0.3)
                    Spacer(minLength: 12)
                    MeetingButton().padding(.top, 4)
                }
                .padding(.top, 48)
                .colonne()

                LiveBar(words: wordCount, text: fullText)
                    .padding(.top, 22)
                    .colonne()

                transcript
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Rectangle().fill(Theme.line).frame(width: 1)
            NotesColumn(text: $state.liveNotes)
                .frame(width: 300)
        }
    }

    private var fullText: String {
        [state.liveText, state.livePending].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private var wordCount: Int {
        fullText.split(whereSeparator: { $0.isWhitespace }).count
    }

    @ViewBuilder private var transcript: some View {
        let layout = cache.layout(state.liveText)
        if isEmpty {
            Text("À l'écoute… le texte apparaît après quelques secondes de parole.")
                .font(.ui(13))
                .foregroundStyle(Theme.muted)
                .padding(.top, 20)
                .colonne()
        } else if !scrolls {
            bubbles(layout).padding(.top, 16).colonne()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        bubbles(layout).padding(.vertical, 16).colonne()
                        Color.clear.frame(height: 1).id("fin")
                    }
                }
                // Remonter suspend le suivi ; revenir tout en bas le reprend. Le décalage baisse aussi quand la bulle la
                // plus ancienne sort de la fenêtre, mais on est alors toujours en bas : le suivi n'est pas coupé.
                .onScrollGeometryChange(for: LiveScroll.self) { geometry in
                    LiveScroll(offset: geometry.contentOffset.y,
                               atEnd: geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 24)
                } action: { old, new in
                    if new.atEnd { follows = true } else if new.offset < old.offset - 4 { follows = false }
                }
                .onChange(of: state.liveText) { _, _ in
                    if follows { proxy.scrollTo("fin", anchor: .bottom) }
                }
                .onChange(of: follows) { _, following in
                    heldFirst = following ? nil : cache.layout(state.liveText).first
                }
                .onChange(of: state.livePending) { _, _ in
                    if follows { withAnimation(Motion.quick) { proxy.scrollTo("fin", anchor: .bottom) } }
                }
                .overlay(alignment: .bottom) {
                    if !follows {
                        HStack {
                            Spacer()
                            Button {
                                follows = true
                                withAnimation(Motion.quick) { proxy.scrollTo("fin", anchor: .bottom) }
                            } label: {
                                Image(systemName: "arrow.down")
                                    .font(.ui(12, weight: .medium))
                                    .foregroundStyle(Theme.fg)
                                    .frame(width: 28, height: 28)
                                    .background(Circle().fill(Theme.bg))
                                    .overlay(Circle().strokeBorder(Theme.line))
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .keyboardFocusRing(radius: 14)
                            .help("Revenir au direct")
                        }
                        .colonne()
                        .padding(.bottom, 16)
                        .transition(.opacity)
                    }
                }
                .animation(Motion.quick, value: follows)
            }
        }
    }

    /// Bulles du texte figé ; la fin encore provisoire s'écrit en gris dans la dernière.
    private func bubbles(_ layout: LiveLayout) -> some View {
        let pending = state.livePending
        let first = heldFirst.map { min($0, layout.first) } ?? layout.first
        let shown = Array(layout.bubbles.enumerated().dropFirst(first))
        return LazyVStack(alignment: .leading, spacing: 8) {
            if first > 0 {
                Text("Le début de la réunion n'est plus affiché ici : il sera dans la fiche à l'arrêt.")
                    .font(.ui(11))
                    .foregroundStyle(Theme.muted)
                    .padding(.bottom, 4)
            }
            ForEach(shown, id: \.offset) { index, text in
                let last = index == layout.bubbles.count - 1
                bubble(text, pending: last ? pending : "")
            }
            if layout.bubbles.isEmpty, !pending.isEmpty {
                bubble("", pending: pending)
            }
        }
    }

    private func bubble(_ text: String, pending: String) -> some View {
        let separator = text.isEmpty || pending.isEmpty ? "" : " "
        return Text("\(Text(text))\(Text(separator + pending).foregroundStyle(Theme.muted))").bulle()
            .previewSafeRightClick {
                // Comme dans la fiche : le clic droit est intercepté, « Copier la sélection » remplace celui du texte.
                [.action("Copier la sélection", "text.cursor") { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) },
                 .action("Copier ce passage", "doc.on.doc") { copy(text + separator + pending) }]
            }
    }
}

/// Position du défilement de la page En direct : décalage, et si l'on est tout en bas.
private struct LiveScroll: Equatable {
    let offset: CGFloat
    let atEnd: Bool
}

/// Bandeau du direct, aux mesures de celui de la transcription : point d'accent qui pulse, « EN DIRECT · 312 MOTS »,
/// l'explication en infobulle, et Copier.
private struct LiveBar: View {
    let words: Int
    let text: String
    @ObservedObject private var state = AppState.shared
    @State private var copied = false
    @State private var dim = false

    var body: some View {
        HStack(spacing: 2) {
            Circle()
                .fill(Theme.accent)
                .frame(width: 6, height: 6)
                // La phase basse reste repérable, en sombre comme en clair.
                .opacity(dim ? 0.6 : 1)
                .padding(.trailing, 6)
                .onAppear {
                    // Pulsation seulement en mode Fluides ; fixe en mode sobre ou sans animations (et dans les aperçus).
                    guard Motion.blinks, !StaticPreview.active else { return }
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
                }
            Text("En direct · \(words.formatted()) mot\(words > 1 ? "s" : "")".uppercased())
                .font(.ui(11, weight: .medium))
                .tracking(0.6)
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
            Spacer(minLength: 8)
            BarIconLabel(symbol: "info.circle")
                .help("Aperçu sans distinction des voix : la transcription par interlocuteur et le compte rendu sont calculés quand vous arrêtez.")
            // Transcription ou rédaction en ligne : un clic garde cette réunion sur ce Mac (son et texte).
            if OnlineTranscription.isChosen || Cleaner.chosen == .claude {
                BarIcon(symbol: state.meetingKeepLocal ? "lock.fill" : "lock.open",
                        help: state.meetingKeepLocal
                            ? "Cette réunion restera sur ce Mac : ni le son ni le texte ne partiront en ligne. Cliquer pour annuler."
                            : "Garder cette réunion sur ce Mac : ni le son ni le texte ne partiront en ligne.") {
                    state.meetingKeepLocal.toggle()
                }
            }
            BarIcon(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copier le texte en direct") {
                copy(text)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            .disabled(text.isEmpty)
        }
        .frame(height: 34)
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.soft))
        .overlay { if Theme.highContrast { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line) } }
    }
}

/// Découpage du texte en direct en bulles, sur des limites qui ne bougent plus une fois posées. Le texte figé ne fait
/// que s'allonger ; une bulle se ferme à la première fin de phrase passé `target` signes (ou à une espace passé
/// `hardLimit`, pour un long passage sans ponctuation), décision qui ne dépend que des deux signes suivants : seule la
/// dernière bulle grandit ou se coupe, les autres ne changent plus. Au-delà de `window` signes, les bulles les plus
/// anciennes sortent entières de l'affichage (la fiche garde tout à l'arrêt).
struct LiveLayout {
    static let target = 400
    static let hardLimit = 900
    static let window = 8_000

    var bubbles: [String] = []
    /// Rang de la première bulle affichée.
    var first = 0

    init() {}

    init(_ text: String) {
        let characters = Array(text)
        var current = ""
        var length = 0
        func close() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { bubbles.append(trimmed) }
            current = ""
            length = 0
        }
        for (index, character) in characters.enumerated() {
            current.append(character)
            length += 1
            if length >= Self.target, ".?!…".contains(character), index + 2 < characters.count, characters[index + 1].isWhitespace {
                let next = characters[index + 2]
                // « M. Dupont », « J.-P. » : une initiale suivie d'un point ne termine pas la phrase.
                let word = current.split(separator: " ").last ?? ""
                let initial = character == "." && word.count <= 2 && word.first?.isUppercase == true
                if (next.isUppercase || next == "«" || next == "\"") && !initial { close(); continue }
            }
            if length >= Self.hardLimit, character.isWhitespace { close() }
        }
        close()
        // Fenêtre : on retire des bulles entières tant que le reste dépasse la limite (la dernière reste toujours).
        var total = bubbles.reduce(0) { $0 + $1.count }
        while total > Self.window, first < bubbles.count - 1 {
            total -= bubbles[first].count
            first += 1
        }
    }
}

/// Découpage gardé tant que le texte figé ne change pas (le corps est réévalué à chaque fin provisoire).
private final class LiveCache {
    private var text: String?
    private var cached = LiveLayout()

    func layout(_ text: String) -> LiveLayout {
        if text != self.text {
            self.text = text
            cached = LiveLayout(text)
        }
        return cached
    }
}

/// Notes libres pendant la réunion, comme sur un bloc : gardées dans la fiche et reprises en priorité
/// dans le compte rendu (ce que dit le texte d'invite).
struct NotesColumn: View {
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Vos notes")
                .font(.ui(13, weight: .medium))
                .padding(.leading, 5) // la marge intérieure de l'éditeur : libellé et texte sur le même bord
            NotesEditor(text: $text, placeholder: "Vos notes, gardées dans la fiche et reprises en priorité dans le compte rendu : points importants, questions, engagements pris…")
        }
        .padding(.horizontal, 20)
        .padding(.top, 52)
        .padding(.bottom, 24)
    }
}

/// Zone de texte sans cadre, avec texte d'invite quand elle est vide. `delta` et `spacing` : taille de lecture
/// et interligne (la fiche l'affiche comme une page, un cran au-dessus de la page En direct).
struct NotesEditor: View {
    @Binding var text: String
    let placeholder: String
    var delta: Double = 0
    var spacing: CGFloat = 4

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .readingFont(delta: delta)
                    .lineSpacing(spacing)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
            if StaticPreview.active {
                // `ImageRenderer` ne dessine pas les vues AppKit (éditeur de texte).
                Text(text)
                    .readingFont(delta: delta)
                    .lineSpacing(spacing)
                    .padding(.top, 1)
                    .padding(.leading, 5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                TextEditor(text: $text)
                    .readingFont(delta: delta)
                    .lineSpacing(spacing)
                    .scrollContentBackground(.hidden)
            }
        }
    }
}
