import Foundation

// Wertetypen der Wahrzeichen-Erkennung. Wie bei `GeoSuggestion` bewusst ohne
// SwiftData, SwiftUI und Netz: Prompt-Auswertung und Trefferbewertung sind reine
// Funktionen über diesen Typen und damit ohne Umgebung testbar.

// MARK: - Was das Modell gesehen hat

/// Die Vermutung des Bildmodells — **ohne Koordinaten**.
///
/// Sprachmodelle raten Koordinaten notorisch ungenau, und ein falsch übernommener
/// Ort ist auf Servern ohne Null-Unterstützung nicht mehr wegzubekommen. Deshalb
/// liefert das Modell nur einen Namen; die Koordinate kommt aus einer
/// Kartendatenbank (``LandmarkResolver``).
struct LandmarkGuess: Sendable, Equatable {
    /// Ob überhaupt ein bestimmter Ort erkannt wurde.
    let recognized: Bool
    /// Eigenname in Landessprache, z. B. „Ponte di Rialto".
    let name: String
    let city: String?
    let region: String?
    let country: String?
    /// ISO 3166-1 alpha-2, für den Abgleich mit dem Kartentreffer.
    let countryCode: String?
    /// Die eine Zeile, die an die Kartensuche geht.
    let searchQuery: String
    /// 0…100, ehrliche Selbsteinschätzung des Modells.
    let confidence: Int
    /// Deutsche Begründung — bei `recognized == false` die Erklärung, warum nicht.
    let reasoning: String

    static func notRecognized(reasoning: String) -> LandmarkGuess {
        LandmarkGuess(recognized: false, name: "", city: nil, region: nil,
                      country: nil, countryCode: nil, searchQuery: "",
                      confidence: 0, reasoning: reasoning)
    }

    /// Wie der Ort in der Oberfläche unter dem Namen steht: „Berlin, Deutschland".
    var placeLine: String {
        [city, region == city ? nil : region, country]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

// MARK: - Zweifel

/// Warum ein aufgelöster Ort nicht ohne Weiteres übernommen werden sollte.
struct LandmarkDoubt: Sendable, Equatable {
    enum Reason: Sendable, Equatable {
        /// Das Modell nennt keine Gattung statt eines Eigennamens.
        case genericName
        /// Modell und Karte sind sich über das Land nicht einig.
        case countryMismatch(guessed: String, resolved: String)
        /// Der Name trifft an vielen weit auseinanderliegenden Orten.
        case scatteredMatches(km: Double)
        /// Das Modell selbst ist unsicher.
        case lowConfidence(Int)
        /// Ein Foto mit GPS von kurz davor oder danach liegt ganz woanders.
        case farFromNearestAnchor(km: Double, gapHours: Double)
        /// Aus der Datenbank zurückgelesen: Der Grund wurde beim Speichern schon
        /// zu Text. Für die Anzeige reicht das, und ein zerlegter Grund wäre bei
        /// jeder Erweiterung ein Migrationsfall.
        case stored(String)
    }

    let reason: Reason

    /// Kurzbegründung für die Karte, z. B. „Treffer 340 km auseinander".
    var summary: String {
        switch reason {
        case .genericName:
            return "Kein Eigenname"
        case .countryMismatch(let guessed, let resolved):
            return "Land laut Bild \(guessed), laut Karte \(resolved)"
        case .scatteredMatches(let km):
            return "Treffer \(Self.km(km)) auseinander"
        case .lowConfidence(let value):
            return "Modell nur zu \(value) % sicher"
        case .farFromNearestAnchor(let km, let hours):
            let gap = hours < 1
                ? "\(Int((hours * 60).rounded())) Min"
                : "\(Int(hours.rounded())) Std"
            return "\(Self.km(km)) vom Foto \(gap) daneben"
        case .stored(let text):
            return text
        }
    }

    private static func km(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f km", value) : "\(Int(value.rounded())) km"
    }
}

/// Wie belastbar ein aufgelöster Ort ist.
///
/// Anders als bei ``GeoPlausibility`` gibt es hier kein „wird gar nicht erst
/// angeboten": Auch ein verworfener Befund bleibt sichtbar, damit der Nutzer
/// versteht, warum ein Foto ohne Vorschlag bleibt — nur anhaken kann er ihn nicht.
enum LandmarkPlausibility: Sendable, Equatable {
    case ok
    /// Sichtbar, mit Warnung, anhakbar.
    case flagged(LandmarkDoubt)
    /// Sichtbar, mit Warnung, **nicht** anhakbar.
    case rejected(LandmarkDoubt)

    var doubt: LandmarkDoubt? {
        switch self {
        case .ok: return nil
        case .flagged(let value), .rejected(let value): return value
        }
    }

    var isSelectable: Bool {
        if case .rejected = self { return false }
        return true
    }

    /// Kürzel für die Datenbank. Der Zweifel wird als fertiger Text daneben
    /// abgelegt — die Oberfläche braucht ihn nur zum Anzeigen, und ein
    /// aufgespaltener `Reason` müsste bei jeder Erweiterung migriert werden.
    var storageKey: String {
        switch self {
        case .ok: return "ok"
        case .flagged: return "flagged"
        case .rejected: return "rejected"
        }
    }
}

// MARK: - Was die Karte daraus gemacht hat

/// Ein Foto mit GPS in zeitlicher Nähe — die Gegenprobe zum erkannten Ort.
struct LandmarkAnchorHint: Sendable, Equatable {
    let gapSeconds: Int
    let latitude: Double
    let longitude: Double
}

/// Der aufgelöste Ort samt Bewertung der Trefferlage.
struct LandmarkResolution: Sendable, Equatable {
    let latitude: Double
    let longitude: Double
    /// Name laut Karte — steht bewusst neben dem Namen des Modells, damit ein
    /// stiller Themenwechsel („Rialto" → irgendein Restaurant) auffällt.
    let displayName: String
    let displayDetail: String
    let matchCount: Int
    /// Streuung der berücksichtigten Treffer.
    let spreadMeters: Int
    let usedQuery: String
    let plausibility: LandmarkPlausibility
}

// MARK: - Zustand je Foto

enum LandmarkState: String, Sendable, CaseIterable {
    /// Ausgewählt, noch nicht gefragt. Reiner Laufzeitzustand.
    case pending
    case analyzing
    case resolving
    /// Koordinate liegt vor.
    case resolved
    /// Das Modell hat nichts Bestimmtes erkannt.
    case noLandmark
    /// Die Karte kennt den Namen nicht — der Vorschlag verfällt ersatzlos.
    case unresolved
    /// Netz, Schlüssel, Überlastung. Wiederholbar.
    case failed
    case applied
    case rejected

    /// Ob ein erneuter Lauf dieses Foto überspringen soll. Jede Anfrage kostet.
    var isSettled: Bool {
        switch self {
        case .resolved, .noLandmark, .unresolved, .applied, .rejected: return true
        case .pending, .analyzing, .resolving, .failed: return false
        }
    }

    var displayName: String {
        switch self {
        case .pending: return "Noch nicht geprüft"
        case .analyzing: return "Wird analysiert"
        case .resolving: return "Ort wird gesucht"
        case .resolved: return "Vorschlag"
        case .noLandmark: return "Nichts erkennbar"
        case .unresolved: return "Ort nicht auffindbar"
        case .failed: return "Fehlgeschlagen"
        case .applied: return "Übernommen"
        case .rejected: return "Verworfen"
        }
    }
}

/// Ein Befund, wie ihn die Oberfläche braucht — Zustand, Vermutung, Auflösung.
struct LandmarkItem: Sendable, Equatable, Identifiable {
    let assetId: String
    var state: LandmarkState
    var guess: LandmarkGuess?
    var resolution: LandmarkResolution?
    var errorMessage: String?

    var id: String { assetId }

    /// Nur was aufgelöst **und** nicht verworfen ist, darf angehakt werden.
    var isSelectable: Bool {
        state == .resolved && (resolution?.plausibility.isSelectable ?? false)
    }
}
