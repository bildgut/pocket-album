import Foundation

/// Woher ein Asset im Einzelbild und im Player kommt: von der Platte oder vom
/// Server. Reiner Wertetyp ohne Netz, Dateisystem und `modelContext` — deshalb
/// prüfbar, siehe `Tests/ImmichPhoneTests/PhoneMediaSourceTests.swift`.
///
/// **Wozu.** Ein offline gehaltenes Album lädt seine Originale beim Pinnen über
/// `LocalFileCacheManager.downloadOriginalToCache` auf das Gerät, aber bisher
/// fragt auf dem Telefon niemand danach: Das Standbild geht über `LazyImage`
/// gegen `thumbnailURL(size: .preview)`, das Video streamt über `playbackURL`.
/// Dieser Typ ist die eine Stelle, an der die Wahl getroffen wird, damit beide
/// Ansichten sie gleich treffen.
///
/// **Warum ein Enum und keine Struktur mit `url` + `kopfzeilen`.** Der Fehler,
/// den es zu verhindern gilt, ist eine `x-api-key`-Kopfzeile an einer
/// `file://`-URL. Die tut nichts — `AVURLAsset` und `URLSession` ignorieren
/// HTTP-Kopfzeilen beim Lesen einer Datei —, aber wer sie später im Code sieht,
/// schließt daraus, hier ginge etwas übers Netz, und sucht einen Fehler an der
/// falschen Stelle. Deshalb hängen die Kopfzeilen am Fall `.server`, und `.lokal`
/// hat kein Feld dafür.
///
/// Zur Genauigkeit: Das macht die falsche Kombination nicht *unmöglich* — nichts
/// hindert einen Aufrufer daran, `.server(url:)` von Hand eine `file://`-URL zu
/// geben. Die Zusage liegt bei ``waehle(lokaleDatei:fernURL:apiKey:)``, nicht am
/// Typ. Wer eine Quelle anders als über `waehle` baut, umgeht sie.
///
/// **Wer prüft, ob es die Datei gibt.** Nicht dieser Typ. Der Aufrufer bringt
/// die lokale URL bereits geprüft mit, genau wie der Mac es tut
/// (`Sources/ImmichMac/Views/ImageDetailView.swift:169-177`: `FetchDescriptor`
/// über `CachedAsset` → `localFilePath` → `FileManager.fileExists`, und erst
/// dessen Ergebnis wird zur Quelle). Dieser Schnitt hält die Wahl rein und
/// damit ohne Dateisystem prüfbar.
enum PhoneMediaSource: Equatable, Sendable {

    /// Eine Datei auf dem Gerät. Ausdrücklich ohne Kopfzeilen.
    case lokal(URL)

    /// Die Server-URL samt API-Schlüssel für die `x-api-key`-Kopfzeile.
    case server(url: URL, apiKey: String)

    /// Die Wahl: Eine vorhandene lokale Datei gewinnt, sonst der Server.
    ///
    /// `lokaleDatei` muss eine `file://`-URL sein. Käme eine Netz-URL herein,
    /// verlöre die Anfrage stillschweigend ihren API-Schlüssel und das Bild
    /// bliebe leer, ohne dass irgendwo ein Fehler stünde — in dem Fall lieber
    /// der Server-Pfad, der nachweislich funktioniert.
    static func waehle(lokaleDatei: URL?, fernURL: URL, apiKey: String) -> PhoneMediaSource {
        if let lokaleDatei, lokaleDatei.isFileURL {
            return .lokal(lokaleDatei)
        }
        return .server(url: fernURL, apiKey: apiKey)
    }

    /// Die zu ladende URL, unabhängig von der Herkunft.
    var url: URL {
        switch self {
        case .lokal(let url): url
        case .server(let url, _): url
        }
    }

    /// HTTP-Kopfzeilen für die Anfrage — bei `.lokal` leer, und zwar nicht aus
    /// Versehen (siehe die Begründung oben am Typ).
    var kopfzeilen: [String: String] {
        switch self {
        case .lokal: [:]
        case .server(_, let apiKey): ["x-api-key": apiKey]
        }
    }

    /// Das `options`-Wörterbuch für `AVURLAsset(url:options:)` — `nil` für eine
    /// lokale Datei. Genau hier passiert der Fehler sonst: Der bestehende
    /// Player baut die Optionen bedingungslos
    /// (`Sources/ImmichPhone/Views/PhoneVideoPlayer.swift:147-149`).
    var avAssetOptions: [String: Any]? {
        let kopfzeilen = kopfzeilen
        guard !kopfzeilen.isEmpty else { return nil }
        return ["AVURLAssetHTTPHeaderFieldsKey": kopfzeilen]
    }

    var istLokal: Bool {
        if case .lokal = self { return true }
        return false
    }

    /// Ein Wort für die Protokollzeile, die belegt, welche Quelle gewählt wurde.
    var protokollName: String {
        istLokal ? "Platte" : "Server"
    }
}
