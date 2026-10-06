import SwiftUI
import UIKit

/// Die Farben der Marke „Pocket Album“. Das iOS-Ziel nimmt diese statt `Marke.akzent`
/// (das teilt es sich mit dem Mac, dessen Marke eine andere ist).
enum Marke {
    static let koralle = Color(red: 1.0, green: 0.239, blue: 0.467)     // #FF3D77
    static let pfirsich = Color(red: 1.0, green: 0.478, blue: 0.349)    // #FF7A59
    static let sonne = Color(red: 1.0, green: 0.824, blue: 0.247)       // #FFD23F
    static let tuerkis = Color(red: 0.180, green: 0.769, blue: 0.714)   // #2EC4B6
    static let jeans = Color(red: 0.114, green: 0.247, blue: 0.733)     // #1D3FBB

    /// Akzent für Knöpfe, Chips, aktive Reiter. Im Dunkelmodus eine hellere Koralle —
    /// die volle ist auf Schwarz zu dunkel für kleine Schrift.
    static let akzent = Color(uiColor: UIColor { eigenschaften in
        eigenschaften.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 0.416, blue: 0.584, alpha: 1)  // #FF6A95
            : UIColor(red: 1.0, green: 0.239, blue: 0.467, alpha: 1)
    })

    /// Der Name — bewusst nicht übersetzt.
    static let name = "Pocket Album"
}
