import Foundation

/// Der Wortlaut, mit dem gemessen wurde. Jede Änderung hier macht die Zahlen in
/// der Spezifikation ungültig: erst `promptVersion` erhöhen, dann
/// `scripts/infobilder/auswerten.py` neu laufen lassen.
enum InfoBildPrompt {

    static let promptVersion = 1
    static let filterVersion = 1

    static let stufeA = """
    You sort photos from a personal photo library. Decide which single category fits the image best:
    foto = a real photograph the owner took as a memory: people, places, events, animals, rooms, objects, food, dishes, drinks, ingredients, cooking, products and packaging, book covers, shop fronts, street signs;
    screenshot = screen capture of a phone or computer UI, app, chat or website, or a photo of such a screen;
    dokument = the main content is readable text or a card: receipt, ticket, invoice, letter, contract, form, certificate, handwritten note, whiteboard, poster, flyer, timetable, restaurant menu, recipe page, passport, ID card, bank card, book or newspaper page.
    Old scanned family prints are foto. When in doubt, choose foto.
    """

    static let stufeB = """
    The image shows a document. Decide which single kind it is:
    beleg = receipt, invoice, bill, ticket, boarding pass, voucher, price tag;
    notiz = note taken to remember something: whiteboard, flipchart, sticky note, handwritten list, meter reading, serial number or type plate;
    information = poster, flyer, timetable, map, information board, opening hours, instructions or manual page;
    rezept = recipe (cookbook page, recipe card, handwritten recipe) or restaurant or bar menu, drink list;
    ausweis = identity document: passport, ID card, student or company ID, driver's license, residence permit, health insurance card, bank card, visa;
    sonstiges = any other document: letter, contract, form, certificate, greeting card, book or e-reader page, newspaper.
    """

    /// Etiketten von Apples Bildklassifikation, die ein Bild an das Modell
    /// weiterreichen. Gemessen: 190 von 198 bekannten Dokumenten passieren,
    /// aber nur 12 % beliebiger Fotos.
    static let vorfilterEtiketten: Set<String> = [
        "document", "receipt", "screenshot", "printed_page", "handwriting", "sticky_note",
        "ticket", "passport", "book", "chart", "envelope", "currency", "money", "blackboard",
        "whiteboard", "poster", "sign", "menu", "map", "calendar",
    ]

    static let mindestKonfidenz: Float = 0.05
    static let mindestZeichen = 5
}
