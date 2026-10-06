import Foundation
import Testing
@testable import ImmichPhone

/// Gerätebefund vom 13.09.2026 (Orte-Reiter, Japan → Osaka): Filterleiste, Chips und
/// die Tagesüberschrift wechselten auf Osaka, die Kacheln darunter zeigten aber
/// weiter die Japan-Fotos — mit denselben Videolängen in derselben Reihenfolge.
///
/// Ursache: Die Kachel trug ihre **Position** (`flachIndex`) als Kennung. Nach einem
/// Neuladen haben andere Fotos wieder die Kennungen 0, 1, 2 …, und das `LazyVGrid`
/// behielt die vorhandenen Zellen. Die Kennung muss das Foto benennen, nicht den Platz.
@Suite("PhoneFeedKachel")
struct PhoneFeedKachelTests {

    @Test("Die Kennung einer Kachel ist die Asset-ID, nicht ihre Position")
    func kennungIstAssetID() {
        let kachel = PhoneFeedKachel(flachIndex: 0, eintrag: PhoneAlbumGridEintrag(id: "asset-a"))
        #expect(kachel.id == "asset-a")
    }

    @Test("Zwei Kacheln an derselben Position mit verschiedenen Fotos sind unterscheidbar")
    func gleichePositionAnderesFoto() {
        let vorher = PhoneFeedKachel(flachIndex: 0, eintrag: PhoneAlbumGridEintrag(id: "japan-neu", isVideo: true, duration: "00:01:26.000"))
        let nachher = PhoneFeedKachel(flachIndex: 0, eintrag: PhoneAlbumGridEintrag(id: "osaka-2023"))
        #expect(vorher.id != nachher.id)
    }

    @Test("Der flache Index bleibt für das Einzelbild erhalten")
    func flachIndexBleibt() {
        let kachel = PhoneFeedKachel(flachIndex: 7, eintrag: PhoneAlbumGridEintrag(id: "asset-b"))
        #expect(kachel.flachIndex == 7)
    }
}
