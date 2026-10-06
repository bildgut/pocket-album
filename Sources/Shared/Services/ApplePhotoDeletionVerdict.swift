import Foundation

/// Warum die lokale Prüfsumme fehlt — die Form, in der der Aufrufer den
/// Hash-Fehlschlag an die reine Regel weiterreicht.
enum ApplePhotoLesefehler: Equatable, Sendable {
    case icloud
    case unvollständig
    /// `AppleResourcePicker` fand keine passende Resource; es wurde gar nicht erst
    /// gelesen. Wiederholt sich beliebig oft mit demselben Ergebnis.
    case keineResource
    case abgebrochen
}

/// Ergebnis der Prüfung eines einzelnen Apple-Photos-Assets vor dem Löschen.
///
/// Bewusst kein `Bool`: „Von 12 400 Fotos wurden 11 900 gelöscht" ist ohne Gründe
/// nicht interpretierbar — die 500 Ausnahmen sind gerade das Interessante.
enum ApplePhotoDeletionVerdict: Equatable, Hashable, CaseIterable {
    /// Alle Stufen bestanden. Führt zum Löschen.
    case freigegeben
    /// Alle Stufen bestanden — das Asset liegt auf dem Server aber im Papierkorb.
    /// Führt ebenfalls zum Löschen: Wer ein Foto in Immich wegwirft, will es auch
    /// nicht mehr in Apple Photos. Die Byte-Gleichheit bleibt Bedingung, denn
    /// Mappings entstehen über Dateiname plus Aufnahmedatum und können auf ein
    /// falsches Asset zeigen; läge ausgerechnet das im Papierkorb, verschwände ein
    /// Foto, das nie zur Disposition stand. Eigener Fall, damit der Bericht sagen
    /// kann, warum diese Fotos gegangen sind.
    case freigegebenPapierkorb
    /// Kein Serverabgleich: Der Nutzer hat das Foto in der Import-Vorschau
    /// abgewählt und ausdrücklich „übrige in Apple Fotos löschen" gewählt. Es gibt
    /// keine Kopie in Immich — die Freigabe beruht allein auf dieser Entscheidung,
    /// geschützt durch `ApplePhotoVerwerfUrteil` (gemeinsame Mediathek, seitdem
    /// bearbeitet). Vergibt ausschließlich diese Funktion.
    case abgewähltVerworfen

    // MARK: Ablehnungen
    case nichtAufServer
    /// Wird von `ApplePhotoDeletionVerifier` nicht mehr vergeben (der Papierkorb
    /// entscheidet nichts mehr allein, siehe `freigegebenPapierkorb`). Der Fall
    /// bleibt erhalten, damit ältere Berichte und Aufrufer weiter übersetzbar sind.
    case imPapierkorb
    case lokalGeändert
    /// Das Mapping stammt aus einer Zeit ohne gespeichertes Änderungsdatum. Nicht
    /// dasselbe wie „geändert" — aber ebenso wenig ein Beweis für „unverändert".
    case änderungsstandUnbekannt
    /// Wird von `ApplePhotoDeletionVerifier` nicht mehr vergeben (der Sammelfall ist
    /// in die drei Fälle darunter zerfallen). Der Fall bleibt erhalten, damit ältere
    /// Berichte und Journal-Einträge weiter übersetzbar sind.
    case livePhotoUnvollständig
    /// Zum Standbild ist überhaupt kein Videoteil auffindbar — weder ein lokales
    /// `/live-video`-Mapping noch eine `livePhotoVideoId` vom Server. Der einzige
    /// der drei Fälle, den ein nachträglicher Upload auflösen könnte.
    case livePhotoVideoFehlt
    /// Der Videoteil lag auf dem Server und wurde dort gelöscht. Ein nachträglicher
    /// Upload löst das **nicht** auf — die Entfernung war eine Entscheidung auf dem
    /// Server, und sie wieder zu unterlaufen steht dem Lauf nicht zu.
    case livePhotoVideoGelöscht
    /// Der Videoteil liegt im Immich-Papierkorb, das Standbild aber nicht. Bewusst
    /// kein Löschgrund: Der Bestand ist widersprüchlich, und das aufzulösen ist eine
    /// Entscheidung des Nutzers.
    case livePhotoVideoImPapierkorb
    /// Die Serverfassung des **Videoteils** stammt aus einer anderen Quelle — dasselbe
    /// wie `serverkopieAusAndererQuelle`, nur eben für den Videoteil statt für das
    /// Standbild.
    ///
    /// Eigener Fall, weil der gemeinsame Name einen Nutzer eine Runde gekostet hat:
    /// 108 Live Photos meldeten `serverkopieAusAndererQuelle`, obwohl ihr Standbild
    /// längst in Ordnung war. Die Oberfläche bot daraufhin „Original nachreichen" an,
    /// lud 105 Standbilder hoch — und der Prüflauf löschte trotzdem null Fotos, weil
    /// der Videoteil der abweichende Teil war. Ein Befund muss sagen, *welcher* Teil
    /// das Problem ist, sonst führt er zur falschen Handlung.
    case livePhotoVideoAusAndererQuelle
    /// Die Serverkopie unterscheidet sich byte-weise vom lokalen Original. Kein
    /// Rauschen, sondern ein Fund: Genau der Fall, für den es diese Prüfung gibt.
    case checksumMismatch
    /// Die Bytes weichen ab, aber schon die Dateigrößen tun es (oder eine der
    /// beiden ist unbekannt). Diese Serverkopie wurde nie von diesem Client
    /// hochgeladen — der Sync hat sie über Dateiname plus Aufnahmedatum gefunden und
    /// nur ein Mapping angelegt. Byte-Gleichheit war dort nie gegeben, das ist
    /// erwartbar und kein Fund. Zusammen mit `checksumMismatch` gemeldet, entwertete
    /// es genau die eine Zeile, die der Nutzer ernst nehmen soll.
    case serverkopieAusAndererQuelle
    /// Der Server liefert kein `checksum`-Feld (ältere Version). Kein Fund, aber
    /// auch kein Beweis — L4 darf dadurch nicht stumm ausgehebelt werden.
    case checksumFehltAufServer
    case nichtLesbar
    /// Der iCloud-Download der Originaldatei schlug fehl. Transient — ein
    /// Wiederholungslauf über diesen Grund räumt den Großteil ab.
    case nichtLesbarICloud
    /// Die Datei wurde unvollständig gelesen (Bytezahl ≠ erwartete Größe). Ebenfalls
    /// wiederholbar; ein Hash über ein Bruchstück kommt nie zustande.
    case nichtLesbarUnvollständig
    /// Zu diesem Foto gibt es gar keine lesbare Resource. Ein Wiederholungslauf
    /// ändert daran nichts — hier entscheidet der Nutzer, nicht der Code.
    case keineResource
    case serverAntwortetNicht
    /// Das Foto liegt gar nicht mehr in Apple Photos (L1) — in einem früheren Lauf
    /// bereits gelöscht. Kein Fehler, aber auch nichts zu tun: Ohne eigenen Grund
    /// fiele bei einem fortgesetzten Lauf der halbe Bericht unter den Tisch.
    case nichtMehrInApplePhotos
    /// Das Foto liegt in der geteilten iCloud-Mediathek. Dort löschen hieße: für
    /// alle Teilnehmer löschen — das steht nie zur Disposition, egal wie sauber
    /// der Server-Abgleich ausfiele. Wird vor jeder anderen Stufe vergeben, damit
    /// für diese Fotos weder ein Server-Request noch ein iCloud-Download anfällt.
    case inGeteilterMediathek
    /// Die Zugehörigkeit zur gemeinsamen Mediathek ließ sich nicht feststellen
    /// (`ApplePhotoLibraryScope.istVerfügbar == false`). Keine Aussage über das
    /// Foto — aber auch keine Freigabe: Ohne diese Unterscheidung könnte ein
    /// Löschvorgang für alle Teilnehmenden wirken.
    case mediathekNichtPrüfbar
    /// Der Nutzer hat abgebrochen, bevor diese Prüfung fertig war — vor ihrem Beginn
    /// oder mitten im Hashen des Originals. Eine Ablehnung wie jede andere — nur eben
    /// ohne Aussage über das Foto selbst.
    case abgebrochen

    // MARK: Nachreichen
    /// Das lokale Original ist hochgeladen und das Mapping zeigt darauf. Ein
    /// Zwischenstand, ausdrücklich kein Endzustand: Ob das Foto aus Apple Photos
    /// verschwindet, entscheidet danach der Löschlauf — und nur er.
    case nachgereicht
    /// Upload oder Mapping-Umschrift sind gescheitert. Wiederholbar, aber **nicht**
    /// direkt: Keine `ApplePhotoNachreichZiel` löst diesen Befund aus, und das
    /// absichtlich — er entsteht bei beiden Zielarten, und eine Zielart, die ihn
    /// aufgriffe, bekäme auch die Fehlschläge der anderen (ein gescheitertes
    /// Videoteil-Nachreichen lüde als `.stapeln` das ganze Original hoch). Der Weg
    /// zurück führt über einen erneuten Prüflauf: Mapping bzw. Paarung fehlen ja
    /// weiterhin, also urteilt er wieder auf `.serverkopieAusAndererQuelle` bzw.
    /// `.livePhotoVideoFehlt` — und erst der ist die richtige Gruppe. Der zweite
    /// Anlauf lädt dann dank der Duplikatprüfung nichts ein zweites Mal hoch.
    case nachreichenFehlgeschlagen
    /// Es gibt lokal nichts zum Nachreichen (keine lesbare Resource), oder die
    /// Zielart ist auf diesem Server nicht umsetzbar. Eine Wiederholung ändert daran
    /// nichts.
    case nachreichenNichtMöglich

    var istFreigabe: Bool {
        self == .freigegeben || self == .freigegebenPapierkorb || self == .abgewähltVerworfen
    }

    /// Überschrift dieses Grundes im Ergebnisbericht. Muss über alle Fälle
    /// eindeutig sein, sonst verschmelzen im Bericht verschiedene Ursachen.
    var berichtstitel: String {
        switch self {
        case .freigegeben:             return "Gelöscht"
        case .freigegebenPapierkorb:   return "Gelöscht — lag im Immich-Papierkorb"
        case .abgewähltVerworfen:      return "Gelöscht — in der Vorschau abgewählt"
        case .nichtAufServer:          return "Nicht mehr auf dem Server"
        case .imPapierkorb:            return "Im Server-Papierkorb"
        case .lokalGeändert:           return "Nach dem Upload bearbeitet"
        case .änderungsstandUnbekannt: return "Änderungsstand unbekannt"
        case .livePhotoUnvollständig:  return "Live Photo unvollständig hochgeladen"
        case .livePhotoVideoFehlt:        return "Live Photo — Videoteil nie hochgeladen"
        case .livePhotoVideoGelöscht:     return "Live Photo — Videoteil auf dem Server gelöscht"
        case .livePhotoVideoImPapierkorb: return "Live Photo — Videoteil im Immich-Papierkorb"
        case .livePhotoVideoAusAndererQuelle:
            return "Live Photo — Videoteil stammt aus anderer Quelle (erwartbar)"
        case .checksumMismatch:        return "Serverkopie weicht ab (Prüfsumme)"
        case .serverkopieAusAndererQuelle:
            return "Serverkopie stammt aus anderer Quelle (erwartbar)"
        case .checksumFehltAufServer:  return "Server liefert keine Prüfsumme"
        case .nichtLesbar:             return "Original nicht lesbar"
        case .nichtLesbarICloud:       return "Original nicht ladbar (iCloud)"
        case .nichtLesbarUnvollständig: return "Original unvollständig gelesen"
        case .keineResource:           return "Keine lesbare Originaldatei"
        case .serverAntwortetNicht:    return "Server nicht erreichbar"
        case .nichtMehrInApplePhotos:  return "Nicht mehr in Apple Photos"
        case .inGeteilterMediathek:    return "In gemeinsamer Mediathek — bleibt erhalten"
        case .mediathekNichtPrüfbar:   return "Mediathek-Zugehörigkeit nicht prüfbar"
        case .abgebrochen:             return "Prüfung abgebrochen"
        case .nachgereicht:                return "Nachgereicht — wartet auf die Prüfung"
        case .nachreichenFehlgeschlagen:   return "Nachreichen fehlgeschlagen"
        case .nachreichenNichtMöglich:     return "Nachreichen nicht möglich"
        }
    }

    /// Stabiler Bezeichner für die Ablage im Befundjournal.
    ///
    /// Bewusst nicht der Enum-Name: Dieser Wert steht in der Datenbank und muss
    /// eine Umbenennung im Code überleben. Reines ASCII, weil Umlaute in
    /// Store-Werten Vergleiche still scheitern lassen.
    var journalSchlüssel: String {
        switch self {
        case .freigegeben:                 return "freigegeben"
        case .freigegebenPapierkorb:       return "freigegebenPapierkorb"
        case .abgewähltVerworfen:          return "abgewaehltVerworfen"
        case .nichtAufServer:              return "nichtAufServer"
        case .imPapierkorb:                return "imPapierkorb"
        case .lokalGeändert:               return "lokalGeaendert"
        case .änderungsstandUnbekannt:     return "aenderungsstandUnbekannt"
        case .livePhotoUnvollständig:      return "livePhotoUnvollstaendig"
        case .livePhotoVideoFehlt:        return "livePhotoVideoFehlt"
        case .livePhotoVideoGelöscht:     return "livePhotoVideoGeloescht"
        case .livePhotoVideoImPapierkorb: return "livePhotoVideoImPapierkorb"
        case .livePhotoVideoAusAndererQuelle: return "livePhotoVideoAusAndererQuelle"
        case .checksumMismatch:            return "checksumMismatch"
        case .serverkopieAusAndererQuelle: return "serverkopieAusAndererQuelle"
        case .checksumFehltAufServer:      return "checksumFehltAufServer"
        case .nichtLesbar:                 return "nichtLesbar"
        case .nichtLesbarICloud:           return "nichtLesbarICloud"
        case .nichtLesbarUnvollständig:    return "nichtLesbarUnvollstaendig"
        case .keineResource:               return "keineResource"
        case .serverAntwortetNicht:        return "serverAntwortetNicht"
        case .nichtMehrInApplePhotos:      return "nichtMehrInApplePhotos"
        case .inGeteilterMediathek:        return "inGeteilterMediathek"
        case .mediathekNichtPrüfbar:       return "mediathekNichtPruefbar"
        case .abgebrochen:                 return "abgebrochen"
        case .nachgereicht:                return "nachgereicht"
        case .nachreichenFehlgeschlagen:   return "nachreichenFehlgeschlagen"
        case .nachreichenNichtMöglich:     return "nachreichenNichtMoeglich"
        }
    }

    /// - Returns: `nil` für einen Schlüssel, den diese Fassung nicht kennt. Ein
    ///   Journal-Eintrag aus einer älteren Version darf nichts zum Absturz bringen;
    ///   er zählt dann schlicht nicht mit.
    init?(journalSchlüssel: String) {
        guard let treffer = ApplePhotoDeletionVerdict.allCases.first(
            where: { $0.journalSchlüssel == journalSchlüssel }
        ) else { return nil }
        self = treffer
    }
}

/// Der Video-Teil eines Live Photos — als eigenes Immich-Asset hochgeladen und
/// deshalb eigenständig zu prüfen.
struct LivePhotoVideoInput: Equatable {
    var serverState: ImmichAPIClient.AssetServerState?
    var serverChecksumHex: String?
    var localChecksumHex: String?
    /// Dieselbe Unterscheidung wie beim Standbild: Ohne zwei gleiche Dateigrößen ist
    /// eine Byte-Abweichung kein Fund, sondern eine fremde Serverkopie. Gerade beim
    /// Videoteil ist das die Regel, seit L0 auf `livePhotoVideoId` zurückfällt.
    var mappingUploadFileSize: Int64?
    var serverFileSizeInByte: Int?
    /// Warum `localChecksumHex` fehlt. `nil` heißt „kein Grund überliefert" — dann
    /// bleibt es beim Sammelurteil `.nichtLesbar`.
    var lokalerLesefehler: ApplePhotoLesefehler?

    init(
        serverState: ImmichAPIClient.AssetServerState?,
        serverChecksumHex: String?,
        localChecksumHex: String?,
        mappingUploadFileSize: Int64? = nil,
        serverFileSizeInByte: Int? = nil,
        lokalerLesefehler: ApplePhotoLesefehler? = nil
    ) {
        self.serverState = serverState
        self.serverChecksumHex = serverChecksumHex
        self.localChecksumHex = localChecksumHex
        self.mappingUploadFileSize = mappingUploadFileSize
        self.serverFileSizeInByte = serverFileSizeInByte
        self.lokalerLesefehler = lokalerLesefehler
    }
}

/// Alles, was zur Beurteilung eines Kandidaten nötig ist — als Werte, ohne
/// `PHAsset` und ohne Netzwerk, damit die Regel prüfbar bleibt.
///
/// `nil` heißt durchgängig „nicht ermittelbar", nicht „in Ordnung".
struct ApplePhotoVerificationInput: Equatable {
    /// `nil`, wenn der Server nicht geantwortet hat.
    var serverState: ImmichAPIClient.AssetServerState?
    var serverChecksumHex: String?
    /// `nil`, wenn die lokale Resource nicht gelesen werden konnte.
    var localChecksumHex: String?
    /// Beim Upload festgehaltener Stand (`ApplePhotosAssetMapping.lastKnownModificationDate`).
    var mappingModificationDate: Date?
    var currentModificationDate: Date?
    var isLivePhoto: Bool
    /// `nil` bei `isLivePhoto == true` heißt: weder ein lokales `/live-video`-Mapping
    /// noch eine `livePhotoVideoId` vom Server — der Videoteil ist nicht auffindbar.
    var livePhotoVideo: LivePhotoVideoInput?
    /// Beim Upload notierte Dateigröße (`ApplePhotosAssetMapping.lastUploadedFileSize`).
    /// `nil` heißt: dieser Client hat die Datei nie hochgeladen (oder es war vor V4).
    var mappingUploadFileSize: Int64?
    /// Größe der Serverdatei (`exifInfo.fileSizeInByte`). `nil` heißt: unbekannt.
    var serverFileSizeInByte: Int?
    /// Warum `localChecksumHex` fehlt. `nil` heißt „kein Grund überliefert" — dann
    /// bleibt es beim Sammelurteil `.nichtLesbar`.
    var lokalerLesefehler: ApplePhotoLesefehler?

    init(
        serverState: ImmichAPIClient.AssetServerState?,
        serverChecksumHex: String?,
        localChecksumHex: String?,
        mappingModificationDate: Date?,
        currentModificationDate: Date?,
        isLivePhoto: Bool,
        livePhotoVideo: LivePhotoVideoInput?,
        mappingUploadFileSize: Int64? = nil,
        serverFileSizeInByte: Int? = nil,
        lokalerLesefehler: ApplePhotoLesefehler? = nil
    ) {
        self.serverState = serverState
        self.serverChecksumHex = serverChecksumHex
        self.localChecksumHex = localChecksumHex
        self.mappingModificationDate = mappingModificationDate
        self.currentModificationDate = currentModificationDate
        self.isLivePhoto = isLivePhoto
        self.livePhotoVideo = livePhotoVideo
        self.mappingUploadFileSize = mappingUploadFileSize
        self.serverFileSizeInByte = serverFileSizeInByte
        self.lokalerLesefehler = lokalerLesefehler
    }
}

/// Entscheidet, ob ein Apple-Photos-Asset gelöscht werden darf.
///
/// Reine Funktion über Wertetypen — dieselbe Trennung wie bei `AppleResourcePicker`
/// und aus demselben Grund: `PHAsset` lässt sich im Test nicht bauen, die Regel soll
/// aber prüfbar sein. Die Verdrahtung zu Photos liegt eine Schicht darüber.
enum ApplePhotoDeletionVerifier {

    /// Photos und das gespeicherte Mapping runden Zeitstempel unterschiedlich.
    /// Ohne diese Toleranz gälte praktisch jedes Foto als nachbearbeitet.
    static let datumsToleranz: TimeInterval = 1.0

    /// Prüft in der Reihenfolge billig → teuer und bricht bei der ersten Ablehnung ab.
    /// Die Reihenfolge ist nicht kosmetisch: Sie entscheidet, ob im echten Lauf ein
    /// mehrere Gigabyte großes Original überhaupt aus iCloud geladen werden muss.
    ///
    /// L1 (existiert das PHAsset lokal überhaupt noch) steckt nicht hier, sondern im
    /// Aufrufer — für einen Kandidaten ohne PHAsset entsteht gar kein Input.
    static func verdict(for input: ApplePhotoVerificationInput) -> ApplePhotoDeletionVerdict {
        // L0 — Serverzustand. Der Papierkorb bricht hier bewusst *nicht* ab: Er ändert
        // nur, welche Freigabe am Ende steht — die Kette muss vollständig bestanden
        // werden, insbesondere die Byte-Gleichheit.
        var imPapierkorb = false
        switch input.serverState {
        case .none:            return .serverAntwortetNicht
        case .some(.deleted):  return .nichtAufServer
        case .some(.trashed):  imPapierkorb = true
        case .some(.alive):    break
        }

        // L2 — Änderungsstand
        guard let mappingDate = input.mappingModificationDate,
              let currentDate = input.currentModificationDate else {
            return .änderungsstandUnbekannt
        }
        if currentDate > mappingDate.addingTimeInterval(datumsToleranz) {
            return .lokalGeändert
        }

        // L3 — Live Photo: der Video-Teil ist ein eigenes Asset und wird eigenständig
        // geprüft. Ohne die Checksum wäre das hier nur eine Existenzprüfung.
        if input.isLivePhoto {
            let videoUrteil = livePhotoVideoUrteil(input.livePhotoVideo, hauptAssetImPapierkorb: imPapierkorb)
            guard videoUrteil.istFreigabe else { return videoUrteil }
        }

        // L4 — Byte-Gleichheit
        let urteil = checksumUrteil(
            server: input.serverChecksumHex,
            local: input.localChecksumHex,
            uploadGröße: input.mappingUploadFileSize,
            serverGröße: input.serverFileSizeInByte,
            lesefehler: input.lokalerLesefehler
        )
        guard urteil == .freigegeben else { return urteil }
        return imPapierkorb ? .freigegebenPapierkorb : .freigegeben
    }

    /// Unter welcher Immich-ID der Videoteil eines Live Photos zu prüfen ist.
    ///
    /// Das lokale `/live-video`-Mapping existiert nur für Videoteile, die *dieser*
    /// Client hochgeladen hat — im Bestand sind das wenige. Der Server nennt den
    /// gepaarten Videoteil aber selbst (`Asset.livePhotoVideoId`), und diese Angabe
    /// steckt in derselben Antwort, die L0 ohnehin holt. Ohne diesen Rückfall gälten
    /// tausende vollständige Live Photos als „unvollständig hochgeladen".
    static func videoTeilAssetId(lokalesMapping: String?, serverLivePhotoVideoId: String?) -> String? {
        if let lokalesMapping, !lokalesMapping.isEmpty { return lokalesMapping }
        guard let serverLivePhotoVideoId, !serverLivePhotoVideoId.isEmpty else { return nil }
        return serverLivePhotoVideoId
    }

    /// L3 als eigenständig aufrufbare Regel.
    ///
    /// Der Aufrufer beurteilt den Video-Teil, sobald er vorliegt, und lädt das
    /// Standbild dann gar nicht erst aus iCloud. Die Regel steht trotzdem nur einmal
    /// hier — zwei Fassungen driften auseinander.
    /// - Parameter hauptAssetImPapierkorb: Wird das Standbild gelöscht, weil es in
    ///   Immich im Papierkorb liegt, liegt sein Videoteil dort normalerweise mit —
    ///   das ist dann kein unvollständiger Upload. Die Prüfsumme muss trotzdem
    ///   stimmen. Liegt das Standbild dagegen normal auf dem Server, bleibt ein
    ///   weggeworfener Videoteil wie bisher ein Ablehnungsgrund.
    static func livePhotoVideoUrteil(
        _ video: LivePhotoVideoInput?,
        hauptAssetImPapierkorb: Bool = false
    ) -> ApplePhotoDeletionVerdict {
        guard let video else { return .livePhotoVideoFehlt }
        switch video.serverState {
        case .none:             return .serverAntwortetNicht
        case .some(.deleted):   return .livePhotoVideoGelöscht
        case .some(.trashed):
            guard hauptAssetImPapierkorb else { return .livePhotoVideoImPapierkorb }
        case .some(.alive):     break
        }
        let urteil = checksumUrteil(
            server: video.serverChecksumHex,
            local: video.localChecksumHex,
            uploadGröße: video.mappingUploadFileSize,
            serverGröße: video.serverFileSizeInByte,
            lesefehler: video.lokalerLesefehler
        )
        // `checksumUrteil` kennt nur „die Datei", nicht welche der beiden — sein
        // Ergebnis heißt für Standbild und Videoteil gleich. Genau daran ist ein
        // Nutzer gescheitert: 108 Live Photos meldeten
        // `serverkopieAusAndererQuelle`, obwohl das Standbild in Ordnung war, und die
        // Oberfläche bot folgerichtig die falsche Aktion an. Deshalb bekommt dieser
        // eine Fall hier seinen eigenen Namen.
        //
        // Bewusst nur dieser: Die übrigen Urteile, die von hier kommen können
        // (`checksumMismatch`, die drei `nichtLesbar*`-Varianten, `keineResource`,
        // `abgebrochen`, `checksumFehltAufServer`), tragen dieselbe Mehrdeutigkeit —
        // sie sagen nicht, ob Standbild oder Videoteil gemeint ist. Sie treten im
        // Bestand praktisch nicht auf und lösen keine Nachreich-Aktion aus; sie alle
        // zu verdoppeln wäre Vorratsbau. Wer hier einen weiteren Fall vermisst: Er
        // fehlt absichtlich, nicht aus Versehen.
        if urteil == .serverkopieAusAndererQuelle { return .livePhotoVideoAusAndererQuelle }
        return urteil
    }

    /// - Parameters:
    ///   - uploadGröße: Beim Anlegen des Mappings notierte Größe der hochgeladenen Datei.
    ///   - serverGröße: Größe der Datei, die jetzt auf dem Server liegt.
    ///
    /// Die beiden Größen entscheiden nicht über die Freigabe — die hängt allein an
    /// den Bytes. Sie entscheiden nur, wie eine Abweichung *heißt*: Gleiche Länge bei
    /// anderen Bytes ist ein echter Fund, alles andere ist eine Serverkopie, die nie
    /// von hier stammte.
    private static func checksumUrteil(
        server: String?,
        local: String?,
        uploadGröße: Int64?,
        serverGröße: Int?,
        lesefehler: ApplePhotoLesefehler?
    ) -> ApplePhotoDeletionVerdict {
        guard let server, !server.isEmpty else { return .checksumFehltAufServer }
        guard let local, !local.isEmpty else {
            switch lesefehler {
            case .icloud:         return .nichtLesbarICloud
            case .unvollständig:  return .nichtLesbarUnvollständig
            case .keineResource:  return .keineResource
            case .abgebrochen:    return .abgebrochen
            // Kein Grund überliefert: Aufrufer, die den Fehlschlag nicht
            // weiterreichen, bekommen wie bisher das Sammelurteil.
            case .none:           return .nichtLesbar
            }
        }
        if ChecksumHex.equal(server, local) { return .freigegeben }
        guard let uploadGröße, let serverGröße, Int64(serverGröße) == uploadGröße else {
            return .serverkopieAusAndererQuelle
        }
        return .checksumMismatch
    }
}
