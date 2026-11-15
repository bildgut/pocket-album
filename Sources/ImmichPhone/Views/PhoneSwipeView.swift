import SwiftData
import SwiftUI
import UIKit

/// Vollbild-Swipe-Deck für die Standbilder der letzten 30 Tage.
struct PhoneSwipeView: View {
    let apiClient: ImmichAPIClient
    let onGeloescht: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ConnectionManager.self) private var connection

    @State private var modell: PhoneSwipeModell
    @State private var prefetcher: PhoneCoverPrefetcher?
    @State private var zeigtKorbSheet = false
    @State private var zeigtSchliessenFrage = false

    init(
        apiClient: ImmichAPIClient,
        rechte: KeyRechte = KeyRechte(),
        onGeloescht: @escaping ([String]) -> Void = { _ in }
    ) {
        self.apiClient = apiClient
        self.onGeloescht = onGeloescht
        _modell = State(initialValue: PhoneSwipeModell(rechte: rechte))
    }

    private var hatLadeFehler: Bool {
        modell.stapel.isEmpty && !modell.laedt && modell.fehler != nil
            && modell.gesamtImZeitraum == 0 && modell.verlauf.isEmpty
    }

    private var modusBindung: Binding<PhoneSwipeModus> {
        Binding(
            get: { modell.modus },
            set: { neu in
                Task { await modell.wechseleModus(neu, apiClient: apiClient) }
            }
        )
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 16) {
                kopfzeile
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                hauptbereich
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !modell.stapel.isEmpty || !modell.verlauf.isEmpty {
                    daumenLeiste
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task(id: apiClient.baseURL) {
            modell.aktualisiereRechte(connection.keyRechte)
            if let pipeline = connection.imagePipeline {
                prefetcher = PhoneCoverPrefetcher(pipeline: pipeline)
            }
            await modell.lade(apiClient: apiClient)
        }
        .onChange(of: modell.stapel.first?.id) { _, _ in
            waermeNaechsteKarten()
        }
        .onChange(of: modell.stapel.isEmpty) { _, leer in
            if leer, modell.hatGeladen, !modell.laedt,
               modell.modus == .aussortieren,
               !modell.vorgemerkteKarten.isEmpty,
               !modell.verlauf.isEmpty {
                zeigtKorbSheet = true
            }
        }
        .onDisappear {
            prefetcher?.stop()
        }
        .sheet(isPresented: $zeigtKorbSheet) {
            PhoneSwipeKorbSheet(modell: modell) {
                await fuehrePapierkorbAus()
            }
        }
        .alert(
            PhoneSwipeTexts.schliessenFrageTitel,
            isPresented: $zeigtSchliessenFrage
        ) {
            Button(PhoneSwipeTexts.korbButton(anzahl: modell.vorgemerkteKarten.count)) {
                Task {
                    let erfolg = await fuehrePapierkorbAus()
                    if erfolg {
                        dismiss()
                    }
                }
            }
            Button(PhoneSwipeTexts.ohneLoeschenSchliessen, role: .destructive) {
                dismiss()
            }
            Button(PhoneSwipeTexts.abbrechen, role: .cancel) {}
        } message: {
            Text(PhoneSwipeTexts.schliessenFrageText(anzahl: modell.vorgemerkteKarten.count))
        }
        .alert(
            PhoneSwipeTexts.fehlerTitel,
            isPresented: Binding(
                get: { modell.fehler != nil && !hatLadeFehler },
                set: { if !$0 { modell.leereFehler() } }
            )
        ) {
            Button(PhoneSwipeTexts.ok, role: .cancel) {
                modell.leereFehler()
            }
        } message: {
            Text(modell.fehler ?? "")
        }
    }

    // MARK: - Kopfzeile

    private var kopfzeile: some View {
        HStack(spacing: 12) {
            if modell.verfuegbareModi.count > 1 {
                Picker("", selection: modusBindung) {
                    ForEach(modell.verfuegbareModi) { modus in
                        Text(modus.titel).tag(modus)
                    }
                }
                .pickerStyle(.segmented)
                .tint(Marke.akzent)
                .labelsHidden()
            } else if let einziger = modell.verfuegbareModi.first {
                Text(einziger.titel)
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
            } else {
                Spacer()
            }

            if !modell.vorgemerkteKarten.isEmpty {
                let korbAnzahl = modell.vorgemerkteKarten.count
                Button {
                    zeigtKorbSheet = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "trash.fill")
                            .font(.subheadline.weight(.semibold))
                        Text(korbAnzahl.formatted())
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Marke.koralle, in: Capsule())
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(PhoneSwipeTexts.korbZaehler(anzahl: korbAnzahl))
            }

            Button {
                if modell.vorgemerkteKarten.isEmpty {
                    dismiss()
                } else {
                    zeigtSchliessenFrage = true
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.thinMaterial, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(PhoneSwipeTexts.schliessen)
        }
    }

    // MARK: - Hauptbereich

    @ViewBuilder
    private var hauptbereich: some View {
        if modell.laedt && modell.stapel.isEmpty {
            VStack(spacing: 14) {
                ProgressView().tint(.white)
                Text(PhoneSwipeTexts.laedtText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        } else if hatLadeFehler {
            ContentUnavailableView {
                Label(PhoneSwipeTexts.nichtVerfuegbar, systemImage: "wifi.slash")
            } description: {
                Text(modell.fehler ?? "")
            } actions: {
                Button(PhoneSwipeTexts.erneut) {
                    Task { await modell.lade(apiClient: apiClient) }
                }
                .buttonStyle(.borderedProminent)
            }
        } else if modell.stapel.isEmpty {
            leerzustand
        } else {
            kartenstapel
                .padding(.horizontal, 14)
        }
    }

    private var kartenstapel: some View {
        let sichtbar = Array(modell.stapel.prefix(2).enumerated().reversed())
        return ZStack {
            ForEach(sichtbar, id: \.element.id) { index, karte in
                let istOben = index == 0
                PhoneSwipeKarte(
                    karte: karte,
                    modus: modell.modus,
                    istObersteKarte: istOben
                ) { entscheidung in
                    wischeKarte(entscheidung)
                }
                .scaleEffect(istOben ? 1.0 : 0.95)
                .opacity(istOben ? 1.0 : 0.6)
                .allowsHitTesting(istOben)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: modell.stapel.first?.id)
    }

    private var leerzustand: some View {
        let beschreibung = modell.modus == .favoriten
            ? PhoneSwipeTexts.leerFavoritenText
            : PhoneSwipeTexts.leerAussortierenText
        let symbol = modell.modus == .favoriten ? "star.circle" : "checkmark.circle"

        return ContentUnavailableView {
            Label(PhoneSwipeTexts.leerTitel, systemImage: symbol)
        } description: {
            Text(beschreibung)
        } actions: {
            if !modell.vorgemerkteKarten.isEmpty {
                Button(PhoneSwipeTexts.vorgemerktPruefen) {
                    zeigtKorbSheet = true
                }
                .buttonStyle(.borderedProminent)
                .tint(Marke.koralle)
            }
            Button(PhoneSwipeTexts.nochmalDurchsehen) {
                Task { await modell.nochmalsDurchsehen(apiClient: apiClient) }
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Daumen-Leiste

    private var daumenLeiste: some View {
        let gesamt = modell.verlauf.count + modell.stapel.count
        let position = min(modell.verlauf.count + 1, max(1, gesamt))
        let fortschrittText = "\(position) / \(gesamt)"
        let hatKarten = !modell.stapel.isEmpty

        return HStack(spacing: 26) {
            aktionsKnopf(
                symbol: modell.modus == .favoriten ? "arrow.left" : "trash.fill",
                farbe: modell.modus == .favoriten ? .white : Marke.koralle,
                beschriftung: modell.modus == .favoriten ? PhoneSwipeTexts.aktionWeiter : PhoneSwipeTexts.aktionVormerken,
                groesse: 60,
                aktiv: hatKarten
            ) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.snappy(duration: 0.22)) {
                    wischeKarte(.links)
                }
            }

            VStack(spacing: 4) {
                aktionsKnopf(
                    symbol: "arrow.uturn.backward",
                    farbe: .white,
                    beschriftung: PhoneSwipeTexts.aktionRueckgaengig,
                    groesse: 48,
                    aktiv: !modell.verlauf.isEmpty
                ) {
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    withAnimation(.snappy(duration: 0.22)) {
                        _ = modell.rueckgaengig(
                            apiClient: apiClient,
                            context: modelContext,
                            onRechtAbgelehnt: { connection.merkeAbgelehnt($0) }
                        )
                    }
                }
                if hatKarten {
                    Text(fortschrittText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            aktionsKnopf(
                symbol: modell.modus == .favoriten ? "star.fill" : "checkmark",
                farbe: modell.modus == .favoriten ? Theme.favorite : Marke.tuerkis,
                beschriftung: modell.modus == .favoriten ? PhoneSwipeTexts.aktionFavorit : PhoneSwipeTexts.aktionBehalten,
                groesse: 60,
                aktiv: hatKarten
            ) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.snappy(duration: 0.22)) {
                    wischeKarte(.rechts)
                }
            }
        }
    }

    private func aktionsKnopf(
        symbol: String,
        farbe: Color,
        beschriftung: String,
        groesse: CGFloat,
        aktiv: Bool,
        aktion: @escaping () -> Void
    ) -> some View {
        Button(action: aktion) {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(aktiv ? farbe : Color.white.opacity(0.28))
                .frame(width: groesse, height: groesse)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(
                            aktiv ? farbe.opacity(0.45) : Color.white.opacity(0.1),
                            lineWidth: 1.5
                        )
                }
        }
        .buttonStyle(.plain)
        .disabled(!aktiv)
        .accessibilityLabel(beschriftung)
    }

    // MARK: - Helfer

    private func wischeKarte(_ entscheidung: PhoneSwipeEntscheidung) {
        modell.wische(
            entscheidung,
            apiClient: apiClient,
            context: modelContext,
            onRechtAbgelehnt: { recht in
                connection.merkeAbgelehnt(recht)
                modell.aktualisiereRechte(connection.keyRechte)
            }
        )
    }

    private func fuehrePapierkorbAus() async -> Bool {
        await modell.leereInPapierkorb(
            apiClient: apiClient,
            context: modelContext,
            onGeloescht: onGeloescht,
            onRechtAbgelehnt: { recht in
                connection.merkeAbgelehnt(recht)
                modell.aktualisiereRechte(connection.keyRechte)
            }
        )
    }

    private func waermeNaechsteKarten() {
        guard let prefetcher else { return }
        let urls = modell.stapel.prefix(5).map {
            apiClient.thumbnailURL(assetId: $0.id, size: .preview)
        }
        if !urls.isEmpty {
            prefetcher.warm(urls)
        }
    }
}
