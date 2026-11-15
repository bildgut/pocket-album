import Foundation

/// Welcher Stapel nach dem Hochladen eines Apple-Fotos entsteht.
///
/// Zwei Anlässe: das RAW eines RAW+HEIC/JPEG-Paars, und die **bearbeitete
/// Fassung** eines schon gesicherten Fotos (auf dem iPhone geändert, als neues
/// Immich-Asset hochgeladen). Die alte Fassung — samt ihrem bisherigen Stapel —
/// kommt dann unter die neue, statt als Doppel in der Zeitleiste zu bleiben.
enum ApplePhotosNeuStapel {

    /// Die Kinder unter dem neu hochgeladenen Asset, ohne Doppel und ohne das
    /// Asset selbst.
    ///
    /// - Parameters:
    ///   - neu: das gerade hochgeladene Asset (Titelbild).
    ///   - vorher: das Asset, auf das die Zuordnung vorher zeigte; `nil` beim
    ///     ersten Hochladen. Gleich `neu`, wenn der Server das Hochladen als
    ///     Duplikat erkannt hat — dann gibt es keine alte Fassung.
    ///   - alterStapel: die Mitglieder des Stapels, in dem `vorher` lag, falls einer.
    ///   - raw: die RAW-Hälfte, falls das Foto eine hat.
    static func kinder(neu: String, vorher: String?, alterStapel: [String]?, raw: String?) -> [String] {
        var kinder: [String] = []
        func nimm(_ id: String) {
            if id != neu && !kinder.contains(id) { kinder.append(id) }
        }
        if let vorher, vorher != neu {
            if let alterStapel, !alterStapel.isEmpty {
                alterStapel.forEach(nimm)
            }
            // Auch wenn der alte Stapel `vorher` nicht (mehr) listet: Die alte
            // Fassung gehört in jedem Fall dazu.
            nimm(vorher)
        }
        if let raw { nimm(raw) }
        return kinder
    }

    /// Das Abzeichen wie `GridIndexStore.badgeText`, aber ohne die Assets zu
    /// kennen — das neue ist zu diesem Zeitpunkt noch nicht im Index.
    static func badge(kinder: [String], rawIds: Set<String>, dateiname: String) -> String? {
        guard !kinder.isEmpty else { return nil }
        if kinder.contains(where: rawIds.contains) {
            let ext = (dateiname as NSString).pathExtension.lowercased()
            return ext == "heic" || ext == "heif" ? "HEIC + RAW" : "JPEG + RAW"
        }
        return "\(kinder.count + 1)"
    }
}
