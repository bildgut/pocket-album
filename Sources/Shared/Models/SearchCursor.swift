import Foundation

/// Übersetzt Seitennummern in den Cursor der strukturierten Suche (Immich v3.2.0).
///
/// Der Cursor ist laut API opak, tatsächlich aber ein verpackter Offset:
/// base64url(`{"offset":N}`) ohne Auffüllzeichen (`server/src/utils/search-cursor.ts`).
/// Die Sync-Pfade blättern seit jeher über Seitennummern — die EXIF-Reparatur speichert
/// die Seite sogar zum Fortsetzen und rechnet mit „Seite ≥ Startseite". Statt diese
/// Logik auf opake Zeichenketten umzubauen, rechnet diese Stelle die Seite um.
///
/// Damit das nicht still an einem geänderten Format hängt, prüft
/// `ImmichAPIClient.searchAssets(page:size:)` jede Antwort: Der gelieferte
/// `nextCursor` muss genau ``forOffset(_:)`` der nächsten Seite sein, sonst bricht der
/// Abruf ab. Einen unverständlichen Cursor lehnt der Server außerdem mit 400 ab.
enum SearchCursor {

    static func forOffset(_ offset: Int) -> String {
        let json = #"{"offset":\#(offset)}"#
        return Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Cursor für die 1-basierte Seite `page` — `nil` für die erste.
    static func forPage(_ page: Int, size: Int) -> String? {
        page > 1 ? forOffset((page - 1) * size) : nil
    }

    /// Umkehrung, für Tests und Mocks — `nil` bei allem, was kein solcher Cursor ist.
    static func offset(of cursor: String) -> Int? {
        var base64 = cursor.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let offset = object["offset"] as? Int else { return nil }
        return offset
    }
}
