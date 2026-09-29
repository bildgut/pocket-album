import NukeUI
import SwiftUI

/// Wischbare Reihe runder Gesichter auf der Startseite von „Entdecken“.
struct PhonePersonenReihe: View {
    let personen: [Person]
    let apiClient: ImmichAPIClient
    let tippen: (Person) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(personen) { person in
                    Button { tippen(person) } label: {
                        VStack(spacing: 6) {
                            PhonePersonenGesicht(person: person, apiClient: apiClient, groesse: 66)
                            Text(person.name)
                                .font(.caption)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .frame(width: 72)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(person.name)
                }
            }
            .padding(.horizontal, 14)
        }
    }
}

/// Rundes Gesicht einer Person (`/api/people/:id/thumbnail`, braucht `person.read`).
struct PhonePersonenGesicht: View {
    let person: Person
    let apiClient: ImmichAPIClient
    let groesse: CGFloat
    @Environment(ConnectionManager.self) private var connection

    var body: some View {
        // `.pipeline` gehört an die `LazyImage` selbst — bei NukeUI 12.8 eine
        // Instanzmethode, kein Umgebungsmodifier (CLAUDE.md).
        LazyImage(url: apiClient.personThumbnailURL(personId: person.id)) { zustand in
            if let bild = zustand.image {
                bild.resizable().scaledToFill()
            } else {
                Circle().fill(.quaternary)
                    .overlay(Image(systemName: "person.fill").foregroundStyle(.secondary))
            }
        }
        .pipeline(connection.imagePipeline ?? .shared)
        .frame(width: groesse, height: groesse)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}
