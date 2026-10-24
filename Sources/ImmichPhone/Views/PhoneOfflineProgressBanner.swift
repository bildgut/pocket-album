import SwiftUI

/// Zeigt einen laufenden Offline-Durchgang: Balken, Zahlen, Abbrechen.
///
/// Eine Ansicht für beide Stellen — Albumraster und Albumdetail. Vorher stand
/// im Raster ein handgebauter `HStack` mit einem **unbestimmten** Kreisel, und
/// das Detail zeigte gar nichts: Wer dort ein Album offline nahm, sass vor
/// einer stillen Ansicht, während im Hintergrund Dateien liefen.
///
/// Der Balken ist bewusst zweistufig, weil der Lauf es auch ist. Solange
/// `total == 0`, löst `OfflineDownloadManager` noch die Albumzugehörigkeit über
/// die API auf — es gibt schlicht noch keine Gesamtzahl, an der sich ein
/// Fortschritt messen liesse. Ein Balken, der in dieser Phase auf 0 % stünde,
/// behauptete Stillstand, wo Arbeit läuft; deshalb dort der unbestimmte
/// Kreisel. `labelText` sagt dazu von sich aus „Vorbereitung…".
struct PhoneOfflineProgressBanner: View {
    /// `OfflineSyncProgress.shared`, von aussen hereingereicht, damit die
    /// Ansicht in einer Vorschau auch ohne laufenden Dienst zu zeigen ist.
    var fortschritt: OfflineSyncProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if fortschritt.total > 0 {
                    ProgressView(value: fortschritt.progress)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Spacer(minLength: 0)
                }

                // Abbrechen gehört hierher und nicht in ein Menü: Ein Lauf über
                // ein grosses Album lädt Originale, und wer unterwegs merkt,
                // dass das die falsche Entscheidung war, soll ihn dort stoppen
                // können, wo er ihn sieht. Bereits geladene Dateien bleiben
                // liegen (siehe `OfflineSyncProgress.cancel`).
                Button(Self.abbrechenText) { fortschritt.cancel() }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                    .disabled(fortschritt.isCancelling)
            }

            // Immer eine Variable, nie ein Literal — SwiftUI parst
            // Text-Literale als Markdown (siehe `PhoneAlbumTile`). `labelText`
            // enthält Albumnamen, und die kommen vom Server.
            Text(fortschritt.labelText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private static let abbrechenText = String(localized: "Cancel")
}

/// Bettet den Ladebalken dezent am unteren Rand (`safeAreaInset`) ein,
/// sobald ein Offline-Download aktiv ist (`OfflineSyncProgress.isActive`).
@MainActor
struct PhoneOfflineProgressBannerModifier: ViewModifier {
    var fortschritt: OfflineSyncProgress = .shared

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom) {
                if fortschritt.isActive {
                    PhoneOfflineProgressBanner(fortschritt: fortschritt)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: fortschritt.isActive)
    }
}

extension View {
    /// Heftet den Offline-Ladebalken am unteren Rand dieser Ansicht an,
    /// sobald `OfflineSyncProgress.isActive` wahr ist.
    @MainActor
    func phoneOfflineProgressBanner(fortschritt: OfflineSyncProgress = .shared) -> some View {
        modifier(PhoneOfflineProgressBannerModifier(fortschritt: fortschritt))
    }
}
