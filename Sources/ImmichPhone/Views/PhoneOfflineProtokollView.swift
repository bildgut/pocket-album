import SwiftUI

/// Die letzten Offline-Läufe als Text — für die Frage „warum kommt das Laden
/// nicht voran?". Zeigt, ob die Zeit in der Auflösung oder im Laden steckt,
/// warum ein Lauf endete und woran die erste Datei scheiterte.
struct PhoneOfflineProtokollView: View {
    @State private var eintraege: [OfflineLaufEintrag] = []

    var body: some View {
        List {
            if OfflineSyncProgress.shared.isActive { liveAbschnitt }
            if eintraege.isEmpty {
                Text(Self.leer).foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach(Array(eintraege.reversed().enumerated()), id: \.offset) { _, eintrag in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: eintrag.zeile()).font(.footnote.weight(.semibold))
                            ForEach(Array(eintrag.details().enumerated()), id: \.offset) { _, zeile in
                                Text(verbatim: zeile).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .textSelection(.enabled)
                    }
                } footer: {
                    Text(Self.erklaerung)
                }
            }
        }
        .navigationTitle(Self.titel)
        .toolbar {
            if !eintraege.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: OfflineLaufProtokoll().text(kopf: Self.kopf))
                }
            }
        }
        .task { eintraege = OfflineLaufProtokoll().eintraege }
        .refreshable { eintraege = OfflineLaufProtokoll().eintraege }
    }

    /// Was gerade passiert: Bleibt der Zähler stehen, sieht man hier, ob Anfragen
    /// hängen (hohes Alter) oder gar keine laufen.
    private var liveAbschnitt: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 1)) { kontext in
                let p = OfflineSyncProgress.shared
                let jetzt = kontext.date
                let aelteste = p.anfragen.values.map { jetzt.timeIntervalSince($0) }.max()
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: p.total > 0 ? "\(p.completed)/\(p.total) Dateien, \(p.failed) fehlgeschlagen" : "Vorbereitung…")
                        .font(.footnote.weight(.semibold))
                    Text(verbatim: "Laufende Anfragen: \(p.anfragen.count)"
                         + (aelteste.map { " · älteste " + OfflineLaufEintrag.sek($0) } ?? ""))
                    if let letzte = p.letzteDatei {
                        Text(verbatim: "Letzte Datei fertig vor " + OfflineLaufEintrag.sek(jetzt.timeIntervalSince(letzte)))
                    }
                }
                .font(.caption)
                .monospacedDigit()
            }
        } header: {
            Text(Self.liveTitel)
        }
    }

    /// Version und System, damit ein weitergegebenes Protokoll für sich steht.
    private static var kopf: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Pocket Album \(version) (\(build)) · \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    private static let liveTitel = String(localized: "Running Now")
    private static let titel = String(localized: "Download Log")
    private static let leer = String(localized: "No runs recorded yet.")
    private static let erklaerung = String(localized: "Newest first. “Resolution” is the time spent finding out which photos belong to your sources, before the first file loads.")
}
