import SwiftUI

/// Der Reiter „Entdecken“ (bis September 2026 „Orte“). Drei Zustände:
/// Suchzeile + Orts-Treffer (während man tippt), Startseite (keine Auswahl: Zuletzt
/// gesucht, Personen, Orte, Jahre), Ergebnis (Filterleiste, Chips, Raster). Jeder
/// Einstieg führt zu derselben ``PhoneSuchAuswahl``; das Land ist keine Pflicht mehr.
/// Der Zustand liegt in ``PhoneOrtsModell``, das `PhoneRootView` hält.
struct PhoneEntdeckenView: View {

    @Bindable var modell: PhoneOrtsModell
    let apiClient: ImmichAPIClient

    @Environment(ConnectionManager.self) private var connection
    @AppStorage(PhoneOrtsUebersicht.aufgeklapptSchluessel) private var alleLaender = false

    private var istOffline: Bool { connection.state.isOffline }

    private let spalten = PhoneRasterSpalten.kacheln

    var body: some View {
        NavigationStack {
            Group {
                if !modell.suchtext.isEmpty {
                    trefferListe
                } else if modell.auswahl.istLeer {
                    startseite
                } else {
                    ergebnis
                }
            }
            .navigationTitle(PhoneOrtsTexts.titel)
            .navigationBarTitleDisplayMode(.inline)
            // Immer sichtbar: Die Suche ist hier der Haupteinstieg. Mit der
            // Voreinstellung klappte iOS das Feld beim Scrollen weg.
            .searchable(
                text: $modell.suchtext,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text(PhoneOrtsTexts.suchPrompt)
            )
            .onSubmit(of: .search) { sucheText() }
        }
        // Reagiert auch auf `istOffline`, nicht nur auf die Basis-URL: Sonst
        // bliebe ein Kaltstart offline ohne Katalog beim späteren
        // Online-Wechsel stehen — `apiClient.baseURL` ändert sich dabei nicht,
        // `canBrowse` bleibt wahr, also baut `PhoneRootView` die `TabView`
        // nicht neu, und dieser `.task` würde ohne die Ergänzung nie erneut
        // laufen (Befund aus der Review).
        .task(id: erscheintID) {
            let connection = connection
            modell.darf = { connection.keyRechte.darf($0) }
            modell.merkeAbgelehnt = { connection.merkeAbgelehnt($0) }
            await modell.erscheint(apiClient: apiClient, offline: istOffline)
            guard !istOffline else { return }
            await modell.ladeEinstiege(
                apiClient: apiClient,
                personenErlaubt: connection.keyRechte.darf("person.read")
            )
        }
    }

    private var erscheintID: String {
        "\(apiClient.baseURL.absoluteString)#\(istOffline)"
    }

    private func waehle(_ neu: PhoneSuchAuswahl) {
        Task { await modell.waehle(neu, apiClient: apiClient) }
    }

    private func sucheText() {
        let text = modell.suchtext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !istOffline else { return }
        Task { await modell.suche(text, apiClient: apiClient) }
    }

    private func waehlePerson(_ person: Person) {
        modell.uebernimmNamen([person.id: person.name])
        waehle(.person(person.id))
    }

    // MARK: - Trefferliste

    /// Während man tippt: oben „Suchen nach …“ (Personen, Jahre, Zeiträume, Orte und
    /// Bildsuche per `PhoneSuchZerlegung`), darunter die Orts-Treffer aus dem Katalog.
    @ViewBuilder private var trefferListe: some View {
        let treffer = modell.treffer
        List {
            Button(action: sucheText) {
                Label(PhoneOrtsTexts.suchenNach(modell.suchtext), systemImage: "magnifyingglass")
            }
            .disabled(istOffline)
            ForEach(treffer) { eintrag in
                Button {
                    waehle(eintrag.auswahl)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(eintrag.art == .land ? Laendernamen.anzeigename(fuer: eintrag.name, sprache: .current) : eintrag.name)
                        Text(PhoneOrtsTexts.trefferArt(eintrag.art, land: eintrag.land))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(istOffline)
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Startseite

    private var startseite: some View {
        ScrollView {
            if istOffline {
                offlineHinweis
            }
            VStack(alignment: .leading, spacing: 18) {
                zuletztAbschnitt
                personenAbschnitt
                if modell.katalog?.laender.isEmpty == false {
                    VStack(alignment: .leading, spacing: 2) {
                        abschnittsKopf(PhoneOrtsTexts.orte)
                        Text(PhoneOrtsTexts.nurMitOrt)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                    }
                }
                orteAbschnitt
                jahreAbschnitt
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .refreshable {
            guard !istOffline else { return }
            async let katalogNeu: Void = modell.aktualisieren(apiClient: apiClient)
            async let einstiegeNeu: Void = modell.ladeEinstiege(
                apiClient: apiClient, personenErlaubt: connection.keyRechte.darf("person.read"))
            _ = await (katalogNeu, einstiegeNeu)
        }
    }

    private func abschnittsKopf(_ titel: String) -> some View {
        Text(titel)
            .font(.title3.weight(.bold))
            .padding(.horizontal, 14)
    }

    @ViewBuilder private var zuletztAbschnitt: some View {
        if !modell.zuletzt.isEmpty {
            abschnittsKopf(PhoneOrtsTexts.zuletzt)
            VStack(spacing: 6) {
                ForEach(modell.zuletzt) { eintrag in
                    Button {
                        modell.uebernimmNamen(eintrag.personenNamen)
                        waehle(eintrag.auswahl)
                    } label: {
                        HStack {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                            Text(eintrag.titel).lineLimit(1).minimumScaleFactor(0.8)
                            Spacer()
                            if let anzahl = eintrag.anzahl {
                                Text(anzahl.formatted())
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(.quaternary, in: .rect(cornerRadius: 12))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(istOffline)
                    .contextMenu {
                        Button(PhoneOrtsTexts.entfernen, systemImage: "trash", role: .destructive) {
                            modell.entferneZuletzt(eintrag.auswahl, basis: apiClient.baseURL.absoluteString)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
        }
    }

    @ViewBuilder private var personenAbschnitt: some View {
        if !modell.personen.isEmpty {
            HStack {
                abschnittsKopf(PhoneOrtsTexts.personen)
                Spacer()
                NavigationLink(PhoneOrtsTexts.alle) {
                    PhonePersonenListe(personen: modell.allePersonen, apiClient: apiClient, tippen: waehlePerson)
                }
                .font(.subheadline)
                .padding(.trailing, 14)
            }
            PhonePersonenReihe(personen: modell.personen, apiClient: apiClient, tippen: waehlePerson)
                .disabled(istOffline)
        }
    }

    @ViewBuilder private var jahreAbschnitt: some View {
        if !modell.jahre.isEmpty {
            abschnittsKopf(PhoneOrtsTexts.jahre)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(modell.jahre, id: \.self) { jahr in
                        PhoneChip(titel: String(jahr), anzahl: nil, aktiv: false) { waehle(.jahr(jahr)) }
                    }
                }
                .padding(.horizontal, 14)
            }
            .disabled(istOffline)
        }
    }

    // MARK: - Orte

    @ViewBuilder private var orteAbschnitt: some View {
        if let katalog = modell.katalog, !katalog.laender.isEmpty {
            let laender = katalog.nachZuletzt
            let teile = PhoneOrtsUebersicht.aufteilen(laender)
            VStack(alignment: .leading, spacing: 0) {
                LazyVGrid(columns: spalten, spacing: 16) {
                    ForEach(teile.kacheln) { land in
                        Button { waehle(.land(land.name)) } label: {
                            PhoneLandKachel(land: land)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .disabled(istOffline)
                .opacity(istOffline ? 0.5 : 1)

                if !teile.rest.isEmpty {
                    DisclosureGroup(isExpanded: $alleLaender) {
                        VStack(spacing: 0) {
                            ForEach(teile.rest) { land in
                                Button { waehle(.land(land.name)) } label: {
                                    landZeile(land)
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                        }
                        .disabled(istOffline)
                        .opacity(istOffline ? 0.5 : 1)
                    } label: {
                        Text(PhoneOrtsTexts.alleLaender(laender.count))
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(14)
                }
            }
        } else if istOffline {
            ContentUnavailableView(PhoneOrtsTexts.offline, systemImage: "airplane", description: Text(PhoneOrtsTexts.offlineText))
        } else if let fehler = modell.aufbauFehler {
            ContentUnavailableView {
                Label(PhoneOrtsTexts.nichtVerfuegbar, systemImage: "wifi.slash")
            } description: {
                Text(fehler)
            } actions: {
                Button(PhoneOrtsTexts.erneut) {
                    Task { await modell.aktualisieren(apiClient: apiClient) }
                }
                .buttonStyle(.borderedProminent)
            }
        } else if modell.katalog != nil && !modell.baut {
            // „Keine Orte" braucht einen Weg zurück: Ohne Aktion hier bliebe der
            // Reiter stehen, bis Serverdaten sich sonst wie ändern (Befund aus
            // der Review — Spec: „Kein Tap führt in ein leeres Raster.").
            ContentUnavailableView {
                Label(PhoneOrtsTexts.keineOrte, systemImage: "map")
            } description: {
                Text(PhoneOrtsTexts.keineOrteText)
            } actions: {
                Button(PhoneOrtsTexts.erneut) {
                    Task { await modell.aktualisieren(apiClient: apiClient) }
                }
                .buttonStyle(.borderedProminent)
            }
        } else if modell.baut {
            // Der Spinner darf nur zeigen, wenn wirklich ein Aufbau läuft —
            // sonst bliebe er ein Leerlauf-Zustand ohne jede Handlung.
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text(PhoneOrtsTexts.ladeKatalog)
            }
        } else {
            // Online, kein Katalog, kein Fehler, kein laufender Aufbau: Das
            // tritt auf, wenn die App offline ohne Katalog startete und der
            // Server erst danach erreichbar wurde — `.task(id:)` oben fängt
            // den Übergang zwar jetzt schon ab, aber diese Stelle ist die
            // zweite Absicherung dagegen (Review-Vorgabe „statt eines
            // Leerlauf-Spinners den Aufbau selbst anstoßen"). Kein sichtbarer
            // Spinner hier — sobald `aktualisieren` `baut` setzt, übernimmt
            // der Zweig darüber.
            Color.clear
                .task {
                    await modell.aktualisieren(apiClient: apiClient)
                }
        }
    }

    /// Spec, „Fehlerfälle": Offline bleibt der gespeicherte Katalog sichtbar, und
    /// eine Hinweiszeile sagt, warum die Kacheln grau sind. Symbol und Zurückhaltung
    /// wie die Zustandszeile in den Einstellungen (`PhoneServerStatus`).
    private var offlineHinweis: some View {
        Label {
            Text(PhoneOrtsTexts.offlineHinweis)
        } icon: {
            Image(systemName: PhoneServerStatus.from(.offline).symbol)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private func landZeile(_ land: PhoneOrtsLand) -> some View {
        HStack {
            Text(Laendernamen.anzeigename(fuer: land.name, sprache: .current))
            Spacer()
            Text(PhoneOrtsTexts.landUntertitel(land))
                .font(.caption)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    // MARK: - Ergebnis

    private var ergebnis: some View {
        ScrollView {
            if istOffline {
                offlineHinweis
            }
            chipReihen
            PhoneFeedRaster(feed: modell.feed, apiClient: apiClient, istOffline: istOffline)
            if modell.feed.abschnitte.isEmpty {
                rasterLeer
                    .padding(.top, 40)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
            PhoneOrtsFilterLeiste(
                auswahl: modell.auswahl,
                personenNamen: modell.personenNamen,
                treffer: modell.facetten.treffer,
                istOffline: istOffline,
                entfernen: waehle
            )
            if modell.feed.bildsucheAmLimit {
                Text(PhoneOrtsTexts.bildsucheGrenze)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(.bar)
            }
            }
        }
        // „Zuletzt gesucht“: erst nach einer Weile merken — damit die Trefferzahl da
        // ist und ein schnelles Durchtippen nicht fünf Zwischenstände speichert.
        .task(id: modell.auswahl) {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, !istOffline else { return }
            modell.merkeZuletzt(
                titel: PhoneOrtsTexts.beschriftung(fuer: modell.auswahl, namen: modell.personenNamen),
                basis: apiClient.baseURL.absoluteString
            )
        }
        .refreshable {
            guard !istOffline else { return }
            // Spec: „Ziehen zum Aktualisieren im Raster erzwingt den Lauf." —
            // das galt bisher nur für den Feed, nicht für den Katalog (Befund
            // aus der Review). Beide nebenläufig, `async let` statt
            // nacheinander: Sie sind unabhängig voneinander.
            async let feedNeu: Void = modell.feed.ladeVonVorne(apiClient: apiClient)
            async let katalogNeu: Void = modell.aktualisieren(apiClient: apiClient)
            _ = await (feedNeu, katalogNeu)
        }
    }

    @ViewBuilder private var chipReihen: some View {
        let facetten = modell.facetten
        let auswahl = modell.auswahl
        VStack(alignment: .leading, spacing: 12) {
            if !facetten.staedte.isEmpty || facetten.staedteLaden {
                PhoneChipReihe(
                    titel: PhoneOrtsTexts.staedte,
                    chips: facetten.staedte,
                    ausgewaehlt: Set([auswahl.stadt].compactMap { $0 }),
                    laedt: facetten.staedteLaden
                ) { chip in
                    // Nicht `auswahl.mitStadt(…)` von oben: Das ist der Stand beim
                    // Zeichnen, und ein schneller zweiter Tipp überschriebe den ersten.
                    Task { await modell.tippeStadt(chip, apiClient: apiClient) }
                }
            }
            if !facetten.jahre.isEmpty || facetten.jahreLaden {
                PhoneChipReihe(
                    titel: PhoneOrtsTexts.jahre,
                    chips: facetten.jahre,
                    ausgewaehlt: Set([auswahl.jahr].compactMap { $0 }.map(String.init)),
                    laedt: facetten.jahreLaden
                ) { chip in
                    Task { await modell.tippeJahr(chip, apiClient: apiClient) }
                }
            }
            personenReihe
        }
        .padding(.vertical, 10)
        .disabled(istOffline)
    }

    @ViewBuilder private var personenReihe: some View {
        switch modell.facetten.personen {
        case .keine:
            EmptyView()
        case .laedt:
            PhoneChipReihe(titel: PhoneOrtsTexts.personen, chips: [], ausgewaehlt: [], laedt: true) { _ in }
        case .aufAnfrage(let megabyte):
            VStack(alignment: .leading, spacing: 6) {
                Text(PhoneOrtsTexts.personen)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                PhoneChip(titel: PhoneOrtsTexts.personenErmitteln(megabyte: megabyte), anzahl: nil, aktiv: false) {
                    modell.personenErmitteln(apiClient: apiClient)
                }
            }
            .padding(.horizontal, 14)
        case .bereit(let chips):
            if !chips.isEmpty {
                PhoneChipReihe(titel: PhoneOrtsTexts.personen, chips: chips, ausgewaehlt: Set(modell.auswahl.personen)) { chip in
                    Task { await modell.tippePerson(chip, apiClient: apiClient) }
                }
            }
        case .fehler(let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
        }
    }

    @ViewBuilder private var rasterLeer: some View {
        if istOffline {
            ContentUnavailableView(PhoneOrtsTexts.offline, systemImage: "airplane", description: Text(PhoneOrtsTexts.offlineText))
        } else if let fehler = modell.feed.fehler {
            ContentUnavailableView {
                Label(PhoneOrtsTexts.nichtVerfuegbar, systemImage: "wifi.slash")
            } description: {
                Text(fehler)
            } actions: {
                Button(PhoneOrtsTexts.erneut) {
                    Task { await modell.feed.ladeVonVorne(apiClient: apiClient) }
                }
                .buttonStyle(.borderedProminent)
            }
        } else if modell.feed.hatJeGeladen && !modell.feed.laedt {
            ContentUnavailableView(PhoneOrtsTexts.keineFotos, systemImage: "photo.on.rectangle", description: Text(PhoneOrtsTexts.keineFotosText))
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
        }
    }
}
