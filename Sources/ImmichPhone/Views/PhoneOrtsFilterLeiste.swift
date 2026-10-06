import SwiftUI

/// Die gesetzten Filter als Chips mit ✕, rechts die Trefferzahl. Steht über dem
/// Raster fest. Jeder Chip lässt sich einzeln entfernen; ist nichts mehr übrig,
/// zeigt der Reiter seine Startseite.
struct PhoneOrtsFilterLeiste: View {

    let auswahl: PhoneSuchAuswahl
    let personenNamen: [String: String]
    let treffer: Int?
    /// Offline greift nur ein ✕, nach dem nichts mehr übrig ist (zurück zur
    /// Startseite, kein Netz nötig). Jedes andere Entfernen löste über
    /// `PhoneOrtsModell.waehle` ein Neuladen aus, das offline nur ein leeres Raster
    /// ergibt (Befund aus der Review).
    let istOffline: Bool
    let entfernen: (PhoneSuchAuswahl) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let land = auswahl.land {
                        // Nur das Land (samt Stadt/Region) fällt weg; Personen, Jahr und
                        // der Rest bleiben. Ist danach nichts mehr übrig, zeigt der Reiter
                        // seine Startseite.
                        // Offline nur, wenn danach nichts bleibt (Startseite, kein Netz);
                        // sonst löste es ein Neuladen aus, das offline das Raster leert.
                        EntfernChip(
                            titel: Laendernamen.anzeigename(fuer: land, sprache: .current),
                            deaktiviert: istOffline && !auswahl.ohneLand().istLeer
                        ) { entfernen(auswahl.ohneLand()) }
                    }
                    if let stadt = auswahl.stadt {
                        EntfernChip(titel: stadt, deaktiviert: istOffline) { entfernen(auswahl.ohneStadt()) }
                    }
                    if let region = auswahl.region {
                        EntfernChip(titel: region, deaktiviert: istOffline) { entfernen(auswahl.ohneStadtUndRegion()) }
                    }
                    if let jahr = auswahl.jahr {
                        EntfernChip(titel: String(jahr), deaktiviert: istOffline) { entfernen(auswahl.ohneJahr()) }
                    }
                    if let zeitraum = auswahl.zeitraum {
                        EntfernChip(titel: zeitraum.label, deaktiviert: istOffline) { entfernen(auswahl.mitZeitraum(nil)) }
                    }
                    ForEach(auswahl.personen, id: \.self) { id in
                        EntfernChip(titel: personenNamen[id] ?? id, deaktiviert: istOffline) { entfernen(auswahl.mitPerson(id)) }
                    }
                    if let typ = auswahl.typ {
                        EntfernChip(titel: PhoneOrtsTexts.typ(typ), deaktiviert: istOffline) { entfernen(auswahl.mitTyp(nil)) }
                    }
                    if auswahl.nurFavoriten {
                        EntfernChip(titel: PhoneOrtsTexts.favoriten, deaktiviert: istOffline) { entfernen(auswahl.mitFavoriten(false)) }
                    }
                    if !auswahl.freitext.isEmpty {
                        EntfernChip(titel: "“\(auswahl.freitext)”", deaktiviert: istOffline) { entfernen(auswahl.mitFreitext("")) }
                    }
                }
                .padding(.horizontal, 12)
            }
            if let treffer {
                Text(PhoneOrtsTexts.trefferZahl(treffer))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 12)
            }
        }
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct EntfernChip: View {

    let titel: String
    /// Nur für die Chips, deren Entfernen offline einen Netzlauf anstieße —
    /// das ✕ am Land bleibt immer aktiv (Standardwert `false`).
    var deaktiviert = false
    let aktion: () -> Void

    var body: some View {
        Button(action: aktion) {
            HStack(spacing: 4) {
                Text(titel)
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Marke.akzent, in: Capsule())
            .foregroundStyle(Color.white)
        }
        .buttonStyle(.plain)
        .disabled(deaktiviert)
        .opacity(deaktiviert ? 0.5 : 1)
        .accessibilityLabel(Text(titel))
        .accessibilityHint(Text(PhoneOrtsTexts.filterEntfernen))
    }
}
