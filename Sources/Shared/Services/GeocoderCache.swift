import Foundation
import CoreLocation
import MapKit

/// App-weiter Geocoder-Cache mit Koordinaten-Rasterung und Rate-Limiting.
///
/// **Strategie gegen Throttling:**
/// - Koordinaten werden auf 1° gerundet (≈ 111 km) → viele Alben aus derselben Region
///   landen im selben Cache-Bucket und kosten exakt **einen** Request.
/// - Maximal **1 Request pro Sekunde** (seriell via Actor).
/// - Bereits aufgelöste Koordinaten werden für die gesamte App-Session gecacht (in-memory).
///   Ein `nil`-Ergebnis (kein Land ermittelbar) wird ebenfalls gecacht, damit kein
///   Retry-Storm entsteht — **aber nur, wenn es eine Antwort war.** Eine Störung
///   (Netzfehler, Drosselung) bleibt ungemerkt, sonst gälte eine ganze 1°-Zelle für
///   die restliche Sitzung als „kein Land". Siehe `throttledGeocode`.
actor GeocoderCache {

    static let shared = GeocoderCache()
    private init() {}

    // MARK: - Cache

    /// Schlüssel: gerundete (lat, lon) in 1°-Schritten → Land-Name oder nil
    private var cache: [CoordKey: String?] = [:]

    /// Laufende Requests (damit parallele Anfragen für denselben Key nicht doppelt feuern)
    private var inFlight: [CoordKey: Task<String?, Never>] = [:]

    /// Zeitstempel des letzten echten Geocoder-Calls
    private var lastRequestAt: Date = .distantPast

    /// Mindestabstand zwischen zwei Geocoder-Requests
    private static let minInterval: TimeInterval = 1.1

    // MARK: - Public

    /// Gibt das Land für `location` zurück. Trifft den Geocoder höchstens einmal
    /// pro 1°×1°-Gitterzelle und wartet bei Bedarf das Rate-Limit ab.
    func country(for location: CLLocation) async -> String? {
        let key = CoordKey(location: location)

        // Cache-Hit
        if let cached = cache[key] { return cached }

        // Laufender Request für diesen Key → warten statt doppelt feuern
        if let task = inFlight[key] { return await task.value }

        // Neuen Request starten
        let task = Task<String?, Never> {
            await throttledGeocode(key: key, location: location)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight.removeValue(forKey: key)
        return result
    }

    // MARK: - Private

    private func throttledGeocode(key: CoordKey, location: CLLocation) async -> String? {
        // Rate-Limit: Slot sofort reservieren, bevor wir den Actor-Kontext via sleep verlassen.
        // Dadurch sieht der nächste wartende Task bereits das vorausgeschriebene lastRequestAt
        // und wartet entsprechend länger – verhindert Burst-Flooding.
        let now = Date()
        let fireAt = max(now, lastRequestAt.addingTimeInterval(Self.minInterval))
        lastRequestAt = fireAt          // Slot reservieren
        let wait = fireAt.timeIntervalSince(now)
        if wait > 0 {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }

        // `MKReverseGeocodingRequest` statt des veralteten `CLGeocoder`. Gemessen am
        // 19.09.2026 an acht Orten (u. a. Grenze Basel, Bodensee, offener Atlantik):
        // dasselbe Land in derselben Sprache, auf dem Meer bei beiden `nil` ohne Fehler.
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        let result: String?
        let error: Error?
        do {
            let items = try await request.mapItems
            result = items.first?.addressRepresentations?.regionName
            error = nil
        } catch let fehler {
            result = nil
            error = fehler
        }

        // Nur eine **Antwort** wird gemerkt, keine Störung.
        //
        // Der Kopfkommentar begründet das Cachen von `nil` mit „kein Land
        // ermittelbar" — dem legitimen Fall (offenes Meer, unkartiertes Gebiet).
        // Gecacht wurde bisher aber auch der Fehlerfall: Bei einem Netzaussetzer oder
        // dem Drosseln durch den Geocoder kam ebenfalls `nil` heraus, und die
        // 1°-Zelle galt für die ganze Sitzung als „kein Land". Betroffen sind alle
        // Alben derselben Region — ein Aussetzer verdirbt sie gemeinsam.
        //
        // `placemarkNotFound` ist die Antwort „hier ist nichts" und wird deshalb
        // wie ein Erfolg behandelt. Alles andere bleibt ungemerkt und darf erneut
        // gefragt werden; gegen einen Sturm schützen weiterhin das Rate-Limit oben
        // und die `inFlight`-Bündelung.
        let istAntwort = error == nil || (error as? MKError)?.code == .placemarkNotFound
        if istAntwort {
            cache[key] = result
        } else if let error {
            AppLogger.app.warning(
                "GeocoderCache: Geocoding fehlgeschlagen, Ergebnis nicht gemerkt: \(error.localizedDescription)"
            )
        }
        return result
    }
}

// MARK: - CoordKey

/// Cache-Schlüssel: Koordinaten auf 1° gerundet (≈ 111 km Rasterung).
private struct CoordKey: Hashable {
    let lat: Int
    let lon: Int

    init(location: CLLocation) {
        lat = Int(location.coordinate.latitude.rounded())
        lon = Int(location.coordinate.longitude.rounded())
    }
}
