import Foundation
import Photos
import CryptoKit

/// Warum eine lokale Prüfsumme nicht zustande kam.
///
/// Der Unterschied ist keine Kosmetik: Ein iCloud-Fehler und ein abgeschnittener
/// Lesevorgang verschwinden beim nächsten Versuch, eine fehlende Resource nicht.
/// Bis hierher wurden alle drei zu einem `nil` eingeebnet, und der Bericht meldete
/// sie als ein und denselben Grund — 236 Fotos, bei denen niemand wusste, welche
/// davon einen zweiten Versuch verdient hätten.
enum ApplePhotoHashErgebnis: Equatable, Sendable {
    case hash(String)
    /// Photos meldete einen Fehler — typischerweise ein fehlgeschlagener
    /// iCloud-Download. Wiederholbar.
    case icloudFehler
    /// Die gelesene Bytezahl passt nicht zur erwarteten Größe. Die Schutzabschaltung
    /// gegen einen Hash über ein Bruchstück, kein Defekt des Fotos. Wiederholbar.
    case unvollständig
    case abgebrochen

    var hex: String? {
        if case .hash(let wert) = self { return wert }
        return nil
    }
}

/// Berechnet den SHA-1 einer `PHAssetResource`, indem sie chunkweise durch den
/// Hasher gestreamt wird.
///
/// Bewusst kein Export in eine Datei: Bei einem Nachhol-Abgleich über zehntausende
/// Originale liefe sonst leicht ein Volume voll, und ein Abbruch müsste aufräumen.
/// Der Streamingweg hat außerdem eine `PHAssetResourceDataRequestID`, über die ein
/// hängender iCloud-Download sofort abgebrochen werden kann — ein Abbruch, der auf
/// einen 4-GB-Download wartet, wirkt defekt.
///
/// **Zustand liegt pro Aufruf in einem `HashLauf`, nicht auf der Instanz.** Vorher
/// teilten sich alle Aufrufe ein Abbruch-Flag und einen Anfrage-Slot. Das ließ die
/// gefährlichste aller Ausgaben zu: Ein `abbrechen()` stoppte Anfrage A mitten im
/// Download, der nächste Aufruf setzte das Flag zurück, bevor A's
/// `completionHandler` lief — und der sah dann „nicht abgebrochen, kein Fehler" und
/// gab den SHA-1 der bis dahin empfangenen Bytes als Hash der ganzen Resource aus.
/// Ein gültig aussehender Hash eines Bruchstücks ist genau das, wogegen diese Klasse
/// gebaut ist; ein Treffer gilt oben als Beweis und löscht das Foto des Nutzers.
/// Dieselbe Falle steckte schon einmal in `UploadManager.computeSHA1` (siehe den
/// Kommentar dort). Mit Zustand pro Lauf kann ein späterer Aufruf den Zustand eines
/// früheren strukturell nicht mehr anfassen.
///
/// `UploadManager.computeSHA1` bleibt unberührt; es arbeitet auf Datei-URLs.
final class ApplePhotoResourceHasher: @unchecked Sendable {

    /// Schützt ausschließlich den Verweis auf den gerade laufenden Vorgang, damit
    /// `abbrechen()` ihn erreichen kann. Aller Rechenzustand steckt im `HashLauf`.
    private let lock = NSLock()
    private var aktiverLauf: HashLauf?

    /// - Parameter fortschritt: 0…1 des iCloud-Downloads, falls die Resource nicht
    ///   lokal vorliegt. Wird auf einer beliebigen Queue aufgerufen.
    /// - Returns: `.hash` mit Hex in Kleinbuchstaben, sonst der Grund für den
    ///   Fehlschlag — Abbruch, Lesefehler oder unvollständig gelesene Bytes. Alles
    ///   außer `.hash` heißt „nicht ermittelbar" und führt oben zu einer Ablehnung,
    ///   nie zu einer Freigabe.
    ///
    /// Aufrufe sind auf jeweils eigenem Zustand gefahrlos, aber `abbrechen()`
    /// erreicht immer nur den zuletzt gestarteten Lauf. Die Löschprüfung arbeitet
    /// bewusst seriell ein Foto nach dem anderen ab; wer parallelisiert, braucht
    /// pro Nebenläufigkeit eine eigene Hasher-Instanz.
    func sha1Hex(
        for resource: PHAssetResource,
        fortschritt: (@Sendable (Double) -> Void)? = nil
    ) async -> ApplePhotoHashErgebnis {
        // Erwartete Größe vor dem Lesen holen: Sie ist die zweite, von Photos'
        // Fehlersemantik unabhängige Absicherung gegen einen abgeschnittenen Lesevorgang.
        let erwarteteBytes = Self.resourceFileSize(resource)

        let lauf = HashLauf()
        lock.withLock { aktiverLauf = lauf }
        defer {
            lock.withLock { if aktiverLauf === lauf { aktiverLauf = nil } }
        }

        let optionen = PHAssetResourceRequestOptions()
        // Volle Byte-Prüfung ist die getroffene Entscheidung — iCloud-Downloads
        // gehören dazu.
        optionen.isNetworkAccessAllowed = true
        optionen.progressHandler = fortschritt

        return await withCheckedContinuation { (continuation: CheckedContinuation<ApplePhotoHashErgebnis, Never>) in
            // Zuerst eintragen: Ein `abbrechen()`, das schon zwischen Registrierung
            // und hier eingetroffen ist, hat sonst nichts zum Fortsetzen und der
            // Aufrufer wartete ewig.
            guard lauf.continuationSetzen(continuation) else { return }

            let id = PHAssetResourceManager.default().requestData(
                for: resource,
                options: optionen,
                dataReceivedHandler: { daten in
                    lauf.update(daten)
                },
                completionHandler: { fehler in
                    lauf.anfrageBeendet()

                    if lauf.wurdeAbgebrochen {
                        // Nach einem Abbruch ist die Continuation bereits mit
                        // `.abgebrochen` fortgesetzt; das hier ist nur noch ein No-op.
                        lauf.fortsetzen(.abgebrochen)
                        return
                    }
                    if let fehler {
                        AppLogger.upload.info("AppleDelete: Resource nicht lesbar — \(fehler.localizedDescription)")
                        lauf.fortsetzen(.icloudFehler)
                        return
                    }
                    lauf.fortsetzen(lauf.finalisieren(erwarteteBytes: erwarteteBytes))
                }
            )

            // `abbrechen()` kann zwischen dem Setzen der Continuation und dem Erhalt
            // der ID eingetroffen sein. Ohne diese Nachprüfung liefe der Download
            // weiter, obwohl der Aufrufer längst `.abgebrochen` zurückbekommen hat.
            if let sofortAbbrechen = lauf.anfrageRegistrieren(id) {
                PHAssetResourceManager.default().cancelDataRequest(sofortAbbrechen)
            }
        }
    }

    /// Bricht den laufenden Hash-Vorgang sofort ab, auch mitten im iCloud-Download.
    ///
    /// Der Aufrufer bekommt sein `.abgebrochen` sofort, ohne auf Photos zu warten:
    /// `cancelDataRequest` sagt nirgends zu, dass der `completionHandler` danach
    /// überhaupt noch läuft — beim Geschwister-API `PHImageManager.cancelImageRequest`
    /// läuft er ausdrücklich *nicht*. Würde nur dort fortgesetzt, hinge ein `await`
    /// im Zweifel für immer. Ein später doch noch eintreffender Handler ist durch die
    /// Einmal-Fortsetzung ein No-op.
    func abbrechen() {
        lock.lock()
        let lauf = aktiverLauf
        lock.unlock()
        lauf?.abbrechen()
    }

    /// Dateigröße einer `PHAssetResource` über KVC ("fileSize" ist kein
    /// dokumentiertes API), daher optional — gleicher Weg wie in
    /// `UploadManager.resourceFileSize`. Fehlt der Wert, greifen nur noch die
    /// Fehler- und Abbruchprüfungen; das Foto deswegen durchfallen zu lassen,
    /// würde die Löschprüfung für ganze Resource-Typen lahmlegen.
    private static func resourceFileSize(_ resource: PHAssetResource) -> Int64? {
        (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value
    }
}

/// Der gesamte Zustand *eines* Hash-Vorgangs: Hasher, gezählte Bytes, Abbruch-Flag,
/// Anfrage-ID und Continuation. Gehört dem einen `sha1Hex`-Aufruf, der ihn erzeugt
/// hat; die Instanz hält nur einen Verweis, damit `abbrechen()` ihn erreicht.
///
/// Die Chunk- und Completion-Handler laufen auf fremden Queues, `Insecure.SHA1` ist
/// ein Werttyp — beides zusammen verlangt die Sperre. Sie wird nie über einen
/// `cancelDataRequest`- oder `resume`-Aufruf gehalten.
private final class HashLauf: @unchecked Sendable {

    private let lock = NSLock()
    private var hasher = Insecure.SHA1()
    private var gehashteBytes: Int64 = 0
    private var abgebrochen = false
    private var anfrage: PHAssetResourceDataRequestID?
    private var anfrageBeendetFlag = false
    private var continuation: CheckedContinuation<ApplePhotoHashErgebnis, Never>?

    var wurdeAbgebrochen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return abgebrochen
    }

    /// - Returns: `false`, wenn der Lauf bereits abgebrochen war. Dann ist die
    ///   Continuation schon mit `.abgebrochen` fortgesetzt und es darf keine Anfrage
    ///   mehr gestartet werden.
    func continuationSetzen(_ c: CheckedContinuation<ApplePhotoHashErgebnis, Never>) -> Bool {
        lock.lock()
        if abgebrochen {
            lock.unlock()
            c.resume(returning: .abgebrochen)
            return false
        }
        continuation = c
        lock.unlock()
        return true
    }

    /// - Returns: Die ID, falls der Lauf in der Zwischenzeit abgebrochen wurde und
    ///   die Anfrage darum außerhalb der Sperre storniert werden muss.
    func anfrageRegistrieren(_ id: PHAssetResourceDataRequestID) -> PHAssetResourceDataRequestID? {
        lock.lock()
        defer { lock.unlock() }
        // Zuerst prüfen, ob der Handler schon gelaufen ist: Sonst könnte unten
        // `id` als „sofort abzubrechen" zurückgegeben werden, obwohl die Anfrage
        // längst beendet ist — der Aufrufer stornierte dann eine fremde,
        // möglicherweise von Photos wiederverwendete ID.
        if anfrageBeendetFlag { return nil }
        if abgebrochen { return id }
        anfrage = id
        return nil
    }

    func anfrageBeendet() {
        lock.lock()
        anfrageBeendetFlag = true
        anfrage = nil
        lock.unlock()
    }

    func update(_ daten: Data) {
        lock.lock()
        hasher.update(data: daten)
        gehashteBytes += Int64(daten.count)
        lock.unlock()
    }

    /// - Returns: `.hash` des Gelesenen — aber nur, wenn die Bytezahl zur erwarteten
    ///   Größe passt, sonst `.unvollständig`. Photos' Fehlersemantik allein ist als
    ///   Schutz gegen einen abgeschnittenen Lesevorgang zu wenig; ein Hash über ein
    ///   Bruchstück sieht gültig aus. Ist die Größe unbekannt, bleibt es beim Hash
    ///   des Gelesenen.
    func finalisieren(erwarteteBytes: Int64?) -> ApplePhotoHashErgebnis {
        lock.lock()
        let hex = ChecksumHex.fromBytes(hasher.finalize())
        let gezählt = gehashteBytes
        lock.unlock()

        guard let erwarteteBytes, erwarteteBytes > 0 else {
            // Zweite Absicherung entfällt: Ohne bekannte Erwartungsgröße greift nur
            // noch die Fehler-/Abbruchprüfung von Photos. Das Foto darf deswegen
            // nicht durchfallen (siehe `resourceFileSize`), aber der Ausfall der
            // zweiten Absicherung muss sichtbar sein.
            AppLogger.upload.info(
                "AppleDelete: Resource-Größe nicht ermittelbar — Bytezahl nicht verifiziert"
            )
            return .hash(hex)
        }

        if gezählt != erwarteteBytes {
            AppLogger.upload.info(
                "AppleDelete: Resource unvollständig gelesen (\(gezählt) von \(erwarteteBytes) Bytes) — kein Hash"
            )
            return .unvollständig
        }
        return .hash(hex)
    }

    /// Setzt die Continuation genau einmal fort — ein zweiter Aufruf ist in Swift ein
    /// Laufzeitabsturz, und die Photos-Callbacks geben keine Garantie, dass
    /// `completionHandler` nach einem Abbruch genau einmal kommt.
    func fortsetzen(_ wert: ApplePhotoHashErgebnis) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: wert)
    }

    /// Markiert den Abbruch, setzt den Aufrufer sofort mit `.abgebrochen` fort und storniert
    /// die Anfrage — beides außerhalb der Sperre.
    func abbrechen() {
        lock.lock()
        abgebrochen = true
        let id = anfrage
        anfrage = nil
        let c = continuation
        continuation = nil
        lock.unlock()

        c?.resume(returning: .abgebrochen)
        if let id {
            PHAssetResourceManager.default().cancelDataRequest(id)
        }
    }
}
