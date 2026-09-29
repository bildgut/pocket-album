import Foundation
@testable import ImmichPhone

/// URLProtocol für die Orte-Tests. Der Handler hängt am **Host**, nicht an einer
/// einzigen statischen Variable: Zwei Suiten am selben statischen Handler
/// überschreiben sich, sobald Swift Testing sie parallel laufen lässt —
/// `.serialized` wirkt nur innerhalb einer Suite.
final class OrteMockURLProtocol: URLProtocol {
    /// (Anfrage, gelesener Körper) → (Statuscode, Antwort)
    typealias Handler = @Sendable (URLRequest, Data) -> (Int, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var verzoegerungen: [String: TimeInterval] = [:]

    /// `verzoegerung` hält die Antwort zurück, **ohne** den Ladefaden zu blockieren —
    /// alle `URLProtocol`-Anfragen teilen sich einen Faden, ein `Thread.sleep` im
    /// Handler hielte also auch die Anfragen anderer Hosts auf.
    static func registriere(host: String, verzoegerung: TimeInterval = 0, _ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        handlers[host] = handler
        verzoegerungen[host] = verzoegerung
    }

    static func entferne(host: String) {
        lock.lock(); defer { lock.unlock() }
        handlers[host] = nil
        verzoegerungen[host] = nil
    }

    private static func verzoegerung(fuer host: String) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return verzoegerungen[host] ?? 0
    }

    private static func handler(fuer host: String) -> Handler? {
        lock.lock(); defer { lock.unlock() }
        return handlers[host]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host, let handler = Self.handler(fuer: host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let (code, body) = handler(request, Self.koerper(von: request))
        let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
        let ausliefern = { [self] in
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        let warten = Self.verzoegerung(fuer: host)
        if warten > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + warten, execute: ausliefern)
        } else {
            ausliefern()
        }
    }

    override func stopLoading() {}

    /// `URLProtocol` bekommt den POST-Körper fast nie als `httpBody`, sondern als
    /// `httpBodyStream`. Wer nur `httpBody` liest, sieht `nil` und prüft nichts.
    static func koerper(von request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var puffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let gelesen = stream.read(&puffer, maxLength: puffer.count)
            guard gelesen > 0 else { break }
            data.append(puffer, count: gelesen)
        }
        return data
    }

    static func client(host: String) -> ImmichAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OrteMockURLProtocol.self]
        return ImmichAPIClient(baseURL: URL(string: "https://\(host)")!, apiKey: "test", sessionConfiguration: config)
    }

    static func query(_ request: URLRequest, _ name: String) -> String? {
        guard let url = request.url else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == name })?.value
    }

    /// Körper als Wörterbuch; leer, wenn er kein JSON-Objekt ist.
    static func json(_ koerper: Data) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: koerper)) as? [String: Any]) ?? [:]
    }

    /// Minimales Asset, das der `Asset`-Decoder annimmt. Pflicht sind dort `id`,
    /// `type`, `originalFileName`, `fileCreatedAt`, `fileModifiedAt`, `isFavorite`.
    static func assetJSON(
        id: String,
        localDateTime: String,
        people: [(id: String, name: String, hidden: Bool)] = []
    ) -> String {
        let personen = people
            .map { #"{"id":"\#($0.id)","name":"\#($0.name)","isHidden":\#($0.hidden)}"# }
            .joined(separator: ",")
        return #"{"id":"\#(id)","type":"IMAGE","originalFileName":"\#(id).jpg","fileCreatedAt":"\#(localDateTime)","fileModifiedAt":"\#(localDateTime)","localDateTime":"\#(localDateTime)","isFavorite":false,"people":[\#(personen)]}"#
    }

    static func seiteJSON(_ assets: [String], nextCursor: String? = nil) -> Data {
        let cursor = nextCursor.map { #""\#($0)""# } ?? "null"
        return #"{"assets":{"items":[\#(assets.joined(separator: ","))],"nextCursor":\#(cursor)}}"#.data(using: .utf8)!
    }
}

/// Zeichnet Anfragen auf, damit die Prüfungen **nach** dem Aufruf im Test laufen —
/// ein `#expect` im Handler liefe auf dem Ladefaden außerhalb des Tests.
final class OrteMitschnitt: @unchecked Sendable {
    private let lock = NSLock()
    private var eintraege: [(request: URLRequest, koerper: Data)] = []

    func merke(_ request: URLRequest, _ koerper: Data) {
        lock.lock(); defer { lock.unlock() }
        eintraege.append((request, koerper))
    }

    var alle: [(request: URLRequest, koerper: Data)] {
        lock.lock(); defer { lock.unlock() }
        return eintraege
    }
}
