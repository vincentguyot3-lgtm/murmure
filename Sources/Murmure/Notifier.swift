import Foundation
import UserNotifications

/// Notification macOS quand une réunion est traitée ; un clic ouvre sa fiche (voir AppDelegate).
enum Notifier {
    /// Le centre de notifications n'existe que pour une application en paquet : lancé à nu (`.build/release/Murmure
    /// --meeting …`), `UNUserNotificationCenter.current()` fait planter le processus. On s'abstient alors.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestPermission() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// À appeler sur le fil principal, une fois le traitement terminé.
    static func meetingReady(_ id: UUID) {
        guard isAvailable, Settings.notifyWhenReady, let recording = RecordingStore.shared.recording(id), !recording.text.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = recording.status == .summarized ? "Compte rendu prêt" : "Transcription prête"
        content.body = recording.title
        content.sound = .default
        content.userInfo = ["recording": id.uuidString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id.uuidString, content: content, trigger: nil))
    }
}
