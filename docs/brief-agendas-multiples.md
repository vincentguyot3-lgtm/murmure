# Brief : plusieurs agendas (Apple, Google, Outlook) en même temps

Brief à confier à un agent de développement. Il contient la décision, le périmètre et le code prêt à
intégrer. Lis d'abord `CLAUDE.md` (règles du projet : worktree, commit, `./build.sh`, style).

## Ce que veut l'utilisateur

Brancher en même temps son agenda Apple (iCloud), son agenda Google et son agenda Outlook (Microsoft
365 du cabinet), voire plusieurs comptes de chaque, pour que Murmure voie toutes ses réunions : page
Aujourd'hui, ligne « prochain rendez-vous », titre et invités d'une réunion lancée, « Enregistrer à
l'heure ». Avec des autorisations explicites.

## Décision : passer par l'agenda de macOS, pas par des connexions directes

**Ce qui existe déjà** (`Sources/Murmure/Connectors.swift`) : Murmure lit l'agenda de macOS par
EventKit, avec `calendars: nil`, donc **tous** les comptes ajoutés dans Réglages Système › Comptes
Internet (Microsoft Exchange = Outlook, Google, iCloud) sont déjà lus ensemble. Une seule autorisation
(« Calendriers », accès complet) couvre tous les comptes.

On garde cette voie et on la complète. Raisons :

- Une connexion directe à Google (API Calendar) ou Microsoft Graph impose d'enregistrer une
  application chez chacun (identifiant client, écran de consentement, vérification Google pour un
  périmètre « sensible », consentement de l'administrateur du locataire Microsoft 365 du cabinet),
  de garder des jetons dans le trousseau et de les renouveler. C'est lourd, fragile, et contraire au
  principe affiché « Murmure ne se connecte à aucun service ».
- macOS fait déjà ce travail : connexion OAuth Microsoft et Google dans Comptes Internet,
  synchronisation en tâche de fond, récurrences, fuseaux horaires, modifications poussées.

**Ce qui manque**, et que ce brief livre :

1. **Choisir les agendas pris en compte**, compte par compte (aujourd'hui tout est lu, y compris
   anniversaires, jours fériés, agenda familial).
2. **Voir les comptes séparément** : deux comptes Outlook ou deux comptes Google ne doivent plus se
   confondre sous un seul « Outlook ».
3. **Fusionner les doublons** : une invitation reçue sur Outlook et transférée sur Google apparaît
   deux fois. On n'en garde qu'une, en réunissant les invités.
4. **S'abonner par un lien** quand le compte ne peut pas être ajouté à macOS (adresse iCal secrète
   de Google, agenda publié d'Outlook) : Murmure confie le lien à Calendrier, qui l'ajoute et le
   tient à jour. Aucun analyseur iCalendar à écrire.
5. **Dire clairement** que l'application Outlook pour Mac ne partage pas son agenda avec macOS : il
   faut ajouter le compte Microsoft Exchange dans Comptes Internet.
6. Montrer de quel agenda vient un rendez-vous (pastille de couleur sur la page Aujourd'hui).

**Hors périmètre** (à ne pas faire) : connexion directe Google / Microsoft Graph, écriture dans les
agendas, création d'événements. Voir « Plus tard » en fin de document.

## Fichiers touchés

| Fichier | Modification |
|---|---|
| `Sources/Murmure/Connectors.swift` | comptes, agendas, choix, fusion, abonnement ; `CalendarEvent` porte l'agenda |
| `Sources/Murmure/Settings.swift` | `calendarChoices` |
| `Sources/Murmure/DesignSystem.swift` | `SettingsRow` accepte une pastille `tint` |
| `Sources/Murmure/SettingsView.swift` | sous-page Agenda refaite, résumé de la ligne Agenda |
| `Sources/Murmure/MainView.swift` | pastille d'agenda dans `EventLine`, message si aucun agenda coché |
| `Sources/Murmure/main.swift` | `--agendas` (diagnostic) et `--test-agenda` (fusion des doublons) |
| `Info.plist` | phrase d'autorisation Calendriers |
| `README.md` | section Agenda (ligne `- **Agenda** :`) et sous-page Agenda des Réglages |

Avant de commencer : `git status --short`. Si d'autres fichiers sont modifiés, travaille dans un
worktree (branche `agendas-multiples`), comme le dit `CLAUDE.md`.

---

## 1. `Settings.swift`

Ajouter sous `useCalendar` :

```swift
    /// Agendas cochés ou décochés par l'utilisateur (identifiant EventKit → pris en compte). Un agenda absent
    /// suit la règle par défaut de `Connectors.includedByDefault` : tout sauf anniversaires et jours fériés.
    static var calendarChoices: [String: Bool] {
        get { UserDefaults.standard.dictionary(forKey: "calendarChoices") as? [String: Bool] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "calendarChoices") }
    }
```

## 2. `Connectors.swift`

### 2.1 Imports et commentaire d'en-tête

`import SwiftUI` en plus d'`AppKit` et `EventKit` (pour `Color`). Remplacer le commentaire de l'enum :

```swift
/// Connecteurs vers l'agenda et la messagerie. Murmure ne se connecte à aucun service en ligne :
/// il lit l'agenda de macOS, où l'on ajoute autant de comptes qu'on veut (Outlook / Microsoft Exchange,
/// Google, iCloud dans Réglages Système › Comptes Internet, abonnements par lien dans Calendrier), et
/// ouvre l'application de messagerie choisie, où un brouillon est préparé sans jamais être envoyé.
```

### 2.2 Remplacer `calendarAccounts`, `currentEvent`, `todayEvents`, `event(_:)`

Tout le bloc `// MARK: Agenda` jusqu'à `meetingService(in:)` (exclu) devient :

```swift
    // MARK: Agenda

    static let eventStore = EKEventStore()

    static var calendarAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// Demande l'accès à l'agenda (une fois ; ensuite, Réglages Système › Confidentialité › Calendriers).
    static func requestCalendar(_ done: @escaping (Bool) -> Void) {
        eventStore.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async { done(granted) }
        }
    }

    /// Demande à macOS de resynchroniser les comptes (bouton « Actualiser », retour sur la sous-page Agenda).
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

    /// Ordre d'affichage des comptes.
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
                         color: Color(cgColor: calendar.cgColor), included: isIncluded(calendar))
        }
        func sorted(_ calendars: [EKCalendar]) -> [CalendarInfo] {
            calendars.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.map(info)
        }
        var accounts: [CalendarAccount] = []
        var subscriptions: [EKCalendar] = []
        for source in eventStore.sources {
            guard let kind = kind(of: source) else { continue }
            let all = source.calendars(for: .event).filter { $0.type != .birthday }
            subscriptions += all.filter { $0.type == .subscription }
            let own = all.filter { $0.type != .subscription }
            guard !own.isEmpty, kind != "Abonnements" else { continue }
            let address = source.title.contains("@") ? source.title : nil
            accounts.append(CalendarAccount(id: source.sourceIdentifier, kind: kind, address: address, calendars: sorted(own)))
        }
        if !subscriptions.isEmpty {
            accounts.append(CalendarAccount(id: "abonnements", kind: "Abonnements", address: nil, calendars: sorted(subscriptions)))
        }
        // Un seul compte d'un service : son adresse n'apprend rien, on la garde pour en distinguer plusieurs.
        let counts = Dictionary(grouping: accounts, by: \.kind).mapValues(\.count)
        accounts = accounts.map { counts[$0.kind] == 1 && $0.kind != "Agenda en ligne"
            ? CalendarAccount(id: $0.id, kind: $0.kind, address: nil, calendars: $0.calendars) : $0 }
        return accounts.sorted { a, b in
            let ia = kindOrder.firstIndex(of: a.kind) ?? 2, ib = kindOrder.firstIndex(of: b.kind) ?? 2
            return ia != ib ? ia < ib : a.label.localizedStandardCompare(b.label) == .orderedAscending
        }
    }

    /// Rendez-vous des agendas pris en compte entre deux dates.
    private static func events(from start: Date, to end: Date) -> [EKEvent] {
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
        let origin = ek.calendar.map { calendar in
            CalendarOrigin(title: calendar.title, account: calendar.source.flatMap(kind(of:)), color: Color(cgColor: calendar.cgColor))
        }
        return CalendarEvent(id: ek.eventIdentifier ?? ek.calendarItemIdentifier, title: title, attendees: people,
                             start: ek.startDate, end: ek.endDate,
                             location: location?.isEmpty == false ? location : nil, service: meetingService(in: clues),
                             origin: origin)
    }

    /// Abonnement à un agenda par son lien (adresse iCal secrète de Google, agenda publié d'Outlook, tout
    /// lien .ics) : Murmure le confie à l'application Calendrier, qui demande confirmation, l'ajoute et le
    /// tient à jour ; il apparaît ensuite sous « Abonnements ». Rend false si le texte n'est pas un lien.
    @discardableResult
    static func subscribe(to link: String) -> Bool {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), ["https", "http", "webcal", "webcals"].contains(scheme),
              components.host?.isEmpty == false else { return false }
        components.scheme = "webcal"
        guard let url = components.url else { return false }
        // Calendrier explicitement : Outlook s'enregistre parfois pour les liens webcal.
        if let calendarApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.open([url], withApplicationAt: calendarApp, configuration: NSWorkspace.OpenConfiguration())
            return true
        }
        return NSWorkspace.shared.open(url)
    }
```

Note sur `kind(of:)` : sur le Mac, le nom d'une source Google est souvent l'adresse du compte
(`prenom@gmail.com`, ou l'adresse Google Workspace du cabinet). `gmail` est reconnu ; une adresse
Workspace tombe sur « Agenda en ligne · adresse », ce qui reste lisible. Vérifier avec `--agendas`
(§ 6) ce que macOS renvoie vraiment et ajuster si besoin.

### 2.3 `CalendarEvent`, `CalendarOrigin`, `Attendee`

Dans `CalendarEvent`, ajouter après `service` :

```swift
    /// Agenda d'où vient le rendez-vous (pastille de couleur sur la page Aujourd'hui) ; nil pour un aperçu.
    var origin: CalendarOrigin?
```

et, après `detail` :

```swift
    /// Même rendez-vous vu dans deux agendas : même titre (sans casse ni accents), mêmes heures à la minute.
    func isSameMeeting(as other: CalendarEvent) -> Bool {
        guard let start, let end, let otherStart = other.start, let otherEnd = other.end else { return false }
        return abs(start.timeIntervalSince(otherStart)) < 60 && abs(end.timeIntervalSince(otherEnd)) < 60
            && foldedForSearch(title.trimmingCharacters(in: .whitespaces)) == foldedForSearch(other.title.trimmingCharacters(in: .whitespaces))
    }

    /// Ce que le rendez-vous apprend : invités d'abord, puis lien de visio, puis lieu. Départage les doublons.
    var richness: Int { guestCount * 4 + (service != nil ? 2 : 0) + (location != nil ? 1 : 0) }
```

Nouveau type, sous `CalendarEvent` :

```swift
/// Agenda d'origine d'un rendez-vous : « Calendrier » du compte Outlook, en bleu.
struct CalendarOrigin: Hashable {
    var title: String
    var account: String?
    var color: Color

    /// « Calendrier (Outlook) », ou le titre seul.
    var label: String { account.map { "\(title) (\($0))" } ?? title }
}
```

Dans `Attendee`, ajouter :

```swift
    /// Même personne : même adresse si les deux en ont une, sinon même nom (sans casse ni accents).
    func isSamePerson(as other: Attendee) -> Bool {
        if let email, let otherEmail = other.email { return email.lowercased() == otherEmail.lowercased() }
        return foldedForSearch(name) == foldedForSearch(other.name)
    }
```

`Attendee` est `Codable` (stocké dans l'historique) : la méthode ne change pas son encodage.
`CalendarEvent` n'est pas `Codable` : ajouter `origin` (avec un `Color`) ne casse rien.

## 3. `DesignSystem.swift` : pastille dans `SettingsRow`

Dans `SettingsRow`, ajouter une propriété **après** `keywords` (les appels existants restent valides) :

```swift
    /// Pastille de couleur devant le libellé (agendas de la sous-page Agenda).
    var tint: Color?
```

et remplacer `Text(label).font(.ui(13))` dans le `HStack` par :

```swift
                if let tint {
                    Circle().fill(tint).frame(width: 8 * Settings.uiScale, height: 8 * Settings.uiScale)
                }
                Text(label).font(.ui(13))
```

## 4. `SettingsView.swift`

### 4.1 État

`import EventKit` en tête (pour `.EKEventStoreChanged`). Remplacer
`@State private var calendarAccounts = Connectors.calendarAccounts` (type désormais
`[Connectors.CalendarAccount]`, la ligne ne change pas) et ajouter :

```swift
    @State private var subscriptionLink = ""
    @State private var subscriptionError = false
    @FocusState private var subscriptionFocused: Bool
```

### 4.2 Résumé de la ligne « Agenda » (panneau Connecteurs)

```swift
    private var calendarSummary: String {
        guard calendarAuthorized else { return "non autorisé" }
        var kinds: [String] = []
        for account in calendarAccounts where account.hasIncluded && !kinds.contains(account.kind) { kinds.append(account.kind) }
        return kinds.isEmpty ? "aucun agenda" : kinds.joined(separator: " · ")
    }
```

### 4.3 `refreshCalendar`

```swift
    private func refreshCalendar() {
        calendarAuthorized = Connectors.calendarAuthorized
        calendarAccounts = Connectors.calendarAccounts
        currentEvent = Connectors.currentEvent()
    }
```

(inchangé) ; mais le bouton « Actualiser » et l'apparition de la sous-page appellent d'abord
`Connectors.refreshSources()`.

### 4.4 Sous-page Agenda (`calendarPage`) — remplacer entièrement

```swift
    private var calendarPage: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            subpageHeader(.calendar, title: "Agenda")
            SettingsSection(title: "Accès",
                            footer: "Murmure lit l'agenda du Mac, celui de l'application Calendrier, avec tous ses comptes, sans se connecter lui-même à aucun service. L'autorisation se retire dans Réglages Système › Confidentialité et sécurité › Calendriers.") {
                SettingsRow(label: "Autorisation Calendriers", last: true) {
                    if calendarAuthorized {
                        Label("Autorisée", systemImage: "checkmark").font(.ui(12, weight: .medium))
                    } else {
                        Button("Autoriser…") {
                            Connectors.requestCalendar { granted in
                                refreshCalendar()
                                if !granted { SystemSettings.open(.calendars) }
                            }
                        }
                        .buttonStyle(OutlineButtonStyle(prominent: true))
                        .keyboardFocusRing()
                    }
                }
            }
            if calendarAuthorized && calendarAccounts.isEmpty {
                SettingsSection(title: "Agendas") {
                    SettingsRow(label: "Aucun compte avec un agenda", last: true) { EmptyView() }
                }
            }
            ForEach(calendarAccounts) { account in
                SettingsSection(title: account.label,
                                footer: account.id == calendarAccounts.last?.id
                                    ? "Seuls les agendas cochés alimentent la page Aujourd'hui, le prochain rendez-vous et le titre des réunions. Un rendez-vous présent dans deux agendas n'est montré qu'une fois." : nil) {
                    ForEach(account.calendars) { calendar in
                        SettingsRow(label: calendar.title, last: calendar.id == account.calendars.last?.id,
                                    keywords: "agenda calendrier " + account.label, tint: calendar.color) {
                            toggle(Binding(get: { calendar.included },
                                           set: { Connectors.setIncluded(calendar.id, $0); refreshCalendar() }))
                        }
                    }
                }
            }
            SettingsSection(title: "Ajouter un agenda",
                            footer: "Outlook (Microsoft 365 ou Exchange), Google et iCloud s'ajoutent dans Réglages Système › Comptes Internet ; on peut en ajouter plusieurs de chaque. L'application Outlook pour Mac garde son agenda pour elle : ajoutez-y aussi le compte « Microsoft Exchange » pour que Murmure le voie. Si un compte ne peut pas être ajouté, collez son lien d'abonnement : « Adresse secrète au format iCal » dans les paramètres de l'agenda Google, « Publier un calendrier » dans Outlook sur le web. Calendrier vous demandera de confirmer, puis le tiendra à jour.") {
                SettingsRow(label: "Outlook, Google, iCloud", keywords: "compte microsoft exchange office 365 gmail") {
                    Button("Réglages Système…") { SystemSettings.open(.internetAccounts) }
                        .buttonStyle(OutlineButtonStyle())
                        .keyboardFocusRing()
                }
                SettingsRow(label: "Par un lien d'abonnement", last: true, keywords: "ics ical webcal publier adresse secrète") {
                    HStack(spacing: 8) {
                        if subscriptionError { Hint("lien non reconnu") }
                        TextField("https://…/calendar.ics", text: $subscriptionLink)
                            .textFieldStyle(.plain)
                            .font(.ui(12))
                            .frame(width: 220)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .overlay(RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(subscriptionFocused ? Theme.fg : Theme.line))
                            .focused($subscriptionFocused)
                            .onSubmit(subscribe)
                            .onChange(of: subscriptionLink) { subscriptionError = false }
                        Button("S'abonner", action: subscribe)
                            .buttonStyle(OutlineButtonStyle(prominent: true))
                            .keyboardFocusRing()
                            .disabled(subscriptionLink.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            SettingsSection(title: "Rendez-vous en cours",
                            footer: "Le rendez-vous en cours, ou qui commence dans les dix minutes, donnerait son titre et ses invités à une réunion lancée maintenant.") {
                if let event = currentEvent {
                    SettingsRow(label: event.title) { Hint(event.origin?.label ?? "maintenant") }
                    SettingsRow(label: "Invités", last: true) {
                        Hint(event.attendees.isEmpty ? "aucun" : event.attendees.map(\.name).joined(separator: ", "))
                    }
                } else {
                    SettingsRow(label: useCalendar ? "Aucun rendez-vous en cours" : "Nommage d'après l'agenda désactivé", last: true) {
                        Button("Actualiser") { Connectors.refreshSources(); refreshCalendar() }
                            .buttonStyle(OutlineButtonStyle()).keyboardFocusRing()
                    }
                }
            }
        }
        .onAppear { Connectors.refreshSources(); refreshCalendar() }
        // Un compte ajouté, un abonnement confirmé dans Calendrier : la liste suit sans rouvrir la page.
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged, object: Connectors.eventStore)) { _ in
            refreshCalendar()
        }
    }

    private func subscribe() {
        if Connectors.subscribe(to: subscriptionLink) {
            subscriptionLink = ""
            subscriptionFocused = false
        } else {
            subscriptionError = true
        }
    }
```

À vérifier en intégrant :

- L'interface est monochrome (`Theme` dans `MainView.swift` n'a pas de rouge) : un lien refusé est
  signalé par « lien non reconnu » en gris à gauche du champ, pas par une couleur.
- `StaticPreview.active` : la ligne « Votre prénom » remplace son `TextField` par un `Text` dans les
  aperçus `--apercu-reglages` ; faire de même pour le champ d'abonnement si l'aperçu le rend mal.
- Le texte du pied « Ajouter un agenda » dépasse 120 caractères : `SettingsSection` le replie
  d'elle-même sur sa première ligne, avec un chevron. C'est voulu.

## 5. `MainView.swift`

### 5.1 `EventLine` : pastille de l'agenda

Dans `EventLine.body`, juste avant le `VStack(alignment: .leading, spacing: 2)` du titre :

```swift
            if let origin = event.origin {
                Circle().fill(origin.color)
                    .frame(width: 7 * Settings.uiScale, height: 7 * Settings.uiScale)
                    .help("Agenda \(origin.label)")
            }
```

Mettre à jour le commentaire de `EventLine` : « … heure en gras, pastille de l'agenda, titre, … ».

### 5.2 `TodayEvents` : aucun agenda coché

Remplacer la branche `else if agenda.today.isEmpty { … }` par :

```swift
            } else if agenda.today.isEmpty {
                Text(agenda.sample == nil && Connectors.activeCalendars.isEmpty
                     ? "Aucun agenda n'est coché : choisissez-les dans Réglages › Connecteurs › Agenda."
                     : "Aucun rendez-vous aujourd'hui dans l'agenda.")
                    .font(.ui(12)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
```

### 5.3 Aperçu `--apercu-accueil`

Dans `main.swift`, la fonction `event(...)` de l'aperçu de l'accueil peut passer
`origin: CalendarOrigin(title: "Calendrier", account: "Outlook", color: .blue)` (et `.green` pour
Google sur une autre ligne) pour que l'image montre les pastilles.

## 6. `main.swift` : deux modes en ligne de commande

À placer avec les autres modes, et à ajouter à la ligne « Modes : … » de l'aide.

```swift
// Agendas vus par Murmure : `Murmure --agendas` liste comptes, agendas (✓ pris en compte) et rendez-vous du jour.
// Lecture seule. L'autorisation Calendriers est celle du processus qui lance la commande (Terminal…).
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--agendas" {
    let semaphore = DispatchSemaphore(value: 0)
    if !Connectors.calendarAuthorized {
        Connectors.eventStore.requestFullAccessToEvents { _, _ in semaphore.signal() }
        semaphore.wait()
    }
    guard Connectors.calendarAuthorized else { print("Calendriers non autorisé pour ce processus"); exit(1) }
    for source in Connectors.eventStore.sources {
        print("source « \(source.title) » type \(source.sourceType.rawValue)")
    }
    for account in Connectors.calendarAccounts {
        print("\n\(account.label)")
        for calendar in account.calendars { print("  \(calendar.included ? "✓" : "·") \(calendar.title)") }
    }
    print("\nAujourd'hui :")
    for event in Connectors.todayEvents() {
        let hour = event.start?.formatted(date: .omitted, time: .shortened) ?? "?"
        print("  \(hour)  \(event.title)  [\(event.origin?.label ?? "?")]  \(event.guestCount) invité(s)")
    }
    exit(0)
}

// Fusion des doublons d'agenda : `Murmure --test-agenda`, sans accès à l'agenda.
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
                               start: nine.addingTimeInterval(20), end: nine.addingTimeInterval(3610), location: "Cabinet")
    let other = CalendarEvent(id: "x", title: "Point client", attendees: [], start: nine.addingTimeInterval(1800), end: nine.addingTimeInterval(5400))
    let result = Connectors.merged([outlook, google, other])
    check(result.count == 2, "deux rendez-vous restent (doublon fusionné, homonyme à une autre heure gardé)")
    check(result.first?.id == "g", "le plus riche est gardé (2 invités contre 1)")
    check(result.first?.attendees.count == 2, "Alice n'est comptée qu'une fois (même adresse, casse différente)")
    check(result.first?.service == "Teams", "le service de visio de l'autre agenda est repris")
    check(result.first?.location == "Cabinet", "le lieu est gardé")
    check(Connectors.merged([outlook, outlook]).count == 1, "deux fois le même rendez-vous → un seul")
    print(failures.isEmpty ? "Tout est bon." : "\(failures.count) échec(s).")
    exit(failures.isEmpty ? 0 : 1)
}
```

Ajouter `import EventKit` en tête de `main.swift` (il n'importe aujourd'hui qu'`AppKit`,
`AVFoundation` et `SwiftUI`).

## 7. `Info.plist`

`NSCalendarsFullAccessUsageDescription` :

> Murmure lit les agendas du Mac (Outlook, Google, iCloud…) pour montrer vos rendez-vous du jour,
> nommer une réunion d'après le rendez-vous en cours et préparer l'e-mail du compte rendu. Rien ne
> quitte ce Mac.

## 8. `README.md`

Remplacer la première phrase de la ligne `- **Agenda** :` par :

> - **Agenda** : l'agenda de macOS (EventKit), avec autant de comptes qu'on veut : Outlook /
>   Microsoft Exchange, Google, iCloud (Réglages Système › Comptes Internet ; l'application Outlook
>   pour Mac ne partage pas son agenda, il faut y ajouter le compte Microsoft Exchange), ou un lien
>   d'abonnement (.ics, adresse iCal secrète de Google, agenda publié d'Outlook) collé dans la
>   sous-page Agenda et confié à Calendrier. Chaque agenda se coche ou se décoche, compte par compte
>   (anniversaires et jours fériés décochés par défaut) ; un rendez-vous présent dans deux agendas
>   n'apparaît qu'une fois, avec les invités des deux. Une pastille de la couleur de l'agenda précède
>   chaque rendez-vous de la page Aujourd'hui.

et, dans la description des sous-pages des Réglages, « Agenda (autorisation, comptes détectés,
rendez-vous en cours) » devient « Agenda (autorisation, agendas cochés compte par compte, ajout d'un
compte ou d'un lien d'abonnement, rendez-vous en cours) ».

## 9. Vérifier

1. `swift build -c release` sans avertissement nouveau, puis
   `.build/release/Murmure --test-agenda` → « Tout est bon. ».
2. Fermer l'interface (`osascript -e 'tell application "Murmure" to quit'`, jamais `pkill`),
   `./build.sh`, `open ~/Applications/Murmure.app`, aucun rapport nouveau dans
   `~/Library/Logs/DiagnosticReports`.
3. `~/Applications/Murmure.app/Contents/MacOS/Murmure --agendas` : comptes et agendas réels. Si le
   terminal n'a pas l'autorisation Calendriers, le dire à l'utilisateur plutôt que de la forcer.
4. `--apercu-reglages` et `--apercu-accueil` (voir `main.swift`) pour regarder la sous-page Agenda et
   la page Aujourd'hui en clair et en sombre.
5. Ce que l'agent ne peut pas vérifier seul, à dire explicitement à l'utilisateur : ajout réel d'un
   compte Microsoft 365 et Google dans Comptes Internet ; abonnement par lien confirmé dans
   Calendrier ; doublon réel Outlook + Google fusionné sur la page Aujourd'hui.

## 10. Commit

Un seul commit (dans le worktree puis fusion `--no-ff` dans `main` si `main` compile encore) :

```
Agendas multiples : choix agenda par agenda, doublons fusionnés, abonnement par lien

Tous les comptes de macOS (Outlook, Google, iCloud, plusieurs de chaque) étaient lus sans tri.
On coche désormais les agendas pris en compte, un rendez-vous vu dans deux agendas n'apparaît
qu'une fois, et un lien .ics s'ajoute depuis Murmure via Calendrier.
```

---

## Plus tard (ne pas faire maintenant)

Si le cabinet interdit l'ajout du compte Microsoft 365 à macOS (accès conditionnel) **et** la
publication de l'agenda, seule une connexion directe resterait : Microsoft Graph
(`/me/calendarView`), client public avec PKCE, application enregistrée dans le locataire Azure du
cabinet, périmètre `Calendars.Read`, jeton gardé dans le trousseau comme la clé Claude
(`ClaudeAPI`). Même chose pour Google (API Calendar, `calendar.readonly`, application à faire
vérifier). Ces rendez-vous seraient convertis en `CalendarEvent` et passés par
`Connectors.merged` avec ceux d'EventKit. À n'entreprendre que si la voie macOS échoue chez
l'utilisateur, parce qu'elle fait sortir des requêtes de Murmure lui-même.
