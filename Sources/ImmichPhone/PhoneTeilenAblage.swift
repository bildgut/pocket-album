import Foundation

/// Die temporären Ordner, in die das Einzelbild ein Original zum Teilen lädt.
///
/// Zwei Aufgaben, beide rein und ohne Netz prüfbar:
/// - **Dateiname absichern.** Der Name kommt aus `Content-Disposition` des
///   Servers. Ein Name mit `/` oder `..` landete sonst außerhalb des eigenen
///   Ordners; ein leerer Name wäre der Ordner selbst.
/// - **Alte Ordner aufräumen.** Das System leert `temporaryDirectory` nur
///   gelegentlich; Originale sind groß. Geräumt wird beim nächsten Teilen, und
///   nur, was älter als eine Stunde ist — ein frischer Ordner kann noch in einem
///   offenen Teilenblatt stecken.
enum PhoneTeilenAblage {
    static let praefix = "Teilen-"
    static let hoechstalter: TimeInterval = 3600

    /// Nur der letzte Pfadteil; leer, `.` oder `..` fällt auf die Asset-ID zurück.
    static func sichererName(_ roh: String, assetId: String) -> String {
        let letzter = (roh as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if letzter.isEmpty || letzter == "." || letzter == ".." || letzter == "/" {
            return assetId
        }
        return letzter
    }

    /// Entfernt `Teilen-*`-Ordner in `basis`, deren Änderungsdatum älter als
    /// `hoechstalter` ist. Liefert die Zahl der entfernten Ordner.
    @discardableResult
    static func raeumeAuf(in basis: URL = FileManager.default.temporaryDirectory,
                          jetzt: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let eintraege = try? fm.contentsOfDirectory(
            at: basis, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
        ) else { return 0 }
        var entfernt = 0
        for url in eintraege where url.lastPathComponent.hasPrefix(praefix) {
            guard let werte = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
                  werte.isDirectory == true,
                  let datum = werte.contentModificationDate,
                  jetzt.timeIntervalSince(datum) > hoechstalter
            else { continue }
            if (try? fm.removeItem(at: url)) != nil { entfernt += 1 }
        }
        return entfernt
    }
}
