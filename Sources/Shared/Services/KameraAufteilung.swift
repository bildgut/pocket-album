import Foundation

/// Ein Foto der Auswahl, so wie der Rasterindex es kennt — Grundlage für
/// „Nach Kamera aufteilen".
struct KameraZeile: Equatable, Sendable {
    let id: String
    /// `cameraModel` ohne Leerraum; `nil`, wenn keines vorliegt.
    let modell: String?
    /// Hat der Server schon EXIF geliefert (`exifCheckedAt`)? Ohne Vermerk heißt ein
    /// fehlendes Modell nur „noch nicht nachgesehen", nicht „keine Kamera".
    let exifGeprueft: Bool
    /// `fileCreatedAt` in Sekunden seit 1970; `nil`, wenn das Foto nicht im Index liegt.
    let aufnahme: Int?
}

enum KameraGruppenArt: Equatable, Sendable {
    case kamera(String)
    /// EXIF geprüft, aber kein Modell — Messenger, Screenshots, Exporte.
    case ohneKameradaten
    /// EXIF nie geprüft oder das Foto fehlt im Index.
    case exifUnbekannt
}

struct KameraGruppe: Identifiable, Equatable, Sendable {
    let art: KameraGruppenArt
    let ids: [String]
    let istHauptkamera: Bool
    let istGemerkt: Bool

    var id: String { Self.id(fuer: art) }
    var vorausgewaehlt: Bool { istHauptkamera || istGemerkt }

    static func id(fuer art: KameraGruppenArt) -> String {
        switch art {
        case .kamera(let modell): "kamera:\(modell)"
        case .ohneKameradaten: "ohneKameradaten"
        case .exifUnbekannt: "exifUnbekannt"
        }
    }
}

/// Teilt eine Auswahl nach Kameramodell auf, damit sich die eigenen Fotos eines
/// Ereignisses von den zugeschickten trennen lassen.
///
/// Der Eigentümer hilft dabei nicht: Alles kommt über den Apple-Fotos-Sync. WhatsApp
/// erkennt man nur am **Fehlen** der Kameradaten (HD-Stufe: volle Auflösung, teils
/// `IMG_…`-Namen), AirDrop und iMessage behalten sie. „Meine Kamera" gilt nur für
/// einen Zeitraum — deshalb wird die Hauptkamera je Aufruf aus dem Umfeld bestimmt
/// statt als feste Liste geführt.
enum KameraAufteilung {
    static let fensterSekunden = 90 * 86_400
    static let mindestAnteil = 0.5
    static let mindestAnzahl = 20

    static func zeitfenster(_ zeilen: [KameraZeile]) -> ClosedRange<Int>? {
        let zeiten = zeilen.compactMap(\.aufnahme)
        guard let frueh = zeiten.min(), let spaet = zeiten.max() else { return nil }
        return (frueh - fensterSekunden)...(spaet + fensterSekunden)
    }

    /// Das häufigste Modell im Umfeld — nur wenn es klar vorn liegt. Bei Gleichstand
    /// gewinnt der alphabetisch erste Name, damit das Ergebnis nicht vom Wörterbuch abhängt.
    static func hauptkamera(anzahlen: [String: Int]) -> String? {
        let summe = anzahlen.values.reduce(0, +)
        let vorn = anzahlen.max { a, b in
            a.value != b.value ? a.value < b.value : a.key > b.key
        }
        guard let vorn, vorn.value >= mindestAnzahl,
              Double(vorn.value) >= Double(summe) * mindestAnteil
        else { return nil }
        return vorn.key
    }

    static func gruppen(zeilen: [KameraZeile], hauptkamera: String?, gemerkt: Set<String>) -> [KameraGruppe] {
        var jeModell: [String: [String]] = [:]
        var ohne: [String] = []
        var unbekannt: [String] = []
        for zeile in zeilen {
            if let modell = zeile.modell {
                jeModell[modell, default: []].append(zeile.id)
            } else if zeile.exifGeprueft {
                ohne.append(zeile.id)
            } else {
                unbekannt.append(zeile.id)
            }
        }

        let kameras = jeModell.map { modell, ids in
            KameraGruppe(art: .kamera(modell), ids: ids,
                         istHauptkamera: modell == hauptkamera,
                         istGemerkt: modell != hauptkamera && gemerkt.contains(modell))
        }.sorted { a, b in
            if a.vorausgewaehlt != b.vorausgewaehlt { return a.vorausgewaehlt }
            if a.istHauptkamera != b.istHauptkamera { return a.istHauptkamera }
            if a.ids.count != b.ids.count { return a.ids.count > b.ids.count }
            return a.id < b.id
        }

        var ergebnis = kameras
        if !ohne.isEmpty {
            ergebnis.append(KameraGruppe(art: .ohneKameradaten, ids: ohne, istHauptkamera: false, istGemerkt: false))
        }
        if !unbekannt.isEmpty {
            ergebnis.append(KameraGruppe(art: .exifUnbekannt, ids: unbekannt, istHauptkamera: false, istGemerkt: false))
        }
        return ergebnis
    }

    static func auswahl(gruppen: [KameraGruppe], angehakt: Set<String>) -> Set<String> {
        Set(gruppen.filter { angehakt.contains($0.id) }.flatMap(\.ids))
    }

    /// Angehakte Nebenkameras kommen dazu, abgehakte gemerkte fallen heraus. Modelle,
    /// die in dieser Auswahl nicht vorkommen, bleiben unberührt; die Hauptkamera wird
    /// nie gemerkt — sie ergibt sich jedes Mal neu aus dem Zeitraum.
    static func neueMerkliste(alt: Set<String>, gruppen: [KameraGruppe], angehakt: Set<String>, hauptkamera: String?) -> Set<String> {
        var neu = alt
        for gruppe in gruppen {
            guard case .kamera(let modell) = gruppe.art else { continue }
            if angehakt.contains(gruppe.id) {
                if modell != hauptkamera { neu.insert(modell) }
            } else {
                neu.remove(modell)
            }
        }
        return neu
    }
}

/// Kameramodelle, die der Nutzer beim Aufteilen als eigene angehakt hat (etwa die
/// Leica neben dem Telefon).
enum KameraMerkliste {
    static let defaultsKey = "kameraAufteilungEigeneModelle"

    static func load(from defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: defaultsKey) ?? [])
    }

    static func save(_ modelle: Set<String>, to defaults: UserDefaults) {
        if modelle.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(modelle.sorted(), forKey: defaultsKey)
        }
    }
}
