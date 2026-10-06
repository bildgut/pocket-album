import SwiftUI

/// Die Rückfrage vor dem Abmelden — und die einzige Stelle, an der jemand das
/// Entfernen der offline geladenen Originale wählt.
///
/// Warum ein eigenes Blatt und kein `.alert`: Ein `.alert` trägt keinen Schalter.
/// Und warum kein `confirmationDialog`: iOS 26 zeigte den auf dem iPhone als
/// Popover mit **nur** der roten Taste; „Abbrechen" ließ es weg. Bei genau dieser
/// Aktion wäre ein Dialog, dessen einzige sichtbare Taste die zerstörerische ist,
/// das Gegenteil dessen, was die Rückfrage leisten soll.
///
/// Die Aufteilung in „fällt immer" und „fällt nur auf Ankreuzen" ist keine
/// Bequemlichkeit, sondern der Unterschied zwischen billig und teuer: Alben und
/// Fotos holt der nächste Abgleich in Sekunden zurück, die Originale kosten einen
/// erneuten Download über womöglich Gigabyte. Deshalb ist der Schalter aus und die
/// Vorgabe die schonende.
struct PhoneAbmeldeBlatt: View {

    let serverAdresse: String
    /// Vorformatiert aus ``PhoneStorageSummary/gesamtGroesse`` — dieselbe Zahl, die
    /// der Reiter darüber anzeigt.
    let offlineGroesse: String
    let offlineAnzahl: Int
    let abmelden: (Bool) -> Void
    let abbrechen: () -> Void

    @State private var auchOriginale = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(hinweis)
                        .font(.callout)
                } header: {
                    Text("What Happens")
                }

                if offlineAnzahl > 0 {
                    Section {
                        Toggle(isOn: $auchOriginale) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Remove Downloaded Originals")
                                Text(offlineZeile)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } footer: {
                        Text(offlineFusszeile)
                            .font(.caption)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        abmelden(auchOriginale)
                    } label: {
                        Text("Sign Out")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("Sign Out?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: abbrechen)
                }
            }
        }
        // `.large` und **nicht** `[.medium, .large]`.
        //
        // Befund aus der Sichtprüfung: Beim mittleren Detent lag die rote
        // „Abmelden"-Taste genau auf der Schnittkante und war zur Hälfte
        // abgeschnitten — und die `List` scrollte nicht, weil ihr Inhalt für die
        // volle Höhe passt. Die bestätigende Taste eines Rückfrage-Dialogs, die
        // man nicht sehen und nicht erreichen kann, ist derselbe Fehler wie der
        // `confirmationDialog`, der oben schon aussortiert wurde.
        .presentationDetents([.large])
    }

    /// Muss ausdrücklich sagen, **was verloren geht**: die Zugangsdaten auf diesem
    /// Gerät. `KeychainStore.deleteAll()` ist nicht rückgängig zu machen und der
    /// Grund, warum hier überhaupt gefragt wird.
    ///
    /// Der zweite Satz nennt den Cache — nicht als Warnung, sondern damit niemand
    /// die kurze Leere danach für Datenverlust hält.
    private var hinweis: String {
        String(localized: "The server address and API key for \(serverAdresse) will be removed from this device.\n\nAlbums and photos will be removed from the local cache; the app reloads them the next time you sign in.")
    }

    private var offlineZeile: String {
        String(localized: "\(offlineGroesse) · \(offlineAnzahl) albums")
    }

    /// Sagt beides: was der Schalter tut und was er kostet. Ohne den zweiten Halbsatz
    /// läse sich das Ankreuzen wie reines Aufräumen.
    private var offlineFusszeile: String {
        auchOriginale
            ? String(localized: "The files will be deleted from this device. After signing in again they must be downloaded again.")
            : String(localized: "The files stay on this device but can’t be accessed without signing in.")
    }
}
