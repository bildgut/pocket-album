import Testing
@testable import ImmichPhone

/// Prüft die einzige Stelle des Zweitbildschirms, die sich ohne
/// Zweitbildschirm prüfen lässt: welche Folgerungen aus seiner An- oder
/// Abwesenheit gezogen werden.
///
/// Die Szene selbst (`PhoneZweitbildschirmSzenenDelegat`) und die beiden
/// Vollbildansichten bleiben ungeprüft — dafür bräuchte es einen echten Apple
/// TV, den weder dieser Testlauf noch der Simulator herstellen kann. Genau
/// deshalb steht die Logik in einem Wertetyp und nicht im Body.
@Suite("PhoneDiashowRolle")
struct PhoneDiashowRolleTests {

    @Test("Ohne Zweitbildschirm bleibt es beim Vollbild")
    func ohneZweitbildschirmVollbild() {
        #expect(PhoneDiashowRolle.fuer(zweitbildschirmAngeschlossen: false) == .vollbild)
    }

    @Test("Mit Zweitbildschirm wird das Telefon zur Fernbedienung")
    func mitZweitbildschirmFernbedienung() {
        #expect(PhoneDiashowRolle.fuer(zweitbildschirmAngeschlossen: true) == .fernbedienung)
    }

    @Test("Das Telefon zeigt das Bild nur groß, wenn es sonst niemand zeigt")
    func bildGrossNurImVollbild() {
        #expect(PhoneDiashowRolle.vollbild.zeigtBildGross)
        #expect(!PhoneDiashowRolle.fernbedienung.zeigtBildGross)
    }

    @Test("Der Zweitbildschirm wird nur versorgt, wenn einer hängt")
    func versorgungNurAlsFernbedienung() {
        #expect(!PhoneDiashowRolle.vollbild.versorgtZweitbildschirm)
        #expect(PhoneDiashowRolle.fernbedienung.versorgtZweitbildschirm)
    }

    /// Der Kern der Fernbedienung: Knöpfe, die nach drei Sekunden
    /// verschwinden, wären auf einer Fernbedienung ein Fehler — im Vollbild
    /// sind sie es umgekehrt genau dann nicht, wenn sie verschwinden.
    @Test("Die Bedienung blendet nur im Vollbild aus")
    func bedienungBlendetNurImVollbildAus() {
        #expect(PhoneDiashowRolle.vollbild.bedienungBlendetAus)
        #expect(!PhoneDiashowRolle.fernbedienung.bedienungBlendetAus)
    }

    @Test("Statusleiste und Home-Indikator verschwinden nur im Vollbild")
    func systemleistenNurImVollbildVersteckt() {
        #expect(PhoneDiashowRolle.vollbild.verstecktSystemleisten)
        #expect(!PhoneDiashowRolle.fernbedienung.verstecktSystemleisten)
    }

    /// Kein Unterschied zwischen den Rollen — und das ist die Aussage: Sperrt
    /// sich das Telefon, endet auch die Vorführung auf dem Fernseher. Der Test
    /// steht hier, damit ein späteres „auf der Fernbedienung darf der
    /// Bildschirm ja einschlafen" auffällt, statt still durchzugehen.
    @Test("Der Ruhemodus bleibt in beiden Rollen ausgesetzt")
    func wachInBeidenRollen() {
        #expect(PhoneDiashowRolle.vollbild.haeltBildschirmWach)
        #expect(PhoneDiashowRolle.fernbedienung.haeltBildschirmWach)
    }
}
