import Foundation
import Testing
@testable import ImmichPhone

@Suite("PhoneAssetInfo")
struct PhoneAssetInfoTests {

    private func asset(
        localDateTime: String? = "2026-09-14T18:03:22.000Z",
        exif: ExifInfo? = nil,
        name: String = "IMG_0001.HEIC"
    ) -> Asset {
        Asset(
            id: "a", type: .image, originalFileName: name,
            fileCreatedAt: "2026-09-14T16:03:22.000Z", fileModifiedAt: "2026-09-14T16:03:22.000Z",
            localDateTime: localDateTime, isFavorite: false, exifInfo: exif, width: 4000, height: 3000
        )
    }

    private func exif(
        make: String? = "Apple", model: String? = "iPhone 16 Pro",
        lat: Double? = 53.55, lon: Double? = 9.99, city: String? = "Hamburg", country: String? = "Germany"
    ) -> ExifInfo {
        ExifInfo(
            make: make, model: model, exifImageWidth: nil, exifImageHeight: nil, fileSizeInByte: 3_500_000,
            city: city, state: nil, country: country, latitude: lat, longitude: lon,
            focalLength: 24, fNumber: 1.8, iso: 100, exposureTime: "1/250", lensModel: "Main Camera"
        )
    }

    @Test("Belichtungs-Badge fasst Blende, Zeit, Brennweite und ISO zusammen")
    func badge() {
        let info = PhoneAssetInfo(asset: asset(exif: exif()))
        #expect(info.belichtung == "ƒ/1.8 · 1/250 s · 24 mm · ISO 100")
    }

    @Test("Fehlende Belichtungsteile fallen weg, ohne Rest ist es nil")
    func badgeTeilweise() {
        #expect(PhoneAssetInfo.belichtung(blende: nil, zeit: nil, brennweite: nil, iso: 400) == "ISO 400")
        #expect(PhoneAssetInfo.belichtung(blende: nil, zeit: nil, brennweite: nil, iso: nil) == nil)
    }

    @Test("Belichtungszeit: Bruch bleibt, Dezimalzahl wird zum Bruch")
    func belichtungszeit() {
        #expect(PhoneAssetInfo.belichtungszeit("1/250") == "1/250 s")
        #expect(PhoneAssetInfo.belichtungszeit("0.004") == "1/250 s")
        #expect(PhoneAssetInfo.belichtungszeit("2") == "2 s")
        #expect(PhoneAssetInfo.belichtungszeit("0") == nil)
        #expect(PhoneAssetInfo.belichtungszeit("nan") == nil)
        #expect(PhoneAssetInfo.belichtungszeit("") == nil)
    }

    @Test("Hersteller wird nicht doppelt vor das Modell gesetzt")
    func kamera() {
        #expect(PhoneAssetInfo.kamera(make: "Apple", model: "iPhone 16 Pro") == "Apple iPhone 16 Pro")
        #expect(PhoneAssetInfo.kamera(make: "Apple", model: "Apple iPhone 8") == "Apple iPhone 8")
        #expect(PhoneAssetInfo.kamera(make: nil, model: "X100V") == "X100V")
        #expect(PhoneAssetInfo.kamera(make: " ", model: nil) == nil)
    }

    @Test("Koordinaten als Grad und Minuten, Süd und West mit Vorzeichen")
    func koordinaten() {
        let hh = PhoneAssetInfo.Koordinate(breite: 53.55, laenge: 9.99)
        #expect(hh.grad == "53° 33′ N, 9° 59′ E")
        let sp = PhoneAssetInfo.Koordinate(breite: -33.8688, laenge: -70.5)
        #expect(sp.grad == "33° 52′ S, 70° 30′ W")
        #expect(PhoneAssetInfo.Koordinate(breite: 10.9999, laenge: 0).grad == "11° 0′ N, 0° 0′ E")
        #expect(hh.dezimal == "53.55000, 9.99000")
    }

    @Test("Ohne Koordinaten oder bei 0/0 und Unsinn gibt es keine Karte")
    func ohneKoordinate() {
        #expect(PhoneAssetInfo(asset: asset(exif: exif(lat: nil, lon: nil))).koordinate == nil)
        #expect(PhoneAssetInfo(asset: asset(exif: exif(lat: 0, lon: 0))).koordinate == nil)
        #expect(PhoneAssetInfo(asset: asset(exif: exif(lat: 95, lon: 9))).koordinate == nil)
    }

    @Test("Ort aus Stadt und Land, Land deutsch")
    func ort() {
        #expect(PhoneAssetInfo(asset: asset(exif: exif())).ort == "Hamburg, Deutschland")
        #expect(PhoneAssetInfo(asset: asset(exif: exif(city: nil, country: nil))).ort == nil)
    }

    @Test("Datum ist die fotoeigene Ortszeit, unabhängig von der Zone des Geräts")
    func datum() {
        let info = PhoneAssetInfo(asset: asset(), sprache: Locale(identifier: "de_DE"))
        #expect(info.datum == "14. September 2026")
        #expect(info.wochentag == "Montag")
        #expect(info.uhrzeit == "18:03")
    }

    @Test("Ohne localDateTime fällt es auf fileCreatedAt zurück, Unsinn ergibt kein Datum")
    func datumFallback() {
        let a = PhoneAssetInfo(asset: asset(localDateTime: nil), sprache: Locale(identifier: "de_DE"))
        #expect(a.uhrzeit == "16:03")
        let b = PhoneAssetInfo(asset: asset(localDateTime: "kaputt"), sprache: Locale(identifier: "de_DE"))
        // Unlesbar → Fallback gilt nur für nil, nicht für Müll.
        #expect(b.datum == nil)
    }

    @Test("Auflösung, Dateityp und Größe")
    func technik() {
        let info = PhoneAssetInfo(asset: asset(exif: exif()))
        #expect(info.aufloesung == "12.0 MP · 4000 × 3000")
        #expect(info.dateityp == "HEIC")
        #expect(info.dateigroesse != nil)
        #expect(PhoneAssetInfo.dateityp("a.jpeg") == "JPG")
        #expect(PhoneAssetInfo.dateityp("ohne") == nil)
    }
}
