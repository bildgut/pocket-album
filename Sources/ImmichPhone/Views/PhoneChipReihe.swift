import SwiftUI

/// Eine waagerecht scrollende Reihe von Chips mit Überschrift — Städte, Jahre
/// oder Personen.
struct PhoneChipReihe: View {

    let titel: String
    let chips: [PhoneOrtsChip]
    let ausgewaehlt: Set<String>
    var laedt = false
    let tippen: (PhoneOrtsChip) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(titel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if laedt {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, 14)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chips) { chip in
                        PhoneChip(titel: chip.titel, anzahl: chip.anzahl, aktiv: ausgewaehlt.contains(chip.id)) {
                            tippen(chip)
                        }
                    }
                }
                .padding(.horizontal, 14)
            }
        }
    }
}

/// Ein einzelner Chip. Aktiv in `Marke.akzent`, sonst in der Systemfüllung.
struct PhoneChip: View {

    let titel: String
    var anzahl: Int?
    let aktiv: Bool
    let aktion: () -> Void

    var body: some View {
        Button(action: aktion) {
            HStack(spacing: 4) {
                Text(titel)
                if let anzahl {
                    Text(anzahl.formatted())
                        .foregroundStyle(aktiv ? Color.white.opacity(0.8) : Color.secondary)
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(aktiv ? Marke.akzent : Color(uiColor: .secondarySystemFill), in: Capsule())
            .foregroundStyle(aktiv ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(aktiv ? .isSelected : [])
    }
}
