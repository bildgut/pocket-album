import SwiftUI
import UIKit

/// Die UIKit-Seite des Zweitbildschirms: der App-Delegat, der die Szene
/// überhaupt erst zustande kommen lässt, und der Szenen-Delegat, der ihr
/// Fenster aufbaut.
///
/// **Worum es geht.** Hängt ein Apple TV per Bildschirmsynchronisierung am
/// iPhone, spiegelt iOS von sich aus den Telefonbildschirm — Hochformat mit
/// schwarzen Balken links und rechts, und das Telefon ist für die Dauer der
/// Vorführung belegt. Meldet eine App dagegen eine Szene in der Rolle
/// ``UISceneSession/Role/windowExternalDisplayNonInteractive`` an, **ersetzt**
/// deren Inhalt die Spiegelung: Der Fernseher zeigt, was diese Szene zeichnet,
/// und der Telefonbildschirm ist wieder frei für etwas anderes. Genau das ist
/// hier gebaut — Foto auf den Fernseher, Fernbedienung aufs Telefon.
///
/// **Das Manifest ist Pflicht — der Delegat allein genügt nicht.** Diese Datei
/// stand einmal ohne `UIApplicationSceneManifest` im Info.plist, in der
/// Annahme, der Delegat unten reiche aus. Er reicht nicht: Der Fernseher
/// spiegelte weiter, ``PhoneZweitbildschirmSzenenDelegat`` wurde nie
/// aufgerufen. UIKit bietet die Rolle
/// `UIWindowSceneSessionRoleExternalDisplayNonInteractive` erst an, wenn sie
/// im Manifest steht. Seither trägt `project.yml` sie unter
/// `info.properties` ein, mit `UISceneDelegateClassName` auf genau die Klasse
/// unten.
///
/// **Die Anwendungsrolle fehlt dort absichtlich.** Ein Manifest, das
/// `UIWindowSceneSessionRoleApplication` nur unvollständig beschriebe, legte
/// nicht den Zweitbildschirm lahm, sondern den **Hauptbildschirm** — den
/// Eintrag steuert SwiftUI selbst bei. Deshalb steht im Manifest ausschließlich
/// die Zweitbildschirmrolle, und der Delegat unten reicht für die Hauptszene
/// unverändert die Konfiguration zurück, die UIKit ohnehin gebaut hätte (Name
/// `nil`, kein eigener Delegat, SwiftUI bleibt zuständig).
///
/// **Auf diesem Rechner nicht prüfbar, am Gerät bestätigt.** Der Simulator
/// stellt keinen Zweitbildschirm her; hier belegbar ist nur, dass der
/// Hauptbildschirm mit diesem Delegaten unverändert startet. Dass die Szene
/// wirklich verbunden wird, hat der Nutzer am 06.09.2026 an einem Apple TV
/// gesehen — der Fernseher zeigte den Ruhezustand dieser Ansicht statt einer
/// Spiegelung. Genau dieser Unterschied ist der Lackmustest: Spiegelung zeigt
/// den Telefonbildschirm samt Balken, unsere Szene zeigt ihren eigenen Inhalt
/// im Querformat.
final class PhoneAppDelegat: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let konfiguration = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role
        )
        // Der einzige Eingriff. Jede andere Rolle — allen voran die Hauptszene
        // — geht unangetastet zurück; `delegateClass` bleibt dort `nil`, und
        // damit bleibt SwiftUI der Aufbau der `WindowGroup` überlassen.
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive {
            konfiguration.delegateClass = PhoneZweitbildschirmSzenenDelegat.self
        }
        return konfiguration
    }
}

/// Baut das Fenster auf dem Zweitbildschirm auf und meldet der ``PhoneBuehne``,
/// dass es ihn gibt.
///
/// Der Inhalt ist eine gewöhnliche SwiftUI-Ansicht in einem
/// `UIHostingController` — nur eben in einem Fenster, das zu einer anderen
/// Szene gehört. Sie bekommt weder `ConnectionManager` noch `ModelContainer`
/// mit: Sie zeigt ausschließlich, was in ``PhoneBuehne/bild`` liegt, und das
/// legt die Diashow dort fertig dekodiert ab (Begründung bei ``PhoneBuehne``).
final class PhoneZweitbildschirmSzenenDelegat: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let fensterSzene = scene as? UIWindowScene else { return }

        let wurzel = UIHostingController(
            rootView: PhoneZweitbildschirmView(buehne: PhoneBuehne.geteilt)
        )
        // Ohne das blitzt beim Verbinden für einen Moment Weiß auf dem
        // Fernseher auf, bevor SwiftUI zum ersten Mal gezeichnet hat.
        wurzel.view.backgroundColor = .black

        let fenster = UIWindow(windowScene: fensterSzene)
        fenster.rootViewController = wurzel
        fenster.backgroundColor = .black
        fenster.isHidden = false
        window = fenster

        Self.protokolliereGeometrie(fensterSzene: fensterSzene, fenster: fenster)
        PhoneBuehne.geteilt.szeneKam()
    }

    /// Schreibt einmal beim Verbinden auf, in welcher Auflösung diese Szene
    /// überhaupt zeichnet.
    ///
    /// **Wozu.** Der Nutzer berichtet von zackigen Kanten an geraden Linien auf
    /// dem Fernseher. Dafür gibt es zwei Erklärungen, die sich nur mit Zahlen
    /// auseinanderhalten lassen:
    ///
    /// 1. **Der Weg zum Fernseher.** AirPlay-Spiegelung kodiert den
    ///    Bildschirminhalt als Videostrom mit begrenzter Bitrate. An
    ///    kontrastreichen geraden Kanten entstehen dabei genau solche Artefakte
    ///    — daran ist von hier aus nichts zu machen.
    /// 2. **Unsere Szene zeichnet zu klein.** Dann rechnet der Fernseher hoch,
    ///    und das wäre behebbar.
    ///
    /// Unterscheiden lässt sich das an `nativeBounds` (die Pixel, die der
    /// Bildschirm tatsächlich hat) gegenüber `bounds × displayScale` (die
    /// Pixel, die wir zeichnen). Sind beide gleich groß, zeichnen wir voll
    /// auf; ist unser Wert kleiner, skaliert jemand hoch.
    ///
    /// Auslesen ohne Xcode, während ein Apple TV hängt:
    /// `log stream --predicate 'subsystem == "com.ralksta.immichmac"' --info`
    private static func protokolliereGeometrie(fensterSzene: UIWindowScene, fenster: UIWindow) {
        let bildschirm = fensterSzene.screen
        let punkte = fenster.bounds.size
        let massstab = fenster.traitCollection.displayScale
        let gezeichnet = CGSize(width: punkte.width * massstab, height: punkte.height * massstab)
        let nativ = bildschirm.nativeBounds.size
        AppLogger.app.info(
            "Zweitbildschirm-Geometrie: Fenster \(Int(punkte.width), privacy: .public)x\(Int(punkte.height), privacy: .public) pt bei displayScale \(massstab, privacy: .public), gezeichnet \(Int(gezeichnet.width), privacy: .public)x\(Int(gezeichnet.height), privacy: .public) px, Bildschirm nativ \(Int(nativ.width), privacy: .public)x\(Int(nativ.height), privacy: .public) px bei nativeScale \(bildschirm.nativeScale, privacy: .public)"
        )
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window = nil
        PhoneBuehne.geteilt.szeneGing()
    }
}
