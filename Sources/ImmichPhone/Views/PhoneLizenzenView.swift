import SwiftUI

/// „Open-Source-Lizenzen“ in den Einstellungen.
///
/// Nuke steht unter MIT, und MIT verlangt Copyright- und Lizenzhinweis in jeder
/// ausgelieferten Kopie. Der Text ist wörtlich die `LICENSE` aus dem
/// Paket-Checkout (Nuke 12.x) — als String statt als Bundle-Ressource, damit
/// `project.yml` unberührt bleibt. Bei einem Nuke-Update mit neuem
/// Copyright-Jahr hier nachziehen. Der Lizenztext selbst wird nicht übersetzt.
struct PhoneLizenzenView: View {
    static let titel = String(localized: "Open Source Licenses")

    struct Eintrag: Identifiable {
        let name: String
        let lizenz: String
        var id: String { name }
    }

    static let eintraege: [Eintrag] = [
        Eintrag(name: "Nuke", lizenz: nukeMIT),
    ]

    var body: some View {
        List(Self.eintraege) { eintrag in
            Section(eintrag.name) {
                Text(verbatim: eintrag.lizenz)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
        }
        .navigationTitle(Self.titel)
        .navigationBarTitleDisplayMode(.inline)
    }

    static let nukeMIT = """
    The MIT License (MIT)

    Copyright (c) 2015-2024 Alexander Grebenyuk

    Permission is hereby granted, free of charge, to any person obtaining a copy \
    of this software and associated documentation files (the "Software"), to deal \
    in the Software without restriction, including without limitation the rights \
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
    copies of the Software, and to permit persons to whom the Software is \
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all \
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE \
    SOFTWARE.
    """
}
