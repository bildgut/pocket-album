import Foundation
import Testing
@testable import ImmichPhone

/// Nagelt den Umschalter Alle / Fotos / Videos fest.
///
/// Warum ausgerechnet diese drei Dinge: Sie fallen im Betrieb lautlos falsch
/// aus. Ein vertauschter ``PhoneFeedFilter/assetType`` zeigt unter „Videos"
/// Standbilder — was aussieht wie ein Serverproblem. Und ein Leerzustand, der
/// unter „Videos" behauptet, der Server kenne keine Fotos, schickt den Nutzer
/// zum Falschen: Er sucht beim Server, während bloß der Umschalter woanders
/// steht.
@Suite("PhoneFeedFilter")
struct PhoneFeedFilterTests {

    @Test("Der Umschalter hat genau drei Felder, in dieser Reihenfolge")
    func dreiFelder() {
        #expect(PhoneFeedFilter.allCases == [.alle, .fotos, .videos])
        #expect(PhoneFeedFilter.allCases.map(\.titel) == ["All", "Photos", "Videos"])
    }

    // Das ist der Wert, der in den Suchkörper geht. Vertauscht wäre er im
    // Raster kaum zu erkennen (Videos tragen dieselbe Kachel wie Fotos, nur mit
    // Dauer), im Zweifel hielte man es für einen Serverfehler.
    @Test("Nur „Alle“ schränkt den Typ nicht ein")
    func typZuordnung() {
        #expect(PhoneFeedFilter.alle.assetType == nil)
        #expect(PhoneFeedFilter.fotos.assetType == .image)
        #expect(PhoneFeedFilter.videos.assetType == .video)
    }

    @Test("Der Leerzustand nennt „Videos“, wo Videos gemeint sind")
    func leerzustandKenntDenFilter() {
        #expect(PhoneFeedFilter.videos.leerTitel == "No Videos")
        #expect(PhoneFeedFilter.alle.leerTitel == "No Photos")
        #expect(PhoneFeedFilter.fotos.leerTitel == "No Photos")

        // Die drei Texte müssen sich unterscheiden — sonst wäre der Titel oben
        // die einzige Auskunft und der Satz darunter irreführend.
        let texte = Set(PhoneFeedFilter.allCases.map(\.leerText))
        #expect(texte.count == 3)
        #expect(PhoneFeedFilter.alle.leerText == "The server has no photos yet.")
        #expect(PhoneFeedFilter.videos.leerText.contains("video"))
    }

    @Test("Der Ladetext spricht vom richtigen Bestand")
    func ladetext() {
        #expect(PhoneFeedFilter.videos.ladeText == "Loading videos…")
        #expect(PhoneFeedFilter.alle.ladeText == "Loading photos…")
    }

    // Jedes Feld braucht ein eigenes Symbol und eine eigene `id`; zwei gleiche
    // `id`s brächten den `ForEach` des Umschalters durcheinander.
    @Test("Symbole und Kennungen sind je Filter verschieden")
    func kennungenSindEindeutig() {
        #expect(Set(PhoneFeedFilter.allCases.map(\.leerSymbol)).count == 3)
        #expect(Set(PhoneFeedFilter.allCases.map(\.id)).count == 3)
        #expect(PhoneFeedFilter.allCases.allSatisfy { !$0.leerSymbol.isEmpty })
    }
}
