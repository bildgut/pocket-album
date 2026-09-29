import Testing
@testable import ImmichPhone

/// Der Erklärtext unter den Wählern folgt der Auswahl (Praxistest: bei
/// „Original“ stand weiter der Vorschau-Text).
@Suite("Offline-Blatt: Hinweis je Option")
@MainActor
struct PhoneOfflineBlattHinweisTests {
    @Test func jedeOptionHatEigenenText() {
        let fotos = OfflineWahl.Fotos.allCases.map(PhoneOfflineBlatt.hinweis(fuer:))
        let videos = OfflineWahl.Videos.allCases.map(PhoneOfflineBlatt.hinweis(fuer:))
        #expect(Set(fotos).count == fotos.count)
        #expect(Set(videos).count == videos.count)
        #expect(PhoneOfflineBlatt.hinweis(fuer: OfflineWahl.Fotos.original).contains("Original"))
        #expect(PhoneOfflineBlatt.hinweis(fuer: OfflineWahl.Videos.keine).contains("cloud"))
    }
}
