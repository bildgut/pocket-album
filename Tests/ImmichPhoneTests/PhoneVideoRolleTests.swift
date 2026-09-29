import Testing
@testable import ImmichPhone

/// Prüft die beiden Fragen des Video-Zweitbildschirms, die sich ohne
/// Zweitbildschirm beantworten lassen: welche Ansicht auf dem Telefon gilt,
/// und was beim Wechsel mit dem laufenden `AVPlayer` geschieht.
///
/// Der Player selbst, die `AVPlayerLayer` und die Szene bleiben ungeprüft —
/// dafür bräuchte es einen echten Apple TV, den weder dieser Testlauf noch der
/// Simulator herstellen kann. Genau deshalb steht die Logik in einem Wertetyp
/// und nicht im Body; dieselbe Begründung wie bei `PhoneDiashowRolleTests`.
@Suite("PhoneVideoRolle")
struct PhoneVideoRolleTests {

    @Test("Ohne Zweitbildschirm bleibt das Video auf dem Telefon")
    func ohneZweitbildschirmAufDemTelefon() {
        #expect(PhoneVideoRolle.fuer(zweitbildschirmAngeschlossen: false) == .aufDemTelefon)
    }

    @Test("Mit Zweitbildschirm wandert das Video auf die Bühne")
    func mitZweitbildschirmAufDieBuehne() {
        #expect(PhoneVideoRolle.fuer(zweitbildschirmAngeschlossen: true) == .aufDerBuehne)
    }

    /// Der Kern der Weiche: Das Bild läuft an genau einer Stelle, nie an
    /// beiden. Ein zweiter Dekodierweg fürs selbe Video wäre nicht nur
    /// verschwendet — er ließe die Bedienung keinen Platz.
    @Test("Videobild und Bedienung schließen einander aus")
    func bildUndBedienungSchliessenSichAus() {
        #expect(PhoneVideoRolle.aufDemTelefon.zeigtVideoAufTelefon)
        #expect(!PhoneVideoRolle.aufDemTelefon.zeigtBedienungAufTelefon)

        #expect(!PhoneVideoRolle.aufDerBuehne.zeigtVideoAufTelefon)
        #expect(PhoneVideoRolle.aufDerBuehne.zeigtBedienungAufTelefon)
    }

    @Test("Die Bühne wird nur gespeist, wenn eine hängt")
    func buehneNurMitZweitbildschirm() {
        #expect(!PhoneVideoRolle.aufDemTelefon.speistBuehne)
        #expect(PhoneVideoRolle.aufDerBuehne.speistBuehne)
    }

    // MARK: - Der Übergang

    @Test("Ohne Player gibt es nichts zu übergeben")
    func ohneSpielerKeinSchritt() {
        #expect(
            PhoneVideoRolle.schritt(von: .aufDemTelefon, nach: .aufDerBuehne, spielerVorhanden: false)
                == .nichts
        )
        #expect(
            PhoneVideoRolle.schritt(von: .aufDerBuehne, nach: .aufDemTelefon, spielerVorhanden: false)
                == .nichts
        )
    }

    /// SwiftUI wertet `onChange` auch dann aus, wenn sich am Wert nichts
    /// geändert hat — etwa weil der Rumpf aus einem anderen Grund neu lief.
    /// Ein `uebergeben` bei jeder Aktualisierung setzte den Player der
    /// `AVPlayerLayer` immer wieder neu, und das Bild auf dem Fernseher
    /// stotterte.
    @Test("Gleiche Rolle heißt: nichts tun")
    func gleicheRolleKeinSchritt() {
        #expect(
            PhoneVideoRolle.schritt(von: .aufDemTelefon, nach: .aufDemTelefon, spielerVorhanden: true)
                == .nichts
        )
        #expect(
            PhoneVideoRolle.schritt(von: .aufDerBuehne, nach: .aufDerBuehne, spielerVorhanden: true)
                == .nichts
        )
    }

    @Test("Kommt der Zweitbildschirm mitten im Video, zieht das Bild um")
    func zweitbildschirmKommtWaehrendDerWiedergabe() {
        #expect(
            PhoneVideoRolle.schritt(von: .aufDemTelefon, nach: .aufDerBuehne, spielerVorhanden: true)
                == .uebergeben
        )
    }

    /// Der Fall, der sonst Ton ohne Bild hinterlässt: Der Apple TV fällt weg,
    /// die Bühne verschwindet — und der Player muss zurück aufs Telefon, statt
    /// als verwaiste Referenz weiterzulaufen.
    @Test("Geht der Zweitbildschirm, kommt das Bild aufs Telefon zurück")
    func zweitbildschirmGehtWaehrendDerWiedergabe() {
        #expect(
            PhoneVideoRolle.schritt(von: .aufDerBuehne, nach: .aufDemTelefon, spielerVorhanden: true)
                == .zuruecknehmen
        )
    }
}
