import AppKit
import SwiftUI

/// Réglages › Transcription › Annuaire des noms : l'interrupteur, l'autorisation des Contacts et les noms
/// réunis par source. Les mots, corrections et raccourcis qu'on saisit soi-même vivent dans le
/// Lexique du panneau gauche (`ShortcutsView`).
struct NameDirectorySettings: View {
    @AppStorage("useNameDirectory") private var useNameDirectory = true
    @State private var directoryCounts: [NameDirectory.Source: Int] = [:]

    private func names(_ source: NameDirectory.Source) -> String {
        let count = directoryCounts[source] ?? 0
        return count == 1 ? "1 nom" : "\(count.formatted()) noms"
    }

    var body: some View {
        SettingsSection(title: "Annuaire des noms",
                        footer: "Les noms de vos contacts, de vos rendez-vous de l'année, de vos réunions et de vos dossiers, réunis sur ce Mac. Quand un passage dicté sonne comme l'un d'eux, Murmure le signale à Claude, qui l'écrit avec la bonne orthographe. Seuls ces quelques noms accompagnent la dictée.",
                        showsTitle: false) {
            SettingsRow(label: "Rétablir les noms de l'annuaire", keywords: "contacts agenda orthographe") {
                Toggle("", isOn: $useNameDirectory).toggleStyle(MonoToggleStyle()).labelsHidden()
                    .confirmsChange(of: useNameDirectory)
            }
            if useNameDirectory {
                SettingsRow(label: "Contacts") {
                    if NameDirectory.contactsAuthorized {
                        Hint(names(.contact))
                    } else if NameDirectory.contactsAsked {
                        Button("Ouvrir les réglages") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")!)
                        }
                        .buttonStyle(OutlineButtonStyle())
                    } else {
                        Button("Autoriser") { NameDirectory.requestContacts { _ in } }
                            .buttonStyle(OutlineButtonStyle(prominent: true))
                    }
                }
                SettingsRow(label: "Rendez-vous de l'agenda") {
                    Hint(Connectors.calendarAuthorized && Settings.useCalendar ? names(.calendar) : "agenda non relié")
                }
                SettingsRow(label: "Réunions, dossiers et vocabulaire", last: true) {
                    Hint("\((directoryCounts[.meeting] ?? 0) + (directoryCounts[.folder] ?? 0) + (directoryCounts[.lexicon] ?? 0)) noms")
                }
            }
        }
        .onAppear { directoryCounts = NameDirectory.shared.counts }
        .onReceive(NotificationCenter.default.publisher(for: NameDirectory.changed)) { _ in directoryCounts = NameDirectory.shared.counts }
    }
}
