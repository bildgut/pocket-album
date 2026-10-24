import Foundation

/// Was ``URLSessionTaskMetrics`` über eine einzelne Datei verrät — getrennt nach
/// Verbindungsaufbau, Warten auf das erste Byte und Übertragung. Daran lässt sich
/// unterscheiden, ob eine Strecke langsam *anfängt* (Aufbau, Server) oder langsam
/// *überträgt* (Durchsatz, Paketverlust).
struct OfflineTransferMetrik: Sendable, Equatable {
    /// Von der gesendeten Anfrage bis zum ersten Antwortbyte, Sekunden.
    var ttfbSek: Double?
    /// DNS + TCP + TLS; `nil`, wenn eine bestehende Verbindung wiederverwendet wurde.
    var verbindungSek: Double?
    var wiederverwendet: Bool?
    /// `h2`, `http/1.1`, `h3` …
    var protokoll: String?
    var bytes: Int64 = 0
    /// Netz galt als teuer oder eingeschränkt.
    var teuer: Bool?
    var mobilfunk: Bool?
}

/// Das Ergebnis einer Datei im Lauf — erfolgreich (`fehler == nil`) oder nicht.
struct OfflineDateiMessung: Sendable, Equatable {
    var gesamtSek: Double
    var transfer: OfflineTransferMetrik?
    /// Wie viele Anläufe die Datei brauchte (mindestens 1).
    var versuche: Int
    /// Fehlerschlüssel (`URLError -1001`, `HTTP 404`); `nil` = geladen.
    var fehler: String?
    var zeitueberschreitung: Bool

    /// Schlüssel und Zeitüberschreitung für einen Fehler. Der Schlüssel enthält den
    /// Code, nicht `localizedDescription` — die verschluckt bei Nuke- und
    /// URL-Fehlern das Entscheidende (siehe `ThumbnailFehlerDrossel`).
    static func schluessel(fuer fehler: Error) -> (text: String, zeitueberschreitung: Bool) {
        if let url = fehler as? URLError {
            return ("URLError \(url.code.rawValue)", url.code == .timedOut)
        }
        if case APIError.httpError(let code) = fehler {
            return ("HTTP \(code)", code == 408)
        }
        return (String(describing: type(of: fehler)), false)
    }
}

/// Sammelt die Messungen eines Laufs und fasst sie zusammen. Reiner Wertetyp.
struct OfflineMessSammler: Sendable, Equatable {
    private var gemessen: [OfflineDateiMessung] = []
    private var fehlerArten: [String: Int] = [:]
    private var proMinute: [Int] = []
    private var zeitueberschreitungen = 0

    mutating func nimm(_ messung: OfflineDateiMessung, minute: Int) {
        if let fehler = messung.fehler {
            fehlerArten[fehler, default: 0] += 1
        } else {
            gemessen.append(messung)
            let index = max(0, min(minute, 600))
            if proMinute.count <= index {
                proMinute.append(contentsOf: Array(repeating: 0, count: index + 1 - proMinute.count))
            }
            proMinute[index] += 1
        }
        if messung.zeitueberschreitung { zeitueberschreitungen += 1 }
    }

    var isEmpty: Bool { gemessen.isEmpty && fehlerArten.isEmpty }

    func zusammenfassung(ladeSek: Double) -> OfflineLaufEintrag.Messung {
        let dauern = gemessen.map(\.gesamtSek)
        let transfers = gemessen.compactMap(\.transfer)
        let bytes = transfers.reduce(Int64(0)) { $0 + $1.bytes }
        var protokolle: [String: Int] = [:]
        for p in transfers.compactMap(\.protokoll) { protokolle[p, default: 0] += 1 }
        return OfflineLaufEintrag.Messung(
            dateienOk: gemessen.count,
            bytes: bytes,
            durchsatzKBs: ladeSek > 0 && bytes > 0 ? Double(bytes) / 1024 / ladeSek : nil,
            gesamtMedian: Self.perzentil(dauern, 0.5),
            gesamtP90: Self.perzentil(dauern, 0.9),
            gesamtMax: dauern.max(),
            ueber30s: dauern.filter { $0 > 30 }.count,
            ttfbMedian: Self.perzentil(transfers.compactMap(\.ttfbSek), 0.5),
            ttfbP90: Self.perzentil(transfers.compactMap(\.ttfbSek), 0.9),
            verbindungMedian: Self.perzentil(transfers.compactMap(\.verbindungSek), 0.5),
            neueVerbindungen: transfers.filter { $0.wiederverwendet == false }.count,
            wiederverwendet: transfers.filter { $0.wiederverwendet == true }.count,
            protokolle: protokolle,
            wiederholte: gemessen.filter { $0.versuche > 1 }.count,
            zeitueberschreitungen: zeitueberschreitungen,
            fehlerArten: fehlerArten,
            proMinute: proMinute,
            teuerDateien: transfers.filter { $0.teuer == true }.count,
            mobilfunkDateien: transfers.filter { $0.mobilfunk == true }.count
        )
    }

    /// Nächster-Rang-Perzentil; `nil` bei leerer Liste.
    static func perzentil(_ werte: [Double], _ p: Double) -> Double? {
        let sauber = werte.filter(\.isFinite).sorted()
        guard !sauber.isEmpty else { return nil }
        let rang = Int((p * Double(sauber.count)).rounded(.up)) - 1
        return sauber[max(0, min(rang, sauber.count - 1))]
    }
}

/// Zustand des Geräts, der Netz und Hintergrundzeit beeinflusst.
enum OfflineGeraeteZustand {
    static func text() -> String {
        let info = ProcessInfo.processInfo
        let waerme: String
        switch info.thermalState {
        case .nominal: waerme = "kühl"
        case .fair: waerme = "warm"
        case .serious: waerme = "heiß"
        case .critical: waerme = "kritisch"
        @unknown default: waerme = "?"
        }
        var teile = ["Temperatur \(waerme)", info.isLowPowerModeEnabled ? "Stromsparmodus AN" : "Stromsparmodus aus"]
        if let frei = try? URL.documentsDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage {
            teile.append(String(format: "frei %.1f GB", Double(frei) / 1_000_000_000))
        }
        return teile.joined(separator: " · ")
    }
}
