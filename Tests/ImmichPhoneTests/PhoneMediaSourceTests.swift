import Foundation
import Testing
@testable import ImmichPhone

// Prüft `PhoneMediaSource` — die Entscheidung „lokale Datei oder Server?", die
// Einzelbild und Videoplayer künftig stellen.
//
// **Warum das überhaupt geprüft werden kann:** Die Wahl ist eine reine
// Funktion über drei Werte (lokale Datei, Fern-URL, API-Schlüssel). Kein
// `modelContext`, kein `FileManager`, kein Netz. Ob die Datei wirklich auf der
// Platte liegt, entscheidet der Aufrufer, bevor er hier hereingeht — genau wie
// der Mac es tut (`Sources/ImmichMac/Views/ImageDetailView.swift:169-177`:
// `FetchDescriptor` → `localFilePath` → `fileExists`, und erst das Ergebnis
// dieser Kette wird zur Quelle). Dieser Schnitt ist der Grund, warum hier
// überhaupt Tests stehen: Hätte der Typ selbst nachgesehen, ob es die Datei
// gibt, bräuchte jeder Test ein Dateisystem.
//
// **Der Punkt, um den es eigentlich geht:** Eine `file://`-URL darf keine
// `x-api-key`-Kopfzeile tragen. HTTP-Kopfzeilen an einer Datei-URL tun nichts —
// `AVURLAsset` ignoriert sie beim lokalen Lesen, und wer sie später im Code
// sieht, schließt daraus fälschlich, hier ginge etwas übers Netz. Der Typ macht
// das deshalb nicht bloß „richtig", sondern unmöglich: Die Kopfzeilen hängen an
// `.server`, und `.lokal` hat kein Feld dafür.
@Suite("PhoneMediaSource")
struct PhoneMediaSourceTests {

    private let lokal = URL(fileURLWithPath: "/var/mobile/Caches/ImmichMac/ab/cd/asset.heic")
    private let fern = URL(string: "https://immich.example/api/assets/abc/original")!

    @Test("Liegt eine lokale Datei vor, gewinnt sie")
    func lokaleDateiGewinnt() {
        let quelle = PhoneMediaSource.waehle(lokaleDatei: lokal, fernURL: fern, apiKey: "geheim")
        #expect(quelle == .lokal(lokal))
        #expect(quelle.url == lokal)
        #expect(quelle.istLokal)
    }

    @Test("Ohne lokale Datei wird die Fern-URL samt Kopfzeile gewählt")
    func ohneLokaleDatei() {
        let quelle = PhoneMediaSource.waehle(lokaleDatei: nil, fernURL: fern, apiKey: "geheim")
        #expect(quelle == .server(url: fern, apiKey: "geheim"))
        #expect(quelle.url == fern)
        #expect(quelle.kopfzeilen == ["x-api-key": "geheim"])
        #expect(quelle.istLokal == false)
    }

    @Test("Die lokale Quelle trägt keine x-api-key-Kopfzeile")
    func lokalOhneKopfzeilen() {
        let quelle = PhoneMediaSource.waehle(lokaleDatei: lokal, fernURL: fern, apiKey: "geheim")
        #expect(quelle.kopfzeilen.isEmpty)
        #expect(quelle.kopfzeilen["x-api-key"] == nil)
    }

    @Test("Die lokale Quelle gibt AVURLAsset keine Optionen mit")
    func lokalOhneAVOptionen() {
        // Die Stelle, an der der Fehler tatsächlich passieren würde: Der
        // bestehende Player baut `AVURLAsset(url:options:)` immer mit
        // `AVURLAssetHTTPHeaderFieldsKey` (`PhoneVideoPlayer.swift:147-149`).
        // Für eine Datei-URL muss dort `nil` stehen.
        let lokaleQuelle = PhoneMediaSource.waehle(lokaleDatei: lokal, fernURL: fern, apiKey: "geheim")
        #expect(lokaleQuelle.avAssetOptions == nil)

        let fernQuelle = PhoneMediaSource.waehle(lokaleDatei: nil, fernURL: fern, apiKey: "geheim")
        let kopfzeilen = fernQuelle.avAssetOptions?["AVURLAssetHTTPHeaderFieldsKey"] as? [String: String]
        #expect(kopfzeilen == ["x-api-key": "geheim"])
    }

    @Test("Zwei Quellen sind vergleichbar")
    func vergleichbar() {
        #expect(PhoneMediaSource.lokal(lokal) == PhoneMediaSource.lokal(lokal))
        #expect(PhoneMediaSource.lokal(lokal) != PhoneMediaSource.lokal(URL(fileURLWithPath: "/anders.heic")))
        #expect(PhoneMediaSource.lokal(lokal) != PhoneMediaSource.server(url: fern, apiKey: "geheim"))
        #expect(
            PhoneMediaSource.server(url: fern, apiKey: "geheim")
                != PhoneMediaSource.server(url: fern, apiKey: "anders")
        )
    }

    @Test("Eine Netz-URL als lokale Datei zählt nicht als lokal")
    func nurDateiURLsSindLokal() {
        // Kein erfundener Fall zur Zierde: Fiele eine `https`-URL hier durch
        // als „lokal", verlöre die Anfrage stillschweigend ihren
        // API-Schlüssel — das Bild bliebe leer, ohne dass irgendwo ein Fehler
        // stünde. Lieber der Server-Pfad, der nachweislich funktioniert.
        let angeblichLokal = URL(string: "https://immich.example/nicht-lokal.heic")!
        let quelle = PhoneMediaSource.waehle(lokaleDatei: angeblichLokal, fernURL: fern, apiKey: "geheim")
        #expect(quelle == .server(url: fern, apiKey: "geheim"))
    }

    @Test("Ein leerer API-Schlüssel setzt die Kopfzeile trotzdem")
    func leererSchluessel() {
        // Der Fall ist heute unerreichbar: `OnboardingKeySchritt` sperrt den
        // Verbinden-Knopf bei leerem Schlüssel und übergibt ihn getrimmt,
        // `ImmichAPIClient.apiKey` ist ein `let` daraus. Festgehalten wird hier
        // trotzdem, dass `waehle` den Schlüssel unverändert durchreicht statt
        // bei leerem Wert die Kopfzeile wegzulassen — sonst hinge das Verhalten
        // an einer stillen Sonderbehandlung, die niemand erwartet.
        //
        // Die frühere Begründung („eine leere Kopfzeile ergibt einen 401, den
        // man im Log sieht") stand hier zu Unrecht: Immich antwortet auf einen
        // leeren wie auf einen fehlenden `x-api-key` mit 401. Der Unterschied
        // liegt beim Codeleser, nicht im Protokoll.
        let quelle = PhoneMediaSource.waehle(lokaleDatei: nil, fernURL: fern, apiKey: "")
        #expect(quelle.kopfzeilen == ["x-api-key": ""])
    }

    @Test("Die Herkunft steht als Wort fürs Protokoll bereit")
    func protokollName() {
        #expect(PhoneMediaSource.lokal(lokal).protokollName == "Platte")
        #expect(PhoneMediaSource.server(url: fern, apiKey: "geheim").protokollName == "Server")
    }
}
