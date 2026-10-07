import Foundation
import Synchronization

/// Die IDs der Alben, die andere mit diesem Konto teilen — für die Suche in „Entdecken".
///
/// Der Server durchsucht ohne Albumfilter nur die eigene Bibliothek; Fotos aus einem
/// geteilten Album fänden Suche, Orte und Jahre sonst nie (siehe
/// ``SearchFilter/mitGeteiltenAlben(_:)``). `PhoneRootView` setzt die Liste nach jedem
/// Albumabgleich, `PhoneOrtsModell.leere()` leert sie beim Abmelden.
///
/// Prozessweit statt durchgereicht, weil der Filter an vielen Stellen aus
/// ``PhoneSuchAuswahl`` entsteht (Raster, Zählungen, Ortskatalog), auch in
/// `nonisolated`-Zählfunktionen. Sortiert, damit der Ortskatalog eine geänderte Liste
/// an einem einfachen Vergleich erkennt.
enum PhoneGeteilteAlben {
    private static let ids = Mutex<[String]>([])

    static var aktuell: [String] { ids.withLock { $0 } }

    /// - Returns: ob sich die Liste geändert hat.
    @discardableResult
    static func setze(_ neu: [String]) -> Bool {
        let sortiert = Array(Set(neu)).sorted()
        return ids.withLock { alt in
            guard alt != sortiert else { return false }
            alt = sortiert
            return true
        }
    }
}

/// Länder mit Städten und Regionen aus den Fotos geteilter Alben.
///
/// Die Vorschlagsliste des Servers (`/search/suggestions`) kennt keinen Albumfilter und
/// nennt nur Orte der eigenen Bibliothek. Die Ortsangaben fremder Fotos liefert die
/// Suche dagegen mit (`withExif`), also sammelt der Ortskatalog sie dort ein.
enum PhoneGeteilteOrte {
    struct Land: Equatable, Sendable {
        var staedte: [String]
        var regionen: [String]
    }

    static func aus(_ assets: [Asset]) -> [String: Land] {
        var staedte: [String: Set<String>] = [:]
        var regionen: [String: Set<String>] = [:]
        for asset in assets {
            guard let exif = asset.exifInfo, let land = sauber(exif.country) else { continue }
            staedte[land, default: []].formUnion([sauber(exif.city)].compactMap { $0 })
            regionen[land, default: []].formUnion([sauber(exif.state)].compactMap { $0 })
        }
        var ergebnis: [String: Land] = [:]
        for (land, s) in staedte {
            ergebnis[land] = Land(staedte: s.sorted(), regionen: (regionen[land] ?? []).sorted())
        }
        return ergebnis
    }

    /// Die eigenen Namen zuerst, in ihrer Reihenfolge; neue aus geteilten Alben dahinter.
    static func vereint(_ eigene: [String], _ geteilte: [String]) -> [String] {
        var gesehen = Set(eigene)
        return eigene + geteilte.filter { gesehen.insert($0).inserted }
    }

    private static func sauber(_ text: String?) -> String? {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
