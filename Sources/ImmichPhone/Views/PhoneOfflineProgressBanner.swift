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

/// Was die Leiste am unteren Rand zeigt. Offline schlägt Laden: Ohne Netz ist ein
/// Ladebalken eine falsche Auskunft, und „Offline“ soll auf jedem Reiter stehen,
/// nicht nur im Fotos-Reiter (Gerätebefund 26.10.2026).
enum PhoneStatusLeiste: Equatable {
    case keine, offline, laden

    static func art(istOffline: Bool, laeuft: Bool) -> PhoneStatusLeiste {
        if istOffline { return .offline }
        return laeuft ? .laden : .keine
    }
}

/// Ohne Netz: was die App gerade zeigt, und der Weg zurück.
struct PhoneOfflineLeiste: View {
    @Environment(ConnectionManager.self) private var connection
    @State private var verbindet = false

    var body: some View {
        HStack(spacing: 8) {
            Label(Self.hinweisText, systemImage: "airplane")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if verbindet {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(Self.verbindenText) {
                    verbindet = true
                    Task {
                        await connection.reconnect()
                        verbindet = false
                    }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
                .tint(Marke.akzent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private static let hinweisText = String(localized: "Offline · saved content")
    private static let verbindenText = String(localized: "Reconnect")
}

/// Bettet am unteren Rand (`safeAreaInset`) die Offline-Leiste ein, sobald die App
/// offline ist, sonst den Ladebalken eines laufenden Offline-Downloads
/// (`OfflineSyncProgress.isActive`).
@MainActor
struct PhoneOfflineProgressBannerModifier: ViewModifier {
    var fortschritt: OfflineSyncProgress = .shared
    @Environment(ConnectionManager.self) private var connection

    private var art: PhoneStatusLeiste {
        .art(istOffline: connection.state.isOffline, laeuft: fortschritt.isActive)
    }

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom) {
                switch art {
                case .offline:
                    PhoneOfflineLeiste()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                case .laden:
                    PhoneOfflineProgressBanner(fortschritt: fortschritt)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                case .keine:
                    EmptyView()
                }
            }
            .animation(.snappy, value: art)
    }
}

extension View {
    /// Heftet am unteren Rand dieser Ansicht die Offline-Leiste oder den
    /// Offline-Ladebalken an (siehe ``PhoneStatusLeiste``).
    @MainActor
    func phoneOfflineProgressBanner(fortschritt: OfflineSyncProgress = .shared) -> some View {
        modifier(PhoneOfflineProgressBannerModifier(fortschritt: fortschritt))
    }
}
