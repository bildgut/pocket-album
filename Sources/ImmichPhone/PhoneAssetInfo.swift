import Foundation

/// Die Anzeigewerte des Info-Blatts („Wann · Wie · Wo") — reiner Wertetyp
/// ohne SwiftUI, `ModelContext` oder Netz, damit sich Formatierung und
/// Auswahl prüfen lassen.
///
/// **Datum aus `localDateTime`, nicht aus einer `TimeZone`:** Immich leitet die
/// Ortszeit beim Import aus den EXIF-Daten ab. Das Blatt zeigt sie als
/// Wanduhr-Zeit (ein UTC-Formatierer über den zerlegten Teilen), sodass weder
/// die Zone des Telefons noch eine Sommerzeitgrenze das Ergebnis verschiebt —
/// dieselbe Überlegung wie in ``PhotoFeedGrouping``. Eine eigene Zeile
/// „Zeitzone" gibt es bewusst nicht: `ExifInfo` führt keine, und
/// `dateTimeOriginal` ist beim Server schon nach UTC umgerechnet.
struct PhoneAssetInfo: Equatable, Sendable {
    struct Koordinate: Equatable, Sendable {
        let breite: Double
        let laenge: Double

        /// `53° 33′ N, 9° 59′ E`
        var grad: String {
            "\(Self.dms(breite, plus: "N", minus: "S")), \(Self.dms(laenge, plus: "E", minus: "W"))"
        }

        /// Für die Zwischenablage und `maps://`: `53.55000, 9.99000`.
        var dezimal: String {
            String(format: "%.5f, %.5f", breite, laenge)
        }

        private static func dms(_ wert: Double, plus: String, minus: String) -> String {
            let betrag = abs(wert)
            var grad = Int(betrag)
            var minuten = Int(((betrag - Double(grad)) * 60).rounded())
            if minuten == 60 { grad += 1; minuten = 0 }
            return "\(grad)° \(minuten)′ \(wert >= 0 ? plus : minus)"
        }
    }

    // Wann
    let datum: String?
    let uhrzeit: String?
    let wochentag: String?

    // Wie
    let kamera: String?
    let objektiv: String?
    /// `ƒ/1.8 · 1/250 s · 24 mm · ISO 100` — fehlende Teile fallen weg.
    let belichtung: String?
    let aufloesung: String?
    let dateigroesse: String?
    let dateityp: String?

    // Wo
    let ort: String?
    let koordinate: Koordinate?

    var hatWann: Bool { datum != nil }
    var hatWie: Bool {
        kamera != nil || objektiv != nil || belichtung != nil
            || aufloesung != nil || dateigroesse != nil || dateityp != nil
    }

    init(asset: Asset, sprache: Locale = .current) {
        let teile = Self.zerlege(asset.localDateTime ?? asset.exifInfo?.dateTimeOriginal ?? asset.fileCreatedAt)
        if let teile {
            var kalender = Calendar(identifier: .gregorian)
            kalender.timeZone = TimeZone(identifier: "UTC") ?? .gmt
            let komponenten = DateComponents(
                year: teile.jahr, month: teile.monat, day: teile.tag,
                hour: teile.stunde, minute: teile.minute
            )
            let date = kalender.date(from: komponenten)
            func formatierer(_ vorlage: String) -> DateFormatter {
                let f = DateFormatter()
                f.locale = sprache
                f.timeZone = kalender.timeZone
                f.setLocalizedDateFormatFromTemplate(vorlage)
                return f
            }
            datum = date.map { formatierer("yMMMMd").string(from: $0) }
            uhrzeit = date.map { formatierer("jm").string(from: $0) }
            wochentag = date.map { formatierer("EEEE").string(from: $0) }
        } else {
            datum = nil; uhrzeit = nil; wochentag = nil
        }

        let exif = asset.exifInfo
        kamera = Self.kamera(make: exif?.make, model: exif?.model)
        objektiv = Self.leer(exif?.lensModel)
        belichtung = Self.belichtung(
            blende: exif?.fNumber, zeit: exif?.exposureTime,
            brennweite: exif?.focalLength, iso: exif?.iso
        )
        aufloesung = Self.aufloesung(breite: asset.effectiveWidth, hoehe: asset.effectiveHeight)
        dateigroesse = exif?.fileSizeInByte.flatMap { $0 > 0 ? Self.bytes($0) : nil }
        dateityp = Self.dateityp(asset.originalFileName)

        if let breite = exif?.latitude, let laenge = exif?.longitude,
           abs(breite) <= 90, abs(laenge) <= 180, !(breite == 0 && laenge == 0) {
            koordinate = Koordinate(breite: breite, laenge: laenge)
        } else {
            koordinate = nil
        }
        let land = Self.leer(exif?.country).map { Laendernamen.anzeigename(fuer: $0) }
        let teileOrt = [Self.leer(exif?.city), land].compactMap { $0 }
        ort = teileOrt.isEmpty ? nil : teileOrt.joined(separator: ", ")
    }

    // MARK: - Bausteine (einzeln prüfbar)

    static func kamera(make: String?, model: String?) -> String? {
        let hersteller = leer(make), modell = leer(model)
        switch (hersteller, modell) {
        case (nil, nil): return nil
        case (let h?, nil): return h
        case (nil, let m?): return m
        case (let h?, let m?):
            // „Apple" + „iPhone 16 Pro" – der Hersteller steht schon im Modell
            // oder wäre doppelt (EXIF: „SONY" + „ILCE-7M4" bleibt beides).
            return m.lowercased().hasPrefix(h.lowercased()) ? m : "\(h) \(m)"
        }
    }

    static func belichtung(blende: Double?, zeit: String?, brennweite: Double?, iso: Double?) -> String? {
        var teile: [String] = []
        if let blende, blende > 0 { teile.append("ƒ/" + zahl(blende)) }
        if let zeit = belichtungszeit(zeit) { teile.append(zeit) }
        if let brennweite, brennweite > 0 { teile.append(zahl(brennweite) + " mm") }
        if let iso, iso > 0 { teile.append("ISO " + zahl(iso)) }
        return teile.isEmpty ? nil : teile.joined(separator: " · ")
    }

    /// Immich liefert `"1/250"` oder eine Dezimalzahl (`"0.004"`, `"2"`).
    static func belichtungszeit(_ roh: String?) -> String? {
        guard let roh = leer(roh) else { return nil }
        if roh.contains("/") { return roh + " s" }
        guard let wert = Double(roh), wert.isFinite, wert > 0 else { return nil }
        if wert < 1 { return "1/\(Int((1 / wert).rounded())) s" }
        return zahl(wert) + " s"
    }

    static func aufloesung(breite: Int?, hoehe: Int?) -> String? {
        guard let breite, let hoehe, breite > 0, hoehe > 0 else { return nil }
        let mp = Double(breite) * Double(hoehe) / 1_000_000
        return String(format: "%.1f MP · %d × %d", mp, breite, hoehe)
    }

    static func dateityp(_ name: String) -> String? {
        let endung = (name as NSString).pathExtension.uppercased()
        switch endung {
        case "": return nil
        case "JPEG": return "JPG"
        default: return endung
        }
    }

    static func bytes(_ anzahl: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(anzahl), countStyle: .file)
    }

    /// Ganze Zahlen ohne Nachkommastelle, sonst eine (`1.8`, `24`, `100`).
    private static func zahl(_ wert: Double) -> String {
        wert.rounded() == wert ? String(Int(wert)) : String(format: "%.1f", wert)
    }

    private static func leer(_ text: String?) -> String? {
        guard let t = text?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        return t
    }

    private struct Teile { let jahr, monat, tag, stunde, minute: Int }

    /// `2026-09-14T18:03:22.000Z` → Teile. Die Zone im Text wird ignoriert.
    private static func zerlege(_ text: String) -> Teile? {
        let z = Array(text.utf8)
        guard z.count >= 16, z[4] == 45, z[7] == 45, z[10] == 84 || z[10] == 32, z[13] == 58 else { return nil }
        func zahl(_ von: Int, _ bis: Int) -> Int? { Int(String(decoding: z[von..<bis], as: UTF8.self)) }
        guard let j = zahl(0, 4), let m = zahl(5, 7), let t = zahl(8, 10),
              let h = zahl(11, 13), let mi = zahl(14, 16),
              (1...12).contains(m), (1...31).contains(t), (0...23).contains(h), (0...59).contains(mi)
        else { return nil }
        return Teile(jahr: j, monat: m, tag: t, stunde: h, minute: mi)
    }
}
