import AppKit
import EventKit
import SwiftUI

/// Connecteurs vers l'agenda et la messagerie. Murmure ne se connecte à aucun service en ligne :
/// il lit l'agenda de macOS, où l'on ajoute autant de comptes qu'on veut (Outlook / Microsoft Exchange,
/// Google, iCloud dans Réglages Système › Comptes Internet, abonnements par lien dans Calendrier), et
/// ouvre l'application de messagerie choisie, où un brouillon est préparé sans jamais être envoyé.
enum Connectors {
    // MARK: Agenda

    static let eventStore = EKEventStore()

    static var calendarAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// Demande l'accès à l'agenda (une fois ; ensuite, Réglages Système › Confidentialité › Calendriers).
    static func requestCalendar(_ done: @escaping (Bool) -> Void) {
        eventStore.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async { done(granted) }
        }
    }

    /// Demande à macOS de resynchroniser les comptes (bouton « Actualiser », ouverture de la sous-page Agenda).
    static func refreshSources() {
        guard calendarAuthorized else { return }
        eventStore.refreshSourcesIfNecessary()
    }

    /// Un agenda du Mac (« Calendrier » d'Outlook, « Perso » de Google…) et s'il est pris en compte.
    struct CalendarInfo: Identifiable, Hashable {
        let id: String
        let title: String
        let color: Color
        let included: Bool
    }

    /// Un compte et ses agendas. Deux comptes du même service restent distincts (« Outlook · vg@… »).
    struct CalendarAccount: Identifiable, Hashable {
        let id: String
        /// « Outlook », « Google », « iCloud », « Abonnements », « Sur ce Mac » ou le nom donné par macOS.
        let kind: String
        /// Adresse du compte quand macOS la donne comme nom.
        let address: String?
        let calendars: [CalendarInfo]

        var label: String { address.map { "\(kind) · \($0)" } ?? kind }
        var hasIncluded: Bool { calendars.contains(where: \.included) }
    }

    /// Ordre d'affichage des comptes ; les autres s'intercalent après iCloud.
    private static let kindOrder = ["Outlook", "Google", "iCloud", "Abonnements", "Sur ce Mac"]

    /// Nom du service d'une source EventKit ; nil pour les anniversaires (jamais proposés).
    private static func kind(of source: EKSource) -> String? {
        let title = source.title.lowercased()
        switch source.sourceType {
        case .exchange: return "Outlook"
        case .calDAV where title.contains("icloud"): return "iCloud"
        case .calDAV where title.contains("google") || title.contains("gmail"): return "Google"
        case .subscribed: return "Abonnements"
        case .local: return "Sur ce Mac"
        case .birthdays: return nil
        default: return title.contains("@") ? "Agenda en ligne" : source.title
        }
    }

    /// Couleur donnée à l'agenda par son compte ; gris s'il n'en a pas.
    private static func color(of calendar: EKCalendar) -> Color {
        (calendar.cgColor as CGColor?).map(Color.init(cgColor:)) ?? Theme.muted
    }

    /// Règle par défaut d'un agenda jamais coché ni décoché : tout est pris en compte, sauf les anniversaires
    /// et les jours fériés, qui ne sont pas des rendez-vous à enregistrer.
    static func includedByDefault(_ calendar: EKCalendar) -> Bool {
        if calendar.type == .birthday { return false }
        let title = foldedForSearch(calendar.title)
        return !["ferie", "holiday", "vacances scolaires"].contains { title.contains($0) }
    }

    static func isIncluded(_ calendar: EKCalendar) -> Bool {
        Settings.calendarChoices[calendar.calendarIdentifier] ?? includedByDefault(calendar)
    }

    /// Coche ou décoche un agenda ; la page Aujourd'hui suit aussitôt.
    static func setIncluded(_ id: String, _ included: Bool) {
        Settings.calendarChoices[id] = included
        Agenda.shared.refresh()
    }

    /// Agendas de rendez-vous pris en compte ; vide si l'utilisateur les a tous décochés.
    static var activeCalendars: [EKCalendar] {
        guard calendarAuthorized else { return [] }
        return eventStore.calendars(for: .event).filter(isIncluded)
    }

    /// Comptes qui ont au moins un agenda, chacun avec ses agendas par ordre alphabétique.
    /// Les abonnements (jours fériés, liens ajoutés dans Calendrier) sont regroupés sous « Abonnements »,
    /// quel que soit le compte qui les héberge.
    static var calendarAccounts: [CalendarAccount] {
        guard calendarAuthorized else { return [] }
        func info(_ calendar: EKCalendar) -> CalendarInfo {
            CalendarInfo(id: calendar.calendarIdentifier, title: calendar.title,
                         color: color(of: calendar), included: isIncluded(calendar))
        }
        func sorted(_ calendars: [EKCalendar]) -> [CalendarInfo] {
            calendars.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.map(info)
        }
        var accounts: [CalendarAccount] = []
        var subscriptions: [EKCalendar] = []
        for source in eventStore.sources {
            guard let kind = kind(of: source) else { continue }
            let all = Array(source.calendars(for: .event)).filter { $0.type != .birthday }
            if kind == "Abonnements" {
                subscriptions += all
                continue
            }
            subscriptions += all.filter { $0.type == .subscription }
            let own = all.filter { $0.type != .subscription }
            guard !own.isEmpty else { continue }
            let address = source.title.contains("@") ? source.title : nil
            accounts.append(CalendarAccount(id: source.sourceIdentifier, kind: kind, address: address, calendars: sorted(own)))
        }
        if !subscriptions.isEmpty {
            accounts.append(CalendarAccount(id: "abonnements", kind: "Abonnements", address: nil, calendars: sorted(subscriptions)))
        }
        // Un seul compte d'un service : son adresse n'apprend rien ; on la garde pour en distinguer plusieurs.
        let counts = Dictionary(grouping: accounts, by: \.kind).mapValues(\.count)
        accounts = accounts.map { counts[$0.kind] == 1 && $0.kind != "Agenda en ligne"
            ? CalendarAccount(id: $0.id, kind: $0.kind, address: nil, calendars: $0.calendars) : $0 }
        return accounts.sorted { a, b in
            let ia = kindOrder.firstIndex(of: a.kind) ?? 2, ib = kindOrder.firstIndex(of: b.kind) ?? 2
            return ia != ib ? ia < ib : a.label.localizedStandardCompare(b.label) == .orderedAscending
        }
    }

    /// Rendez-vous des agendas pris en compte entre deux dates.
    static func events(from start: Date, to end: Date) -> [EKEvent] {
        let calendars = activeCalendars
        guard !calendars.isEmpty else { return [] }
        return eventStore.events(matching: eventStore.predicateForEvents(withStart: start, end: end, calendars: calendars))
    }

    /// Rendez-vous en cours (ou qui commence dans les 10 minutes) : celui qu'on enregistre.
    /// À égalité, celui qui a des invités, puis celui dont l'heure de début est la plus proche.
    static func currentEvent(at date: Date = Date()) -> CalendarEvent? {
        guard Settings.useCalendar else { return nil }
        let candidates = events(from: date.addingTimeInterval(-6 * 3600), to: date.addingTimeInterval(600)).filter {
            !$0.isAllDay && $0.startDate <= date.addingTimeInterval(600) && $0.endDate > date
                && $0.availability != .free
        }
        return merged(candidates.compactMap(event)).min { a, b in
            if (a.guestCount > 0) != (b.guestCount > 0) { return a.guestCount > 0 }
            return abs((a.start ?? date).timeIntervalSince(date)) < abs((b.start ?? date).timeIntervalSince(date))
        }
    }

    /// Rendez-vous qui commencent (de 1 min avant à 5 min après leur heure) : Murmure propose de les enregistrer.
    /// Ni journées entières, ni plages libres, ni blocs de plus de 4 h (« Audience », « Congés »).
    static func startingEvents(at date: Date = Date()) -> [CalendarEvent] {
        guard Settings.useCalendar else { return [] }
        return merged(events(from: date.addingTimeInterval(-300), to: date.addingTimeInterval(60)).filter {
            !$0.isAllDay && $0.availability != .free
                && $0.startDate >= date.addingTimeInterval(-300) && $0.startDate <= date.addingTimeInterval(60)
                && $0.endDate > date && $0.endDate.timeIntervalSince($0.startDate) <= 4 * 3600
        }.compactMap(event))
    }

    /// Rendez-vous qui commencent dans les 2 prochaines minutes : rappel déplié dans le bouton flottant.
    /// Mêmes exclusions qu'au-dessus (journées entières, plages libres, blocs de plus de 4 h).
    static func upcomingEvents(at date: Date = Date(), within seconds: TimeInterval = 120) -> [CalendarEvent] {
        guard Settings.useCalendar else { return [] }
        let limit = date.addingTimeInterval(seconds)
        return merged(events(from: date, to: limit).filter {
            !$0.isAllDay && $0.availability != .free && $0.startDate > date && $0.startDate <= limit
                && $0.endDate.timeIntervalSince($0.startDate) <= 4 * 3600
        }.compactMap(event))
    }

    /// « Autoriser » de l'agenda dans le bouton flottant : la demande de macOS la première fois, ensuite
    /// Réglages Système › Confidentialité › Calendriers (macOS ne redemande pas).
    static func askCalendarAccess() {
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            requestCalendar { _ in Agenda.shared.refresh() }
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Rendez-vous de la journée (hors journée entière), du premier au dernier : la page Aujourd'hui.
    static func todayEvents(on date: Date = Date()) -> [CalendarEvent] {
        let day = Calendar.current.startOfDay(for: date)
        guard let next = Calendar.current.date(byAdding: .day, value: 1, to: day) else { return [] }
        return merged(events(from: day, to: next)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
            .compactMap(event))
    }

    /// Un même rendez-vous peut figurer dans plusieurs agendas (invitation reçue sur Outlook et transférée
    /// sur Google, agenda partagé d'un associé) : on n'en garde qu'un, celui qui en dit le plus, complété
    /// des invités, du lieu et du service de visio de l'autre. L'ordre d'arrivée est conservé.
    static func merged(_ events: [CalendarEvent]) -> [CalendarEvent] {
        var result: [CalendarEvent] = []
        for event in events {
            guard let index = result.firstIndex(where: { $0.isSameMeeting(as: event) }) else {
                result.append(event)
                continue
            }
            let first = result[index]
            var kept = event.richness > first.richness ? event : first
            let other = event.richness > first.richness ? first : event
            for person in other.attendees where !kept.attendees.contains(where: { $0.isSamePerson(as: person) }) {
                kept.attendees.append(person)
            }
            kept.location = kept.location ?? other.location
            kept.service = kept.service ?? other.service
            kept.joinURL = kept.joinURL ?? other.joinURL
            result[index] = kept
        }
        return result
    }

    /// Un rendez-vous de l'agenda : titre, invités, heures, lieu ou service de visio, agenda d'origine.
    private static func event(_ ek: EKEvent) -> CalendarEvent? {
        guard let title = ek.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return nil }
        var people: [Attendee] = []
        for participant in (ek.attendees ?? []) + [ek.organizer].compactMap({ $0 }) {
            let email = participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "").removingPercentEncoding
            let name = participant.name?.trimmingCharacters(in: .whitespaces)
            guard let label = (name?.isEmpty == false ? name : email), !people.contains(where: { $0.email == email && email != nil }) else { continue }
            people.append(Attendee(name: label, email: email?.contains("@") == true ? email : nil, isMe: participant.isCurrentUser))
        }
        let location = ek.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        let clues = [ek.url?.absoluteString, location, ek.notes].compactMap { $0 }.joined(separator: " ")
        let origin = (ek.calendar as EKCalendar?).map { calendar in
            CalendarOrigin(title: calendar.title, account: (calendar.source as EKSource?).flatMap(kind(of:)), color: color(of: calendar))
        }
        return CalendarEvent(id: ek.eventIdentifier ?? ek.calendarItemIdentifier, title: title, attendees: people,
                             start: ek.startDate, end: ek.endDate,
                             location: location?.isEmpty == false ? location : nil, service: meetingService(in: clues),
                             origin: origin, joinURL: meetingLink(in: clues))
    }

    /// Lien d'abonnement reconnu (https, http, webcal, webcals), ramené au schéma que Calendrier attend :
    /// `webcals` pour un lien https (Google exige le chiffrement), `webcal` sinon. Nil si ce n'est pas un lien.
    static func subscriptionURL(from link: String) -> URL? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), ["https", "http", "webcal", "webcals"].contains(scheme),
              components.host?.isEmpty == false else { return nil }
        components.scheme = ["https", "webcals"].contains(scheme) ? "webcals" : "webcal"
        return components.url
    }

    /// Abonnement à un agenda par son lien (adresse iCal secrète de Google, agenda publié d'Outlook, tout
    /// lien .ics) : Murmure le confie à l'application Calendrier, qui demande confirmation, l'ajoute et le
    /// tient à jour ; il apparaît ensuite sous « Abonnements ». Rend false si le texte n'est pas un lien.
    @discardableResult
    static func subscribe(to link: String) -> Bool {
        guard let url = subscriptionURL(from: link) else { return false }
        // Calendrier explicitement : Outlook s'enregistre parfois pour les liens webcal.
        if let calendarApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.open([url], withApplicationAt: calendarApp, configuration: NSWorkspace.OpenConfiguration())
            return true
        }
        return NSWorkspace.shared.open(url)
    }

    /// « Google Meet », « Teams »… d'après le lien de visio du rendez-vous (adresse, lieu ou notes).
    static func meetingService(in text: String) -> String? {
        let lower = text.lowercased()
        let services = [("meet.google", "Google Meet"), ("teams.microsoft", "Teams"), ("teams.live", "Teams"),
                        ("zoom.us", "Zoom"), ("webex", "Webex"), ("facetime", "FaceTime"), ("whereby", "Whereby")]
        return services.first { lower.contains($0.0) }?.1
    }

    /// Lien pour rejoindre la visio (Teams, Meet, Zoom…) trouvé dans l'adresse, le lieu ou les notes du rendez-vous.
    static func meetingLink(in text: String) -> URL? {
        guard meetingService(in: text) != nil,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap(\.url).first { url in
            guard let scheme = url.scheme?.lowercased(), ["https", "http", "msteams", "zoommtg"].contains(scheme) else { return false }
            return meetingService(in: url.absoluteString) != nil
        }
    }

    // MARK: Messagerie

    enum MailApp: String, CaseIterable {
        case system, outlook, gmail, outlookWeb

        var label: String {
            switch self {
            case .system: return "Application par défaut"
            case .outlook: return "Outlook (application)"
            case .gmail: return "Gmail (navigateur)"
            case .outlookWeb: return "Outlook (navigateur)"
            }
        }

        /// Nom court pour les menus : « Préparer un e-mail dans Outlook ».
        var shortName: String {
            switch self {
            case .system: return "Mail"
            case .outlook, .outlookWeb: return "Outlook"
            case .gmail: return "Gmail"
            }
        }

        static let outlookBundleID = "com.microsoft.Outlook"
        static var outlookInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: outlookBundleID) != nil }

        /// Choix proposés : l'application Outlook seulement si elle est installée.
        static var available: [MailApp] { allCases.filter { $0 != .outlook || outlookInstalled } }

        /// Tant que rien n'est choisi : l'application Outlook si elle est installée (la messagerie du cabinet), sinon Mail.
        static var preferred: MailApp { outlookInstalled ? .outlook : .system }
    }

    static var mailApp: MailApp {
        guard let saved = MailApp(rawValue: UserDefaults.standard.string(forKey: "mailApp") ?? "") else { return MailApp.preferred }
        return saved == .outlook && !MailApp.outlookInstalled ? .system : saved
    }

    /// Ouvre un brouillon adressé à `to` dans la messagerie choisie ; rien n'est envoyé.
    static func compose(to: [String], subject: String, body: String) {
        // Le corps passe dans l'adresse « mailto: » : on le borne pour rester accepté par les messageries.
        let body = String(body.prefix(10_000))
        var components = URLComponents()
        switch mailApp {
        case .system, .outlook:
            components.scheme = "mailto"
            components.path = to.joined(separator: ",")
            components.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        case .gmail:
            components = URLComponents(string: "https://mail.google.com/mail/")!
            components.queryItems = [URLQueryItem(name: "view", value: "cm"), URLQueryItem(name: "fs", value: "1"),
                                     URLQueryItem(name: "to", value: to.joined(separator: ",")),
                                     URLQueryItem(name: "su", value: subject), URLQueryItem(name: "body", value: body)]
        case .outlookWeb:
            components = URLComponents(string: "https://outlook.office.com/mail/deeplink/compose")!
            components.queryItems = [URLQueryItem(name: "to", value: to.joined(separator: ",")),
                                     URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        }
        guard let url = components.url else { return }
        if mailApp == .outlook, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MailApp.outlookBundleID) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Rendez-vous de l'agenda associé à une réunion, ou listé par la page Aujourd'hui.
struct CalendarEvent: Hashable, Identifiable {
    var id = UUID().uuidString
    var title: String
    var attendees: [Attendee]
    var start: Date?
    var end: Date?
    var location: String?
    /// Service de visio reconnu dans le lien du rendez-vous (« Google Meet », « Teams »), nil sinon.
    var service: String?
    /// Agenda d'où vient le rendez-vous (pastille de couleur sur la page Aujourd'hui) ; nil pour un aperçu.
    var origin: CalendarOrigin?
    /// Lien pour rejoindre la visio, quand le rendez-vous en donne un (bouton « Rejoindre » de l'encoche).
    var joinURL: URL?

    /// Invités autres que soi.
    var guestCount: Int { attendees.filter { !$0.isMe }.count }

    /// « Google Meet · 3 invités », sinon le lieu, sinon les invités seuls ; vide s'il n'y a rien à dire.
    var detail: String {
        var parts: [String] = []
        if let service { parts.append(service) } else if let location { parts.append(location) }
        if guestCount > 0 { parts.append("\(guestCount) invité\(guestCount > 1 ? "s" : "")") }
        return parts.joined(separator: " · ")
    }

    /// Même rendez-vous vu dans deux agendas : même titre (sans casse ni accents), mêmes heures à la minute.
    func isSameMeeting(as other: CalendarEvent) -> Bool {
        guard let start, let end, let otherStart = other.start, let otherEnd = other.end else { return false }
        return abs(start.timeIntervalSince(otherStart)) < 60 && abs(end.timeIntervalSince(otherEnd)) < 60
            && foldedForSearch(title.trimmingCharacters(in: .whitespaces)) == foldedForSearch(other.title.trimmingCharacters(in: .whitespaces))
    }

    /// Ce que le rendez-vous apprend : invités d'abord, puis lien de visio, puis lieu. Départage les doublons.
    var richness: Int { guestCount * 4 + (service != nil ? 2 : 0) + (location != nil ? 1 : 0) }

    /// Déjà commencé (et pas fini) à cet instant.
    func isUnderway(at now: Date = Date()) -> Bool {
        guard let start, let end else { return false }
        return start <= now && end > now
    }

    func isOver(at now: Date = Date()) -> Bool { (end ?? .distantFuture) <= now }
}

/// Agenda d'origine d'un rendez-vous : « Calendrier » du compte Outlook, en bleu.
struct CalendarOrigin: Hashable {
    var title: String
    var account: String?
    var color: Color

    /// « Calendrier (Outlook) », ou le titre seul.
    var label: String { account.map { "\(title) (\($0))" } ?? title }
}

/// Rendez-vous du jour, lus dans l'agenda du Mac et tenus à jour (chaque minute, et dès que l'agenda change) :
/// compteur du panneau, ligne « prochain rendez-vous » de l'accueil, page Aujourd'hui.
final class Agenda: ObservableObject {
    static let shared = Agenda()

    @Published private(set) var today: [CalendarEvent] = []
    /// Minute courante : fait avancer « en cours » et « terminé » sans relire l'agenda.
    @Published private(set) var now = Date()
    /// Rendez-vous imposés (aperçu en ligne de commande), à la place de l'agenda.
    var sample: [CalendarEvent]? { didSet { refresh() } }
    private var timer: Timer?

    private init() {
        refresh()
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: Connectors.eventStore, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        now = Date()
        let events = sample ?? Connectors.todayEvents(on: now)
        if events != today { today = events }
    }

    /// Rendez-vous pas encore terminés, du plus proche au plus lointain.
    var remaining: [CalendarEvent] { today.filter { !$0.isOver(at: now) } }

    /// Le prochain (ou celui en cours).
    var next: CalendarEvent? { remaining.first }
}

/// Invité d'un rendez-vous (« Moi » si c'est le titulaire du compte).
struct Attendee: Codable, Hashable {
    var name: String
    var email: String?
    var isMe: Bool

    /// Même personne : même adresse si les deux en ont une, sinon même nom (sans casse ni accents).
    func isSamePerson(as other: Attendee) -> Bool {
        if let email, let otherEmail = other.email { return email.lowercased() == otherEmail.lowercased() }
        return foldedForSearch(name) == foldedForSearch(other.name)
    }
}
