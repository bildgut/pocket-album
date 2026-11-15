import Foundation

/// Welches Asset „Bearbeiten“ wirklich öffnet.
///
/// Die Fassung ist Titelbild ihres Stapels, also steht der Nutzer beim Weiterbearbeiten
/// fast immer auf ihr — bearbeitet wird aber immer das Original, sonst rechnete jede
/// Runde auf einer schon verlustbehaftet gespeicherten Datei weiter.
enum BearbeitungsZiel {

    /// - Parameters:
    ///   - gezeigt: das Foto in der Einzelansicht.
    ///   - stapel: alle Mitglieder seines Stapels (leer ohne Stapel).
    ///   - verweis: der Rückverweis am gezeigten Foto, falls es eine Fassung ist.
    /// - Returns: die ID des zu bearbeitenden Assets.
    static func waehle(gezeigt: Asset, stapel: [Asset], verweis: FassungsVerweis?) -> String {
        if let verweis { return verweis.originalId }
        if !istRaw(gezeigt) {
            // RAW+JPEG/HEIC-Paar: Die Einstellungen hängen am RAW, damit es je Paar nur
            // eine Fassung gibt — gleich, welche Hälfte geöffnet wurde.
            let raws = stapel.filter { $0.id != gezeigt.id && istRaw($0) }
            let stamm = dateistamm(gezeigt)
            if let raw = raws.first(where: { dateistamm($0) == stamm }) {
                return raw.id
            }
            // Apple-Fotos-Importe von bearbeiteten Aufnahmen heißen „<UUID>_L0_001-FullSizeRender.heic"
            // neben „<UUID>_L0_001-IMG_4370.DNG": gleicher Apple-Vorspann, verschiedener Rest.
            if let praefix = applePraefix(gezeigt),
               let raw = raws.first(where: { applePraefix($0) == praefix }) {
                return raw.id
            }
            // Hat der Stapel genau ein RAW, ist es das Paar-Original.
            if raws.count == 1 {
                return raws[0].id
            }
        }
        return gezeigt.id
    }

    /// Die Kinder unter der neu hochgeladenen Fassung: das Original und alle übrigen
    /// Mitglieder seines bestehenden Stapels (z. B. das Kamera-HEIC eines RAW+HEIC-Paars),
    /// ohne die neue Fassung selbst und ohne die alte Fassung, die gleich in den
    /// Papierkorb wandert.
    static func stapelKinder(
        originalId: String,
        stapel: [Asset],
        neu: String,
        alteFassung: String?
    ) -> [String] {
        var kinder: [String] = []
        var gesehen: Set<String> = [neu]
        if let alteFassung { gesehen.insert(alteFassung) }
        func nimm(_ id: String) {
            if gesehen.insert(id).inserted { kinder.append(id) }
        }
        nimm(originalId)
        for mitglied in stapel {
            nimm(mitglied.id)
        }
        return kinder
    }

    /// Welches Mitglied beim Zurücksetzen („Alles zurücksetzen" + Fertig) wieder
    /// Titelbild des Stapels wird: bei einem RAW+HEIC/JPEG-Stapel die Kamera-Fassung
    /// (so wie der Stapel vor der ersten Bearbeitung aussah), sonst das Original selbst.
    static func titelbildNachZuruecksetzen(
        original: Asset,
        stapel: [Asset],
        alteFassung: String?
    ) -> String {
        guard istRaw(original) else { return original.id }
        if let kamera = stapel.first(where: {
            $0.id != original.id && $0.id != alteFassung && !$0.isVideo && !istRaw($0)
        }) {
            return kamera.id
        }
        return original.id
    }

    private static func istRaw(_ asset: Asset) -> Bool {
        !asset.isVideo && MediaType.isRawFile(fileName: asset.originalFileName, path: asset.originalPath)
    }

    private static func dateistamm(_ asset: Asset) -> String {
        ((asset.originalFileName as NSString).deletingPathExtension).lowercased()
    }

    /// Gemeinsamer `<UUID>_L0_001-`-Vorspann eines Apple-Fotos-Exports, oder `nil`.
    private static func applePraefix(_ asset: Asset) -> String? {
        let name = asset.originalFileName.lowercased()
        guard let range = name.range(of: "_l0_001-") else { return nil }
        let prefix = String(name[..<range.upperBound])
        return prefix.count >= 16 ? prefix : nil
    }
}

/// Startwerte aus der Zeit vor der Server-Ablage.
enum BearbeitungsStart {

    /// Träge Übertragung: Ein RAW, das bisher nur lokal entwickelt wurde
    /// (``RawDevelopState``), öffnet mit diesen Reglern, und seine alte Entwicklung gilt
    /// als Fassung — das nächste „Fertig“ ersetzt sie, statt eine zweite anzulegen.
    static func ausLokal(_ state: RawDevelopState?) -> BearbeitungsEintrag? {
        guard let state, let params = RawDevelopParams(json: state.paramsJSON) else { return nil }
        return BearbeitungsEintrag(
            einstellungen: Bearbeitung(raw: params),
            fassungId: state.developedAssetId,
            geaendertAm: state.updatedAt
        )
    }
}

/// Der Stand einer laufenden Bearbeitung aus den Werkzeugen, die geöffnet wurden.
enum BearbeitungsStand {

    /// Ein `nil`-Werkzeug wurde in dieser Sitzung nie geöffnet und behält den Wert aus
    /// `start`; ein geöffnetes gilt mit seinem aktuellen Stand.
    static func aktuell(
        start: Bearbeitung,
        raw: RawDevelopParams?,
        anpassen: ImageAdjustmentParams?,
        zuschnitt: Zuschnitt?
    ) -> Bearbeitung {
        Bearbeitung(
            raw: raw ?? start.raw,
            anpassen: anpassen ?? start.anpassen,
            zuschnitt: zuschnitt ?? start.zuschnitt
        )
    }
}

/// Die Server-Schritte eines „Fertig“ als Wertfolge — wie ``RawDevelopPlan``, damit der
/// Test genau die Reihenfolge prüft, die `BearbeitungSpeichern` abarbeitet.
///
/// Zusagen: erst hochladen, dann löschen; die alte Fassung wandert erst in den
/// Papierkorb, wenn die neue gestapelt und der Eintrag geschrieben ist.
enum FassungsPlan {

    enum Modus: Equatable, Sendable {
        /// Fassung hochladen und als Titelbild auf das Original stapeln.
        case stapeln
        /// Ergebnis ersetzt das Original (Original in den Papierkorb). Nur Nicht-RAW.
        case ersetzen
    }

    enum Schritt: Equatable, Sendable {
        case hochladen
        /// `POST /api/stacks` mit `[neu, original]` — vereinigt einen bestehenden
        /// Stapel des Originals und macht die Fassung zum Titelbild.
        case stapelnFassungZuerst
        case metadatenUebertragen
        case verweisSchreiben
        case eintragSchreiben
        case alteFassungInPapierkorb(String)
        case originalWirdTitel
        /// Ausgeführt als leerer Eintrag, nicht als Löschen (siehe `BearbeitungSpeichern`).
        case eintragLoeschen
        case ersetzen
        case benachrichtigen
    }

    static func schritte(
        vorher: BearbeitungsEintrag?,
        jetzt: Bearbeitung,
        start: Bearbeitung,
        modus: Modus
    ) -> [Schritt] {
        guard jetzt != start else { return [] }
        let alt = vorher?.fassungId

        if modus == .ersetzen {
            var s: [Schritt] = [.ersetzen]
            if let alt { s.append(.alteFassungInPapierkorb(alt)) }
            s.append(.benachrichtigen)
            return s
        }

        if jetzt.istLeer {
            guard let alt else { return [.eintragLoeschen] }
            return [.originalWirdTitel, .alteFassungInPapierkorb(alt), .eintragLoeschen, .benachrichtigen]
        }

        var s: [Schritt] = [.hochladen, .stapelnFassungZuerst, .metadatenUebertragen,
                            .verweisSchreiben, .eintragSchreiben]
        if let alt { s.append(.alteFassungInPapierkorb(alt)) }
        s.append(.benachrichtigen)
        return s
    }
}
