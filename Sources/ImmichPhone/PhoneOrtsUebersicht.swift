import Foundation

/// Aufteilung der Länder-Übersicht im Orte-Reiter: oben große Kacheln, der Rest
/// in einer aufklappbaren Liste. Sechs Kacheln sind drei Reihen — so viele passen
/// auf jedes iPhone, ohne dass die Liste unter den Rand rutscht.
enum PhoneOrtsUebersicht {
    static let kachelAnzahl = 6

    /// Merker, ob die Liste „Alle Länder“ offen ist — überlebt Reiterwechsel und Neustart.
    static let aufgeklapptSchluessel = "orteAlleLaenderAufgeklappt"

    static func aufteilen(_ laender: [PhoneOrtsLand]) -> (kacheln: [PhoneOrtsLand], rest: [PhoneOrtsLand]) {
        (Array(laender.prefix(kachelAnzahl)), Array(laender.dropFirst(kachelAnzahl)))
    }
}
