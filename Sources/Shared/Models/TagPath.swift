import Foundation

/// Regeln für Tag-Pfade und -Namen, bevor sie an den Server gehen.
///
/// Immich speichert einen Tag als Pfad (`value` = „reise/berlin"); der *Name* ist das
/// letzte Segment. Seit Server v3.2.0 lehnen `POST /api/tags` und `PUT /api/tags/{id}`
/// einen Namen mit Schrägstrich ab (`^[^/]*$`) — verschachtelt anlegen geht nur noch
/// über `PUT /api/tags` (upsert), das fehlende Elternteile selbst anlegt.
enum TagPath {

    /// Meldung, wenn der Server `name` beim Aktualisieren nicht kennt (vor v3.2.0).
    static let renameUnsupportedMessage =
        "Der Server kann Tags nicht umbenennen – das geht erst ab Immich v3.2.0."

    /// Leerraum je Segment und leere Segmente fallen weg; der Server teilt am
    /// Schrägstrich, trimmt aber nicht — aus „reise / berlin" würde sonst ein Tag
    /// „reise " mit Kind „ berlin".
    static func normalized(_ input: String) -> String? {
        let segments = input
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return segments.isEmpty ? nil : segments.joined(separator: "/")
    }

    /// Ein einzelner Tag-Name: getrimmt, nicht leer, ohne Schrägstrich.
    static func validatedName(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return nil }
        return trimmed
    }

    /// Der Pfad nach dem Umbenennen — so rechnet es auch der Server
    /// (`tag.service.ts`, `update`): nur das letzte Segment wird ersetzt.
    static func renamedValue(_ value: String, to name: String) -> String {
        var parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return name }
        parts[parts.count - 1] = name
        return parts.joined(separator: "/")
    }
}
