import CoreAudio
import Foundation

/// Repère une conversation qui commence et propose de l'enregistrer, une fois chacune :
/// - un appel FaceTime ou téléphonique (iPhone relayé sur le Mac) : le service d'appel de macOS tient le micro depuis 6 s ;
/// - une visio : une application de réunion (Teams, Zoom, Webex, Slack, WhatsApp, ou un navigateur pour Meet)
///   tient le micro depuis 20 s ;
/// - un rendez-vous de l'agenda qui commence, même sans visio (rendez-vous au cabinet).
/// Lecture seule de l'état des micros par CoreAudio et de l'agenda : rien n'est enregistré sans accord.
final class MeetingDetector {
    /// Appelé sur le fil principal quand une conversation semble commencer.
    var onDetected: ((MeetingProposal) -> Void)?
    /// Appelé quand elle se termine sans avoir été enregistrée (micro relâché) : la proposition est retirée.
    var onEnded: ((String) -> Void)?
    /// Vrai quand Murmure enregistre déjà (dictée ou réunion) : pas de proposition.
    var isBusy: () -> Bool = { false }
    /// Rendez-vous déjà programmé (« Enregistrer à l'heure ») : il démarrera seul, inutile de le proposer.
    var scheduledEventID: () -> String? = { nil }
    /// Rendez-vous déjà rappelé dans le bouton flottant (rappel affiché ou déjà répondu) : pas de doublon.
    var skipsEvent: (String) -> Bool = { _ in false }

    private var timer: Timer?
    private var since: [String: Date] = [:]
    private var proposed = Set<String>()
    private var proposedEvents = Set<String>()
    private var ticks = 0

    /// Préfixe d'identifiant d'application → nom affiché et nature. Préfixe : l'audio passe souvent par un
    /// processus auxiliaire (« com.google.Chrome.helper »). Un appel FaceTime ou un appel iPhone relayé sur le
    /// Mac ne passe pas par l'application FaceTime mais par `avconferenced`, le service d'appel de macOS.
    private static let apps: [(prefix: String, name: String, call: Bool)] = [
        ("com.apple.avconferenced", "Appel", true), ("com.apple.TelephonyUtilities", "Appel", true),
        ("com.apple.FaceTime", "Appel", true),
        ("com.microsoft.teams", "Teams", false), ("us.zoom.xos", "Zoom", false), ("com.cisco.webex", "Webex", false),
        ("Cisco-Systems.Spark", "Webex", false), ("com.tinyspeck.slackmacgap", "Slack", false),
        ("net.whatsapp.WhatsApp", "WhatsApp", false), ("com.skype.skype", "Skype", false), ("com.hnc.Discord", "Discord", false),
        ("org.whispersystems.signal-desktop", "Signal", false), ("ru.keepcoder.Telegram", "Telegram", false),
        ("com.google.Chrome", "Chrome", false), ("com.apple.Safari", "Safari", false), ("com.apple.WebKit", "Safari", false),
        ("company.thebrowser.Browser", "Arc", false), ("com.microsoft.edgemac", "Edge", false),
        ("org.mozilla.firefox", "Firefox", false), ("com.brave.Browser", "Brave", false),
    ]

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        guard !isBusy() else { since.removeAll(); return }
        ticks += 1
        if Settings.detectMeetings { pollMicrophone() } else { since.removeAll() }
        // L'agenda change peu : un coup d'œil toutes les 30 s suffit.
        if Settings.proposeAtAppointments, ticks % 10 == 1 { pollCalendar() }
    }

    private func pollMicrophone() {
        let now = Date()
        var current: [String: Bool] = [:]
        for bundleID in Self.processesUsingMicrophone() {
            guard let app = Self.apps.first(where: { bundleID.hasPrefix($0.prefix) }) else { continue }
            current[app.name] = app.call
        }
        for name in current.keys where since[name] == nil { since[name] = now }
        // Micro relâché : la conversation est finie, la suivante pourra être proposée.
        for name in Array(since.keys) where current[name] == nil {
            since[name] = nil
            if proposed.remove(name) != nil { onEnded?(name) }
        }
        for (name, start) in since where !proposed.contains(name) {
            let call = current[name] ?? false
            guard now.timeIntervalSince(start) >= (call ? 6 : 20) else { continue }
            proposed.insert(name)
            onDetected?(call ? .call : .visio(name))
        }
    }

    /// Rendez-vous qui commence (de 1 min avant à 5 min après son heure) : proposé une fois.
    private func pollCalendar() {
        let scheduled = scheduledEventID()
        for event in Connectors.startingEvents() where !proposedEvents.contains(event.id) && event.id != scheduled && !skipsEvent(event.id) {
            proposedEvents.insert(event.id)
            onDetected?(.appointment(event))
            return
        }
    }

    /// Identifiants des processus qui captent le micro en ce moment (macOS 14.4 et suivants).
    static func processesUsingMicrophone() -> [String] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return [] }

        let own = Bundle.main.bundleIdentifier
        return processes.compactMap { process in
            var running = UInt32(0)
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var input = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(process, &input, 0, nil, &runningSize, &running) == noErr, running != 0 else { return nil }
            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var identifier = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(process, &identifier, 0, nil, &bundleSize, &bundle) == noErr,
                  let id = bundle?.takeRetainedValue() as String?, id != own else { return nil }
            return id
        }
    }
}

/// Ce que Murmure propose d'enregistrer.
enum MeetingProposal: Equatable {
    case call
    case visio(String)
    case appointment(CalendarEvent)

    /// Clé de la conversation : l'application qui tient le micro, ou le rendez-vous.
    var source: String {
        switch self {
        case .call: return "Appel"
        case .visio(let app): return app
        case .appointment(let event): return event.id
        }
    }

    var title: String {
        switch self {
        case .call: return "Appel en cours"
        case .visio(let app): return "Réunion détectée dans \(app)"
        case .appointment(let event): return event.title
        }
    }

    var subtitle: String {
        switch self {
        case .appointment(let event):
            let hour = event.start.map { $0.formatted(date: .omitted, time: .shortened) }
            return [hour.map { "Rendez-vous de \($0)" } ?? "Rendez-vous", event.detail].filter { !$0.isEmpty }.joined(separator: " · ")
        default:
            return "Enregistrer et retranscrire sur ce Mac ?"
        }
    }

    /// Ce que la capsule dit de la réunion une fois l'enregistrement lancé.
    var recordingDetail: String {
        switch self {
        case .call: return "Appel · retranscrit sur ce Mac"
        case .visio(let app): return "\(app) · retranscrit sur ce Mac"
        case .appointment(let event): return event.title
        }
    }

    var symbol: String {
        switch self {
        case .call: return "phone.fill"
        case .visio: return "video.fill"
        case .appointment: return "calendar"
        }
    }
}
