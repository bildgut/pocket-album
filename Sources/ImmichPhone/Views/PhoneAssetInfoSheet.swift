import SwiftUI
import SwiftData
import MapKit
import CoreLocation
import UIKit

/// Info-Blatt zum Einzelbild: Wann · Wie · Wo.
///
/// **Woher die Daten kommen — und warum nicht aus dem `GridIndexStore`:** Den
/// gibt es auf dem iPhone nicht (die Reiter laden über `searchAssets`). Die
/// Reihenfolge ist deshalb: (1) `CachedAsset`, falls das Foto in einem
/// Offline-Album liegt — sofort und ohne Netz; (2) `getAssetDetail`, wenn der
/// Server erreichbar ist, überschreibt und ergänzt (der Cache hat keine
/// `localDateTime`). Ohne beides bleibt ein ehrlicher Leerzustand.
///
/// Die Karte ist nicht verschiebbar: Im scrollenden Blatt würde sie Wischer
/// schlucken. Ein Tipp öffnet Karten.
struct PhoneAssetInfoSheet: View {
    let assetId: String

    @Environment(ConnectionManager.self) private var connection
    @Environment(\.modelContext) private var modelContext

    @State private var info: PhoneAssetInfo?
    @State private var laedt = true
    @State private var kopiert = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let info {
                        wann(info)
                        wie(info)
                        wo(info)
                    } else if laedt {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        Text(Self.keineDaten)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(Self.titel)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sensoryFeedback(.success, trigger: kopiert)
        .task(id: assetId) { await lade() }
    }

    // MARK: - Abschnitte

    @ViewBuilder
    private func wann(_ info: PhoneAssetInfo) -> some View {
        if info.hatWann {
            abschnitt(Self.wannTitel) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: info.datum ?? "").font(.title3.weight(.semibold))
                    Text(verbatim: [info.wochentag, info.uhrzeit].compactMap { $0 }.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func wie(_ info: PhoneAssetInfo) -> some View {
        if info.hatWie {
            abschnitt(Self.wieTitel) {
                VStack(alignment: .leading, spacing: 10) {
                    if let kamera = info.kamera {
                        Text(verbatim: kamera).font(.headline)
                    }
                    if let objektiv = info.objektiv {
                        Text(verbatim: objektiv).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let belichtung = info.belichtung {
                        Text(verbatim: belichtung)
                            .font(.subheadline.monospacedDigit())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    let technik = [info.aufloesung, info.dateigroesse, info.dateityp].compactMap { $0 }
                    if !technik.isEmpty {
                        Text(verbatim: technik.joined(separator: " · "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func wo(_ info: PhoneAssetInfo) -> some View {
        abschnitt(Self.woTitel) {
            if let koordinate = info.koordinate {
                VStack(alignment: .leading, spacing: 10) {
                    if let ort = info.ort {
                        Text(verbatim: ort).font(.headline)
                    }
                    karte(koordinate, name: info.ort)
                    Button {
                        UIPasteboard.general.string = koordinate.dezimal
                        kopiert += 1
                    } label: {
                        Label {
                            Text(verbatim: koordinate.grad)
                        } icon: {
                            Image(systemName: "doc.on.doc")
                        }
                        .font(.footnote.monospacedDigit())
                    }
                    .accessibilityLabel(Self.koordinatenKopieren)
                    Button {
                        oeffneInKarten(koordinate, name: info.ort)
                    } label: {
                        Label(Self.inKartenOeffnen, systemImage: "map")
                    }
                    .font(.subheadline.weight(.medium))
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if let ort = info.ort { Text(verbatim: ort).font(.headline) }
                    Text(Self.keineOrtsdaten).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func karte(_ k: PhoneAssetInfo.Koordinate, name: String?) -> some View {
        let mitte = CLLocationCoordinate2D(latitude: k.breite, longitude: k.laenge)
        return Map(
            initialPosition: .region(MKCoordinateRegion(
                center: mitte,
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            )),
            interactionModes: []
        ) {
            Marker(name ?? Self.fotoOrt, coordinate: mitte).tint(Marke.akzent)
        }
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { oeffneInKarten(k, name: name) }
        .accessibilityHidden(true)
    }

    private func abschnitt<Inhalt: View>(_ titel: String, @ViewBuilder inhalt: () -> Inhalt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(titel).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            inhalt()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func oeffneInKarten(_ k: PhoneAssetInfo.Koordinate, name: String?) {
        let ziel = MKMapItem(location: CLLocation(latitude: k.breite, longitude: k.laenge), address: nil)
        ziel.name = name ?? Self.fotoOrt
        ziel.openInMaps()
    }

    // MARK: - Laden

    private func lade() async {
        laedt = true
        defer { laedt = false }
        let id = assetId
        var d = FetchDescriptor<CachedAsset>(predicate: #Predicate { $0.assetId == id })
        d.fetchLimit = 1
        if let zwischengespeichert = try? modelContext.fetch(d).first {
            info = PhoneAssetInfo(asset: zwischengespeichert.toAsset())
        }
        guard let client = connection.apiClient, !connection.state.isOffline else { return }
        if let asset = try? await client.getAssetDetail(id: id) {
            info = PhoneAssetInfo(asset: asset)
        }
    }

    // Texte als Konstanten (Markdown-Falle bei Literalen, siehe CLAUDE.md).
    private static let titel = String(localized: "Info")
    private static let wannTitel = String(localized: "When")
    private static let wieTitel = String(localized: "How")
    private static let woTitel = String(localized: "Where")
    private static let keineDaten = String(localized: "No details available offline")
    private static let keineOrtsdaten = String(localized: "No location data")
    private static let inKartenOeffnen = String(localized: "Open in Maps")
    private static let koordinatenKopieren = String(localized: "Copy coordinates")
    private static let fotoOrt = String(localized: "Photo location")
}
