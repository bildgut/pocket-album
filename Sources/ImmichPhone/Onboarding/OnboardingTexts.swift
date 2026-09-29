import Foundation

/// Alle Texte des Onboardings. Konstanten statt `Text`-Literale (Markdown-Falle).
enum OnboardingTexts {
    // Vorspann
    static let ueberspringen = String(localized: "Skip")
    static let weiter = String(localized: "Continue")
    static let einrichten = String(localized: "Set Up")
    static let fertigKnopf = String(localized: "Done")
    /// Der Markenname — bewusst nicht übersetzt.
    static let zeigenTitel = "Pocket Album"
    /// Unterzeile zum Namen: Ohne sie verrät die erste Seite nicht, dass die App einen
    /// Immich-Server braucht. „Immich“ ist der Name des Projekts und bleibt stehen.
    static let zeigenMarke = String(localized: "for Immich")
    static let zeigenText = String(localized: "Your favorite albums, always with you — even offline.")
    static let offlineAbzeichen = String(localized: "available offline")
    static let findenTitel = String(localized: "Find it in two taps")
    static let findenText = String(localized: "Country, year, people — tap a few chips and thousands of photos become the ones you meant.")
    static let fernseherTitel = String(localized: "Big on the TV")
    static let fernseherText = String(localized: "Start a slideshow on AirPlay — your phone becomes the remote.")
    static func fotoZahl(_ n: Int) -> String { String(localized: "\(n) photos") }

    // Server
    static let schritt1 = String(localized: "Step 1 of 2")
    static let serverTitel = String(localized: "Where’s your server?")
    static let serverText = String(localized: "The address you open Immich with in the browser.")
    static let serverPlatzhalter = "photos.example.com"
    static func serverGefunden(_ v: String) -> String { String(localized: "Immich \(v) found") }
    static let serverNichtErreichbar = String(localized: "Can’t reach this address.")
    static let serverKeinImmich = String(localized: "This doesn’t look like an Immich server.")
    static func serverZuAlt(_ v: String) -> String {
        String(localized: "Pocket Album needs Immich 3.2 or later. This server runs \(v).")
    }

    // Key
    static let schritt2 = String(localized: "Step 2 of 2")
    static let keyTitel = String(localized: "Your API key")
    static let keyText = String(localized: "Paste a key from Immich. Pocket Album checks what it’s allowed to do.")
    static let keyPlatzhalter = String(localized: "API key")
    static let einfuegen = String(localized: "Paste")
    static let verbinden = String(localized: "Connect")
    static let rechtAlben = String(localized: "Albums & photos")
    static let rechtOrte = String(localized: "Places & filters")
    static let rechtPersonen = String(localized: "People")
    static let rechtOffline = String(localized: "Offline downloads")
    static let rechtAendern = String(localized: "Favorite & delete")
    static let keyAbgelehnt = String(localized: "The server doesn’t accept this API key.")
    static let keyOhneAlben = String(localized: "This key is missing the permission album.read.")
    static let wieKey = String(localized: "How do I get a key?")
    static let stattdessenAnmelden = String(localized: "Or sign in to create one automatically")

    // Hilfe
    static let hilfeTitel = String(localized: "Create a key in Immich")
    static let hilfeSchritt1 = String(localized: "Open Immich → your avatar → Account Settings")
    static let hilfeSchritt2 = String(localized: "API Keys → New API Key")
    static let hilfeSchritt3 = String(localized: "Name it “Pocket Album”, tick these permissions:")
    static let nurAnsehen = String(localized: "View only")
    static let allesErlaubt = String(localized: "View, favorite & delete")
    static let kopieren = String(localized: "Copy")
    static let kopiert = String(localized: "Copied")
    static let immichOeffnen = String(localized: "Open Immich")

    // Anmelden
    static let anmeldenTitel = String(localized: "Sign in instead")
    static let anmeldenText = String(localized: "Pocket Album signs in once, creates its own key with exactly the permissions you chose, and forgets your password.")
    static let email = String(localized: "Email")
    static let passwort = String(localized: "Password")
    static let ssoHinweis = String(localized: "Doesn’t work with single sign-on (OAuth). Use a key instead.")
    static let anmeldenKnopf = String(localized: "Sign In & Create Key")
    static let stattdessenKey = String(localized: "Use an API key instead")
    static let falschesPasswort = String(localized: "Wrong email or password.")
    static func keyAnlageGescheitert(_ grund: String) -> String {
        String(localized: "Signed in, but the key couldn’t be created: \(grund)")
    }

    // Fertig
    static let fertigTitel = String(localized: "You’re all set")
    /// `nil`, wenn die Albumzahl fehlt — dann entfällt die Zeile ganz.
    static func fertigZahlen(alben: Int?, fotos: Int?) -> String? {
        guard let alben else { return nil }
        if let fotos { return String(localized: "\(alben) albums · \(fotos) photos") }
        return String(localized: "\(alben) albums")
    }
    static let albenOeffnen = String(localized: "Open Albums")

    // Einstellungen
    static let vorspannErneut = String(localized: "Show Intro Again")
}
