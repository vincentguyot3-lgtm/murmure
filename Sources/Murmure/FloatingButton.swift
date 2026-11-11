import AppKit
import Combine
import SwiftUI

/// État montré par le bouton flottant : il suit la dictée et la réunion en cours.
final class FloatingButtonModel: ObservableObject {
    enum Mode: Equatable { case idle, dictating, processing, meeting }
    enum Half { case top, bottom }

    @Published var mode: Mode = .idle
    @Published var level: Float = 0
    /// Moitié survolée de la capsule dépliée, ou nil quand le pointeur est ailleurs.
    @Published var hovered: Half?
    @Published var meetingStartedAt: Date?

    /// Ce que la capsule dit en se dépliant en carte, comme l'encoche de Wispr Flow.
    enum Notice: Equatable {
        /// Conversation détectée : « Ignorer » ou « Enregistrer ».
        case proposal(MeetingProposal)
        /// Rendez-vous qui commence dans 2 min : « Rejoindre », « Rejoindre et enregistrer ».
        case upcoming(CalendarEvent)
        /// Rendez-vous restants de la journée, dépliés en laissant le pointeur sur la capsule (qui reste visible).
        case agenda
        /// La réunion vient de démarrer ; `detail` dit laquelle (application, rendez-vous).
        case recording(detail: String)
        /// Réunion en cours où plus personne ne parle depuis `since` : « Continuer » ou « Terminer ».
        case quiet(since: Date)
        /// La réunion est arrêtée et gardée ; l'étape du traitement est lue dans la fiche.
        case saved(UUID)
        /// Traitement terminé : compte rendu (ou transcription) prêt, ou rien d'entendu.
        case ready(UUID)
        case message(String, detail: String? = nil)

        var isProposal: Bool {
            if case .proposal = self { return true }
            return false
        }

        /// Proposition, rappel ou réunion silencieuse : la carte attend une réponse, une simple annonce ne la remplace pas.
        var waitsForAnswer: Bool {
            switch self {
            case .proposal, .upcoming, .quiet: return true
            default: return false
            }
        }
    }
    @Published var notice: Notice?
    /// Vrai quand la capsule est dans la moitié droite de l'écran : la carte se déplie vers la gauche.
    @Published var opensLeft = true
    /// Décalage vertical de la capsule dans la fenêtre dépliée, quand la carte a dû être recadrée dans l'écran.
    @Published var capsuleOffset: CGFloat = 0
}

/// Ce que l'on peut faire depuis la carte dépliée.
enum NoticeAction: Equatable {
    case record, ignore, stop, open(UUID), close
    /// « Continuer » : la réunion où plus personne ne parle reste enregistrée.
    case keepRecording
    /// Ouvre le lien de la visio du rendez-vous ; avec `record`, démarre aussi l'enregistrement de la réunion.
    case join(CalendarEvent, record: Bool)
    /// « À l'heure » : l'enregistrement démarrera seul au début du rendez-vous ; `unschedule` l'annule.
    case schedule(CalendarEvent), unschedule
    /// Rappel écarté sans suite : le rendez-vous ne sera plus proposé à son début.
    case dismissReminder(CalendarEvent)
    case allowCalendar, openApp
}

/// Petite capsule posée au bord de l'écran, toujours présente (comme celle de Wispr Flow).
/// Au repos, un simple trait ; au survol, elle se déplie : en haut le micro (dictée mains libres),
/// en bas la réunion. Glisser pour la déplacer, clic droit pour le menu.
struct FloatingButtonView: View {
    @ObservedObject var model: FloatingButtonModel
    let scale: CGFloat
    var act: (NoticeAction) -> Void = { _ in }

    private var expanded: Bool {
        model.hovered != nil || model.mode == .dictating || model.mode == .processing || model.notice == .agenda
    }
    /// L'agenda se déplie à côté de la capsule, qui reste là avec ses deux boutons ; les annonces la recouvrent.
    private var showsCapsule: Bool { model.notice == nil || model.notice == .agenda }

    var body: some View {
        // La capsule reste à sa place, collée au bord ; la carte en sort vers l'intérieur de l'écran et la recouvre.
        ZStack(alignment: model.opensLeft ? .trailing : .leading) {
            Color.clear
            capsule
                .frame(width: 40 * scale, height: 104 * scale)
                .offset(y: model.capsuleOffset)
                .opacity(showsCapsule ? 1 : 0)
            if let notice = model.notice {
                NoticeCard(notice: notice, scale: scale, act: act)
                    .padding(model.opensLeft ? .trailing : .leading, (notice == .agenda ? 42 : 6) * scale)
                    .transition(noticeTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Pas d'animation implicite sur l'annonce : la fenêtre change de taille au même moment, et la capsule
        // glisserait de son ancienne place à la nouvelle. Seule la carte s'anime (FloatingButton.notify, collapse).
    }

    /// La carte sort de la capsule, côté bord de l'écran : fondu, léger agrandissement et quelques points de
    /// glissement vers l'intérieur. En fondu seul en mode sobre ou sans animations.
    private var noticeTransition: AnyTransition {
        guard Motion.level == .full else { return .opacity }
        let edge: UnitPoint = model.opensLeft ? .trailing : .leading
        let beside = model.notice == .agenda
        return .opacity
            .combined(with: .scale(scale: beside ? 0.94 : 0.85, anchor: edge))
            .combined(with: .offset(x: (model.opensLeft ? 1 : -1) * (beside ? 14 : 10) * scale))
    }

    private var capsule: some View {
        ZStack {
            if expanded {
                VStack(spacing: 4 * scale) {
                    slot(.top) { top }
                    slot(.bottom) { bottom }
                }
                .padding(4 * scale)
                .background(Capsule().fill(Color.black.opacity(0.82)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14)))
                .transition(Motion.level == .full ? .opacity.combined(with: .scale(scale: 0.6)) : .opacity)
            } else {
                Capsule()
                    .fill(Color.black.opacity(model.mode == .meeting ? 0.82 : 0.55))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.3)))
                    .overlay(alignment: .center) {
                        // Pendant une réunion, un point blanc dit que l'enregistrement continue.
                        if model.mode == .meeting { Circle().fill(.white).frame(width: 4 * scale, height: 4 * scale) }
                    }
                    .frame(width: 8 * scale, height: 46 * scale)
                    .transition(.opacity)
            }
        }
        .animation(Motion.quick, value: expanded)
        .animation(Motion.quick, value: model.mode)
    }

    /// Case ronde de la capsule dépliée, éclaircie au survol.
    private func slot<Content: View>(_ half: FloatingButtonModel.Half, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(width: 28 * scale, height: 42 * scale)
            .background(Capsule().fill(Color.white.opacity(model.hovered == half && interactive(half) ? 0.16 : 0)))
            .animation(Motion.quick, value: model.hovered)
    }

    private func interactive(_ half: FloatingButtonModel.Half) -> Bool {
        switch model.mode {
        case .idle: return true
        case .dictating: return true
        case .processing: return false
        case .meeting: return half == .bottom
        }
    }

    @ViewBuilder private var top: some View {
        switch model.mode {
        case .idle:
            glyph("mic.fill")
        case .dictating:
            HStack(spacing: 2 * scale) {
                ForEach(0..<3, id: \.self) { i in
                    let weights: [Float] = [0.6, 1, 0.6]
                    Capsule().fill(.white).frame(width: 3 * scale, height: CGFloat(4 + 16 * model.level * weights[i]) * scale)
                }
            }
            .animation(Motion.meter, value: model.level)
        case .processing:
            Spinner(size: 13 * scale, color: .white, lineWidth: 1.5)
        case .meeting:
            // Durée de la réunion, en minutes : la dictée attend qu'elle se termine.
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let minutes = Int(context.date.timeIntervalSince(model.meetingStartedAt ?? context.date) / 60)
                Text("\(minutes) min")
                    .font(.system(size: 8.5 * scale, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize()
            }
        }
    }

    @ViewBuilder private var bottom: some View {
        switch model.mode {
        case .idle: glyph("record.circle")
        case .dictating: glyph("stop.fill", size: 10)
        case .processing: glyph("record.circle").opacity(0.35)
        case .meeting: glyph("stop.fill", size: 10)
        }
    }

    private func glyph(_ name: String, size: CGFloat = 13) -> some View {
        Image(systemName: name)
            .font(.system(size: size * scale, weight: .semibold))
            .foregroundStyle(.white)
    }
}

/// Carte de la capsule dépliée. La proposition reprend la carte « Appel en cours · Ignorer · Enregistrer » ;
/// les autres annonces tiennent sur une ligne : pictogramme ou anneau, titre, détail et, au besoin, un bouton.
/// Un clic ailleurs sur la carte ouvre la réunion (ou referme un simple message).
struct NoticeCard: View {
    let notice: FloatingButtonModel.Notice
    let scale: CGFloat
    var act: (NoticeAction) -> Void = { _ in }
    /// L'étape du traitement et le statut de la réunion se lisent en direct dans la fiche.
    @ObservedObject private var store = RecordingStore.shared

    var body: some View {
        switch notice {
        case .proposal(let proposal):
            MeetingPromptView(proposal: proposal, onRecord: { act(.record) }, onDismiss: { act(.ignore) })
        case .upcoming(let event):
            UpcomingCard(event: event, scale: scale, act: act)
        case .agenda:
            AgendaCard(scale: scale, act: act)
        case .recording(let detail):
            NoticeLine(scale: scale, title: "Enregistrement en cours", detail: detail,
                       button: "Arrêter", onButton: { act(.stop) }, onTap: { act(.close) }) {
                RecordingDot(size: 9 * scale)
            }
        case .quiet(let since):
            QuietCard(since: since, scale: scale, act: act)
        case .saved(let id):
            let recording = store.recording(id)
            let progress = recording?.progress ?? "Traitement…"
            // Le compte rendu n'est promis que si un modèle de rédaction est prêt pour cette réunion.
            let summarizes = recording.map { Cleaner.isReady(localOnly: store.isLocalOnly($0)) } ?? false
            NoticeLine(scale: scale, title: "Réunion enregistrée", detail: summarizes ? "\(progress) · le compte rendu suivra" : progress,
                       button: "Ouvrir", onButton: { act(.open(id)) }, onTap: { act(.open(id)) }) {
                Spinner(size: 14 * scale, color: .white, lineWidth: 1.5)
            }
        case .ready(let id):
            let outcome = Self.outcome(store.recording(id))
            NoticeLine(scale: scale, title: outcome.title, detail: outcome.detail,
                       button: "Ouvrir", onButton: { act(.open(id)) }, onTap: { act(.open(id)) }) {
                NoticeGlyph(name: outcome.symbol, scale: scale)
            }
        case .message(let text, let detail):
            NoticeLine(scale: scale, title: text, detail: detail, button: nil, onButton: {}, onTap: { act(.close) }) {
                NoticeGlyph(name: "info.circle", scale: scale)
            }
        }
    }

    /// Ce que dit la carte une fois le traitement fini, selon ce que la fiche contient.
    static func outcome(_ recording: Recording?) -> (title: String, detail: String, symbol: String) {
        guard let recording else { return ("Réunion traitée", "Ouvrez Murmure pour la retrouver", "checkmark.circle") }
        switch recording.status {
        case .summarized: return ("Compte rendu prêt", recording.title, "doc.text")
        case .transcribed:
            // Transcrite sans compte rendu : modèle de rédaction absent, ou rédaction en échec.
            return ("Transcription prête", recording.processingError.map { "Compte rendu impossible : \($0)" } ?? recording.title, "checkmark.circle")
        case .empty:
            // « Aucune parole reconnue : micro muet… » : le titre le dit déjà, le détail garde la raison.
            let prefix = "Aucune parole reconnue : "
            var reason = recording.processingError ?? recording.title
            if reason.hasPrefix(prefix) {
                let rest = reason.dropFirst(prefix.count)
                reason = rest.prefix(1).uppercased() + rest.dropFirst()
            }
            return ("Aucune parole reconnue", reason, "exclamationmark.triangle.fill")
        case .processing: return ("Réunion enregistrée", recording.progress ?? "Traitement…", "clock")
        }
    }
}

/// Une ligne d'annonce, blanc sur noir comme la pastille : indicateur, titre et détail, bouton à droite.
private struct NoticeLine<Indicator: View>: View {
    let scale: CGFloat
    let title: String
    let detail: String?
    let button: String?
    let onButton: () -> Void
    let onTap: () -> Void
    @ViewBuilder let indicator: Indicator

    var body: some View {
        HStack(spacing: 12 * scale) {
            indicator
                .frame(width: 30 * scale, height: 30 * scale)
                .background(Circle().fill(Color.white.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2 * scale) {
                Text(title)
                    .font(.system(size: 13 * scale, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5 * scale))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            if let button { PromptButton(title: button, primary: false, action: onButton).fixedSize() }
        }
        .padding(.horizontal, 14 * scale)
        .padding(.vertical, 12 * scale)
        .frame(width: 330 * scale)
        .background(RoundedRectangle(cornerRadius: 16 * scale).fill(Color.black.opacity(0.86)))
        .overlay(RoundedRectangle(cornerRadius: 16 * scale).strokeBorder(Color.white.opacity(0.12)))
        .contentShape(RoundedRectangle(cornerRadius: 16 * scale))
        .onTapGesture(perform: onTap)
    }
}

private struct NoticeGlyph: View {
    let name: String
    let scale: CGFloat

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 13 * scale, weight: .semibold))
            .foregroundStyle(.white)
    }
}

// MARK: - Agenda dans l'encoche

/// Ce que l'encoche dit d'un rendez-vous : « En cours », « Dans 12 min », « À 16:00 ».
enum AgendaWording {
    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    static func when(_ event: CalendarEvent, now: Date) -> String? {
        guard let start = event.start else { return nil }
        if event.isUnderway(at: now) { return "En cours" }
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "Maintenant" }
        if minutes < 60 { return "Dans \(minutes) min" }
        return "À \(time(start))"
    }

    /// Commencé, ou qui commence dans les 10 min : on peut le rejoindre ou l'enregistrer tout de suite.
    static func isImminent(_ event: CalendarEvent, now: Date) -> Bool {
        guard let start = event.start else { return false }
        return event.isUnderway(at: now) || start.timeIntervalSince(now) <= 600
    }

    /// « Jeudi 6 novembre ».
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        let text = formatter.string(from: date)
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// Boutons d'un rendez-vous qui commence : « Rejoindre » s'il a un lien de visio, et « Rejoindre et
/// enregistrer » (ou « Enregistrer ») tant qu'aucune réunion n'est en cours ni programmée pour lui.
private struct EventButtons: View {
    let event: CalendarEvent
    var act: (NoticeAction) -> Void
    @ObservedObject private var app = AppState.shared

    private var recordable: Bool { app.meetingStartedAt == nil && app.scheduledMeeting?.id != event.id }

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if app.scheduledMeeting?.id == event.id {
                Text("Enregistrement programmé")
                    .font(.system(size: 11 * Settings.uiScale))
                    .foregroundStyle(.white.opacity(0.6))
            }
            if event.joinURL != nil {
                PromptButton(title: "Rejoindre", primary: !recordable) { act(.join(event, record: false)) }.fixedSize()
            }
            if recordable {
                PromptButton(title: event.joinURL != nil ? "Rejoindre et enregistrer" : "Enregistrer", primary: true) {
                    act(.join(event, record: true))
                }
                .fixedSize()
            }
        }
    }
}

/// Rappel deux minutes avant un rendez-vous, déplié de lui-même depuis la capsule.
struct UpcomingCard: View {
    let event: CalendarEvent
    let scale: CGFloat
    var act: (NoticeAction) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * scale) {
            HStack(alignment: .top, spacing: 10 * scale) {
                NoticeGlyph(name: "calendar", scale: scale)
                    .frame(width: 30 * scale, height: 30 * scale)
                    .background(Circle().fill(Color.white.opacity(0.14)))
                VStack(alignment: .leading, spacing: 3 * scale) {
                    Text(event.title)
                        .font(.system(size: 13 * scale, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        Text([AgendaWording.when(event, now: context.date), event.detail.isEmpty ? nil : event.detail]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 11.5 * scale))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                GlyphButton(name: "xmark", scale: scale) { act(.dismissReminder(event)) }
            }
            EventButtons(event: event, act: act)
        }
        .padding(14 * scale)
        .frame(width: 330 * scale)
        .background(RoundedRectangle(cornerRadius: 16 * scale).fill(Color.black.opacity(0.86)))
        .overlay(RoundedRectangle(cornerRadius: 16 * scale).strokeBorder(Color.white.opacity(0.12)))
    }
}

/// Réunion en cours où plus personne ne parle : la capsule propose de la terminer. La durée du silence avance
/// d'elle-même ; la carte se replie seule si l'on reparle (`AppDelegate.meetingWentQuiet`).
struct QuietCard: View {
    let since: Date
    let scale: CGFloat
    var act: (NoticeAction) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * scale) {
            HStack(alignment: .top, spacing: 10 * scale) {
                NoticeGlyph(name: "waveform.slash", scale: scale)
                    .frame(width: 30 * scale, height: 30 * scale)
                    .background(Circle().fill(Color.white.opacity(0.14)))
                VStack(alignment: .leading, spacing: 3 * scale) {
                    Text("Plus personne ne parle")
                        .font(.system(size: 13 * scale, weight: .semibold))
                        .foregroundStyle(.white)
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        let minutes = max(1, Int(context.date.timeIntervalSince(since) / 60))
                        Text("Depuis \(minutes) min · terminer la réunion ?")
                            .font(.system(size: 11.5 * scale))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8 * scale) {
                Spacer(minLength: 0)
                PromptButton(title: "Continuer", primary: false) { act(.keepRecording) }
                PromptButton(title: "Terminer", primary: true) { act(.stop) }
            }
        }
        .padding(14 * scale)
        .frame(width: 330 * scale)
        .background(RoundedRectangle(cornerRadius: 16 * scale).fill(Color.black.opacity(0.86)))
        .overlay(RoundedRectangle(cornerRadius: 16 * scale).strokeBorder(Color.white.opacity(0.12)))
    }
}

/// Rendez-vous restants de la journée, dépliés à côté de la capsule quand on y laisse le pointeur.
struct AgendaCard: View {
    let scale: CGFloat
    var act: (NoticeAction) -> Void = { _ in }
    @ObservedObject private var agenda = Agenda.shared

    /// Au-delà, « et 2 autres » : la carte reste courte.
    private static let shown = 4

    var body: some View {
        let remaining = agenda.remaining
        VStack(alignment: .leading, spacing: 10 * scale) {
            HStack(alignment: .center, spacing: 10 * scale) {
                VStack(alignment: .leading, spacing: 2 * scale) {
                    Text(AgendaWording.day(agenda.now))
                        .font(.system(size: 13 * scale, weight: .semibold))
                        .foregroundStyle(.white)
                    if !remaining.isEmpty {
                        Text("\(remaining.count) rendez-vous restant\(remaining.count > 1 ? "s" : "")")
                            .font(.system(size: 11.5 * scale))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                Spacer(minLength: 0)
                GlyphButton(name: "macwindow", scale: scale) { act(.openApp) }
            }
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            if agenda.sample == nil, !Connectors.calendarAuthorized {
                HStack(spacing: 10 * scale) {
                    Text("Autorisez l'accès à l'agenda pour voir vos rendez-vous ici.")
                        .font(.system(size: 11.5 * scale))
                        .foregroundStyle(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    PromptButton(title: "Autoriser", primary: false) { act(.allowCalendar) }.fixedSize()
                }
            } else if remaining.isEmpty {
                Text(agenda.today.isEmpty ? "Aucun rendez-vous aujourd'hui." : "Plus de rendez-vous aujourd'hui.")
                    .font(.system(size: 11.5 * scale))
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                ForEach(remaining.prefix(Self.shown)) { event in
                    AgendaRow(event: event, now: agenda.now, scale: scale, act: act)
                }
                if remaining.count > Self.shown {
                    Text("et \(remaining.count - Self.shown) autre\(remaining.count - Self.shown > 1 ? "s" : "") · voir dans Murmure")
                        .font(.system(size: 11 * scale))
                        .foregroundStyle(.white.opacity(0.55))
                        .contentShape(Rectangle())
                        .onTapGesture { act(.openApp) }
                }
            }
        }
        .padding(14 * scale)
        .frame(width: 330 * scale)
        .background(RoundedRectangle(cornerRadius: 16 * scale).fill(Color.black.opacity(0.86)))
        .overlay(RoundedRectangle(cornerRadius: 16 * scale).strokeBorder(Color.white.opacity(0.12)))
    }
}

/// Une ligne de l'agenda : couleur de l'agenda d'origine, heure, titre et détail. Un rendez-vous qui commence
/// porte ses boutons ; les suivants proposent « À l'heure » au survol (ou disent qu'ils sont programmés).
private struct AgendaRow: View {
    let event: CalendarEvent
    let now: Date
    let scale: CGFloat
    var act: (NoticeAction) -> Void
    @ObservedObject private var app = AppState.shared
    @State private var hovered = false

    private var imminent: Bool { AgendaWording.isImminent(event, now: now) }
    private var scheduled: Bool { app.scheduledMeeting?.id == event.id }

    private var detail: String {
        var parts: [String] = []
        if imminent, let when = AgendaWording.when(event, now: now) { parts.append(when) }
        if !event.detail.isEmpty { parts.append(event.detail) }
        if parts.isEmpty, let end = event.end { parts.append("Jusqu'à \(AgendaWording.time(end))") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 6 * scale) {
            HStack(spacing: 10 * scale) {
                Capsule()
                    .fill(event.origin?.color ?? Color.white.opacity(0.5))
                    .frame(width: 3 * scale, height: 28 * scale)
                Text(event.start.map(AgendaWording.time) ?? "")
                    .font(.system(size: 12 * scale, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 40 * scale, alignment: .leading)
                VStack(alignment: .leading, spacing: 1 * scale) {
                    Text(event.title)
                        .font(.system(size: 12.5 * scale, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11 * scale))
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !imminent {
                    if scheduled {
                        PromptButton(title: hovered ? "Annuler" : "Programmé", primary: false) { act(.unschedule) }.fixedSize()
                    } else if hovered, app.meetingStartedAt == nil {
                        PromptButton(title: "À l'heure", primary: false) { act(.schedule(event)) }.fixedSize()
                    }
                }
            }
            if imminent { EventButtons(event: event, act: act) }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(Motion.quick, value: hovered)
    }
}

/// Petit bouton rond à pictogramme (fermer, ouvrir Murmure), éclairci au survol.
private struct GlyphButton: View {
    let name: String
    let scale: CGFloat
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 11 * scale, weight: .semibold))
            .foregroundStyle(.white.opacity(hovered ? 1 : 0.7))
            .frame(width: 26 * scale, height: 26 * scale)
            .background(Circle().fill(Color.white.opacity(hovered ? 0.16 : 0.08)))
            .contentShape(Circle())
            .onHover { hovered = $0 }
            .onTapGesture(perform: action)
            .animation(Motion.quick, value: hovered)
    }
}

/// Point blanc de l'enregistrement : il pulse en mode Fluides, fixe en mode sobre, sans animations et dans les aperçus.
private struct RecordingDot: View {
    let size: CGFloat
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(.white)
            .frame(width: size, height: size)
            .opacity(dim ? 0.3 : 1)
            .onAppear {
                guard Motion.blinks, !StaticPreview.active else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

/// Surface du bouton : elle reçoit tous les gestes (survol, clic, glisser, clic droit), même quand Murmure
/// n'est pas l'application active, et sans jamais lui donner le focus : la dictée se colle là où l'on était.
private final class FloatingSurface: NSView {
    var onHover: (FloatingButtonModel.Half?) -> Void = { _ in }
    var onClick: (FloatingButtonModel.Half) -> Void = { _ in }
    var onMenu: (NSPoint) -> Void = { _ in }
    var onMoved: () -> Void = {}
    /// Pointeur entré dans la fenêtre (vrai) ou sorti (faux) : l'agenda déplié se replie quand on s'en va.
    var onInside: (Bool) -> Void = { _ in }
    /// Carte dépliée : les clics vont à ses boutons (vue SwiftUI), plus à la capsule.
    var passesThrough = false
    /// Place de la capsule quand elle reste visible à côté de la carte (agenda) : ses clics lui reviennent.
    var capsuleZone: NSRect?
    private var pressedInZone = false

    private var pressAt: NSPoint?
    private var originAtPress: NSPoint?
    private var dragging = false
    var isDragging: Bool { dragging }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        if passesThrough, let zone = capsuleZone, zone.contains(convert(point, from: superview)) { return self }
        return passesThrough ? super.hitTest(point) : self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private func half(_ event: NSEvent) -> FloatingButtonModel.Half {
        convert(event.locationInWindow, from: nil).y > (capsuleZone ?? bounds).midY ? .top : .bottom
    }

    private func inZone(_ event: NSEvent) -> Bool {
        capsuleZone?.contains(convert(event.locationInWindow, from: nil)) ?? false
    }

    /// Moitié survolée ; agenda déplié, seulement quand le pointeur est sur la capsule.
    private func hoveredHalf(_ event: NSEvent) -> FloatingButtonModel.Half? {
        capsuleZone == nil || inZone(event) ? half(event) : nil
    }

    override func mouseEntered(with event: NSEvent) {
        onInside(true)
        onHover(hoveredHalf(event))
    }
    override func mouseMoved(with event: NSEvent) { if !dragging { onHover(hoveredHalf(event)) } }
    override func mouseExited(with event: NSEvent) {
        onInside(false)
        if !dragging { onHover(nil) }
    }

    // Carte dépliée : un clic hors de ses boutons remonte de la vue SwiftUI jusqu'ici. Il ne doit ni lancer
    // une dictée ou une réunion, ni déplacer la fenêtre dépliée : il est ignoré.
    override func mouseDown(with event: NSEvent) {
        dragging = false
        // Agenda déplié : la capsule visible à côté reste cliquable, mais ne se déplace pas.
        pressedInZone = passesThrough && inZone(event)
        guard !passesThrough else { pressAt = nil; originAtPress = nil; return }
        pressAt = NSEvent.mouseLocation
        originAtPress = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard !passesThrough, let pressAt, let originAtPress, let window else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - pressAt.x, dy = mouse.y - pressAt.y
        if !dragging, hypot(dx, dy) < 4 { return }
        dragging = true
        window.setFrameOrigin(NSPoint(x: originAtPress.x + dx, y: originAtPress.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressAt = nil; originAtPress = nil; pressedInZone = false }
        if passesThrough, pressedInZone, inZone(event) { onClick(half(event)); return }
        guard !passesThrough, pressAt != nil else { dragging = false; return }
        if dragging {
            dragging = false
            onMoved()
            let inside = bounds.contains(convert(event.locationInWindow, from: nil))
            onHover(inside ? half(event) : nil)
        } else {
            onClick(half(event))
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard !passesThrough || inZone(event) else { return }
        onMenu(NSEvent.mouseLocation)
    }
}

/// Fenêtre du bouton flottant : affichée selon le réglage, à la place où on l'a laissée.
final class FloatingButton {
    let model = FloatingButtonModel()
    var onDictate: () -> Void = {}
    var onMeeting: () -> Void = {}
    var onOpen: () -> Void = {}
    /// Message bref, dans la pastille de dictée.
    var onMessage: (String) -> Void = { _ in }
    /// Bouton ou clic dans la carte dépliée (la carte est déjà repliée, sauf pour une proposition).
    var onNotice: (NoticeAction) -> Void = { _ in }
    /// Proposition encore en attente de réponse (celle de MeetingPrompt), à redéplier après une dictée.
    var pendingProposal: () -> MeetingProposal? = { nil }
    /// Le bouton vient d'être masqué : une proposition en attente doit passer à la carte en haut à droite.
    var onHidden: () -> Void = {}

    private var panel: NSPanel?
    private var surface: FloatingSurface?
    private var scale: CGFloat = 1
    private var observers: [NSObjectProtocol] = []
    /// Place de la capsule repliée ; la fenêtre dépliée en part, et y revient.
    private var compactFrame: NSRect?
    private var noticeWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    /// Pointeur posé sur la capsule : l'agenda se déplie s'il y reste.
    private var dwellWork: DispatchWorkItem?
    /// Pointeur sorti de l'agenda déplié : il se replie s'il ne revient pas.
    private var leaveWork: DispatchWorkItem?
    /// Annonce arrivée pendant un glissé de la capsule : montrée quand on la lâche, si elle vaut encore.
    private var deferredNotice: (notice: FloatingButtonModel.Notice, seconds: Double?)?
    private var subscriptions = Set<AnyCancellable>()
    /// Traitements des réunions arrêtées, suivis chacun jusqu'au compte rendu (deux peuvent tourner à la fois).
    private var processingWatches: [UUID: AnyCancellable] = [:]
    /// Réunions dont la fin du traitement a été annoncée dans la capsule (la bannière de macOS s'efface alors).
    private var announced = Set<UUID>()

    /// Vrai quand la capsule est à l'écran : les annonces s'y déplient (sinon, carte ou pastille à la place).
    var isShown: Bool { panel != nil }

    init() {
        // Une dictée qui commence reprend la capsule : la carte se replie pour laisser voir le vumètre. Quand elle
        // se termine, une proposition encore en attente se redéplie (le détecteur ne la refera pas).
        model.$mode
            .removeDuplicates()
            .sink { [weak self] mode in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch mode {
                    case .dictating, .processing:
                        self.collapse()
                    case .idle, .meeting:
                        self.restorePendingProposal()
                    }
                }
            }
            .store(in: &subscriptions)
        // Le réglage peut changer depuis les Réglages, la barre des menus ou le menu du bouton lui-même.
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        })
        // Écran débranché ou résolution changée : le bouton revient dans la partie visible.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.place()
        })
    }

    /// Affiche ou retire le bouton selon le réglage ; reconstruit la fenêtre si la taille de l'interface a changé.
    func refresh() {
        guard Settings.floatingButton else {
            guard let panel else { return }
            panel.orderOut(nil)
            self.panel = nil
            surface = nil
            // Une annonce en suspens ne doit pas resurgir quand le bouton sera réaffiché, et la capsule doit
            // revenir droite, à sa place.
            noticeWork?.cancel()
            collapseWork?.cancel()
            dwellWork?.cancel()
            dwellWork = nil
            leaveWork?.cancel()
            deferredNotice = nil
            processingWatches.removeAll()
            model.notice = nil
            model.hovered = nil
            model.capsuleOffset = 0
            onHidden()
            return
        }
        let wanted = CGFloat(Settings.uiScale)
        if panel != nil, wanted == scale { return }
        panel?.orderOut(nil)
        scale = wanted
        panel = makePanel()
        place()
        panel?.orderFrontRegardless()
    }

    // MARK: Annonces

    /// Déplie la capsule en carte. `seconds` : repli automatique ; nil, la carte reste jusqu'à ce qu'on la retire.
    func notify(_ notice: FloatingButtonModel.Notice, seconds: Double?) {
        guard panel != nil else { return }
        // Pendant un glissé, la fenêtre suit le pointeur : l'annonce attend qu'on lâche la capsule.
        if surface?.isDragging == true {
            if deferredNotice?.notice.isProposal == true, !notice.isProposal { return }
            deferredNotice = (notice, seconds)
            return
        }
        // Une proposition ou un rappel reste déplié tant qu'on n'y a pas répondu : une autre annonce ne le remplace
        // pas (la notification de macOS dit quand même qu'un compte rendu est prêt), et un rappel ne remplace pas
        // une proposition. L'agenda ouvert par l'utilisateur ne cède qu'à une proposition ou à un rappel.
        if let current = model.notice {
            if current.isProposal, !notice.isProposal { return }
            if current.waitsForAnswer || current == .agenda, !notice.waitsForAnswer { return }
        }
        noticeWork?.cancel()
        collapseWork?.cancel()
        leaveWork?.cancel()
        dwellWork?.cancel()
        dwellWork = nil
        // L'agenda laisse la capsule visible : le survol de ses deux boutons continue.
        if notice != .agenda { model.hovered = nil }
        expand(for: notice)
        withAnimation(Motion.unfold) { model.notice = notice }
        if case .ready(let id) = notice { announced.insert(id) }
        guard let seconds else { return }
        let work = DispatchWorkItem { [weak self] in self?.collapse(only: notice) }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Replie la carte ; avec `only`, seulement si elle montre encore cette annonce (une plus récente a pu la remplacer).
    func collapse(only notice: FloatingButtonModel.Notice? = nil) {
        // Une annonce retirée avant d'avoir pu s'afficher (glissé en cours) ne s'affichera plus.
        if notice == nil || deferredNotice?.notice == notice { deferredNotice = nil }
        guard let current = model.notice, notice == nil || notice == current else { return }
        noticeWork?.cancel()
        withAnimation(Motion.unfold) { model.notice = nil }
        // La fenêtre reprend la taille de la capsule une fois la carte effacée. D'ici là, les clics restent à la
        // carte qui s'efface, sans effet : le second clic d'un double-clic ne doit pas lancer une dictée ou
        // arrêter une réunion.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.notice == nil, let compact = self.compactFrame else { return }
            // La capsule revient au centre de la petite fenêtre au même instant où la fenêtre rétrécit : à l'écran,
            // elle ne bouge pas.
            self.resizePanel(to: compact) { self.model.capsuleOffset = 0 }
            self.surface?.passesThrough = false
            self.surface?.capsuleZone = nil
            self.restorePendingProposal()
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.seconds(0.45, reduced: 0.15), execute: work)
    }

    /// Réunion qui vient d'être arrêtée : « Réunion enregistrée » tout de suite, puis « Compte rendu prêt »
    /// (ou « Transcription prête », ou « Aucune parole reconnue ») quand son traitement se termine.
    func follow(_ id: UUID) {
        notify(.saved(id), seconds: 6)
        processingWatches[id] = RecordingStore.shared.$recordings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] recordings in
                guard let self else { return }
                guard let recording = recordings.first(where: { $0.id == id }) else {
                    // Réunion supprimée entre-temps.
                    self.processingWatches[id] = nil
                    self.collapse(only: .saved(id))
                    return
                }
                guard recording.progress == nil else { return }
                self.processingWatches[id] = nil
                guard self.announcesReady else { return }
                self.notify(.ready(id), seconds: 8)
            }
    }

    /// Vrai quand la fin d'un traitement peut s'annoncer dans la capsule : à l'écran, sans dictée en cours
    /// (la capsule reste au vumètre) ni proposition dépliée (elle garde la place).
    private var announcesReady: Bool {
        guard panel != nil, model.mode == .idle || model.mode == .meeting else { return false }
        if case .proposal = model.notice { return false }
        return true
    }

    /// Capsule repliée, hors dictée : une proposition encore sans réponse (que le détecteur ne refera pas) se
    /// redéplie. Appelé à la fin de chaque repli et à la fin d'une dictée.
    private func restorePendingProposal() {
        guard model.notice == nil, deferredNotice == nil, model.mode == .idle || model.mode == .meeting,
              let proposal = pendingProposal() else { return }
        notify(.proposal(proposal), seconds: nil)
    }

    /// Vrai si la capsule a annoncé la fin du traitement de cette réunion : la bannière de macOS ferait doublon.
    func hasAnnounced(_ id: UUID) -> Bool { announced.contains(id) }

    /// Annonce gardée pendant un glissé : montrée une fois la capsule posée (après son court glissement vers le bord).
    private func showDeferred() {
        guard surface?.isDragging != true, let deferred = deferredNotice else { return }
        deferredNotice = nil
        notify(deferred.notice, seconds: deferred.seconds)
    }

    private func handle(_ action: NoticeAction) {
        switch action {
        case .record, .ignore: break // la proposition se retire d'elle-même (MeetingPrompt)
        default: collapse()
        }
        onNotice(action)
    }

    /// Vrai si la capsule montre le rappel de ce rendez-vous : la proposition à son début ferait doublon.
    func showsReminder(for eventID: String) -> Bool {
        if case .upcoming(let event) = model.notice { return event.id == eventID }
        return false
    }

    // MARK: Agenda

    /// Rendez-vous restants de la journée, dépliés à côté de la capsule.
    func showAgenda() {
        guard panel != nil, model.mode == .idle || model.mode == .meeting else { return }
        Agenda.shared.refresh()
        notify(.agenda, seconds: nil)
        // Ouvert depuis le menu, le pointeur peut ne jamais y entrer : l'agenda se replie seul.
        scheduleLeave(after: 5)
    }

    /// Pointeur posé sur la capsule sans cliquer : l'agenda se déplie à côté au bout de 0,7 s.
    private func scheduleAgenda(hovering: Bool) {
        guard hovering else { dwellWork?.cancel(); dwellWork = nil; return }
        guard dwellWork == nil, model.mode == .idle || model.mode == .meeting else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.dwellWork = nil
            guard self.model.hovered != nil, self.model.notice == nil, self.surface?.isDragging != true,
                  NSEvent.pressedMouseButtons == 0 else { return }
            self.showAgenda()
        }
        dwellWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    /// Agenda déplié : il se replie quand le pointeur en sort, sauf s'il y revient dans la demi-seconde.
    private func pointer(inside: Bool) {
        leaveWork?.cancel()
        guard !inside, model.notice == .agenda else { return }
        scheduleLeave(after: 0.5)
    }

    private func scheduleLeave(after seconds: Double) {
        leaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            // Le pointeur est revenu (ou n'est jamais sorti : un agrandissement de la fenêtre peut faire croire à une sortie).
            guard let self, let panel = self.panel, !panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.collapse(only: .agenda)
        }
        leaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Agrandit la fenêtre à la taille de la carte, vers l'intérieur de l'écran, centrée sur la capsule
    /// (recadrée dans l'écran si la capsule est tout en haut ou tout en bas). La capsule ne bouge pas.
    private func expand(for notice: FloatingButtonModel.Notice) {
        guard panel != nil, let compact = compactFrame else { return }
        let card = NSHostingView(rootView: NoticeCard(notice: notice, scale: scale)).fittingSize
        let center = NSPoint(x: compact.midX, y: compact.midY)
        let visible = (NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main)?.visibleFrame ?? compact
        let opensLeft = compact.midX > visible.midX
        // L'agenda se déplie à côté de la capsule, qui reste visible ; les annonces la recouvrent.
        let beside = notice == .agenda
        let width = max(card.width + (beside ? 42 : 6) * scale, compact.width)
        let height = max(card.height, compact.height)
        let y = min(max(compact.midY - height / 2, visible.minY), visible.maxY - height)
        let frame = NSRect(x: opensLeft ? compact.maxX - width : compact.minX, y: y, width: width, height: height)
        // En SwiftUI, l'axe vertical descend : la capsule remonte quand la fenêtre a été recadrée vers le bas.
        resizePanel(to: frame) {
            model.opensLeft = opensLeft
            model.capsuleOffset = frame.midY - compact.midY
        }
        surface?.passesThrough = true
        surface?.capsuleZone = beside
            ? NSRect(x: opensLeft ? width - compact.width : 0, y: compact.minY - frame.minY, width: compact.width, height: compact.height)
            : nil
    }

    /// Change la taille de la fenêtre et la place de la capsule dedans d'un seul coup, sans animation, et les fait
    /// dessiner ensemble : la capsule reste immobile à l'écran pendant que la carte s'anime à côté.
    private func resizePanel(to frame: NSRect, _ layout: () -> Void) {
        guard let panel else { return }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still, layout)
        panel.setFrame(frame, display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
    }

    private func makePanel() -> NSPanel {
        let size = NSSize(width: 40 * scale, height: 104 * scale)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false // c'est la surface qui le déplace, pour distinguer le clic du glissé

        let surface = FloatingSurface(frame: NSRect(origin: .zero, size: size))
        // Vue qui accepte le premier clic : les boutons de la carte répondent sans activer Murmure.
        let host = FirstClickHostingView(rootView: FloatingButtonView(model: model, scale: scale) { [weak self] action in
            self?.handle(action)
        })
        host.frame = surface.bounds
        host.autoresizingMask = [.width, .height]
        surface.addSubview(host)
        // Carte dépliée, ou en train de s'effacer : le survol ne déplie pas la capsule (sauf à côté de l'agenda).
        surface.onHover = { [weak self, weak surface] half in
            guard let self else { return }
            if self.model.notice == .agenda {
                self.model.hovered = half
                return
            }
            guard self.model.notice == nil, surface?.passesThrough == false else { return }
            self.model.hovered = half
            self.scheduleAgenda(hovering: half != nil)
        }
        surface.onInside = { [weak self] inside in self?.pointer(inside: inside) }
        surface.onClick = { [weak self] half in self?.click(half) }
        surface.onMenu = { [weak self] point in self?.showMenu(at: point) }
        surface.onMoved = { [weak self] in
            self?.savePosition()
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.seconds(0.2)) { self?.showDeferred() }
        }
        panel.contentView = surface
        self.surface = surface
        return panel
    }

    private func click(_ half: FloatingButtonModel.Half) {
        dwellWork?.cancel()
        dwellWork = nil
        // Un clic sur la capsule à côté de l'agenda : l'agenda se replie, la dictée ou la réunion démarre.
        if model.notice == .agenda { collapse() }
        switch (model.mode, half) {
        case (.idle, .top), (.dictating, _): onDictate()
        case (.idle, .bottom), (.meeting, .bottom): onMeeting()
        case (.meeting, .top): onMessage("Réunion en cours : la dictée reprendra après l'arrêt")
        case (.processing, _): break
        }
    }

    private func showMenu(at point: NSPoint) {
        let dictating = model.mode == .dictating
        let meeting = model.mode == .meeting
        var entries: [MenuEntry] = []
        if !meeting {
            entries.append(.action(dictating ? "Terminer la dictée" : "Dicter", dictating ? "stop.fill" : "mic.fill") { [weak self] in self?.onDictate() })
        }
        if !dictating {
            entries.append(.action(meeting ? "Arrêter la réunion" : "Nouvelle réunion", meeting ? "stop.fill" : "record.circle") { [weak self] in self?.onMeeting() })
        }
        if !dictating {
            entries.append(.action("Agenda du jour", "calendar") { [weak self] in self?.showAgenda() })
        }
        entries += [
            .divider,
            .action("Ouvrir Murmure", "macwindow") { [weak self] in self?.onOpen() },
            .action("Remettre au bord droit", "arrow.right.to.line") { [weak self] in self?.resetPosition() },
            .action("Masquer le bouton", "eye.slash") { [weak self] in
                Settings.floatingButton = false
                self?.onMessage("Bouton masqué · réaffichez-le depuis la barre des menus ou les Réglages")
            },
        ]
        FloatingMenu.shared.show(entries, at: point)
    }

    // MARK: Position

    /// La position est gardée par rapport à l'écran (fractions de sa partie visible), pour survivre
    /// à un changement de résolution ou au passage d'un écran externe à l'écran du Mac.
    private func place() {
        guard let panel else { return }
        let size = NSSize(width: 40 * scale, height: 104 * scale)
        let saved = UserDefaults.standard.string(forKey: "floatingButtonScreen")
        let screen = NSScreen.screens.first { $0.localizedName == saved } ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let defaults = UserDefaults.standard
        let fx = defaults.object(forKey: "floatingButtonX") as? Double ?? 1
        let fy = defaults.object(forKey: "floatingButtonY") as? Double ?? 0.45
        let x = visible.minX + (visible.width - size.width) * fx
        let y = visible.minY + (visible.height - size.height) * fy
        let compact = NSRect(origin: NSPoint(x: x, y: y), size: size)
        compactFrame = compact
        // Carte dépliée (écran changé, taille de l'interface modifiée) : elle se redéplie depuis la nouvelle place.
        if let notice = model.notice { expand(for: notice) } else { panel.setFrame(compact, display: true) }
    }

    /// Après un glissé : le bouton reste dans l'écran où on l'a lâché, et colle au bord s'il en est tout près.
    private func savePosition() {
        guard let panel else { return }
        let frame = panel.frame
        let center = NSPoint(x: frame.midX, y: frame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let room = NSSize(width: max(visible.width - frame.width, 1), height: max(visible.height - frame.height, 1))
        var fx = min(max((frame.minX - visible.minX) / room.width, 0), 1)
        let fy = min(max((frame.minY - visible.minY) / room.height, 0), 1)
        // À moins de 30 points d'un bord, le bouton s'y range.
        if (frame.minX - visible.minX) < 30 { fx = 0 }
        if (visible.maxX - frame.maxX) < 30 { fx = 1 }
        let defaults = UserDefaults.standard
        defaults.set(Double(fx), forKey: "floatingButtonX")
        defaults.set(Double(fy), forKey: "floatingButtonY")
        defaults.set(screen.localizedName, forKey: "floatingButtonScreen")
        let origin = NSPoint(x: visible.minX + room.width * fx, y: visible.minY + room.height * fy)
        compactFrame = NSRect(origin: origin, size: frame.size)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.seconds(0.18)
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrameOrigin(origin)
        }
    }

    func resetPosition() {
        let defaults = UserDefaults.standard
        ["floatingButtonX", "floatingButtonY", "floatingButtonScreen"].forEach(defaults.removeObject)
        place()
    }
}
