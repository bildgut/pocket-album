import Foundation

/// Merkt sich, welche Apple-Fotos der Start-Dialog „Fotos von Apple Fotos syncen?"
/// schon gezeigt hat, damit er nicht bei jedem Start wegen derselben Fotos kommt.
///
/// „Später" verschiebt `lastSuccessfulSyncAt` nicht — ohne dieses Gedächtnis fand der
/// Startcheck deshalb bei jedem Start dieselben Kandidaten (gemessen: 24 Stück, Start
/// für Start). Jetzt fragt der Dialog nur, wenn **mindestens ein** Kandidat dabei ist,
/// den er noch nicht gezeigt hat.
///
/// Verglichen wird nur `localIdentifier`, bewusst ohne `modificationDate`: Apple Fotos
/// setzt das Datum auch bei eigener Analyse (Gesichter, Szenen) neu, der Dialog käme
/// dann doch wieder ohne sichtbaren Grund. Ein erneut bearbeitetes, schon gezeigtes
/// Foto löst deshalb keine neue Frage aus — der manuelle Sync findet es trotzdem.
enum ApplePhotosStartupPromptMemory {
    static let defaultsKey = "applePhotosStartupPromptShownIDs"

    /// Soll der Dialog für diese Kandidaten erscheinen?
    static func shouldPrompt(pending: Set<String>, shown: Set<String>) -> Bool {
        !pending.subtracting(shown).isEmpty
    }

    /// Der zu speichernde Stand nach einem Startcheck. Nur was **jetzt** noch aussteht,
    /// bleibt gemerkt: Hochgeladenes fällt aus den Kandidaten und damit auch hier
    /// heraus, die Liste wächst also nicht über die Zeit.
    static func remembered(pending: Set<String>, shown: Set<String>, didPrompt: Bool) -> Set<String> {
        didPrompt ? pending : pending.intersection(shown)
    }

    static func load(from defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: defaultsKey) ?? [])
    }

    static func save(_ ids: Set<String>, to defaults: UserDefaults) {
        if ids.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(ids.sorted(), forKey: defaultsKey)
        }
    }
}
