import Foundation

/// Was der Reiter „Fotos" zeigt: alles, nur Standbilder oder nur Videos.
///
/// Reiner Wertetyp — kein SwiftUI, kein Netz. Alles, was an diesem Umschalter
/// lautlos falsch sein kann (der Typ, den der Server bekommt; der Leerzustand,
/// der „keine Videos" nicht mit „der Server kennt keine Fotos" verwechseln
/// darf), steht deshalb hier und ist in
/// `Tests/ImmichPhoneTests/PhoneFeedFilterTests.swift` festgenagelt.
///
/// ## Der Server filtert, nicht der Client
///
/// ``assetType`` geht über `PhonePhotoFeed.anfrage(cursor:filter:)` als `type` in
/// den Suchkörper der strukturierten Suche. Nachträglich in ``PhonePhotoFeed`` zu
/// filtern wäre bei rund 165 000 Assets kein Detail, sondern kaputt: Eine Seite
/// mit 200 Standbildern ergäbe null Videokacheln, damit erschiene keine Kachel,
/// deren `.onAppear` die nächste Seite anstößt — der Reiter „Videos" bliebe leer
/// stehen, obwohl der Server welche hat.
///
/// ## Bewegtbild-Anteile von Live Photos
///
/// Unter `type: "VIDEO"` stecken auch die rund eine Sekunde langen Videos, die zu
/// einem Standbild gehören — auf diesem Server mehr als echte Videos. Sie tragen
/// `visibility == "hidden"` (siehe ``AssetVisibility``). Seit der Umstellung auf
/// die strukturierte Suche (Server v3.2.0) lässt schon der Suchkörper sie weg
/// (`visibility: in ["timeline"]`); ``PhotoFeedGrouping/build(assets:)`` filtert
/// sie weiterhin als Absicherung.
enum PhoneFeedFilter: String, CaseIterable, Identifiable, Sendable {

    /// Standbilder **und** Videos, wie der Reiter es vor diesem Umschalter tat.
    case alle
    case fotos
    case videos

    var id: String { rawValue }

    /// Beschriftung des Umschalters. Immer als `String`-Konstante an `Text`
    /// weitergereicht, nie als Literal — SwiftUI parst Literale als Markdown
    /// (siehe `PhoneAlbumTile`).
    var titel: String {
        switch self {
        case .alle: String(localized: "All")
        case .fotos: String(localized: "Photos")
        case .videos: String(localized: "Videos")
        }
    }

    /// Der `type`, den der Suchkörper bekommt — `nil` heißt „nicht einschränken".
    ///
    /// `.audio` und `.other` kommen bewusst nicht vor: Der Reiter ist ein
    /// Fotoraster, und ein Umschalter mit vier Feldern, von denen zwei auf einer
    /// üblichen Mediathek leer bleiben, hilft niemandem. Sie fallen unter
    /// ``alle`` mit hinein, genau wie bisher.
    var assetType: AssetType? {
        switch self {
        case .alle: nil
        case .fotos: .image
        case .videos: .video
        }
    }

    // MARK: - Leerzustand
    //
    // Drei Filter, drei verschiedene Aussagen. „Keine Videos" bei einer
    // Mediathek voller Fotos ist eine ganz andere Auskunft als „Der Server
    // kennt bisher keine Fotos" — verwechselt der Reiter beides, sucht der
    // Nutzer den Fehler beim Server statt beim Umschalter.

    var leerTitel: String {
        switch self {
        case .alle, .fotos: String(localized: "No Photos")
        case .videos: String(localized: "No Videos")
        }
    }

    var leerSymbol: String {
        switch self {
        case .alle: "photo.on.rectangle"
        case .fotos: "photo"
        case .videos: "video.slash"
        }
    }

    var leerText: String {
        switch self {
        case .alle: String(localized: "The server has no photos yet.")
        case .fotos: String(localized: "There are no still images on this server.")
        case .videos: String(localized: "There are no videos on this server.")
        }
    }

    /// Text unter dem Spinner des Erstabrufs.
    var ladeText: String {
        switch self {
        case .alle, .fotos: String(localized: "Loading photos…")
        case .videos: String(localized: "Loading videos…")
        }
    }

    /// Ein Wort für die Protokollzeile je Seite. Ohne das steht im Protokoll
    /// „Seite 3 — 200 geliefert" ohne jeden Hinweis darauf, welcher Bestand
    /// gemeint war; beim Nachgehen eines Nachladeproblems ist genau das die
    /// erste Frage.
    var protokollName: String { rawValue }
}
