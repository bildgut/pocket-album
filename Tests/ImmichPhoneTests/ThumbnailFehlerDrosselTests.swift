import Foundation
import Nuke
import Testing
@testable import ImmichPhone

// Zwei Dinge werden hier festgehalten:
//
// 1. Die **Messung**, die eine Fehldiagnose aufgelöst hat: „Nuke.ImagePipeline.Error
//    error 0" ist `dataLoadingFailed`, nicht `dataMissingInCache`. Die Zahl in der
//    Meldung ist das ABI-Etikett der Aufzählung (Fälle mit Nutzlast zuerst), nicht
//    der Index in der Quelldatei. Sortiert ein Nuke-Update die Fälle um, fällt das
//    hier auf — und nicht erst wieder in einem Protokollbogen vom Gerät.
// 2. Die Drossel selbst: reiner Wertetyp, die Uhr kommt als Parameter.

@Suite("ThumbnailFehlerUrsache")
struct ThumbnailFehlerUrsacheTests {

    @Test("Nukes Fehlercodes folgen der ABI-Reihenfolge, nicht der Quelldatei")
    func abiEtiketten() {
        #expect((ImagePipeline.Error.dataLoadingFailed(error: URLError(.timedOut)) as NSError).code == 0)
        #expect((ImagePipeline.Error.dataMissingInCache as NSError).code == 4)
        #expect((ImagePipeline.Error.dataIsEmpty as NSError).code == 5)
    }

    @Test("localizedDescription verschweigt die Ursache — description nennt sie")
    func localizedDescriptionIstNutzlos() {
        let fehler = ImagePipeline.Error.dataLoadingFailed(error: DataLoader.Error.statusCodeUnacceptable(404))
        // Genau diese Zeile stand 250-mal im Protokoll des Geräts.
        #expect(fehler.localizedDescription.contains("error 0"))
        #expect(!fehler.localizedDescription.contains("404"))
        #expect(ThumbnailFehlerUrsache.einzelheiten(fehler).contains("404"))
    }

    @Test("HTTP-Status wird ausgepackt")
    func httpStatus() {
        let fehler = ImagePipeline.Error.dataLoadingFailed(error: DataLoader.Error.statusCodeUnacceptable(404))
        #expect(ThumbnailFehlerUrsache.schluessel(fehler) == "HTTP 404")
    }

    @Test("Netzfehler behalten ihren URLError-Code")
    func netzfehler() {
        let fehler = ImagePipeline.Error.dataLoadingFailed(error: URLError(.notConnectedToInternet))
        #expect(ThumbnailFehlerUrsache.schluessel(fehler) == "URLError -1009")
    }

    @Test("Fälle ohne Nutzlast bekommen einen sprechenden Schlüssel")
    func ohneNutzlast() {
        #expect(ThumbnailFehlerUrsache.schluessel(ImagePipeline.Error.dataIsEmpty) == "Nuke: leere Antwort")
        #expect(ThumbnailFehlerUrsache.schluessel(ImagePipeline.Error.dataMissingInCache) == "Nuke: nicht im Cache")
    }

    @Test("Jeder Verbindungszustand hat eine eigene Kurzform fürs Protokoll")
    func zustandsKurzformen() {
        let zustaende: [ConnectionState] = [
            .disconnected, .connecting, .connected(version: "1.2.3"), .offline, .error("kaputt"),
        ]
        let kurzformen = zustaende.map(\.protokollKurzform)
        #expect(Set(kurzformen).count == zustaende.count)
        #expect(kurzformen.allSatisfy { !$0.isEmpty })
        // Die Serverversion und die Fehlermeldung gehören nicht in jede Zeile —
        // die Kurzform ist eine Kurzform.
        #expect(!kurzformen.contains { $0.contains("1.2.3") || $0.contains("kaputt") })
    }

    @Test("Fremde Fehler fallen auf Domäne und Code zurück")
    func fremderFehler() {
        let fehler = NSError(domain: "Irgendwas", code: 7)
        #expect(ThumbnailFehlerUrsache.schluessel(fehler) == "Irgendwas 7")
    }
}

@Suite("ThumbnailFehlerDrossel")
struct ThumbnailFehlerDrosselTests {

    private let start = Date(timeIntervalSince1970: 1_757_000_000)

    @Test("Die erste Meldung je Ursache kommt durch")
    func ersteJeUrsache() {
        var drossel = ThumbnailFehlerDrossel()
        #expect(drossel.melde(assetId: "a", ursache: "HTTP 404", jetzt: start) == .erste(ursache: "HTTP 404"))
        #expect(drossel.melde(assetId: "b", ursache: "HTTP 404", jetzt: start) == .unterdrueckt)
        #expect(drossel.melde(assetId: "c", ursache: "HTTP 500", jetzt: start) == .erste(ursache: "HTTP 500"))
    }

    @Test("Nach der Schwelle folgt eine Sammelmeldung, danach wieder Stille")
    func sammelmeldungNachSchwelle() {
        var drossel = ThumbnailFehlerDrossel()
        drossel.sammelSchwelle = 5
        _ = drossel.melde(assetId: "a-0", ursache: "HTTP 404", jetzt: start)  // .erste
        for i in 1..<5 {
            #expect(drossel.melde(assetId: "a-\(i)", ursache: "HTTP 404", jetzt: start) == .unterdrueckt)
        }
        let ausgabe = drossel.melde(assetId: "a-5", ursache: "HTTP 404", jetzt: start.addingTimeInterval(12))
        #expect(ausgabe == .sammel(.init(
            fehlschlaege: 6, assets: 6, haeufigsteUrsache: "HTTP 404", ursachenAnzahl: 1, sekunden: 12
        )))
        // Der Abschnitt beginnt von vorn: der nächste Fehlschlag zählt wieder ab eins.
        #expect(drossel.melde(assetId: "a-6", ursache: "HTTP 404", jetzt: start.addingTimeInterval(13)) == .unterdrueckt)
    }

    @Test("Auch ohne Schwelle meldet der Abschnitt sich nach Ablauf der Zeit")
    func sammelmeldungNachZeit() {
        var drossel = ThumbnailFehlerDrossel()
        drossel.sammelSchwelle = 1000
        drossel.fensterLaenge = 60
        _ = drossel.melde(assetId: "a", ursache: "HTTP 404", jetzt: start)
        #expect(drossel.melde(assetId: "b", ursache: "HTTP 404", jetzt: start.addingTimeInterval(59)) == .unterdrueckt)
        let ausgabe = drossel.melde(assetId: "c", ursache: "HTTP 404", jetzt: start.addingTimeInterval(60))
        #expect(ausgabe == .sammel(.init(
            fehlschlaege: 3, assets: 3, haeufigsteUrsache: "HTTP 404", ursachenAnzahl: 1, sekunden: 60
        )))
    }

    @Test("Dasselbe Asset mehrfach zählt als ein Asset, aber als viele Fehlschläge")
    func gleichesAssetMehrfach() {
        var drossel = ThumbnailFehlerDrossel()
        drossel.sammelSchwelle = 3
        _ = drossel.melde(assetId: "immer-dasselbe", ursache: "HTTP 404", jetzt: start)
        _ = drossel.melde(assetId: "immer-dasselbe", ursache: "HTTP 404", jetzt: start)
        _ = drossel.melde(assetId: "immer-dasselbe", ursache: "HTTP 404", jetzt: start)
        let ausgabe = drossel.melde(assetId: "immer-dasselbe", ursache: "HTTP 404", jetzt: start)
        #expect(ausgabe == .sammel(.init(
            fehlschlaege: 4, assets: 1, haeufigsteUrsache: "HTTP 404", ursachenAnzahl: 1, sekunden: 0
        )))
    }

    @Test("Die häufigste Ursache gewinnt, bei Gleichstand der Name")
    func haeufigsteUrsache() {
        var drossel = ThumbnailFehlerDrossel()
        drossel.sammelSchwelle = 4
        _ = drossel.melde(assetId: "a", ursache: "HTTP 404", jetzt: start)     // .erste
        _ = drossel.melde(assetId: "b", ursache: "URLError -1001", jetzt: start) // .erste
        _ = drossel.melde(assetId: "c", ursache: "URLError -1001", jetzt: start)
        _ = drossel.melde(assetId: "d", ursache: "URLError -1001", jetzt: start)
        _ = drossel.melde(assetId: "e", ursache: "URLError -1001", jetzt: start)
        let ausgabe = drossel.melde(assetId: "f", ursache: "HTTP 404", jetzt: start)
        #expect(ausgabe == .sammel(.init(
            fehlschlaege: 6, assets: 6, haeufigsteUrsache: "URLError -1001", ursachenAnzahl: 2, sekunden: 0
        )))
    }

    @Test("Nach der Ursachengrenze gibt es keine Einzelmeldungen mehr")
    func ursachenGrenze() {
        var drossel = ThumbnailFehlerDrossel()
        drossel.ursachenGrenze = 2
        drossel.sammelSchwelle = 1000
        #expect(drossel.melde(assetId: "a", ursache: "HTTP 400", jetzt: start) == .erste(ursache: "HTTP 400"))
        #expect(drossel.melde(assetId: "b", ursache: "HTTP 401", jetzt: start) == .erste(ursache: "HTTP 401"))
        #expect(drossel.melde(assetId: "c", ursache: "HTTP 402", jetzt: start) == .unterdrueckt)
    }

    @Test("250 Fehlschläge in 10 Minuten ergeben eine zweistellige Zahl an Zeilen")
    func derEchteFall() {
        var drossel = ThumbnailFehlerDrossel()
        var zeilen = 0
        for i in 0..<250 {
            // Ein Fehlschlag alle 2,4 s — so verteilt lag der Protokollbogen vor.
            let ausgabe = drossel.melde(
                assetId: "asset-\(i)", ursache: "HTTP 404", jetzt: start.addingTimeInterval(Double(i) * 2.4)
            )
            if ausgabe != .unterdrueckt { zeilen += 1 }
        }
        // Eine Einzelmeldung plus neun Sammelmeldungen — vorher: 250 Zeilen.
        #expect(zeilen == 10)
    }
}
