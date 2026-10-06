import Foundation

/// Beschriftungen des Reiters „Entdecken“ (früher „Orte“). Als Konstanten an `Text` weitergereicht, nie
/// als Literal — SwiftUI parst Literale als Markdown.
enum PhoneOrtsTexts {
    static let titel = String(localized: "Explore")
    static let suchPrompt = String(localized: "Anna 2019, beach, Italy …")
    static let orte = String(localized: "Places")
    static let zuletzt = String(localized: "Recent Searches")
    static let alle = String(localized: "All")
    static let entfernen = String(localized: "Remove from Recent Searches")
    static let bildsucheGrenze = String(localized: "Showing the 1,000 best matches.")
    static let favoriten = String(localized: "Favorites")
    static func suchenNach(_ text: String) -> String { String(localized: "Search for “\(text)”") }
    static func typ(_ typ: AssetType) -> String {
        typ == .video ? String(localized: "Videos") : String(localized: "Photos")
    }

    /// Beschriftung eines „Zuletzt gesucht“-Eintrags: die gewählten Teile mit „ · “.
    static func beschriftung(fuer a: PhoneSuchAuswahl, namen: [String: String], sprache: Locale = .current) -> String {
        var teile: [String] = []
        if let land = a.land { teile.append(Laendernamen.anzeigename(fuer: land, sprache: sprache)) }
        if let stadt = a.stadt { teile.append(stadt) }
        if let region = a.region { teile.append(region) }
        if let jahr = a.jahr { teile.append(String(jahr)) }
        if let zeitraum = a.zeitraum { teile.append(zeitraum.label) }
        teile += a.personen.map { namen[$0] ?? $0 }
        if let typ = a.typ { teile.append(Self.typ(typ)) }
        if a.nurFavoriten { teile.append(favoriten) }
        if !a.freitext.isEmpty { teile.append("“\(a.freitext)”") }
        return teile.joined(separator: " · ")
    }
    static let staedte = String(localized: "Cities")
    static let jahre = String(localized: "Years")
    static let personen = String(localized: "People")
    static let ladeKatalog = String(localized: "Loading places…")
    static let keineOrte = String(localized: "No Places")
    static let keineOrteText = String(localized: "None of your photos has location data.")
    static let nichtVerfuegbar = String(localized: "Places Unavailable")
    static let offline = String(localized: "Offline")
    static let offlineText = String(localized: "Places come from the server. Albums kept offline are under Albums.")
    /// Die Hinweiszeile über Übersicht und Ergebnis, solange offline (Spec,
    /// „Fehlerfälle"). Symbol aus `PhoneServerStatus`, wie in den Einstellungen.
    static let offlineHinweis = String(localized: "Offline · showing saved places")
    static let erneut = String(localized: "Try Again")
    static let keineFotos = String(localized: "No Photos")
    static let keineFotosText = String(localized: "There are no photos for this selection.")
    static let filterEntfernen = String(localized: "Remove Filters")

    /// „2025-11-24T08:10:23.000Z" → „Nov 2025" (Deutsch: „Nov. 2025"). Die Zahlen
    /// kommen direkt aus dem Text: `localDateTime` ist schon die Ortszeit des Fotos.
    /// Formatiert wird in UTC, damit keine Gerätezone den Monat verschiebt — dieselbe
    /// Überlegung wie in `PhotoFeedGrouping.titel`.
    static func monatJahr(_ zeitstempel: String?, sprache: Locale = .current) -> String? {
        guard let zeitstempel, zeitstempel.count >= 7,
              let jahr = Int(zeitstempel.prefix(4)),
              let monat = Int(zeitstempel.dropFirst(5).prefix(2)),
              (1...12).contains(monat)
        else { return nil }
        return PhotoFeedGrouping.formatiere(jahr: jahr, monat: monat, tag: 1, vorlage: "MMMy", sprache: sprache)
    }

    static func landUntertitel(_ land: PhoneOrtsLand, sprache: Locale = .current) -> String {
        let wann = monatJahr(land.zuletzt, sprache: sprache)
        // Ohne `asset.statistics` gibt es keine Zahl — dann nur der Monat.
        guard let anzahl = land.anzahl else { return wann ?? "" }
        let fotos = trefferZahl(anzahl)
        guard let wann else { return fotos }
        return "\(fotos) · \(wann)"
    }

    /// `land` ist der Servername; angezeigt wird der Name in Gerätesprache (`Laendernamen`).
    static func trefferArt(_ art: PhoneOrtsTrefferArt, land: String) -> String {
        let landname = Laendernamen.anzeigename(fuer: land, sprache: .current)
        return switch art {
        case .land: String(localized: "Country")
        case .stadt: String(localized: "City, \(landname)")
        case .region: String(localized: "Region, \(landname)")
        }
    }

    static func alleLaender(_ anzahl: Int) -> String {
        String(localized: "All \(anzahl) countries")
    }

    static func personenErmitteln(megabyte: Int) -> String {
        String(localized: "Find People (≈ \(megabyte) MB)")
    }

    /// Unter „Orte“: Gezählt wird nur, was Ortsdaten hat — ein Album mit 23 Fotos
    /// kann im Land 6 ergeben.
    static let nurMitOrt = String(localized: "Only photos with location data")

    static func trefferZahl(_ anzahl: Int) -> String {
        String(localized: "\(anzahl) photos")
    }
}
