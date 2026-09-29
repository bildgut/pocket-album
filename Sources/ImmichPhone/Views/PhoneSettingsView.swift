import SwiftUI
import SwiftData

/// Eine Zeile der Offline-Übersicht: die Kennzahlen aus ``PhoneStorageSummary``
/// plus das, was zum Freigeben nötig ist.
///
/// Eigener Typ auf Dateiebene, nicht in der Ansicht verschachtelt, weil er aus
/// einem `Task.detached` zurückkommt und dafür `Sendable` sein muss.
///
/// **Die `id` ist der `pinId`, nicht der Name.** `PhoneStorageSummary.Eintrag` ist
/// bewusst nicht `Identifiable`: Zwei Alben dürfen gleich heißen, und ein `ForEach`
/// über gleiche IDs zeigt in SwiftUI nur eine der Zeilen — beim Freigeben träfe es
/// dann womöglich das falsche Album. `pinId` (`"album:<id>"`) ist dagegen als
/// `@Attribute(.unique)` am Modell garantiert eindeutig.
private struct PhoneOfflineZeile: Identifiable, Sendable {
    /// `OfflinePin.pinId`.
    let id: String
    let kind: OfflinePinKind
    let targetId: String
    let eintrag: PhoneStorageSummary.Eintrag

    var name: String { eintrag.name }
}

/// Was zum Rechnen in den Hintergrund muss. `OfflinePin` ist ein `@Model` und damit
/// nicht `Sendable` — über die Actor-Grenze geht nur dieser Schnappschuss.
private struct PhonePinSchnappschuss: Sendable {
    let pinId: String
    let kind: OfflinePinKind
    let targetId: String
    let name: String
    let assetIds: [String]
    let fehler: String?
    /// Offline-Wahl des Vermerks — bestimmt, ob Videos mitzählen.
    let wahl: OfflineWahl?
}

/// Der Reiter „Einstellungen": woran das Telefon hängt, was es belegt, und der Weg
/// zurück.
///
/// Bis hierher hatte der Client **keinen Ausweg**: keine Anzeige des Servers, keine
/// Übersicht der Offline-Alben, und vor allem keine Möglichkeit, sich abzumelden
/// oder den Server zu wechseln. Lief der API-Schlüssel ab, half nur Neuinstallieren.
///
/// Das Gegenstück am Mac ist `Sources/ImmichMac/Views/OfflineAlbumsSettingsSection.swift`.
/// Übernommen ist von dort das Vorgehen (Schnappschuss der Vermerke, Zahlen im
/// `Task.detached`, Neurechnen nach jedem Lauf), **nicht** der Code: Die Rechnung
/// selbst steht hier in ``PhoneStorageSummary`` und ist damit geprüft, während sie
/// am Mac im View-Body sitzt. Die Mac-Datei bleibt unverändert.
///
/// **Das Abmelden ist inzwischen im Simulator ausgelöst worden**, beide Wege, auf
/// einem eigens dafür gestarteten Gerät und mit vorher gesichertem API-Schlüssel —
/// woran der erste Anlauf gescheitert war. Ohne Ankreuzen fielen 579 von 580 Alben,
/// stehen blieben genau das gepinnte Album, seine 14 Fotos und deren 56 MB; der
/// Nuke-Cache ging von 9,5 MB auf 0. Mit Ankreuzen fiel alles, auch die 56 MB.
/// Die Zahlen stammen aus dem Store und vom Dateisystem, nicht aus der Oberfläche.
///
/// Dass die Rückfrage existiert, ist kein Feinschliff, sondern der eigentliche
/// Schutz: Ein Abmelden auf einen einzigen Fingertipp wäre hier ein Fehler.
struct PhoneSettingsView: View {

    @Environment(ConnectionManager.self) private var connection
    @Environment(\.modelContext) private var modelContext

    /// Der Fotos-Reiter, damit das Abmelden seine Seiten verwerfen kann.
    ///
    /// Hereingereicht statt als eigener `@State`: Er gehört `PhoneRootView`, und
    /// beide Reiter müssen denselben meinen — sonst leert dieser Reiter eine
    /// zweite, unbeteiligte Liste und die sichtbare bliebe stehen.
    let photoFeed: PhonePhotoFeed

    /// Der Orte-Reiter — für „Orte neu einlesen" und damit das Abmelden seinen
    /// Katalog löscht. Hereingereicht aus demselben Grund wie `photoFeed`.
    let orte: PhoneOrtsModell

    /// Die Vermerke selbst kommen live aus SwiftData — verschwindet einer durch
    /// „Freigeben", verschwindet die Zeile ohne Zutun, und das `.task(id:)` unten
    /// rechnet die Summe neu.
    @Query(sort: \OfflinePin.pinnedAt) private var pins: [OfflinePin]

    /// Die Zahlen zu den Vermerken. Außerhalb des View-Bodys berechnet: Jede Zeile
    /// kostet einen Fetch über alle Assets mit lokaler Datei.
    @State private var zeilen: [PhoneOfflineZeile] = []
    @State private var wirdBerechnet = false

    /// Zählt jede Neuberechnung hoch. Ein Lauf, der nach seinem `await` eine andere
    /// Zahl vorfindet, wurde überholt und verwirft sein Ergebnis — siehe
    /// ``kennzahlenNeuBerechnen()``.
    @State private var berechnungsLauf: UInt64 = 0
    @State private var zeigtAbmeldeFrage = false
    @State private var zeigtVorspann = false

    /// Was beim letzten „Freigeben" passiert ist. Ohne diese Zeile bliebe von der
    /// Aktion nur eine verschwundene Zeile übrig — dass dabei auch die Dateien vom
    /// Gerät geräumt werden, wäre unsichtbar.
    /// Die Meldung zur zuletzt freigegebenen Sammlung. Sie verfällt, sobald die
    /// Zahlen neu berechnet sind — sonst stünde sie den Rest der Sitzung da, auch
    /// nachdem weitere Alben freigegeben oder neu gepinnt wurden.
    @State private var letzteFreigabe: String?

    private var zusammenfassung: PhoneStorageSummary {
        PhoneStorageSummary(eintraege: zeilen.map(\.eintrag))
    }

    private var status: PhoneServerStatus {
        PhoneServerStatus.from(connection.state)
    }

    var body: some View {
        NavigationStack {
            List {
                serverAbschnitt
                offlineAbschnitt
                orteAbschnitt
                abmeldeAbschnitt
                versionAbschnitt
            }
            .navigationTitle("Settings")
        }
        // Die IDs statt `pins.count` wie am Mac: Wird ein Album freigegeben und
        // gleichzeitig ein anderes gepinnt, bliebe die Zahl gleich und die Zeilen
        // zeigten weiter das alte Album.
        // Die Freigabe-Meldung gehört zu dem Besuch, in dem sie ausgelöst wurde.
        // Sie hier zu löschen und nicht am Ende von `kennzahlenNeuBerechnen()` ist
        // Absicht: Dort verschwände sie sofort nach dem Freigeben — dessen
        // Pin-Änderung stößt ja genau diese Neuberechnung an —, also bevor jemand
        // sie lesen kann. So bleibt sie stehen, bis der Reiter neu betreten wird.
        .onAppear { letzteFreigabe = nil }
        .task(id: pins.map(\.pinId)) {
            await kennzahlenNeuBerechnen()
        }
        // Nach dem Ende eines Downloadlaufs stimmen „vorhanden" und die Bytes nicht
        // mehr — dieselbe Verdrahtung wie im Albumraster
        // (`PhoneAlbumGridView.onChange(of: OfflineSyncProgress.shared.isActive)`).
        .task(id: OfflineSyncProgress.shared.isActive) {
            if !OfflineSyncProgress.shared.isActive {
                await kennzahlenNeuBerechnen()
            }
        }
    }

    // MARK: - Server

    /// Zwei schlichte `HStack`-Zeilen statt `LabeledContent`.
    ///
    /// Befund aus der Sichtprüfung: Mit `LabeledContent` wuchs die Karte dieses
    /// Abschnitts im Simulator auf gut die dreifache Höhe — unter den beiden Zeilen
    /// klaffte ein leeres Feld von ~400 pt, das den Rest der Liste unter den
    /// Bildschirmrand schob. Ein `HStack` mit `Spacer()` legt dieselben zwei Zeilen
    /// ohne diesen Effekt.
    private var serverAbschnitt: some View {
        Section("Server") {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Address")
                Spacer(minLength: 8)
                // `Text(verbatim:)` mit einer `String`-Konstante, KEIN Literal:
                // SwiftUI parst `Text`-Literale als Markdown und macht aus etwas,
                // das wie eine URL aussieht, einen `Link` (siehe `PhoneAlbumTile`
                // und den Kopf von `PhoneAlbumDetailView`).
                //
                // Befund aus der Sichtprüfung: Das allein genügte hier NICHT. Auch
                // als `String` übergeben blieb die Adresse antippbar — ein Tipp
                // genau auf die Zeichen sprang aus dem Reiter zurück zu „Alben"
                // (ein Tipp auf die Beschriftung „Adresse" links daneben und auf
                // die Zeile „Zustand" darunter tat dagegen nichts; damit ist es
                // die Adresse selbst und nicht die Zeile). Die Erklärung liegt
                // unterhalb von Markdown: Der Text sieht wie eine URL aus, und
                // etwas im Zusammenspiel von `List` und `Text` erkennt sie.
                // `.allowsHitTesting(false)` nimmt der Zeichenfolge die
                // Antippbarkeit — anzeigen soll sie hier ohnehin nur.
                Text(verbatim: serverAdresse)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .allowsHitTesting(false)
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Status")
                Spacer(minLength: 8)
                Image(systemName: status.symbol)
                    .foregroundStyle(status.istVerbunden ? Marke.akzent : Color.secondary)
                Text(status.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    /// Aus dem Keychain, nicht aus `apiClient.baseURL`: Der Client fehlt in genau den
    /// Zuständen, in denen die Adresse am interessantesten ist. Leer kann sie hier
    /// trotzdem sein (abgemeldet) — dann steht ein Platzhalter statt einer leeren
    /// Zeile.
    private var serverAdresse: String {
        let adresse = connection.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return adresse.isEmpty ? String(localized: "not set up") : adresse
    }

    // MARK: - Offline-Alben

    private var offlineAbschnitt: some View {
        Section {
            if zusammenfassung.istLeer {
                Text(leerHinweis)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(zeilen) { zeile in
                    offlineZeile(zeile)
                }
            }
        } header: {
            HStack {
                Text("Offline Albums")
                Spacer()
                if !zusammenfassung.istLeer {
                    // Die Gesamtsumme aus `PhoneStorageSummary` — dieselbe Rechnung
                    // wie über die Einzelzeilen, nur einmal an einer Stelle.
                    Text(gesamtText)
                        .monospacedDigit()
                }
            }
        } footer: {
            if let letzteFreigabe {
                Text(letzteFreigabe)
                    .font(.caption)
            }
        }
    }

    private var leerHinweis: String {
        String(localized: "No albums are kept offline. You’ll find the switch in an album tile’s context menu and in the album’s header.")
    }

    private var gesamtText: String {
        let anzahl = zusammenfassung.anzahlAlben
        return String(localized: "\(zusammenfassung.gesamtGroesse) · \(anzahl) albums")
    }

    @ViewBuilder
    private func offlineZeile(_ zeile: PhoneOfflineZeile) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: zeile.kind.iconName)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(zeile.name)
                    .font(.callout)
                    .lineLimit(2)

                Text(zeile.eintrag.zustand.beschreibung)
                    .font(.caption.monospacedDigit())
                    // Der Fehlerfall gewinnt in `PhoneStorageSummary.Eintrag.zustand`
                    // über „vollständig" — hier bekommt er auch die Farbe, wie am
                    // Mac (`OfflineAlbumsSettingsSection`, `.orange`).
                    .foregroundStyle(zeile.eintrag.zustand.istFehler ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(zeile.eintrag.groesse)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                // Ohne Rückfrage — anders als das Abmelden ist das hier lokal und
                // umkehrbar: Ein Tipp auf dasselbe Album im Raster pinnt es wieder.
                // Was passiert, steht dafür in der Fußzeile des Abschnitts.
                Button("Remove", role: .destructive) {
                    freigeben(zeile)
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .disabled(connection.apiClient == nil)
            }
        }
        .padding(.vertical, 2)
    }

    /// Entfernt den Vermerk über denselben einzigen Aufruf, den auch das Raster und
    /// der Mac benutzen — `setPinned(false, …)` räumt danach die nicht mehr
    /// gepinnten Originale weg (`OfflinePinStore.swift:113-116`). Ein direktes
    /// `unpin(…)` ließe die Dateien liegen.
    private func freigeben(_ zeile: PhoneOfflineZeile) {
        guard let apiClient = connection.apiClient else { return }
        PhoneOfflineModel.hebeAuf(
            kind: zeile.kind,
            targetId: zeile.targetId,
            displayName: zeile.name,
            context: modelContext,
            apiClient: apiClient
        )
        letzteFreigabe = String(localized: "“\(zeile.name)” is no longer kept offline — \(zeile.eintrag.groesse) will be removed from this device.")
    }

    // MARK: - Orte

    /// Der manuelle Neuaufbau. Anders als der Hintergrundlauf (alle 15 Minuten
    /// beim Öffnen des Reiters) wirft er auch die gezählten Städte weg — der Weg
    /// für nachträglich geografierte oder gelöschte Fotos.
    private var orteAbschnitt: some View {
        Section {
            Button {
                guard let client = connection.apiClient else { return }
                Task { await orte.aktualisieren(apiClient: client, neuEinlesen: true) }
            } label: {
                HStack {
                    Label("Reload Places", systemImage: "arrow.clockwise")
                    Spacer()
                    if orte.baut {
                        ProgressView()
                    }
                }
            }
            .disabled(orte.baut || connection.apiClient == nil || connection.state.isOffline)
        } header: {
            Text("Places")
        } footer: {
            Text(orteFusszeile)
                .font(.caption)
        }
    }

    private var orteFusszeile: String {
        guard let katalog = orte.katalog else { return String(localized: "Not loaded yet.") }
        let laender = String(localized: "\(katalog.laender.count) countries")
        guard let am = katalog.aufgebautAm else {
            return String(localized: "\(laender), the last run was incomplete.")
        }
        return String(localized: "\(laender), loaded \(am.formatted(.relative(presentation: .named))).")
    }

    // MARK: - Abmelden

    private var abmeldeAbschnitt: some View {
        Section {
            Button(role: .destructive) {
                // Setzt NUR das Flag. Das Abmelden selbst steht ausschließlich
                // im Bestätigungsknopf des Blattes unten.
                zeigtAbmeldeFrage = true
            } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } footer: {
            Text(abmeldeFusszeile)
                .font(.caption)
        }
        // Ein Blatt, nicht mehr der `.alert` von vorher — ein `.alert` trägt
        // keinen Schalter, und die Wahl "auch die geladenen Originale entfernen"
        // gehört in denselben Schritt wie die Rückfrage. Die Begründung gegen
        // `confirmationDialog` gilt unverändert: iOS 26 zeigte darin auf dem
        // iPhone nur die rote Taste und ließ "Abbrechen" weg.
        .sheet(isPresented: $zeigtAbmeldeFrage) {
            PhoneAbmeldeBlatt(
                serverAdresse: serverAdresse,
                offlineGroesse: zusammenfassung.gesamtGroesse,
                offlineAnzahl: zeilen.count,
                abmelden: { auchOriginale in
                    zeigtAbmeldeFrage = false
                    Task { await abmelden(auchOriginale: auchOriginale) }
                },
                abbrechen: { zeigtAbmeldeFrage = false }
            )
        }
    }

    /// Räumt auf und meldet ab.
    ///
    /// Die Reihenfolge steckt in ``AccountDataPurge/abmeldenUndAufraeumen(umfang:connection:container:defaults:)``;
    /// hier steht nur der Teil, der in `Sources/Shared` nichts zu suchen hat: Der
    /// Fotos-Reiter hängt als `@State` an `PhoneRootView` und behielte sonst die
    /// Seiten des Vorkontos, weil seine Wache bei gleicher Server-URL nicht neu
    /// lädt (`PhonePhotoFeed.brauchtNeuladen`). Dasselbe gilt für den
    /// Orte-Reiter, dessen Katalog sonst die Orte des Vorkontos zeigte.
    private func abmelden(auchOriginale: Bool) async {
        await AccountDataPurge.abmeldenUndAufraeumen(
            umfang: AccountDataPurge.Umfang(offlineOriginale: auchOriginale),
            connection: connection,
            container: modelContext.container
        )
        photoFeed.leere()
        orte.leere()
    }

    private var abmeldeFusszeile: String {
        String(localized: "To sign in again, you’ll need the server address and API key.")
    }

    // MARK: - Version

    private var versionAbschnitt: some View {
        Section {
            Button(OnboardingTexts.vorspannErneut) { zeigtVorspann = true }
                .fullScreenCover(isPresented: $zeigtVorspann) {
                    OnboardingVorspann(letzterKnopf: OnboardingTexts.fertigKnopf) { zeigtVorspann = false }
                }
            LabeledContent("Version") {
                Text(versionText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            NavigationLink(PhoneLizenzenView.titel) { PhoneLizenzenView() }
        }
    }

    /// Aus dem Bundle, nicht fest verdrahtet — sonst zeigte die Zeile nach der
    /// nächsten Versionserhöhung in `project.yml` etwas Falsches.
    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let kurz = (info?["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let build = (info?["CFBundleVersion"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch (kurz?.isEmpty == false ? kurz : nil, build?.isEmpty == false ? build : nil) {
        case let (k?, b?): return "\(k) (\(b))"
        case let (k?, nil): return k
        case let (nil, b?): return String(localized: "Build \(b)")
        case (nil, nil):    return String(localized: "unknown")
        }
    }

    // MARK: - Zahlen

    /// Schnappschuss der Vermerke, Zahlen im Hintergrund, Ergebnis zurück auf den
    /// MainActor — genau wie `OfflineAlbumsSettingsSection.refreshStats()` am Mac.
    /// `LocalFileCacheManager.status(forAssetIds:container:)` fetcht je Vermerk über
    /// alle Assets mit lokaler Datei; das gehört nicht in den View-Body.
    ///
    /// Bewusst **kein** `guard !wirdBerechnet else { return }`: Ändern sich die
    /// Vermerke (Freigeben), während ein Lauf noch rechnet, kehrte ein neuer Lauf
    /// damit wirkungslos zurück — und der alte schriebe danach sein veraltetes
    /// Ergebnis, in dem das freigegebene Album noch steht. Nachgeholt würde das von
    /// niemandem: Entpinnen stößt keinen Sync-Lauf an, erst der nächste
    /// Reiterwechsel heilte die Anzeige. Stattdessen zählt `berechnungsLauf` hoch;
    /// wer nach seinem `await` eine andere Zahl vorfindet, verwirft sein Ergebnis.
    private func kennzahlenNeuBerechnen() async {
        guard !pins.isEmpty else {
            zeilen = []
            return
        }
        berechnungsLauf &+= 1
        let meinLauf = berechnungsLauf
        wirdBerechnet = true
        defer { if meinLauf == berechnungsLauf { wirdBerechnet = false } }

        let container = modelContext.container
        let speicher = OfflineWahlSpeicher()
        let schnappschuesse = pins.map {
            PhonePinSchnappschuss(
                pinId: $0.pinId,
                kind: $0.kind,
                targetId: $0.targetId,
                name: $0.displayName,
                assetIds: $0.assetIds,
                fehler: $0.lastError,
                wahl: speicher.wahl(fuer: $0.pinId)
            )
        }

        let ergebnis = await Task.detached(priority: .utility) { () -> [PhoneOfflineZeile] in
            schnappschuesse.map { schnappschuss in
                let status = LocalFileCacheManager.statusAufPlatte(
                    forAssetIds: schnappschuss.assetIds,
                    wahl: schnappschuss.wahl,
                    container: container
                )
                return PhoneOfflineZeile(
                    id: schnappschuss.pinId,
                    kind: schnappschuss.kind,
                    targetId: schnappschuss.targetId,
                    eintrag: PhoneStorageSummary.Eintrag(
                        name: schnappschuss.name,
                        vorhanden: status.present,
                        erwartet: status.expected,
                        bytes: status.bytes,
                        fehler: schnappschuss.fehler
                    )
                )
            }
        }.value

        // Überholt? Dann gehört das Ergebnis zu einem Stand, den es nicht mehr gibt.
        guard meinLauf == berechnungsLauf else { return }
        zeilen = ergebnis
    }
}
