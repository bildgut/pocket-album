import Foundation
import MapKit

// MARK: - AddressMatch

struct AddressMatch: Identifiable, Equatable {
    let id: String
    /// Kurzform für den Chip, z. B. „Kastanienallee".
    let name: String
    /// Vollständige Zeile für den Vorschlag, z. B. „Kastanienallee, 10119 Berlin".
    let detail: String
    let latitude: Double
    let longitude: Double
    /// Land laut Karte, z. B. „Italien". `nil`, wenn der Treffer keins nennt.
    let country: String?
    /// ISO 3166-1 alpha-2. Der einzige verlässliche Weg, das Land eines Treffers
    /// mit einer anderen Quelle zu vergleichen — Landesnamen kommen je nach
    /// Sprache anders zurück.
    let countryCode: String?
}

// MARK: - AddressSearchService

/// Wandelt eine getippte Adresse in Koordinaten — der einzige Weg zu einer
/// Straßensuche.
///
/// Immich reverse-geokodiert nur bis zur Stadt: `ExifInfo` kennt `city`, `state` und
/// `country`, eine Straße steht in keinem Feld und lässt sich serverseitig auch nicht
/// erfragen. Die Koordinaten liegen dagegen pro Foto im Grid-Index. Also wird nicht
/// jedes Foto geokodiert (155 000 Anfragen), sondern einmal die *Eingabe* — und danach
/// lokal nach Entfernung gefiltert.
///
/// `MKLocalSearch` statt `CLGeocoder`: Es ist für freie Suchanfragen inklusive Straßen
/// und Orten gebaut und verträgt Teileingaben. Der bestehende ``GeocoderCache`` taugt
/// dafür nicht — der rundet bewusst auf 1° (rund 111 km) und liest nur das Land.
actor AddressSearchService {

    static let shared = AddressSearchService()

    /// Gleiche Eingabe, gleiche Antwort — beim Tippen läuft dieselbe Anfrage sonst
    /// mehrfach, sobald der Nutzer ein Zeichen löscht und neu schreibt.
    private var cache = [String: [AddressMatch]]()

    /// Sucht Orte und Adressen zur Eingabe.
    /// - Returns: Höchstens `limit` Treffer, leer wenn nichts passt oder kein Netz da ist.
    func search(_ query: String, limit: Int = 3) async -> [AddressMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return [] }
        if let cached = cache[trimmed] { return cached }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        request.resultTypes = [.address, .pointOfInterest]

        do {
            let response = try await MKLocalSearch(request: request).start()
            let matches = response.mapItems.prefix(limit).enumerated().compactMap { index, item -> AddressMatch? in
                let coordinate = item.location.coordinate
                guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
                let adresse = item.addressRepresentations
                let name = item.name ?? item.address?.shortAddress ?? trimmed
                return AddressMatch(
                    id: "addr-\(index)-\(coordinate.latitude),\(coordinate.longitude)",
                    name: name,
                    detail: Self.describe(adresse, fallback: name),
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    country: adresse?.regionName,
                    countryCode: adresse?.region?.identifier
                )
            }
            cache[trimmed] = matches
            return matches
        } catch {
            // Kein Netz, keine Treffer, abgebrochen — alles derselbe Fall: Die
            // Umkreis-Zeile erscheint dann einfach nicht. Ein Fehlerbanner wäre hier
            // unangemessen, weil bei jedem Tastendruck gesucht wird.
            AppLogger.ui.debug("Adresssuche für \(trimmed) ohne Ergebnis: \(error.localizedDescription)")
            return []
        }
    }

    /// „Kastanienallee, 10119 Berlin" — einzeilig, ohne das eigene Land.
    ///
    /// Seit macOS 26 gibt es die Einzelteile (`thoroughfare`, `postalCode`, …) nur
    /// noch am veralteten `placemark`; MapKit formatiert selbst. Gemessen am
    /// 19.09.2026 gegen das alte Zusammensetzen: gleiche Straße, PLZ und Stadt, dazu
    /// teils der Stadtteil („Kastanienallee 12, Prenzlauer Berg, 10435 Berlin") und
    /// bei Orten im Ausland das Land („…, 00184 Roma, Italia"). `includingRegion:
    /// false` lässt nur das Land des Nutzers weg, nicht fremde Länder.
    private static func describe(_ adresse: MKAddressRepresentations?, fallback: String) -> String {
        let zeile = adresse?.fullAddress(includingRegion: false, singleLine: true)
        if let zeile, !zeile.isEmpty { return zeile }
        return adresse?.regionName ?? fallback
    }
}
