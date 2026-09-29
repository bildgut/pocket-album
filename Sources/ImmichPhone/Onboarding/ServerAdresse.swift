import Foundation

/// Immich-Serverversion als Zahlen. `getServerVersion()` liefert "3.2.2".
struct ImmichVersion: Comparable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    /// Die strukturierte Suche (`SearchFilter`) gibt es ab 3.2.0.
    static let mindestens = ImmichVersion(major: 3, minor: 2, patch: 0)

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(_ text: String) {
        let ohneV = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let teile = ohneV.split(separator: ".").compactMap { Int($0) }
        guard teile.count == 3 else { return nil }
        self.init(major: teile[0], minor: teile[1], patch: teile[2])
    }

    static func < (a: ImmichVersion, b: ImmichVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }
}

/// Aus einer Eingabe die Adressen, die die Server-Prüfung der Reihe nach versucht.
enum ServerAdresse {
    /// Was aus der Zwischenablage ins Server-Feld kommt: Wer die Adresszeile des
    /// Browsers kopiert, bringt Pfad, Abfrage und Anker mit — übrig bleiben Schema,
    /// Host und Port. Ohne Schema bleibt der Text, nur getrimmt und auf die erste
    /// Zeile gekürzt.
    static func ausZwischenablage(_ text: String) -> String {
        let ersteZeile = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let klein = ersteZeile.lowercased()
        guard klein.hasPrefix("http://") || klein.hasPrefix("https://"),
              let teile = URLComponents(string: ersteZeile),
              let schema = teile.scheme, let host = teile.host, !host.isEmpty
        else { return ersteZeile.trimmingCharacters(in: .whitespaces) }
        let port = teile.port.map { ":\($0)" } ?? ""
        return "\(schema.lowercased())://\(host)\(port)"
    }

    /// Ohne Schema zuerst `https`, dann `http` (Heimnetz ohne TLS).
    static func kandidaten(fuer eingabe: String) -> [URL] {
        let text = eingabe.trimmingCharacters(in: .whitespacesAndNewlines)
        // Das Schema zuerst abtrennen: Erst danach dürfen Schrägstriche am Ende weg,
        // sonst würde aus "https://" der Host "https:".
        let klein = text.lowercased()
        let schemata: [String]
        var rest: Substring
        if klein.hasPrefix("https://") {
            schemata = ["https://"]; rest = text.dropFirst(8)
        } else if klein.hasPrefix("http://") {
            schemata = ["http://"]; rest = text.dropFirst(7)
        } else {
            schemata = ["https://", "http://"]; rest = Substring(text)
        }
        while rest.hasSuffix("/") { rest = rest.dropLast() }
        guard !rest.isEmpty else { return [] }
        let adressen = schemata.map { $0 + rest }
        return adressen.compactMap { adresse in
            guard let url = URL(string: adresse), let host = url.host(), !host.isEmpty else { return nil }
            return url
        }
    }
}
