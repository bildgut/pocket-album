import Foundation

/// Ein `AsyncStream` über eine KVO-beobachtbare Eigenschaft.
///
/// **Warum es das gibt: `publisher(for:).values` verliert Werte.** Genau so
/// stand es bis hierher zweimal in ``PhoneVideoPlayer`` — und beide Male kam
/// **nur der allererste Wert** an, danach nie wieder einer. Der sichtbare
/// Schaden war der Pausenknopf auf der Zweitbildschirm-Bedienung: Er merkte
/// sich beim Abonnieren „läuft", blieb dabei, und ein zweiter Tipp rief
/// deshalb wieder `pause()` statt `play()`. Für den Nutzer sah das so aus, als
/// ließe sich Pause nicht zurücknehmen.
///
/// Die Ursache ist die Kombination aus Combines KVO-Herausgeber und
/// `AsyncPublisher`: Der `for await`-Verbraucher fordert immer nur **einen**
/// Wert an; sobald diese Nachfrage vom ersten Wert (mit `.initial` also
/// sofort) aufgebraucht ist, meldet der KVO-Herausgeber nichts mehr nach.
/// Belegt ist das, nicht vermutet — `PhoneKVOStromTests` stellt beide Wege
/// nebeneinander an denselben laufenden `AVPlayer`:
/// `NSKeyValueObservation` und ein Combine-`sink` sahen alle vier Wechsel
/// (`[0, 2, 0, 2]`), `.values` genau einen (`[0]`).
///
/// **Warum ein `AsyncStream` und nicht einfach die Beobachtung selbst.** Die
/// beiden Aufrufstellen sind abbrechbare `Task`s, die `PhoneVideoPlayer` in
/// `beende()` gemeinsam mit dem Player wegräumt. Eine `NSKeyValueObservation`
/// in einem `@State` bräuchte dort ein zweites Aufräumen mit eigener
/// Reihenfolge; so bleibt es bei „Task abbrechen" — `onTermination` löst die
/// Beobachtung dann von selbst.
enum PhoneKVOStrom {

    /// Die Werte von `pfad`, beginnend mit dem aktuellen.
    ///
    /// - Parameter pfad: Muss auf eine KVO-fähige Eigenschaft zeigen; für
    ///   Swift-Schlüsselpfade auf importierte ObjC-Eigenschaften (etwa
    ///   `\AVPlayer.timeControlStatus`) ist das gegeben.
    ///
    /// `.bufferingNewest(8)` statt `.unbounded`: Die beobachteten
    /// Eigenschaften wechseln ein paar Mal je Wiedergabe, nicht ein paar
    /// tausend Mal — acht Plätze kann kein Verbraucher überlaufen lassen, und
    /// eine unbegrenzte Warteschlange wüchse im Fehlerfall still weiter.
    static func werte<Objekt: NSObject, Wert>(
        von objekt: Objekt,
        _ pfad: KeyPath<Objekt, Wert>
    ) -> AsyncStream<Wert> {
        AsyncStream(Wert.self, bufferingPolicy: .bufferingNewest(8)) { fortsetzung in
            // **Der Wert wird am Objekt gelesen, nicht aus `aenderung.newValue`
            // genommen** — und das ist keine Bequemlichkeit. `newValue` ist
            // `change[.newKey] as? Wert`; KVO legt dort eine `NSNumber` ab, und
            // die lässt sich nicht in einen aus ObjC importierten Aufzählungstyp
            // wie `AVPlayer.TimeControlStatus` umschreiben. `newValue` ist für
            // genau diese Eigenschaften **immer `nil`** — mit `guard let` davor
            // käme nie ein Wert an, und der Strom wäre so still wie der Weg, den
            // er ersetzt. Im Testlauf gemessen, nicht vermutet.
            //
            // Gelesen wird auf dem Thread, der die Eigenschaft gesetzt hat (bei
            // `AVPlayer` eine interne Warteschlange). Der gelesene Wert kann
            // damit schon der nächste sein — für einen Zustand, bei dem nur der
            // jeweils letzte zählt, ist das richtig herum.
            let beobachtung = objekt.observe(pfad, options: [.initial, .new]) { objekt, _ in
                fortsetzung.yield(objekt[keyPath: pfad])
            }
            // Läuft auch beim Abbrechen des verbrauchenden `Task`s — das ist
            // der ganze Grund für die Verpackung.
            fortsetzung.onTermination = { _ in
                beobachtung.invalidate()
            }
        }
    }
}
