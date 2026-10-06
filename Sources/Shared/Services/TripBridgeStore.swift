import Foundation

/// Merkt sich, welche Pausen zwischen zwei Reisen der Nutzer von Hand überbrückt hat.
///
/// Warum überhaupt gemerkt: Die Reisen entstehen bei jedem Neuberechnen neu — nach
/// einem Sync, nach jedem Reglerdreh. Eine Verbindung, die nur im Arbeitsspeicher
/// steht, wäre nach dem nächsten Sync wieder weg, und der Nutzer hätte sie schon
/// zweimal gemacht, bevor er es merkt.
///
/// Warum `UserDefaults` und nicht SwiftData: Es sind ein paar Zahlen ohne Beziehung
/// zu irgendetwas anderem. Ein neues `@Model` kostete eine Schemaversion samt
/// Migrationsplan — für eine Handvoll Zeitstempel ein schlechtes Geschäft. Die
/// Ignorierliste liegt in SwiftData, weil sie an Assets hängt; das hier hängt an
/// nichts.
enum TripBridgeStore {

    private static let key = "tripBridgedGapEnds"

    static func load(defaults: UserDefaults = AppEnvironment.defaults) -> Set<Double> {
        Set(defaults.array(forKey: key) as? [Double] ?? [])
    }

    static func save(_ ends: Set<Double>, defaults: UserDefaults = AppEnvironment.defaults) {
        // Sortiert abgelegt, damit die Datei beim Nachsehen lesbar bleibt — die
        // Reihenfolge selbst bedeutet nichts.
        defaults.set(ends.sorted(), forKey: key)
    }
}
