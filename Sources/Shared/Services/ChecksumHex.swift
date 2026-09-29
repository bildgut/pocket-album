import Foundation

/// Immich liefert `checksum` base64-kodiert, verglichen wird hex. Eine Stelle für
/// beide Aufrufer — den Upload-Stichprobenabgleich und die Löschverifikation —,
/// damit nicht zwei Fassungen auseinanderlaufen können.
enum ChecksumHex {

    /// - Returns: Hex in Kleinbuchstaben, oder `nil` bei ungültigem oder leerem Base64.
    ///   Bewusst `nil` statt `""`: Ein Leerstring vergleicht sich mit einem anderen
    ///   Leerstring als gleich, und ein Foto gälte damit ohne jeden Beweis als gesichert.
    static func fromBase64(_ base64: String) -> String? {
        guard let data = Data(base64Encoded: base64), !data.isEmpty else { return nil }
        return fromBytes(data)
    }

    /// Rohbytes — etwa ein `Insecure.SHA1`-Digest — als Kleinbuchstaben-Hex.
    ///
    /// Gedacht für Digests, die nie leer sind; eine leere Folge liefert
    /// konsequenterweise den Leerstring, und den weist `equal` ohnehin ab.
    /// Existiert, damit die Löschverifikation nicht ihre eigene Hex-Formatierung
    /// mitbringt und die beiden Fassungen auseinanderlaufen können.
    static func fromBytes<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Vergleicht zwei Hex-Checksummen. Nur zwei nicht-leere, gleiche Werte gelten
    /// als gleich — fehlt einer, ist die Antwort „nein", nie „vielleicht".
    static func equal(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, !a.isEmpty, !b.isEmpty else { return false }
        return a.lowercased() == b.lowercased()
    }
}
