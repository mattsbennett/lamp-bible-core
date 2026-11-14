import Testing
@testable import LampCore

struct LampReferenceParserTests {
    @Test(arguments: [
        "John 1:1-", "-John 1:1", "John 0:1", "John 1:0", "John 1000:1",
        "John 1:1000", "John 1:99999999999999999999", "John 1:1-1000",
        "John 1:1-2:0", "John 1:1-1000:1",
    ])
    func rejectsIncompleteOrUnrepresentableReferences(source: String) {
        #expect(throws: LampAgentError.self) { try LampReferenceParser.parse(source) }
    }

    @Test(arguments: [("Exo. 1:1", 2), ("Psa 119:176", 19), ("Eze. 1:1", 26), ("1 Sam. 1:1", 9)])
    func legacyDictionaryAbbreviationsUseTheSharedCatalog(source: String, book: Int) throws {
        #expect(try LampReferenceParser.parse(source).start.book == book)
    }
}

struct LampTranslationBookNameTests {
    private let spanish: [Int: String] = [
        1: "Génesis", 2: "Éxodo", 9: "1 Samuel", 11: "1 Reyes", 19: "Salmos",
        43: "Juan", 50: "Filipenses", 57: "Filemón", 65: "Judas", 66: "Apocalipsis",
    ]

    @Test(arguments: [
        ("Génesis 1", 1), ("genesis 1:3", 1), ("ÉXODO 20", 2), ("1 Reyes 3", 11),
        ("Salmos 23:1-4", 19), ("Juan 3:16", 43), ("Apoc 21", 66), ("Sal 23", 19),
    ])
    func aTranslationsOwnNamesNameItsBooks(source: String, book: Int) throws {
        #expect(try LampReferenceParser.parse(source, bookNames: spanish).start.book == book)
    }

    @Test func itsNamesComeBeforeTheEnglishOnes() throws {
        // "Judas" is no English name, but a translation's name wins wherever
        // the two could differ.
        #expect(try LampReferenceParser.parse("Judas 1", bookNames: spanish).start.book == 65)
        // A start two of its books share ("Fil") is left to the English names.
        #expect(LampReferenceParser.bookNumber(for: "Fil", names: spanish) == nil)
        // English still works beside the translation's names.
        #expect(try LampReferenceParser.parse("John 3:16", bookNames: spanish).start.book == 43)
        #expect(try LampReferenceParser.parse("Gen 1", bookNames: spanish).start.book == 1)
    }

    @Test func withoutATranslationsNamesOnlyEnglishIsRead() {
        #expect(LampSearchQuery("Juan 3:16").reference == nil)
        #expect(LampSearchQuery("Juan 3:16").reference(bookNames: spanish)
            == LampSearchReference(startReference: 43_003_016, endReference: 43_003_016))
        // Accents aside, an English name typed with one is still English.
        #expect(LampSearchQuery("Génesis 1").reference
            == LampSearchReference(startReference: 1_001_001, endReference: 1_001_999))
        #expect(LampSearchQuery("Juan 3:16").reference(bookNames: spanish)?.description(bookNames: spanish)
            == "Juan 3:16")
        #expect(LampBibleReferenceFormatter.describeRange(from: 43_003_016, to: 66_001_001, bookNames: spanish)
            == "Juan 3:16–Apocalipsis 1:1")
        // A book the translation doesn't name keeps the app's name.
        #expect(LampBibleReferenceFormatter.describeRange(from: 45_008_001, to: 45_008_999, bookNames: spanish)
            == "Romans 8")
        // A book's name alone is still a word to search for.
        #expect(LampSearchQuery("Juan").reference(bookNames: spanish) == nil)
    }
}
