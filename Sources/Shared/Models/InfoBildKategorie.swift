import Foundation

/// Was Stufe A über ein Bild sagt. Rohwerte wandern als String in die Datenbank,
/// damit ein neuer Fall keine Migration braucht.
enum InfoBildArt: String, CaseIterable, Sendable {
    case foto
    case screenshot
    case dokument
}

/// Was Stufe B über ein Dokument sagt — gefragt wird sie nur, wenn Stufe A
/// `dokument` gesagt hat. Essensfotos kommen hier also nie an; genau deshalb
/// ist die Einordnung zweistufig (siehe Spezifikation, „Was trägt").
enum InfoBildUnterart: String, CaseIterable, Sendable {
    case beleg
    case notiz
    case information
    case rezept
    case ausweis
    case sonstiges
}
