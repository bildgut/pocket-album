import Foundation
import SwiftData

/// Was die Wahrzeichen-Erkennung zu einem Foto herausgefunden hat.
///
/// Warum das in die Datenbank gehört und nicht bloß ins ViewModel: Jeder Befund
/// hat eine Anfrage an Google gekostet. Ein Ansichtswechsel, ein Neustart oder
/// ein Absturz darf ihn nicht verlieren. Zugleich ist die Tabelle der Merkzettel
/// „schon gefragt" — **auch** für Negativbefunde, die sonst bei jedem Lauf erneut
/// bezahlt würden. Und drittens ist sie das Protokoll dessen, was unumkehrbar
/// geschrieben wurde.
///
/// Nicht in UserDefaults, aus demselben Grund wie bei ``GeoIgnoredAsset``: Die
/// Tabelle wächst auf tausende Einträge, und jedes Einfügen schriebe das ganze
/// Plist neu.
@Model
final class LandmarkFinding {

    /// Ein Befund je Foto. Ein erneuter Lauf überschreibt ihn.
    @Attribute(.unique) var assetId: String

    var createdAt: Date
    var updatedAt: Date

    /// Rohwert von ``LandmarkState``. Als String, damit ein neuer Fall keine
    /// Migration braucht.
    var stateRaw: String

    /// Welches Modell geantwortet hat — bei einem Fehlurteil will man wissen, ob
    /// es das Fallback-Modell war.
    var modelName: String

    // MARK: - Was das Bildmodell sagte

    var landmarkName: String?
    var city: String?
    var region: String?
    var country: String?
    var countryCode: String?
    var searchQuery: String?
    var geminiConfidence: Int
    var reasoning: String?

    // MARK: - Was die Karte sagte

    var latitude: Double?
    var longitude: Double?
    var resolvedName: String?
    var resolvedDetail: String?
    var matchCount: Int
    var matchSpreadMeters: Int
    var usedQuery: String?

    /// Rohwert von ``LandmarkPlausibility`` (`ok` / `flagged` / `rejected`).
    var plausibilityRaw: String
    /// Der Zweifel als fertiger deutscher Text.
    ///
    /// Bewusst kein zerlegter `Reason`: Die Oberfläche zeigt ihn nur an, und jede
    /// Erweiterung der Gründe würde sonst zu einem Migrationsfall.
    var doubtSummary: String?

    var errorMessage: String?
    var appliedAt: Date?

    init(assetId: String,
         state: LandmarkState,
         modelName: String,
         createdAt: Date = Date()) {
        self.assetId = assetId
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.stateRaw = state.rawValue
        self.modelName = modelName
        self.geminiConfidence = 0
        self.matchCount = 0
        self.matchSpreadMeters = 0
        self.plausibilityRaw = LandmarkPlausibility.ok.storageKey
    }

    // MARK: - Zugriff

    var state: LandmarkState {
        get { LandmarkState(rawValue: stateRaw) ?? .failed }
        set { stateRaw = newValue.rawValue }
    }

    /// Übernimmt, was das Bildmodell geliefert hat.
    func apply(guess: LandmarkGuess) {
        landmarkName = guess.recognized ? guess.name : nil
        city = guess.city
        region = guess.region
        country = guess.country
        countryCode = guess.countryCode
        searchQuery = guess.recognized ? guess.searchQuery : nil
        geminiConfidence = guess.confidence
        reasoning = guess.reasoning
        updatedAt = Date()
    }

    /// Übernimmt, was die Karte daraus gemacht hat.
    func apply(resolution: LandmarkResolution) {
        latitude = resolution.latitude
        longitude = resolution.longitude
        resolvedName = resolution.displayName
        resolvedDetail = resolution.displayDetail
        matchCount = resolution.matchCount
        matchSpreadMeters = resolution.spreadMeters
        usedQuery = resolution.usedQuery
        plausibilityRaw = resolution.plausibility.storageKey
        doubtSummary = resolution.plausibility.doubt?.summary
        updatedAt = Date()
    }

    /// Baut die Werte für die Oberfläche zurück.
    ///
    /// Der Zweifel kommt als fertiger Text zurück und nicht als `Reason` — der
    /// genaue Grund wurde beim Speichern schon in Sprache übersetzt.
    var item: LandmarkItem {
        var guess: LandmarkGuess?
        if let landmarkName {
            guess = LandmarkGuess(
                recognized: true, name: landmarkName, city: city, region: region,
                country: country, countryCode: countryCode,
                searchQuery: searchQuery ?? landmarkName,
                confidence: geminiConfidence, reasoning: reasoning ?? ""
            )
        } else if let reasoning {
            guess = .notRecognized(reasoning: reasoning)
        }

        var resolution: LandmarkResolution?
        if let latitude, let longitude {
            resolution = LandmarkResolution(
                latitude: latitude, longitude: longitude,
                displayName: resolvedName ?? landmarkName ?? "",
                displayDetail: resolvedDetail ?? "",
                matchCount: matchCount,
                spreadMeters: matchSpreadMeters,
                usedQuery: usedQuery ?? "",
                plausibility: storedPlausibility
            )
        }

        return LandmarkItem(assetId: assetId, state: state, guess: guess,
                            resolution: resolution, errorMessage: errorMessage)
    }

    private var storedPlausibility: LandmarkPlausibility {
        // Der Grund ist beim Speichern zu Text geworden; für die Anzeige genügt
        // die Stufe plus dieser Text.
        let doubt = LandmarkDoubt(reason: .genericName)
        switch plausibilityRaw {
        case "flagged": return .flagged(doubtSummary.map(StoredDoubt.make) ?? doubt)
        case "rejected": return .rejected(doubtSummary.map(StoredDoubt.make) ?? doubt)
        default: return .ok
        }
    }
}

/// Ein wieder eingelesener Zweifel: Der Grund ist Text, keine Rechnung mehr.
private enum StoredDoubt {
    static func make(_ summary: String) -> LandmarkDoubt {
        LandmarkDoubt(reason: .stored(summary))
    }
}
