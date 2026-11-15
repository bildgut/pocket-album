import Foundation

/// Eine Zeile im Fassungs-Menü der Detailansicht: welche Fassung eines Stapels das
/// ist und was man über sie wissen will.
struct FassungsZeile: Equatable, Identifiable, Sendable {
    enum Rolle: Equatable, Sendable {
        /// Die Fassung, die „Fertig“ im Bearbeiten-Modus abgelegt hat.
        case bearbeitet
        /// RAW-Original des Stapels.
        case original
        /// Alles andere: das, was die Kamera geliefert hat.
        case kamera
    }

    let id: String
    let rolle: Rolle
    let titel: String
    let detail: String
}

/// Beschriftet die Fassungen eines Stapels. Reiner Wertetyp: Die Aufrufer holen
/// Verweise und Einträge vom Server und reichen sie herein, damit die Auswahl der
/// Texte ohne Netz prüfbar bleibt.
///
/// Welche Fassung „bearbeitet“ ist, sagt allein der Rückverweis
/// (``FassungsVerweis``) an ihr — nicht ihre Lage im Stapel. Ein Stapel, der nicht
/// aus dem Bearbeiten-Modus stammt, hat keinen Verweis und zeigt deshalb nur
/// Original und Kamera.
enum FassungsAnzeige {

    static func zeilen(
        stapel: [Asset],
        verweise: [String: FassungsVerweis],
        eintraege: [String: BearbeitungsEintrag],
        geladen: Bool,
        locale: Locale = Locale(identifier: "de_DE")
    ) -> [FassungsZeile] {
        let rohIds = Set(stapel.filter(istRaw).map(\.id))

        func rolle(_ a: Asset) -> FassungsZeile.Rolle {
            if verweise[a.id] != nil { return .bearbeitet }
            return istRaw(a) ? .original : .kamera
        }
        // Bearbeitete zuerst, dann Original, dann Kamera — die Reihenfolge, in der
        // der Nutzer danach fragt. Innerhalb einer Rolle bleibt die Stapelreihenfolge.
        func rang(_ r: FassungsZeile.Rolle) -> Int {
            switch r { case .bearbeitet: 0; case .original: 1; case .kamera: 2 }
        }

        return stapel
            .map { a in (a, rolle(a)) }
            .enumerated()
            .sorted { l, r in
                let (rl, rr) = (rang(l.element.1), rang(r.element.1))
                return rl != rr ? rl < rr : l.offset < r.offset
            }
            .map { _, paar in
                let (a, r) = paar
                let format = formatName(a)
                switch r {
                case .bearbeitet:
                    let quelle = verweise[a.id]?.originalId
                    let ausRaw = quelle.map(rohIds.contains) ?? false
                    var teile = [ausRaw ? "aus RAW entwickelt" : "bearbeitet"]
                    if let datum = quelle.flatMap({ eintraege[$0]?.geaendertAm }) {
                        teile.append(datum.formatted(
                            .dateTime.day().month(.abbreviated).year().hour().minute().locale(locale)
                        ))
                    }
                    if let m = masse(a) { teile.append(m) }
                    return FassungsZeile(id: a.id, rolle: r, titel: "Bearbeitet (\(format))",
                                         detail: teile.joined(separator: " · "))
                case .original:
                    var teile: [String] = []
                    if geladen {
                        let entwickelt = eintraege[a.id].map { !$0.einstellungen.istLeer } ?? false
                        teile.append(entwickelt ? "Regler gespeichert" : "nie entwickelt")
                    }
                    if let g = groesse(a) { teile.append(g) }
                    teile.append("." + endung(a).uppercased())
                    return FassungsZeile(id: a.id, rolle: r, titel: "\(format) (Original)",
                                         detail: teile.joined(separator: " · "))
                case .kamera:
                    var teile = ["unverändert"]
                    if let m = masse(a) { teile.append(m) }
                    return FassungsZeile(id: a.id, rolle: r, titel: "Kamera-\(format)",
                                         detail: teile.joined(separator: " · "))
                }
            }
    }

    /// „RAW“, „HEIC“, „JPEG“ … — wie der alte Schalter es beschriftete.
    static func formatName(_ a: Asset) -> String {
        if istRaw(a) { return "RAW" }
        switch endung(a) {
        case "heic", "heif": return "HEIC"
        case "jpg", "jpeg": return "JPEG"
        case "": return a.type == .video ? "Video" : "Foto"
        case let e: return e.uppercased()
        }
    }

    private static func istRaw(_ a: Asset) -> Bool {
        !a.isVideo && MediaType.isRawFile(fileName: a.originalFileName, path: a.originalPath)
    }

    private static func endung(_ a: Asset) -> String {
        (a.originalFileName as NSString).pathExtension.lowercased()
    }

    private static func masse(_ a: Asset) -> String? {
        guard let b = a.effectiveWidth, let h = a.effectiveHeight, b > 0, h > 0 else { return nil }
        return "\(b) × \(h)"
    }

    private static func groesse(_ a: Asset) -> String? {
        guard let n = a.exifInfo?.fileSizeInByte, n > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}
