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

    /// Name für eine lokale Offline-Datei: Stamm des Originalnamens, Endung der
    /// Datei, die wirklich geteilt wird — eine Vorschau von `IMG_1.HEIC` ist ein
    /// JPEG und heißt deshalb `IMG_1.jpg`.
    static func teilName(originalName: String, lokal: URL) -> String {
        let sicher = sichererName(originalName, assetId: lokal.lastPathComponent)
        let endung = lokal.pathExtension
        guard OfflineFassung.aus(pfad: lokal.lastPathComponent) != .original, !endung.isEmpty else {
            return sicher
        }
        return ((sicher as NSString).deletingPathExtension as String) + "." + endung
    }

    /// Legt die Datei unter ihrem Originalnamen in einen frischen `Teilen-`-Ordner
    /// — als harten Link (kein zweiter Speicherplatz), notfalls als Kopie. Räumt
    /// dabei alte Ordner weg. `nil`, wenn beides scheitert.
    static func benannteKopie(von lokal: URL, originalName: String,
                              basis: URL = FileManager.default.temporaryDirectory) -> URL? {
        raeumeAuf(in: basis)
        let fm = FileManager.default
        let ordner = basis.appending(path: "\(praefix)\(UUID().uuidString)", directoryHint: .isDirectory)
        let ziel = ordner.appending(path: teilName(originalName: originalName, lokal: lokal))
        do {
            try fm.createDirectory(at: ordner, withIntermediateDirectories: true)
            do {
                try fm.linkItem(at: lokal, to: ziel)
            } catch {
                try fm.copyItem(at: lokal, to: ziel)
            }
            return ziel
        } catch {
            try? fm.removeItem(at: ordner)
            return nil
        }
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
