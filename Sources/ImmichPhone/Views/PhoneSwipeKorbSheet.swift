import SwiftUI

/// Kontrollblatt für die im Aussortier-Modus zum Löschen vorgemerkten Fotos.
/// Ein Tipp auf eine Kachel hebt die Vormerkung sofort wieder auf.
struct PhoneSwipeKorbSheet: View {
    var modell: PhoneSwipeModell
    let onLoeschen: () async -> Bool

    @Environment(\.dismiss) private var dismiss

    private let columns = PhoneRasterSpalten.fotos

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(PhoneSwipeTexts.korbHinweis)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(modell.vorgemerkteKarten) { karte in
                            Button {
                                modell.hebeVormerkungAuf(assetId: karte.id)
                            } label: {
                                PhoneGridTile(
                                    eintrag: PhoneAlbumGridEintrag(
                                        id: karte.id,
                                        isFavorite: karte.isFavorite
                                    )
                                )
                                .overlay(alignment: .topTrailing) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.title3)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.65))
                                        .padding(6)
                                        .allowsHitTesting(false)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(modell.loescht)
                            .accessibilityLabel(PhoneSwipeTexts.korbEntfernenLabel)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            .navigationTitle(PhoneSwipeTexts.korbTitel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(PhoneSwipeTexts.schliessen) {
                        dismiss()
                    }
                    .disabled(modell.loescht)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !modell.vorgemerkteKarten.isEmpty {
                    let anzahl = modell.vorgemerkteKarten.count
                    let buttonTitel = PhoneSwipeTexts.korbButton(anzahl: anzahl)
                    Button(role: .destructive) {
                        Task {
                            let erfolg = await onLoeschen()
                            if erfolg {
                                dismiss()
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if modell.loescht {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "trash.fill")
                            }
                            Text(buttonTitel)
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Marke.koralle)
                    .disabled(modell.loescht)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.bar)
                }
            }
            .onChange(of: modell.vorgemerkteKarten.isEmpty) { _, leer in
                if leer {
                    dismiss()
                }
            }
        }
    }
}
