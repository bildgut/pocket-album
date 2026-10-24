import Foundation

/// Task-Delegat, der aus ``URLSessionTaskMetrics`` die Messwerte einer Datei zieht.
///
/// Er setzt einen **Task**-Delegaten an eine Session, die schon einen eigenen hat
/// (``SichereWeiterleitung``). Ob URLSession bei einem Task-Delegaten ohne eigene
/// Umleitungs-Methode auf den der Session zurückfällt, ist nicht zugesichert — und
/// ein Loch hier wäre eines in der Schlüsselsicherung. Deshalb reicht dieser Delegat
/// die Umleitung ausdrücklich weiter.
final class DownloadMetrikDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var gemessen: OfflineTransferMetrik?

    var ergebnis: OfflineTransferMetrik? {
        lock.lock(); defer { lock.unlock() }
        return gemessen
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        SichereWeiterleitung.shared.urlSession(
            session, task: task, willPerformHTTPRedirection: response,
            newRequest: request, completionHandler: completionHandler
        )
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let m = Self.metrik(aus: metrics)
        lock.lock(); gemessen = m; lock.unlock()
    }

    /// Die letzte Transaktion, die wirklich aus dem Netz kam (nicht aus dem Cache).
    static func metrik(aus metrics: URLSessionTaskMetrics) -> OfflineTransferMetrik? {
        guard let t = metrics.transactionMetrics.last(where: { $0.resourceFetchType == .networkLoad })
                ?? metrics.transactionMetrics.last else { return nil }
        var m = OfflineTransferMetrik()
        if let start = t.requestStartDate, let antwort = t.responseStartDate {
            m.ttfbSek = antwort.timeIntervalSince(start)
        }
        m.wiederverwendet = t.isReusedConnection
        if !t.isReusedConnection, let ende = t.connectEndDate,
           let anfang = t.domainLookupStartDate ?? t.connectStartDate {
            m.verbindungSek = ende.timeIntervalSince(anfang)
        }
        m.protokoll = t.networkProtocolName
        m.bytes = t.countOfResponseBodyBytesReceived
        m.teuer = t.isExpensive || t.isConstrained
        m.mobilfunk = t.isCellular
        return m
    }
}
