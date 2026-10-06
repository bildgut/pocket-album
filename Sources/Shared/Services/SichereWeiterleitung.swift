import Foundation

/// Lässt HTTP-Weiterleitungen nur auf demselben Host zu und nie von https auf http.
///
/// **Beleg (28.09.2026, macOS 27, zwei lokale `NWListener` auf 127.0.0.1 und
/// localhost, 302 von einem zum anderen):** `URLSession` schickt beim Folgen einer
/// Weiterleitung auf einen **fremden Host** den `x-api-key` mit — sowohl als
/// `httpAdditionalHeaders` der Configuration als auch als Kopfzeile am einzelnen
/// `URLRequest`. Beides ist hier im Einsatz (die meisten API-Aufrufe setzen den
/// Schlüssel sogar je Anfrage). Ohne diesen Delegaten genügte also ein
/// kompromittierter oder falsch eingestellter Reverse-Proxy, der auf eine fremde
/// Adresse umleitet, und der Schlüssel läge dort im Log. Der Test
/// `SichereWeiterleitungTests` hält den Beleg am echten Socket fest.
///
/// Abgelehnt heißt `completionHandler(nil)`: Die Anfrage endet mit der 3xx-Antwort
/// selbst, die Aufrufer sehen einen HTTP-Fehler statt stiller Daten von woanders.
/// Weiterleitungen auf demselben Host (z. B. `/api` → `/api/`) bleiben erlaubt.
final class SichereWeiterleitung: NSObject, URLSessionTaskDelegate, Sendable {

    static let shared = SichereWeiterleitung()

    /// Die Regel, ohne Session prüfbar.
    static func erlaubt(von alt: URL?, nach neu: URL?) -> Bool {
        guard let alt, let neu,
              let altHost = alt.host()?.lowercased(),
              let neuHost = neu.host()?.lowercased() else { return false }
        guard altHost == neuHost else { return false }
        let altSchema = alt.scheme?.lowercased()
        let neuSchema = neu.scheme?.lowercased()
        if altSchema == "https" && neuSchema != "https" { return false }
        return neuSchema == "https" || neuSchema == "http"
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let von = task.currentRequest?.url ?? response.url
        if Self.erlaubt(von: von, nach: request.url) {
            completionHandler(request)
        } else {
            AppLogger.api.warning("Weiterleitung abgelehnt: \(von?.host() ?? "?", privacy: .public) → \(request.url?.host() ?? "?", privacy: .public) (\(request.url?.scheme ?? "?", privacy: .public))")
            completionHandler(nil)
        }
    }
}

extension URLSession {
    /// Eine Session mit ``SichereWeiterleitung`` — für alles, was Zugangsdaten trägt.
    static func mitSichererWeiterleitung(_ configuration: URLSessionConfiguration) -> URLSession {
        URLSession(configuration: configuration, delegate: SichereWeiterleitung.shared, delegateQueue: nil)
    }
}
