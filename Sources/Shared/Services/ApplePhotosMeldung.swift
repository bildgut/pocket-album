import Foundation

/// Ob neue Apple-Fotos eine macOS-Mitteilung auslösen — und was danach als
/// „gemeldet" gilt. Das Gedächtnis teilt sich den Speicher mit dem früheren
/// Start-Dialog (`ApplePhotosStartupPromptMemory`).
enum ApplePhotosMeldung {
    static let notificationIdentifier = "immichmac.applephotos.pending"
    static let userInfoKey = "applePhotosPending"

    /// - Parameter appAktiv: Ist die App vorn, sieht der Nutzer den Zähler in der
    ///   Seitenleiste. Diese Fotos gelten dann als gesehen und lösen später im
    ///   Hintergrund keine Mitteilung mehr aus.
    static func entscheidung(
        pending: Set<String>,
        gemeldet: Set<String>,
        appAktiv: Bool
    ) -> (melden: Bool, gemerkt: Set<String>) {
        let melden = !appAktiv
            && ApplePhotosStartupPromptMemory.shouldPrompt(pending: pending, shown: gemeldet)
        let gemerkt = ApplePhotosStartupPromptMemory.remembered(
            pending: pending,
            shown: gemeldet,
            didPrompt: melden || appAktiv
        )
        return (melden, gemerkt)
    }

    static func text(anzahl: Int) -> String {
        anzahl == 1
            ? "1 neues Foto wartet auf die Sicherung."
            : "\(anzahl) neue Fotos warten auf die Sicherung."
    }
}
