import Foundation

/// Wann nach Änderungen an der Apple-Fotos-Mediathek nachgezählt wird.
///
/// iCloud liefert Fotos schubweise, und Apple Fotos ändert während der Analyse
/// laufend Metadaten. Gezählt wird deshalb erst, wenn `ruhe` lang nichts mehr kam —
/// spätestens aber `obergrenze` nach der ersten Änderung, damit ein langer Abgleich
/// die Anzeige nicht endlos aufschiebt.
struct ApplePhotosRuhefenster: Equatable {
    static let ruhe: TimeInterval = 120
    static let obergrenze: TimeInterval = 600

    private(set) var ersteÄnderung: Date?
    private(set) var letzteÄnderung: Date?

    mutating func änderung(um jetzt: Date) {
        if ersteÄnderung == nil { ersteÄnderung = jetzt }
        letzteÄnderung = jetzt
    }

    /// Wann gezählt werden soll, oder `nil` ohne ausstehende Änderung.
    func fälligkeit() -> Date? {
        guard let ersteÄnderung, let letzteÄnderung else { return nil }
        return min(
            letzteÄnderung.addingTimeInterval(Self.ruhe),
            ersteÄnderung.addingTimeInterval(Self.obergrenze)
        )
    }

    mutating func gefeuert() {
        ersteÄnderung = nil
        letzteÄnderung = nil
    }
}
