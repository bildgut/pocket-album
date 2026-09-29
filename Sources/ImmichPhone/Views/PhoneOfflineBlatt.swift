import SwiftUI
import SwiftData

/// Blatt „Offline speichern“: Qualität für Fotos und Videos, Mobilfunk, Größe vorab.
struct PhoneOfflineBlatt: View {
    @State var modell: PhoneOfflineBlattModell
    let apiClient: ImmichAPIClient
    let speichern: (OfflineWahl) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    zaehlung
                }
                Section {
                    Picker(Self.fotosTitel, selection: $modell.wahl.fotos) {
                        Text(Self.vorschauText).tag(OfflineWahl.Fotos.vorschau)
                        Text(Self.originalText).tag(OfflineWahl.Fotos.original)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text(Self.fotosTitel)
                } footer: {
                    Text(Self.vorschauHinweis)
                }
                Section {
                    Picker(Self.videosTitel, selection: $modell.wahl.videos) {
                        Text(Self.keineText).tag(OfflineWahl.Videos.keine)
                        Text(Self.kleinText).tag(OfflineWahl.Videos.klein)
                        Text(Self.originalText).tag(OfflineWahl.Videos.original)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text(Self.videosTitel)
                } footer: {
                    Text(Self.kleinHinweis)
                }
                Section {
                    Toggle(Self.mobilfunkText, isOn: $modell.wahl.mobilfunk)
                }
                Section {
                    LabeledContent(Self.groesseText) {
                        if let bytes = modell.schaetzung {
                            Text(String(localized: "≈ \(bytes.formatted(.byteCount(style: .file)))",
                                        comment: "Estimated size, e.g. „≈ 1.2 GB“"))
                        } else if modell.laden == .laedt {
                            ProgressView()
                        } else {
                            Text(Self.unbekanntText).foregroundStyle(.secondary)
                        }
                    }
                    if let frei = modell.freierPlatz {
                        LabeledContent(Self.freiText, value: frei.formatted(.byteCount(style: .file)))
                    }
                } footer: {
                    if !modell.passt {
                        Text(Self.zuWenigPlatzText).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(modell.album.albumName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Self.abbrechenText) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Self.speichernText) {
                        speichern(modell.wahl)
                        dismiss()
                    }
                    .disabled(!modell.passt)
                }
            }
            .task { await modell.lade(apiClient: apiClient) }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var zaehlung: some View {
        switch modell.laden {
        case .fertig:
            // Zwei Schlüssel mit Pluralformen statt einem gemeinsamen — sonst
            // stünde „1 Fotos · 1 Videos“ da.
            Text(Self.zaehlText(fotos: modell.anzahlFotos, videos: modell.anzahlVideos))
        case .laedt:
            HStack {
                Text(Self.zaehltText)
                Spacer()
                ProgressView()
            }
        case .fehlgeschlagen:
            Text(String(localized: "\(modell.album.assetCount) items"))
        }
    }

    /// „12 photos · 3 videos“ — ein Teil mit Anzahl 0 fällt weg, damit kein
    /// „· 0 videos“ dasteht. Sind beide 0, bleibt „0 items“.
    static func zaehlText(fotos: Int, videos: Int) -> String {
        var teile: [String] = []
        if fotos > 0 { teile.append(String(localized: "\(fotos) photos")) }
        if videos > 0 { teile.append(String(localized: "\(videos) videos")) }
        return teile.isEmpty ? String(localized: "\(0) items") : teile.joined(separator: " · ")
    }

    private static let fotosTitel = String(localized: "Photos")
    private static let videosTitel = String(localized: "Videos")
    private static let vorschauText = String(localized: "Preview")
    private static let originalText = String(localized: "Original")
    private static let keineText = String(localized: "None")
    private static let kleinText = String(localized: "Small")
    private static let vorschauHinweis = String(localized: "Previews look sharp on screen and need about a tenth of the space.")
    private static let kleinHinweis = String(localized: "Small videos are converted by the server and play everywhere.")
    private static let mobilfunkText = String(localized: "Also over Cellular")
    private static let groesseText = String(localized: "Estimated Size")
    private static let freiText = String(localized: "Free on This iPhone")
    private static let unbekanntText = String(localized: "Unknown")
    private static let zuWenigPlatzText = String(localized: "Not enough free space for this choice.")
    private static let zaehltText = String(localized: "Counting…")
    private static let abbrechenText = String(localized: "Cancel")
    private static let speichernText = String(localized: "Keep Offline")
}

/// Hängt das Blatt an eine Ansicht — dieselbe Verdrahtung im Albumraster
/// (Kontextmenü) und im Albumdetail (Knopf im Kopf). Vorgabe ist die zuletzt
/// getroffene Wahl.
private struct PhoneOfflineBlattAnbindung: ViewModifier {
    @Binding var album: Album?
    let offline: PhoneOfflineModel

    @Environment(ConnectionManager.self) private var connection
    @Environment(\.modelContext) private var modelContext

    func body(content: Content) -> some View {
        content.sheet(item: $album) { album in
            if let apiClient = connection.apiClient {
                PhoneOfflineBlatt(
                    modell: PhoneOfflineBlattModell(
                        album: album,
                        wahl: OfflineWahlSpeicher().letzte,
                        freierPlatz: PhoneOfflineBlattModell.freierPlatz()
                    ),
                    apiClient: apiClient
                ) { wahl in
                    offline.nimmOffline(album: album, wahl: wahl, context: modelContext, apiClient: apiClient)
                }
            }
        }
    }
}

extension View {
    func offlineBlatt(album: Binding<Album?>, offline: PhoneOfflineModel) -> some View {
        modifier(PhoneOfflineBlattAnbindung(album: album, offline: offline))
    }
}
