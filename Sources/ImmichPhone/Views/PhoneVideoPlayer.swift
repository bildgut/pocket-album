import SwiftUI
import AVKit
import NukeUI
import UIKit

/// Wiedergabe eines Videos auf einer Seite von `PhoneAssetView`.
///
/// **Warum `VideoPlayer` aus AVKit und nicht der Mac-Weg:** Der Mac-Client
/// baut in `Sources/ImmichMac/Views/VideoPlayerView.swift` eine eigene
/// Bedienleiste über einen `NSViewRepresentable` — das ist ein macOS-eigener
/// Umweg (AppKit hat kein SwiftUI-`VideoPlayer`). Unter iOS liefert AVKit den
/// Player samt Transportleiste direkt als SwiftUI-Ansicht; nachgebaut werden
/// müsste hier nichts.
///
/// **Der API-Schlüssel steht in den Kopfzeilen, nicht in der URL** — dieselbe
/// Stelle wie am Mac (`VideoPlayerView.setupPlayer`, dort Zeile 149–152):
/// `AVURLAsset(url:options:)` mit `AVURLAssetHTTPHeaderFieldsKey`. Ein
/// Schlüssel im Query-Teil landete in Protokollen, Proxy-Caches und der
/// Verlaufsliste jedes Zwischenstücks.
///
/// **Und bei einer lokalen Datei gar keine Kopfzeilen.** Liegt das Original
/// eines gepinnten Albums auf der Platte, spielt der Player es von dort —
/// das ist der Punkt der ganzen Änderung, denn ein Strom über `playbackURL`
/// braucht ein Netz, das offline nicht da ist. Welche der beiden Quellen es
/// wird, entscheidet `PhoneMediaSource`; von dort kommt auch das
/// `options`-Wörterbuch (`avAssetOptions`, für eine Datei `nil`). Die
/// Optionen hier ein zweites Mal von Hand zu bauen, wäre genau die Stelle,
/// an der eine `x-api-key`-Kopfzeile an eine `file://`-URL geriete.
///
/// **Offene Lücke: kein Weiterleitungsschutz.** Alle `URLSession`s der App laufen
/// über `SichereWeiterleitung`, das eine Weiterleitung auf einen fremden Host samt
/// `x-api-key` abbricht. `AVURLAsset` hat dafür keinen Haken: Die Kopfzeilen aus
/// `AVURLAssetHTTPHeaderFieldsKey` gehen bei einer Weiterleitung mit. Absichern
/// ließe sich das nur über einen `AVAssetResourceLoaderDelegate` mit eigenem
/// Schema, der jede Byte-Range selbst per `URLSession` holt (Content-Info,
/// Range-Anfragen, Abbruch, HLS-Wiedergabelisten) — geprüft am 29.09.2026 und
/// als zu schwer verworfen. Das Risiko setzt einen Server voraus, der
/// `/api/assets/…/video/playback` auf einen fremden Host umleitet; derselbe Server
/// sieht den Schlüssel ohnehin.
///
/// ---
///
/// **Hängt ein Zweitbildschirm, läuft das Bild dort — und zwar über unsere
/// eigene Szene, nicht über nativen AirPlay.** Der Grund steht ausführlich an
/// ``PhoneVideoRolle``, kurz: Bei nativem AirPlay holt sich der Apple TV die
/// Datei selbst vom Immich-Server, und der API-Schlüssel aus
/// `AVURLAssetHTTPHeaderFieldsKey` überlebt den Weg dorthin nicht — der
/// Fernseher blieb schwarz. Reicht das Telefon stattdessen seinen `AVPlayer`
/// an die ``PhoneBuehne`` weiter, streamt weiterhin das Telefon (mit
/// Schlüssel, oder gleich von der Platte) und der Fernseher bekommt nur Pixel.
/// Ein offline gehaltenes Video läuft damit ganz ohne Server.
///
/// Die Ansicht auf dem Telefon wechselt dann von `VideoPlayer` zu
/// ``bedienungAufDerBuehne`` — dasselbe Muster wie `PhoneDiashowView` und ihre
/// `PhoneDiashowFernbedienung`. Welche Ansicht gilt und was beim Wechsel mit
/// dem Player geschieht, entscheidet ``PhoneVideoRolle``; das ist der prüfbare
/// Teil, den Rest kann ohne echten Apple TV niemand nachstellen.
///
/// ---
///
/// Die vier Fallen aus Schritt 3 des Plans, und wie sie hier gelöst sind:
///
/// **(1) Weiterwischen muss anhalten.** `isCurrentPage` reicht
/// `PhoneAssetView` bereits durch (`index == currentIndex`, dieselbe Angabe,
/// die auch `PageScrollLock` steuert). Sobald sie auf `false` fällt, läuft
/// `beende()`: pausieren, Player freigeben, Tonsitzung schließen. Bewusst
/// *freigeben* statt nur pausieren — `TabView(.page)` hält Nachbarseiten
/// eingehängt, ein bloß pausierter Player bliebe also samt Puffer und
/// Netzverbindung am Leben, und `.onDisappear` ist beim `.page`-Stil
/// nachweislich unzuverlässig (siehe der Kommentar zu `.onAppear` in
/// `PhoneAssetView`). So existiert zu jedem Zeitpunkt höchstens **ein**
/// `AVPlayer`. Preis: Wer zurückwischt, fängt von vorn an. `.onDisappear`
/// ruft dieselbe Aufräumung zusätzlich auf — für den Fall, dass das
/// Einzelbild als Ganzes geschlossen wird, ohne dass `isCurrentPage` je
/// wechselt.
///
/// Seit der Player auch auf der ``PhoneBuehne`` liegen kann, hängt daran
/// mehr als vorher: Die Bühne hält eine **zweite starke Referenz**. Bliebe
/// sie stehen, stürbe der Player nicht mit der Ansicht — der Ton liefe
/// weiter, während der Nutzer längst weitergewischt ist. Deshalb nimmt
/// `beende()` ihn ausdrücklich von der Bühne zurück, **bevor** es die
/// eigene Referenz fallen lässt, und tut das unabhängig von der Rolle: Ein
/// `nimmSpielerZurueck` für einen Player, der gar nicht drauflag, ist ein
/// Nichts; ein vergessenes wäre ein hörbarer Fehler.
///
/// **(2) Der Zoom gilt für Bilder, nicht für Videos.** Diese Ansicht trägt
/// weder `scaleEffect` noch `MagnifyGesture` — beides bleibt im Bildzweig von
/// `PhoneAssetPage`. Entscheidend ist die andere Hälfte: `PageScrollLock`
/// schreibt für eine Videoseite immer `isLocked: false` (siehe dort). Ohne das
/// könnte die geteilte `UIScrollView` gesperrt zurückbleiben — die Wischsperre
/// hinge in einem Zustand fest, aus dem sie nicht zurückfindet, weil auf einer
/// Videoseite nichts mehr existiert, das sie wieder öffnen würde.
///
/// **(3) Ton bei stummgeschaltetem Klingelschalter** — siehe
/// `aktiviereTonsitzung()`.
///
/// **(4) Kein Autostart** — siehe `standbildMitStartknopf`.
struct PhoneVideoPlayer: View {
    let assetId: String
    /// Von `PhoneAssetView` durchgereicht: `index == currentIndex`. Einzige
    /// Quelle für „diese Seite ist sichtbar" — siehe Falle (1) oben.
    let isCurrentPage: Bool
    /// Die bereits geprüfte Originaldatei auf der Platte, sonst `nil`.
    ///
    /// Ebenfalls durchgereicht, statt hier selbst nachzuschlagen: Der
    /// `FetchDescriptor<CachedAsset>` steht einmal in `PhoneAssetPage`, im
    /// `.task` und damit nicht im Zeichenpfad (Begründung dort). Diese Ansicht
    /// wird bei jedem Wischen und jeder Änderung am `ConnectionManager` neu
    /// aufgebaut — ein eigener Fetch liefe entsprechend oft.
    let lokaleDatei: URL?
    /// Der Dateiname des Originals, sofern bekannt — nur für die Bedienung auf
    /// dem Telefon, während das Bild auf dem Fernseher läuft. Kommt aus
    /// demselben `.task` wie `lokaleDatei` (ein `CachedAsset` je Seite, siehe
    /// `PhoneAssetPage`); `nil`, solange kein Eintrag im Cache steht.
    let titel: String?

    // Immer Konstanten, nie Text-Literale: SwiftUI parst `Text`-Literale als
    // Markdown (siehe `PhoneAlbumTile`), und ein Dateiname mit Unterstrichen
    // käme kursiv heraus.
    private static let buehnenHinweis = String(localized: "Playing on TV")
    private static let ohneTitel = String(localized: "Video")
    private static let beendenLabel = String(localized: "Stop Playback")

    @Environment(ConnectionManager.self) private var connection

    /// Der Zweitbildschirm. Zugriff im `body` macht diese Ansicht von den
    /// Änderungen abhängig — dieselbe Konstruktion wie in `PhoneDiashowView`.
    private let buehne = PhoneBuehne.geteilt

    /// Wo das Videobild hingehört. Eine Stelle statt verstreuter `if`-Abfragen
    /// — Begründung an ``PhoneVideoRolle``.
    private var rolle: PhoneVideoRolle {
        .fuer(zweitbildschirmAngeschlossen: buehne.angeschlossen)
    }

    @State private var player: AVPlayer?
    @State private var fehler: String?

    /// Was der Abspielknopf der Bedienung gerade anbietet.
    ///
    /// **Zwei Quellen, mit Absicht** — die Begründung steht ausführlich an
    /// ``PhoneAbspielknopf``: Der Tipp setzt sofort (``PhoneAbspielknopf/getippt()``),
    /// damit die Anzeige nie festhängt, und ``beobachteSpielstand(_:)`` führt
    /// aus dem Player nach, damit sie am Ende des Videos und bei einem
    /// Pufferstillstand stimmt.
    @State private var knopf = PhoneAbspielknopf.fortsetzen

    /// Der Beobachter, der ``knopf`` nachführt.
    @State private var spielstandBeobachtung: Task<Void, Never>?

    /// Das aus der lokalen Datei gewonnene Standbild, sonst `nil`.
    /// `nil` ist kein Fehlerzustand: Es heißt nur „nimm den Serverweg"
    /// — siehe `standbildMitStartknopf`.
    @State private var lokalesStandbild: UIImage?

    /// Steht auf `true`, sobald die lokale Datei einmal gescheitert ist und auf
    /// den Server ausgewichen wurde. Verhindert ein Hin und Her, falls auch der
    /// Server nicht liefert. Wird beim Aufräumen zurückgesetzt.
    @State private var lokalGescheitert = false

    /// Der Beobachter, der auf einen Fehlschlag der lokalen Datei wartet.
    @State private var statusBeobachtung: Task<Void, Never>?

    var body: some View {
        ZStack {
            if let player {
                if rolle.zeigtVideoAufTelefon {
                    VideoPlayer(player: player)
                } else {
                    // Das Bild läuft auf dem Fernseher; hier stehen nur noch
                    // die Knöpfe. Der Player wird trotzdem hier gehalten — er
                    // gehört dieser Ansicht, die Bühne leiht ihn sich nur.
                    bedienungAufDerBuehne(player)
                }
            } else {
                standbildMitStartknopf
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Das Standbild wird geladen, nicht gezeichnet: `AVAssetImageGenerator`
        // dekodiert ein Videobild, das gehört in ein `.task` und nicht in den
        // Rumpf, der bei jedem Wischen und jeder Änderung am
        // `ConnectionManager` erneut ausgewertet wird. `id: lokaleDatei` sorgt
        // dafür, dass die Aufgabe beim Seitenwechsel neu anläuft (und die alte
        // abgebrochen wird) — dieselbe Datei zweimal zu dekodieren, wäre
        // verschwendete Zeit.
        .task(id: lokaleDatei) {
            await ladeLokalesStandbild()
        }
        // Falle (1): Der Wechsel der aktuellen Seite ist das tragende Signal,
        // nicht `.onDisappear`.
        .onChange(of: isCurrentPage) { _, istAktuell in
            if !istAktuell {
                beende()
                // Der Merker gehört zum Abspielversuch, nicht zum Video: Wer
                // zurückwischt, soll es wieder von der Platte versuchen dürfen.
                // Bewusst hier und nicht in `beende()` — das ruft der Rückfall
                // selbst auf, und dort zurückgesetzt liefe er im Kreis.
                lokalGescheitert = false
                fehler = nil
            }
        }
        .onDisappear {
            beende()
            lokalGescheitert = false
            fehler = nil
        }
        // Der Zweitbildschirm kann **während** der Wiedergabe kommen oder
        // gehen: Der Nutzer schaltet die Bildschirmsynchronisierung mitten im
        // Video ein, oder der Apple TV fällt weg. Beides darf die Wiedergabe
        // nicht abreißen lassen — nur das Ziel wechselt. Was dabei zu tun ist,
        // entscheidet `PhoneVideoRolle.schritt`; hier steht nur die Ausführung.
        .onChange(of: rolle) { alt, neu in
            switch PhoneVideoRolle.schritt(von: alt, nach: neu, spielerVorhanden: player != nil) {
            case .nichts:
                break
            case .uebergeben:
                if let player { buehne.zeige(spieler: player) }
            case .zuruecknehmen:
                if let player { buehne.nimmSpielerZurueck(player) }
            }
        }
    }

    /// **Das Vorschaubild kommt von der Platte, wenn das Original dort liegt.**
    /// Vorher ging es ausnahmslos über `LazyImage` gegen den Server — ohne Netz
    /// zeigte eine Videoseite deshalb nur den Startknopf auf schwarzem Grund,
    /// obwohl die Wiedergabe selbst von der Platte lief. Jetzt gewinnt
    /// `PhoneVideoPoster.bild(fuer:)` aus `lokaleDatei` ein Bild; erst wenn es
    /// keine Datei gibt oder sie sich nicht dekodieren lässt, bleibt es beim
    /// bisherigen `LazyImage`-Weg. Dieselbe Reihenfolge wie im Bildzweig von
    /// `PhoneAssetPage` (lokal zuerst, Server als Rückfall) und dieselbe wie
    /// bei der Wiedergabe selbst (`wiedergabequelle`).
    ///
    /// Der Grund, warum das lange offen blieb, ist mit dem Test weg: Auf dem
    /// Gerät liegt kein einziges Videooriginal lokal (das gepinnte Album
    /// enthält nur Fotos), es gab also nichts zum Prüfen.
    /// `Tests/ImmichPhoneTests/PhoneVideoPosterTests.swift` erzeugt sich das
    /// fehlende Video selbst.
    ///
    /// **Falle (4): Kein Autostart über die ganze Mediathek.** Eine Videoseite
    /// zeigt zunächst dasselbe Vorschaubild wie eine Fotoseite plus einen
    /// Startknopf; erst ein Tipp erzeugt überhaupt einen `AVPlayer`.
    ///
    /// Begründung der Wahl: `TabView(.page)` baut die Nachbarseiten im Voraus
    /// auf. Startete die jeweils aktuelle Seite von selbst, liefe beim
    /// Durchwischen eines Albums ein Video nach dem anderen an — jedes mit
    /// eigener Netzverbindung und, seit Falle (3), hörbar. Das ist genau das
    /// Verhalten, das der Plan ausschließt. Der Tipp ist außerdem die
    /// Rechtfertigung für Falle (3): Ton über den Klingelschalter hinweg ist
    /// nur vertretbar, wenn der Nutzer die Wiedergabe *angefordert* hat.
    ///
    /// Über den Server ist das Standbild dieselbe `preview`-Auflösung wie im
    /// Bildzweig von `PhoneAssetPage`, von der Platte dieselbe Obergrenze von
    /// 3000 px (`PhoneVideoPoster`) — die Seite bleibt damit auf beiden Wegen
    /// optisch ruhig, statt beim Wischen zwischen Foto und Video zwischen Bild
    /// und schwarzer Fläche zu springen.
    private var standbildMitStartknopf: some View {
        ZStack {
            if let lokalesStandbild {
                Image(uiImage: lokalesStandbild)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                LazyImage(url: connection.apiClient?.thumbnailURL(assetId: assetId, size: .preview)) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Color.clear
                    }
                }
                // `.pipeline` ist in NukeUI eine Instanzmethode auf `LazyImage`,
                // kein Umgebungsmodifier — am umgebenden `ZStack` gesetzt
                // kompilierte es nicht.
                .pipeline(connection.imagePipeline ?? .shared)
            }

            VStack(spacing: 12) {
                Button {
                    starte()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 28, weight: .semibold))
                        // Weiß auf `.thinMaterial` wie die Schließen-Schaltfläche
                        // in `PhoneAssetView` — dieselbe Rolle (Bedienelement über
                        // beliebigem Bildinhalt), deshalb dieselbe Behandlung.
                        // `Marke.akzent` bliebe auf einem beliebigen Standbild
                        // gerade nicht zuverlässig lesbar.
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play Video")

                if let fehler {
                    // Immer eine Variable, nie ein Literal: SwiftUI parst
                    // `Text`-Literale als Markdown (siehe `PhoneAlbumTile`).
                    Text(fehler)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
        }
    }

    /// Das Telefon, während das Videobild auf dem Fernseher läuft.
    ///
    /// **Warum überhaupt eine eigene Bedienung.** `VideoPlayer` hier stehen zu
    /// lassen, hieße, dasselbe Video ein zweites Mal auf dem Telefon zu
    /// zeichnen — dieselbe Überlegung wie bei `PhoneDiashowRolle.zeigtBildGross`
    /// und der Grund, warum die Diashow eine `PhoneDiashowFernbedienung` hat.
    /// Der Fernseher ist nicht bedienbar (`windowExternalDisplayNonInteractive`),
    /// also muss die Bedienung hier stehen.
    ///
    /// **Und warum sie so klein ist.** Suchen, Lautstärke, Vollbild — das alles
    /// gäbe es nur nachgebaut, weil AVKits Leiste an das lokale Bild gebunden
    /// ist. Der Auftrag ist Abspielen/Pause, Beenden und ein Titel; alles
    /// darüber hinaus wäre eine zweite, halb fertige Transportleiste.
    private func bedienungAufDerBuehne(_ spieler: AVPlayer) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 28) {
                Label {
                    Text(Self.buehnenHinweis)
                } icon: {
                    Image(systemName: "tv")
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Marke.akzent)

                // Der Titel ist der Dateiname des Originals, sofern er im
                // Cache steht — immer als Variable, nie als Literal.
                Text(titel ?? Self.ohneTitel)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                // Dasselbe Standbild wie hinter dem Startknopf — es zeigt, um
                // welches Video es geht, ohne dafür einen zweiten Dekodierweg
                // aufzumachen.
                if let lokalesStandbild {
                    Image(uiImage: lokalesStandbild)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                HStack(spacing: 32) {
                    Button {
                        // Wirkung und Folgezustand kommen aus einem Zug —
                        // getrennt gelesen und geschrieben wäre genau hier die
                        // Stelle, an der die Reihenfolge einmal kippt.
                        let tipp = knopf.getippt()
                        switch tipp.wirkung {
                        case .anhalten: spieler.pause()
                        case .abspielen: spieler.play()
                        }
                        knopf = tipp.danach
                    } label: {
                        Image(systemName: knopf.symbol)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 72, height: 72)
                            .background(.thinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(knopf.beschriftung)

                    Button {
                        // Beendet nur die Wiedergabe, nicht das Einzelbild: Die
                        // Seite fällt auf `standbildMitStartknopf` zurück, der
                        // Fernseher auf seinen Hinweis. Das Einzelbild selbst
                        // schließt weiterhin das X in `PhoneAssetView`.
                        beende()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 72, height: 72)
                            .background(.thinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Self.beendenLabel)
                }

                Spacer(minLength: 0)
            }
            .padding(.top, 72)
        }
    }

    /// Führt ``knopf`` aus dem Player nach.
    ///
    /// Dasselbe Muster wie ``beobachteFehlschlag(_:warLokal:)``: eine Aufgabe
    /// über einen KVO-Strom, abgebrochen in `beende()`.
    ///
    /// **Hier stand der Fehler, den der Nutzer am Apple TV gefunden hat.** Die
    /// Quelle war bis hierher `spieler.publisher(for:).values` — und die
    /// liefert nachweislich nur den *ersten* Wert und danach keinen mehr
    /// (Beleg und Ursache: ``PhoneKVOStrom``). Der Knopf merkte sich damit
    /// beim Abonnieren „läuft" und blieb dabei; der zweite Tipp rief wieder
    /// `pause()` statt `play()`, was aussah, als ließe sich Pause nicht
    /// zurücknehmen. Das Nachführen ist trotzdem geblieben, nicht durch das
    /// Mitschreiben beim Tippen ersetzt — beides zusammen, Begründung an
    /// ``PhoneAbspielknopf``.
    private func beobachteSpielstand(_ spieler: AVPlayer) {
        spielstandBeobachtung?.cancel()
        spielstandBeobachtung = Task { @MainActor in
            for await status in PhoneKVOStrom.werte(von: spieler, \.timeControlStatus) {
                guard !Task.isCancelled else { return }
                knopf = .fuer(spielstand: status)
            }
        }
    }

    /// Holt das Standbild aus der lokalen Datei — oder räumt es weg, wenn es
    /// keine gibt.
    ///
    /// Das Zurücksetzen ist kein Detail: `TabView(.page)` hält dieselbe
    /// Ansichtsinstanz über Seitenwechsel hinweg am Leben. Bliebe ein altes
    /// `lokalesStandbild` stehen, zeigte die nächste Videoseite das Bild der
    /// vorigen.
    private func ladeLokalesStandbild() async {
        guard let lokaleDatei else {
            lokalesStandbild = nil
            return
        }
        let bild = await PhoneVideoPoster.bild(fuer: lokaleDatei)
        // Die Aufgabe kann abgebrochen worden sein, während der Generator lief
        // (schnelles Weiterwischen) — dann gehört das Ergebnis zu einer Seite,
        // die niemand mehr ansieht.
        guard !Task.isCancelled else { return }
        if bild == nil {
            AppLogger.library.error(
                "Standbild lokal nicht gewinnbar \(assetId, privacy: .public), Rückfall auf den Server"
            )
        }
        lokalesStandbild = bild
    }

    private func starte() {
        guard let quelle = wiedergabequelle else {
            // Verbindung getrennt, während das Einzelbild offen ist, und das
            // Album ist nicht gepinnt. Kein Absturz und keine stille
            // Nichtreaktion. Liegt das Original dagegen auf der Platte, kommt
            // dieser Zweig gar nicht mehr dran — genau der Offline-Fall.
            fehler = String(localized: "No connection to the server.")
            AppLogger.library.error("Video ohne Quelle angefordert: \(assetId, privacy: .public)")
            return
        }
        fehler = nil
        aktiviereTonsitzung()

        // `avAssetOptions` ist für `.lokal` `nil` — siehe `PhoneMediaSource`.
        let urlAsset = AVURLAsset(url: quelle.url, options: quelle.avAssetOptions)
        let element = AVPlayerItem(asset: urlAsset)
        let neuerPlayer = AVPlayer(playerItem: element)

        // **`allowsExternalPlayback = false`, und zwar bedingungslos.**
        //
        // Steht die Eigenschaft auf ihrem Standardwert `true`, übernimmt
        // `AVPlayer` bei einer aktiven AirPlay-Route die Ausgabe selbst: Er
        // schickt die Wiedergabe an den Empfänger und zeichnet lokal nur noch
        // eine Platzhalterfläche. Damit fiele genau das aus, was hier gebaut
        // wird — unsere `AVPlayerLayer` auf dem Zweitbildschirm bekäme kein
        // Bild mehr, und der Fernseher zeigte wieder das, was er schon vorher
        // zeigte: nichts. Denn bei nativem AirPlay holt sich der Apple TV die
        // Datei selbst vom Immich-Server, und der API-Schlüssel steht in einer
        // HTTP-Kopfzeile, die den Weg dorthin nicht überlebt.
        //
        // `usesExternalPlaybackWhileExternalScreenIsActive` wäre die feinere
        // Schraube — sie entscheidet genau den Fall „AirPlay-Spiegelung läuft".
        // Sie ist hier trotzdem nicht die richtige: Sie **wirkt nur**, solange
        // `allowsExternalPlayback` `true` ist, und sie auf `false` zu lassen
        // hieße, sich auf ein Zusammenspiel zweier Schalter zu verlassen, wo
        // ein einzelner genügt. Sie bliebe außerdem stumm gegenüber einer
        // AirPlay-Route, die der Nutzer *ohne* Spiegelung wählt — dann liefe
        // wieder der kaputte native Weg.
        //
        // Der Preis, ehrlich benannt: Ein **lokal** vorliegendes Video hätte
        // über nativen AirPlay durchaus funktioniert (dann schickt das Telefon
        // die Datei, kein Schlüssel nötig). Dieser Weg fällt jetzt weg. Er
        // wird aber vom neuen ersetzt, der dasselbe leistet und zusätzlich für
        // Server-Videos gilt — zwei Wege zum selben Ziel, von denen einer nur
        // in der Hälfte der Fälle funktioniert, sind schlechter als einer.
        neuerPlayer.allowsExternalPlayback = false

        player = neuerPlayer
        // Hängt schon ein Zweitbildschirm, geht das Bild sofort dorthin. Hängt
        // keiner, holt `.onChange(of: rolle)` das nach, sobald einer kommt.
        if rolle.speistBuehne {
            buehne.zeige(spieler: neuerPlayer)
        }
        // Sofort setzen, nicht auf den Beobachter warten: Der Tipp auf den
        // Startknopf ist genau der Fall, in dem der Nutzer schon weiß, dass es
        // laufen soll.
        knopf = .pausieren
        beobachteSpielstand(neuerPlayer)
        neuerPlayer.play()
        AppLogger.library.info("Videowiedergabe \(assetId, privacy: .public): Quelle \(quelle.protokollName, privacy: .public), Ziel \(rolle.speistBuehne ? "Zweitbildschirm" : "Telefon", privacy: .public)")

        // **Beide** Quellen werden beobachtet, nicht nur die lokale. Scheiterte
        // die Server-Fassung unbeobachtet, endete sie in einem schwarzen
        // `VideoPlayer` ohne jede Rückmeldung — und genau das ist der Fall, der
        // ohne Netz eintritt.
        beobachteFehlschlag(element, warLokal: quelle.istLokal)
    }

    /// **Warum es diesen Rückfall gibt.** Die lokale Datei ist das **Original**
    /// (`LocalFileCacheManager.downloadOriginalToCache`), die Server-URL dagegen
    /// `/video/playback` — also die vom Server gegebenenfalls **transkodierte**
    /// Fassung. Das sind nicht dieselben Daten: Ein Original in einem Container
    /// oder Codec, den `AVPlayer` nicht dekodiert, spielt lokal nicht, wo der
    /// Serverweg spielte.
    ///
    /// Der Mac umgeht das, indem er Videos **nie** lokal abspielt
    /// (`ImageDetailView` zweigt sie zu `VideoPlayerView` ab, und die baut immer
    /// `playbackURL`). Diesen Weg kann das Telefon nicht gehen, ohne den Zweck
    /// aufzugeben: Ohne Netz gäbe es dann gar keine Wiedergabe. Also lokal
    /// zuerst — und bei Fehlschlag einmal auf den Server zurück. Ohne Netz
    /// scheitern dann beide, aber daran hätte auch der Mac-Weg nichts geändert.
    private func beobachteFehlschlag(_ element: AVPlayerItem, warLokal: Bool) {
        statusBeobachtung?.cancel()
        statusBeobachtung = Task { @MainActor in
            // Ebenfalls über ``PhoneKVOStrom`` statt über
            // `publisher(for:).values`: Beim Abonnieren steht hier immer
            // `.unknown`, der interessante Wechsel auf `.failed` kommt erst
            // danach — über den alten Weg also nie. Der Rückfall von der
            // Platte auf den Server und die Fehlermeldung waren damit tote
            // Zweige, ohne dass es je auffiel.
            for await status in PhoneKVOStrom.werte(von: element, \.status) {
                guard !Task.isCancelled else { return }
                guard status == .failed else { continue }
                let grund = element.error?.localizedDescription ?? "unbekannt"
                AppLogger.library.error(
                    "Wiedergabe fehlgeschlagen \(assetId, privacy: .public) (\(warLokal ? "Platte" : "Server", privacy: .public)): \(grund, privacy: .public)"
                )

                // Ausweichen nur von der Platte auf den Server, nur einmal, und
                // nur wenn es überhaupt einen Server gibt.
                if warLokal, !lokalGescheitert, connection.apiClient != nil {
                    lokalGescheitert = true
                    beende()
                    starte()
                    return
                }

                // Endgültig gescheitert. **Der Player muss weg**, sonst bliebe
                // ein schwarzes Bild stehen und die Meldung unsichtbar: `fehler`
                // zeigt nur `standbildMitStartknopf`, und das erscheint erst,
                // wenn `player` wieder `nil` ist.
                beende()
                fehler = warLokal
                    ? String(localized: "This video can’t be played.")
                    : String(localized: "This video can’t be loaded right now.")
                return
            }
        }
    }

    /// Woher der Strom kommt. `nil` heißt: weder Datei noch Server.
    ///
    /// Der `guard` ist kein Sonderweg um `waehle` herum — ohne `apiClient`
    /// gibt es keine Fern-URL, die man übergeben könnte; eine ausgedachte
    /// wäre schlimmer als keine. Dieselbe Form wie
    /// `PhoneAssetPage.standbildquelle(lokaleDatei:)`.
    private var wiedergabequelle: PhoneMediaSource? {
        guard let apiClient = connection.apiClient else {
            return lokaleDatei.map { PhoneMediaSource.lokal($0) }
        }
        return .waehle(
            // Nach einem Fehlschlag der Datei so tun, als gäbe es sie nicht —
            // siehe `beobachteLokalenFehlschlag`.
            lokaleDatei: lokalGescheitert ? nil : lokaleDatei,
            fernURL: apiClient.playbackURL(assetId: assetId),
            apiKey: apiClient.apiKey
        )
    }

    /// Aufräumen für Falle (1). Idempotent — wird sowohl beim Seitenwechsel
    /// als auch beim Schließen des Einzelbilds gerufen, und beide können in
    /// derselben Runloop-Runde eintreffen.
    ///
    /// **Nachgesehen wegen der lokalen Quelle, Ergebnis: unverändert richtig.**
    /// Für eine Datei gilt jedes Argument von oben genauso — der `AVPlayer`
    /// hält statt einer Netzverbindung eine offene Datei, und beides gibt das
    /// `player = nil` frei, sobald AVFoundation die letzte Referenz fallen
    /// lässt. Die Tonsitzung hängt ohnehin nicht an der Herkunft des Stroms.
    /// Es gibt hier also nichts nach Quelle zu unterscheiden.
    private func beende() {
        statusBeobachtung?.cancel()
        statusBeobachtung = nil
        spielstandBeobachtung?.cancel()
        spielstandBeobachtung = nil
        guard let laufender = player else { return }
        laufender.pause()
        // **Vor** dem Loslassen der eigenen Referenz von der Bühne nehmen:
        // Sonst hielte die Bühne den Player als einzige am Leben, und er liefe
        // — hörbar — weiter. Ohne Zweitbildschirm ist der Aufruf ein Nichts,
        // deshalb steht hier bewusst keine Rollenabfrage davor: Ein `if` an
        // dieser Stelle wäre eine Gelegenheit, den Fall zu verfehlen, in dem
        // die Szene zwischen Übergabe und Aufräumen verschwunden ist.
        buehne.nimmSpielerZurueck(laufender)
        player = nil
        // Zurück auf „Weiter": Die nächste Wiedergabe beginnt gestoppt, und
        // `starte()` setzt den Knopf ohnehin neu.
        knopf = .fortsetzen
        // Erst hier die Tonsitzung schließen, nicht in `starte()` gespiegelt:
        // Weil zu jedem Zeitpunkt höchstens ein Player existiert (siehe Falle
        // (1)), kann dieses Deaktivieren keinem zweiten, noch laufenden Player
        // den Ton unter den Füßen wegziehen. `notifyOthersOnDeactivation` lässt
        // die Musik-App des Nutzers wieder anlaufen, die das Aktivieren unten
        // unterbrochen hat.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// **Falle (3): Ton bei stummgeschaltetem Klingelschalter.**
    ///
    /// Ohne Zutun läuft ein iOS-Prozess in der Kategorie `.soloAmbient`: Der
    /// Klingelschalter schaltet die Wiedergabe stumm, und der Ton verstummt
    /// beim Sperren des Bildschirms. Für einen Klingelton ist das richtig, für
    /// ein Video, das der Nutzer in einer Galerie **bewusst angetippt** hat,
    /// nicht — er hat den Ton gerade angefordert; ihn ohne sichtbaren Hinweis
    /// zu verschlucken, sieht wie ein kaputtes Video aus. Fotos, Youtube und
    /// jede andere Videoansicht verhalten sich hier gleich. Deshalb bewusst
    /// `.playback`.
    ///
    /// **Genau eine Stelle:** Dieser Aufruf steht ausschließlich in `starte()`,
    /// also im einzigen Pfad, der überhaupt einen `AVPlayer` erzeugt — nicht
    /// beim App-Start (`ImmichPhoneApp`) und nicht beim Öffnen des
    /// Einzelbilds. Das ist der Unterschied, auf den es ankommt: Beim App-Start
    /// gesetzt, würde das Aktivieren die Musik des Nutzers unterbrechen, sobald
    /// er die App auch nur öffnet. So passiert es erst mit dem Tipp auf den
    /// Startknopf — und `beende()` gibt die Sitzung wieder frei.
    ///
    /// Fehler werden protokolliert, nicht geworfen: Schlägt das Setzen fehl,
    /// spielt das Video weiterhin — nur eben mit dem Standardverhalten des
    /// Systems. Die Wiedergabe deswegen abzubrechen, wäre die schlechtere
    /// Reaktion.
    private func aktiviereTonsitzung() {
        do {
            let sitzung = AVAudioSession.sharedInstance()
            try sitzung.setCategory(.playback, mode: .moviePlayback)
            try sitzung.setActive(true)
        } catch {
            AppLogger.library.error("AVAudioSession .playback fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
        }
    }
}
