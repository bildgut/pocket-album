import SwiftUI
import SwiftData
import ImageIO
import Nuke
import NukeUI
import UIKit

/// Diashow eines Albums: Vollbild, schwarzer Grund, alle vier Sekunden das
/// nächste Bild, am Ende wieder von vorn.
///
/// **Wofür das gebaut ist.** Für die Bildschirmsynchronisierung auf einen
/// Apple TV — bei den Eltern, mit schlechtem Internet, aber lokalem WLAN. Aus
/// diesem einen Anwendungsfall folgt fast jede Entscheidung hier:
///
/// - **Die lokale Datei gewinnt.** Ein offline gehaltenes Album liegt als
///   Originaldatei auf dem Gerät; die Diashow nimmt sie, wenn es sie gibt, und
///   nur sonst das Vorschaubild vom Server. Die Wahl trifft nicht diese
///   Ansicht, sondern der geprüfte `PhoneMediaSource`
///   (`Sources/ImmichPhone/PhoneMediaSource.swift`) — dieselbe Entscheidung
///   wie im Einzelbild und im Player.
/// - **`.fit`, nicht `.fill`.** Auf einem Fernseher zählt das ganze Bild; ein
///   beschnittenes Hochformat verliert Köpfe. Schwarze Balken sind auf
///   schwarzem Grund ohnehin nicht zu sehen.
/// - **Der Bildschirm darf nicht einschlafen.** Sonst sperrt sich das Telefon
///   mitten in der Vorführung und der Fernseher wird schwarz. Wie das
///   zuverlässig zurückgesetzt wird, steht bei ``PhoneRuhemodus``.
/// - **Das nächste Bild wird vorgeladen** — lokal vorab dekodiert, vom Server
///   über Nukes `ImagePrefetcher` in den Speicher-Cache geholt. Ohne das
///   blitzt bei jedem Wechsel für einen Moment Schwarz auf.
///
/// **Videos werden ausgelassen.** Die Begründung und der Weg, das später
/// umzudrehen, stehen bei ``PhoneDiashowFolge`` — dort sitzt die Filterung,
/// nicht hier.
///
/// **Bedienung.** Antippen blendet Pause/Weiter und Schließen ein; nach ein
/// paar Sekunden verschwinden sie wieder, damit auf dem Fernseher nichts
/// steht. Wischen blättert von Hand und hält dabei den Automatik-Lauf an — wer
/// von Hand blättert, will nicht nach vier Sekunden überfahren werden.
struct PhoneDiashowView: View {

    /// Die Einträge des Albums in Anzeigereihenfolge, wie
    /// `PhoneAlbumDetailView` sie ohnehin schon hält. Videos darin sind
    /// erlaubt und werden von ``PhoneDiashowFolge`` ausgelassen.
    let eintraege: [PhoneAlbumGridEintrag]

    /// Nur für die Fernbedienung: Auf dem Fernseher steht kein Titel, auf dem
    /// Telefon soll man sehen, was da gerade läuft.
    let albumName: String

    /// Ob ein Zweitbildschirm hängt, und was gerade darauf steht. Ein
    /// `@Observable`-Einzelstück, kein `@State`: Die Zweitbildschirm-Szene
    /// gehört nicht zu dieser Ansicht (siehe ``PhoneBuehne``). Der Zugriff im
    /// Body genügt SwiftUI trotzdem, um bei jedem An- und Abstecken neu zu
    /// zeichnen.
    private let buehne = PhoneBuehne.geteilt

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ConnectionManager.self) private var connection
    @Environment(\.modelContext) private var modelContext

    @State private var folge: PhoneDiashowFolge
    @State private var laeuft = true
    @State private var zeigtBedienung = false
    /// Zählt jeden Anlass, die Bedienebene erneut einzublenden — der
    /// Ausblende-Wecker unten hängt daran, damit ein zweiter Tipp die
    /// Wartezeit von vorn beginnt statt die alte weiterlaufen zu lassen.
    @State private var bedienungGezeigtAm = 0
    /// Vorab dekodierte lokale Originale, nach Asset-Kennung. Höchstens zwei
    /// Einträge gleichzeitig (das gezeigte und das nächste) — siehe
    /// ``behalteNur(_:)``. Ohne diese Grenze liefe eine Diashow über ein Album
    /// mit tausend Fotos in den Speicher.
    @State private var lokaleBilder: [String: UIImage] = [:]
    /// Wärmt die Server-Vorschaubilder vor. Nur angelegt, wenn es überhaupt
    /// eine Pipeline gibt.
    @State private var vorlader: ImagePrefetcher?
    /// Hält den Ruhemodus aus, solange dieses Objekt lebt — siehe
    /// ``PhoneWachhalter``.
    @State private var wachhalter = PhoneWachhalter()

    init(eintraege: [PhoneAlbumGridEintrag], albumName: String) {
        self.eintraege = eintraege
        self.albumName = albumName
        _folge = State(initialValue: PhoneDiashowFolge(eintraege: eintraege))
    }

    /// Vollbild oder Fernbedienung — die eine Folgerung aus der Anwesenheit
    /// eines Zweitbildschirms, gezogen in einem geprüften Wertetyp statt in
    /// vier verstreuten `if`-Abfragen (siehe ``PhoneDiashowRolle``).
    private var rolle: PhoneDiashowRolle {
        .fuer(zweitbildschirmAngeschlossen: buehne.angeschlossen)
    }

    /// Vier Sekunden je Bild. Kein einstellbarer Wert: Es gibt (Stand dieser
    /// Fassung) keinen Ort im iOS-Client, an dem er stünde, und ein Regler
    /// gehörte in die Einstellungen, nicht in die Vorführung.
    private static let taktSekunden: Double = 4
    /// So lange bleibt die Bedienebene nach einem Tipp stehen.
    private static let bedienungSekunden: Double = 3

    // Immer Variablen, nie Text-Literale: SwiftUI parst `Text`-Literale als
    // Markdown (siehe `PhoneAlbumTile`).
    private static let nurVideosTitel = String(localized: "Only Videos in This Album")
    private static let nurVideosText =
        String(localized: "The slideshow shows photos. It skips videos so it doesn’t stall for minutes.")
    private static let leerTitel = String(localized: "No Photos")
    private static let leerText = String(localized: "There’s nothing to show in this album.")
    private static let schliessenLabel = String(localized: "End Slideshow")
    private static let pauseLabel = String(localized: "Pause")
    private static let weiterLabel = String(localized: "Play")

    var body: some View {
        Group {
            if rolle.zeigtBildGross {
                vollbild
            } else {
                fernbedienung
            }
        }
        // Überblendet den Bildwechsel, statt hart umzuschalten — zusammen mit
        // dem Vorladen ist das der Unterschied zwischen „Diashow" und
        // „Bilderfolge mit schwarzen Zwischenbildern".
        .animation(.easeInOut(duration: 0.35), value: folge.position)
        .animation(.easeInOut(duration: 0.2), value: zeigtBedienung)
        // Beides hängt an der Rolle: Auf dem Fernseher soll nichts stehen als
        // das Bild — auf einer Fernbedienung ist die Uhrzeit dagegen eher
        // nützlich, und der Home-Indikator gehört dorthin, wo bedient wird.
        .statusBarHidden(rolle.verstecktSystemleisten)
        .persistentSystemOverlays(rolle.verstecktSystemleisten ? .hidden : .automatic)
        .task(id: ladeSchluessel) {
            await ladeUndVorlade()
        }
        .task(id: taktSchluessel) {
            await takt()
        }
        .task(id: bedienungGezeigtAm) {
            await blendeBedienungAus()
        }
        .onAppear {
            if rolle.haeltBildschirmWach { wachhalter.an() }
        }
        // Erster und wichtigster Rückweg: greift bei jedem Schließen dieser
        // Ansicht — über den Knopf, über eine Wischgeste des Systems, oder
        // weil die Elternansicht verschwindet.
        .onDisappear {
            wachhalter.aus()
            vorlader?.stopPrefetching()
            // Der Fernseher soll nicht das letzte Bild einfrieren, wenn die
            // Vorführung vorbei ist.
            buehne.raeumen()
        }
        // Zweiter Rückweg: die App geht in den Hintergrund, ohne dass diese
        // Ansicht verschwindet. Der Ruhemodus wirkt zwar ohnehin nur auf die
        // Vordergrund-App, aber den Halt bis zur Rückkehr stehen zu lassen,
        // wäre ein Zustand, der nicht mehr zu dem passt, was zu sehen ist.
        .onChange(of: scenePhase) { _, neu in
            if neu == .active, rolle.haeltBildschirmWach {
                wachhalter.an()
            } else {
                wachhalter.aus()
            }
        }
    }

    // MARK: - Die beiden Rollen

    /// Der Zustand, in dem die Diashow bis hierher immer lief: das Foto
    /// formatfüllend auf dem Telefon, Bedienung nur auf Tipp.
    private var vollbild: some View {
        ZStack {
            // Der schwarze Grund liegt unter allem und über den sicheren
            // Bereich hinaus — auf dem Fernseher soll nichts als das Bild zu
            // sehen sein.
            Color.black.ignoresSafeArea()

            if let eintrag = folge.aktuelles {
                bildinhalt(fuer: eintrag)
                    .id(eintrag.id)
                    .transition(.opacity)
            } else {
                hinweis
            }

            if zeigtBedienung {
                bedienebene
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { zeigeBedienung() }
        .gesture(wischgeste)
    }

    /// Ein Zweitbildschirm hängt: Das Foto steht dort, hier stehen die
    /// Knöpfe. Der Ausstieg bleibt derselbe wie im Vollbild — `dismiss`
    /// schließt den Vorhang, `onDisappear` räumt die Bühne.
    @ViewBuilder
    private var fernbedienung: some View {
        if folge.istLeer {
            ZStack {
                Color.black.ignoresSafeArea()
                hinweis
            }
        } else {
            PhoneDiashowFernbedienung(
                albumName: albumName,
                vorschau: buehne.bild,
                position: folge.position + 1,
                anzahl: folge.bilder.count,
                laeuft: laeuft,
                zurueck: {
                    laeuft = false
                    folge.zurueck()
                },
                weiter: {
                    laeuft = false
                    folge.weiter()
                },
                pauseUmlegen: { laeuft.toggle() },
                schliessen: { dismiss() }
            )
        }
    }

    // MARK: - Takt

    /// Der Schlüssel, an dem der Automatik-Wecker hängt: Er beginnt neu, sobald
    /// sich die Position ändert (auch durch Wischen) oder die Pause umgelegt
    /// wird. Damit gibt es keinen Timer, der abgemeldet werden müsste — die
    /// Aufgabe wird von SwiftUI abgebrochen, wenn der Schlüssel wechselt oder
    /// die Ansicht verschwindet.
    private var taktSchluessel: String { "\(folge.position)|\(laeuft)" }

    /// Der Schlüssel des Ladelaufs. Die Rolle steht bewusst mit darin: Wird
    /// ein Fernseher **mitten** in der Vorführung angesteckt, wechselt sie von
    /// `.vollbild` auf `.fernbedienung`, der Lauf beginnt neu — und schiebt
    /// das gerade gezeigte Bild sofort hinüber, statt erst beim nächsten
    /// Takt.
    private var ladeSchluessel: String {
        "\(folge.aktuelles?.id ?? "")|\(rolle == .fernbedienung)"
    }

    private func takt() async {
        guard laeuft, !folge.istLeer else { return }
        try? await Task.sleep(for: .seconds(Self.taktSekunden))
        guard !Task.isCancelled else { return }
        folge.weiter()
    }

    private func blendeBedienungAus() async {
        guard rolle.bedienungBlendetAus, zeigtBedienung else { return }
        try? await Task.sleep(for: .seconds(Self.bedienungSekunden))
        guard !Task.isCancelled else { return }
        zeigtBedienung = false
    }

    private func zeigeBedienung() {
        zeigtBedienung = true
        bedienungGezeigtAm += 1
    }

    // MARK: - Bildinhalt

    @ViewBuilder
    private func bildinhalt(fuer eintrag: PhoneAlbumGridEintrag) -> some View {
        if let bild = lokaleBilder[eintrag.id] {
            Image(uiImage: bild)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            // Kein lokales Original (oder es ließ sich nicht dekodieren):
            // Vorschaubild vom Server. `ImagePrefetcher` hat es im Regelfall
            // schon im Speicher-Cache, dann erscheint es ohne Ladephase.
            LazyImage(url: fernURL(fuer: eintrag.id)) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: .fit)
                } else if state.error != nil {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.white.opacity(0.6))
                } else {
                    ProgressView().tint(.white)
                }
            }
            .pipeline(connection.imagePipeline ?? .shared)
        }
    }

    private var hinweis: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                folge.nurVideos ? Self.nurVideosTitel : Self.leerTitel,
                systemImage: folge.nurVideos ? "film" : "photo.on.rectangle",
                description: Text(folge.nurVideos ? Self.nurVideosText : Self.leerText)
            )
            Button(Self.schliessenLabel) { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(Marke.akzent)
        }
        .padding()
        // Auf schwarzem Grund braucht `ContentUnavailableView` helle Schrift.
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }

    // MARK: - Bedienebene

    private var bedienebene: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel(Self.schliessenLabel)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            Spacer()

            if !folge.istLeer {
                Button {
                    laeuft.toggle()
                    // Der Tipp auf Pause soll die Leiste nicht sofort wieder
                    // verschwinden lassen — sonst sieht der Nutzer nicht, dass
                    // sich das Symbol geändert hat.
                    zeigeBedienung()
                } label: {
                    Image(systemName: laeuft ? "pause.fill" : "play.fill")
                        .font(.title.weight(.semibold))
                        .foregroundStyle(Marke.akzent)
                        .frame(width: 64, height: 64)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel(laeuft ? Self.pauseLabel : Self.weiterLabel)
                .padding(.bottom, 40)
            }
        }
    }

    /// Von Hand blättern hält den Automatik-Lauf an. Die Schwelle von 50 Punkten
    /// hält ein Antippen mit leichtem Fingerversatz davon ab, als Wisch zu
    /// gelten — sonst blätterte jeder Tipp auf die Bedienebene mit um.
    private var wischgeste: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { wert in
                guard abs(wert.translation.width) > 50 else { return }
                laeuft = false
                if wert.translation.width < 0 {
                    folge.weiter()
                } else {
                    folge.zurueck()
                }
            }
    }

    // MARK: - Laden und Vorladen

    /// Sorgt dafür, dass das gezeigte Bild da ist und das nächste bereitliegt.
    ///
    /// Läuft aus `.task(id:)`, also genau einmal je gezeigtem Bild — nicht bei
    /// jedem Neuzeichnen. Der `FetchDescriptor` unten liefe sonst mitten in
    /// jeder Animation auf dem Hauptthread (dieselbe Überlegung wie bei
    /// `PhoneAssetPage`).
    private func ladeUndVorlade() async {
        guard let aktuell = folge.aktuelles else { return }

        await dekodiereFallsLokal(aktuell.id)
        await versorgeBuehne(aktuell.id)

        // Erst jetzt das nächste — das gezeigte Bild hat Vorrang.
        if let naechstes = folge.naechstes, naechstes.id != aktuell.id {
            await dekodiereFallsLokal(naechstes.id)
            if lokaleBilder[naechstes.id] == nil {
                warmeServerbild(naechstes.id)
            }
            behalteNur([aktuell.id, naechstes.id])
        } else {
            behalteNur([aktuell.id])
        }
    }

    /// Liegt für `assetId` ein Original auf der Platte, wird es
    /// heruntergerechnet dekodiert und gemerkt. Sonst passiert nichts — die
    /// Ansicht fällt dann auf das Vorschaubild vom Server zurück.
    private func dekodiereFallsLokal(_ assetId: String) async {
        guard lokaleBilder[assetId] == nil else { return }
        guard let datei = lokaleOriginaldatei(fuer: assetId) else { return }

        let quelle = PhoneMediaSource.waehle(
            lokaleDatei: datei,
            // Die Fern-URL ist hier nur das Gegenstück für die Wahl; benutzt
            // wird sie in diesem Zweig nicht, `datei` gewinnt. Ohne
            // `apiClient` gibt es gar keine — dann steht ohnehin nur die
            // lokale Quelle zur Wahl.
            fernURL: fernURL(fuer: assetId) ?? datei,
            apiKey: connection.apiClient?.apiKey ?? ""
        )
        guard quelle.istLokal else { return }

        if let bild = await Self.heruntergerechnetesBild(bei: quelle.url, laengsteKante: Self.maxKantenlaenge) {
            lokaleBilder[assetId] = bild
        } else {
            // Halb geschriebener Download oder unbekanntes Format: kein Grund,
            // die Vorführung anzuhalten — der Serverpfad greift.
            AppLogger.library.error(
                "Diashow \(assetId, privacy: .public): lokale Datei nicht dekodierbar, Rückfall auf den Server"
            )
        }
    }

    /// Legt das gezeigte Bild auf die Bühne, damit der Zweitbildschirm es
    /// zeichnen kann — und nur dann, wenn überhaupt einer hängt.
    ///
    /// **Warum hier ein fertiges `UIImage` entsteht, auch für Serverbilder.**
    /// Im Vollbild genügt für ein Serverbild ein `LazyImage`; die
    /// Zweitbildschirm-Szene hat aber weder Pipeline noch API-Schlüssel in der
    /// Hand (Begründung bei ``PhoneBuehne``). Der Umweg kostet nichts
    /// Zusätzliches: `warmeServerbild` hat dasselbe Bild eine Runde vorher
    /// ohnehin schon in Nukes Speicher-Cache gelegt, `image(for:)` findet es
    /// dort und lädt nicht erneut.
    ///
    /// Schlägt das Laden fehl, bleibt das **vorherige** Bild auf dem
    /// Fernseher stehen, statt ihn schwarz zu machen. Ein Aussetzer im WLAN
    /// soll die Vorführung nicht unterbrechen; der Takt schaltet ohnehin nach
    /// vier Sekunden weiter.
    private func versorgeBuehne(_ assetId: String) async {
        guard rolle.versorgtZweitbildschirm else { return }

        if let lokal = lokaleBilder[assetId] {
            buehne.zeige(lokal)
            return
        }
        guard let url = fernURL(fuer: assetId), let pipeline = connection.imagePipeline else { return }
        do {
            let bild = try await pipeline.image(for: url)
            guard !Task.isCancelled else { return }
            buehne.zeige(bild)
        } catch {
            AppLogger.library.error(
                "Zweitbildschirm \(assetId, privacy: .public): Vorschaubild nicht ladbar, voriges bleibt stehen"
            )
        }
    }

    /// Holt das Vorschaubild des nächsten Assets in Nukes Speicher-Cache,
    /// damit `LazyImage` es beim Wechsel sofort hat.
    ///
    /// Anders als `PhoneCoverPrefetcher` (`destination: .diskCache`, für
    /// Titelbilder, die einen App-Neustart überleben sollen) geht es hier um
    /// die nächsten vier Sekunden — also in den Speicher.
    private func warmeServerbild(_ assetId: String) {
        guard let url = fernURL(fuer: assetId) else { return }
        if vorlader == nil, let pipeline = connection.imagePipeline {
            let neuer = ImagePrefetcher(pipeline: pipeline)
            neuer.priority = .high
            vorlader = neuer
        }
        vorlader?.startPrefetching(with: [url])
    }

    private func fernURL(fuer assetId: String) -> URL? {
        connection.apiClient?.thumbnailURL(assetId: assetId, size: .preview)
    }

    /// Wirft alle vorgehaltenen Bitmaps weg, die nicht mehr gebraucht werden.
    private func behalteNur(_ ids: [String]) {
        lokaleBilder = lokaleBilder.filter { ids.contains($0.key) }
    }

    /// Die Suche nach der lokalen Datei kommt aus `PhoneOriginaldatei`.
    ///
    /// Während des Baus stand hier eine bewusste Dopplung: An `PhoneAssetView`
    /// wurde parallel gearbeitet, und zwei Sitzungen auf derselben Datei haben
    /// uns zweimal Zeit gekostet. Inzwischen ist die Suche dort als eigener,
    /// `internal` sichtbarer Typ herausgelöst — sie lässt sich also aufrufen,
    /// **ohne** jene Datei anzufassen. Damit entfällt der Grund für die
    /// Dopplung, und sie ist hier wieder entfernt.
    private func lokaleOriginaldatei(fuer assetId: String) -> URL? {
        PhoneOriginaldatei.aufPlatte(assetId: assetId, context: modelContext)
    }

    /// Obergrenze für die längste Kante beim Dekodieren — wie im Einzelbild
    /// (`PhoneAssetPage.maxKantenlaenge`). Ein 50-MP-Original in voller
    /// Auflösung wären grob 150–200 MB Bitmapdaten, und die Diashow hält
    /// **zwei** Bilder gleichzeitig vor. 3000 px decken die längste
    /// iPhone-Bildschirmkante (≈ 2796 px auf einem iPhone 16 Pro Max) und
    /// damit auch das, was die Bildschirmsynchronisierung an den Fernseher
    /// weitergibt: Gespiegelt wird der Telefonbildschirm, nicht das Original.
    private static let maxKantenlaenge: CGFloat = 3000

    /// Dekodiert `url` gleich heruntergerechnet, auf einem Hintergrundthread.
    /// `kCGImageSourceCreateThumbnailWithTransform` bäckt die EXIF-Ausrichtung
    /// in die Pixel ein — ohne das läge ein hochkant fotografiertes Bild quer.
    ///
    /// Dieselbe Dopplung wie oben und aus demselben Grund: Das Gegenstück
    /// steht in `PhoneAssetView.swift` und gehört später mit dieser Fassung
    /// zusammengelegt.
    private static func heruntergerechnetesBild(bei url: URL, laengsteKante: CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: laengsteKante
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            return UIImage(cgImage: cgImage)
        }.value
    }
}

/// Zählt die Halter des ausgesetzten Ruhemodus, statt `isIdleTimerDisabled`
/// von mehreren Stellen aus direkt zu setzen.
///
/// **Warum gezählt wird.** `isIdleTimerDisabled` ist ein einzelner globaler
/// Schalter. Setzt ihn eine Ansicht beim Erscheinen auf `true` und eine andere
/// beim Verschwinden auf `false`, gewinnt die letzte Zuweisung — und der
/// Bildschirm schläft mitten in einer laufenden Vorführung ein. Mit einem
/// Zähler ist der Schalter genau dann aus, wenn ihn niemand mehr hält. Heute
/// gibt es nur einen Halter; die Zählung kostet vier Zeilen und macht den
/// zweiten ungefährlich.
@MainActor
enum PhoneRuhemodus {
    private static var haltegriffe = 0

    static func halten() {
        haltegriffe += 1
        anwenden()
    }

    static func freigeben() {
        haltegriffe = max(0, haltegriffe - 1)
        anwenden()
    }

    private static func anwenden() {
        UIApplication.shared.isIdleTimerDisabled = haltegriffe > 0
    }
}

/// Ein Halt auf ``PhoneRuhemodus``, gebunden an die Lebensdauer dieses
/// Objekts.
///
/// **Warum ein Objekt und nicht zwei Zeilen in der Ansicht.** Der Auftrag
/// verlangt, dass der Ruhemodus *zuverlässig* zurückkommt — auch wenn die
/// Ansicht anders geschlossen wird als über den Knopf. Es gibt drei Wege
/// hinaus, und dieses Objekt deckt alle drei ab:
///
/// 1. `.onDisappear` in `PhoneDiashowView` — der Regelfall (Knopf, Wischgeste,
///    verschwindende Elternansicht).
/// 2. Der Wechsel der Szenenphase — die App geht in den Hintergrund, ohne dass
///    die Ansicht verschwindet.
/// 3. `deinit` — das Netz unter dem Netz. Wird das Objekt freigegeben, ohne
///    dass eines der beiden griff, geht der Halt trotzdem zurück. Genau dafür
///    zählt ``PhoneRuhemodus``: Ein verspätetes Freigeben aus `deinit` kann
///    keinen fremden, inzwischen gesetzten Halt versehentlich aufheben, es
///    nimmt nur den eigenen zurück.
///
/// `an()` und `aus()` sind gegen Mehrfachaufrufe unempfindlich (`haelt`), damit
/// ein zweites `.onAppear` oder ein Szenenwechsel hin und her den Zähler nicht
/// hochtreibt.
@MainActor
final class PhoneWachhalter {
    private var haelt = false

    func an() {
        guard !haelt else { return }
        haelt = true
        PhoneRuhemodus.halten()
    }

    func aus() {
        guard haelt else { return }
        haelt = false
        PhoneRuhemodus.freigeben()
    }

    deinit {
        guard haelt else { return }
        // `deinit` ist nicht an den MainActor gebunden, `PhoneRuhemodus` schon
        // — deshalb über eine Aufgabe. Dass sie erst im nächsten
        // Runloop-Durchlauf läuft, ist unkritisch: Der Zähler nimmt genau
        // diesen einen Halt zurück, egal wer inzwischen einen eigenen hält.
        Task { @MainActor in
            PhoneRuhemodus.freigeben()
        }
    }
}
