import Foundation

/// Welche Datei das Teilenblatt bekommt.
///
/// Geteilt wird das **Original** — wer teilt, will die Datei, nicht ein
/// bildschirmgroßes JPEG. Liegt offline nur eine Vorschau oder die kleine
/// Videofassung, holt der Server das Original; scheitert das (kein Netz), wird
/// die lokale Fassung geteilt statt einer Fehlermeldung.
enum PhoneTeilenWeg: Equatable {
    case lokal(URL)
    case server(ersatz: URL?)
    case nichts

    static func bestimme(lokal: URL?, hatServer: Bool) -> PhoneTeilenWeg {
        if let lokal, OfflineFassung.aus(pfad: lokal.lastPathComponent) == .original {
            return .lokal(lokal)
        }
        if hatServer { return .server(ersatz: lokal) }
        if let lokal { return .lokal(lokal) }
        return .nichts
    }
}
