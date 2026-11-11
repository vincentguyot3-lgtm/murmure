import SwiftUI

/// Sous-page « Voix connues » des Réglages (Transcription › Réunions) : reconnaître ou non les voix d'une réunion à
/// l'autre, les voix apprises (renommer, oublier) et tout effacer. Voir `VoiceBook`.
struct VoicesPage: View {
    let header: AnyView
    let spacing: CGFloat
    @ObservedObject private var book = VoiceBook.shared
    @AppStorage("recognizeVoices") private var recognize = true

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            header
            SettingsSection(title: "Reconnaissance",
                            footer: "Quand vous nommez une voix dans une réunion, Murmure en garde une empreinte (une suite de nombres, pas le son) et propose ce nom quand la même voix revient dans une réunion suivante, avec la mention « voix reconnue, à confirmer ». Confirmer ou corriger affine l'empreinte ; un nom proposé qui n'est pas confirmé n'est pas appris. Les invités du rendez-vous sont reconnus plus facilement. Tout reste sur ce Mac. Une empreinte vocale qui sert à reconnaître une personne est une donnée biométrique : ne nommez que les voix des personnes qui l'acceptent, et oubliez les autres ici.") {
                SettingsRow(label: "Reconnaître les voix d'une réunion à l'autre", last: true) {
                    Toggle("", isOn: $recognize).toggleStyle(MonoToggleStyle()).labelsHidden().confirmsChange(of: recognize)
                }
            }
            SettingsSection(title: "Voix connues",
                            footer: book.voices.isEmpty
                                ? "Aucune voix pour l'instant : nommez un interlocuteur dans la transcription d'une réunion (8 secondes de parole au moins)."
                                : "« Moi » s'apprend seul quand votre voix est reconnue au micro pendant une visio.") {
                if book.voices.isEmpty {
                    SettingsRow(label: "Aucune voix", last: true) { EmptyView() }
                } else {
                    ForEach(Array(sorted.enumerated()), id: \.element.id) { index, voice in
                        SettingsRow(label: voice.isOwn ? "Moi (votre voix)" : voice.name, last: index == sorted.count - 1) {
                            HStack(spacing: 10) {
                                Hint(detail(voice))
                                if !voice.isOwn {
                                    Button("Renommer") { rename(voice) }.buttonStyle(OutlineButtonStyle()).keyboardFocusRing()
                                }
                                Button("Oublier") { forget(voice) }.buttonStyle(OutlineButtonStyle()).keyboardFocusRing()
                            }
                        }
                    }
                }
            }
            SettingsSection(title: "Tout effacer",
                            footer: "Efface les voix connues et les empreintes gardées avec chaque réunion. Les noms déjà donnés dans les fiches restent.") {
                SettingsRow(label: "Oublier toutes les voix", last: true) {
                    Button("Tout oublier…") {
                        Modals.shared.confirm("Oublier toutes les voix ?",
                                              message: "Murmure ne reconnaîtra plus personne tant que vous n'aurez pas nommé de nouvelles voix.",
                                              confirm: "Tout oublier") { book.forgetAll() }
                    }
                    .buttonStyle(OutlineButtonStyle())
                    .keyboardFocusRing()
                }
            }
        }
    }

    /// « Moi » d'abord, puis les autres par ordre alphabétique.
    private var sorted: [KnownVoice] {
        book.voices.sorted { ($0.isOwn ? 0 : 1, foldedForSearch($0.name)) < ($1.isOwn ? 0 : 1, foldedForSearch($1.name)) }
    }

    /// « 4 réunions · 12 min » : de quoi juger si l'empreinte est solide.
    private func detail(_ voice: KnownVoice) -> String {
        let meetings = voice.meetings
        let minutes = max(1, Int((voice.seconds / 60).rounded()))
        return "\(meetings) réunion\(meetings > 1 ? "s" : "") · \(minutes) min"
    }

    private func rename(_ voice: KnownVoice) {
        Modals.shared.ask("Renommer « \(voice.name) »",
                          message: "Le nouveau nom sera proposé aux prochaines réunions ; les fiches déjà nommées ne changent pas. Le nom d'une autre voix connue réunit les deux.",
                          placeholder: "Me Delorme", initial: voice.name, confirm: "Renommer") { book.rename(voice.id, to: $0) }
    }

    private func forget(_ voice: KnownVoice) {
        Modals.shared.confirm("Oublier la voix « \(voice.isOwn ? "Moi" : voice.name) » ?",
                              message: "Son empreinte est effacée : Murmure ne la reconnaîtra plus. Les fiches déjà nommées ne changent pas.",
                              confirm: "Oublier") { book.delete(voice.id) }
    }
}
