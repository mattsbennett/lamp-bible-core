import Foundation
import GRDB
import Testing
@testable import LampCore

struct LampTranslationCoverageTests {
    @Test func bookNamesAreTheTranslationsOwn() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE translation_books (translation_id TEXT, book_number INTEGER, book_id TEXT, name TEXT, testament TEXT, chapter_count INTEGER)")
            try db.execute(sql: "INSERT INTO translation_books VALUES ('RV', 1, 'Gen', 'Génesis', 'OT', 50), ('RV', 2, 'Exod', '', 'OT', 40), ('KJV', 1, 'Gen', 'Genesis', 'OT', 50)")
            try db.execute(sql: "CREATE TABLE books (id INTEGER, name TEXT, testament TEXT)")
        }
        let (spanish, missing, unnamed) = try queue.read { db in
            (
                try LampTranslationCoverage.bookNames(in: db, translationID: "RV"),
                try LampTranslationCoverage.bookNames(in: db, translationID: "Missing"),
                // The bundle's canonical list beside it is no translation's.
                try LampTranslationCoverage.bookNames(in: db, translationID: nil)
            )
        }
        // A book listed without a name is left for the caller to name.
        #expect(spanish == [1: "Génesis"])
        #expect(missing.isEmpty)
        #expect(unnamed.isEmpty)

        let single = try DatabaseQueue()
        try single.write { db in
            try db.execute(sql: "CREATE TABLE books (id INTEGER, name TEXT, chapter_count INTEGER)")
            try db.execute(sql: "INSERT INTO books VALUES (40, 'Mateo', 28)")
        }
        #expect(try single.read { try LampTranslationCoverage.bookNames(in: $0, translationID: nil) } == [40: "Mateo"])
    }

    @Test func aPlaceLandsWhereTheTranslationHasIt() {
        let septuagint = [1: 50, 2: 40, 19: 151]
        let newTestament = [40: 28, 66: 22]
        // The place itself, at its last chapter where it numbers fewer.
        #expect(LampTranslationCoverage.landing(book: 19, chapter: 23, chapterCounts: septuagint)! == (19, 23))
        #expect(LampTranslationCoverage.landing(book: 2, chapter: 45, chapterCounts: septuagint)! == (2, 40))
        // Else the same testament's first book, at chapter 1.
        #expect(LampTranslationCoverage.landing(book: 23, chapter: 6, chapterCounts: septuagint)! == (1, 1))
        // Else the first book at all.
        #expect(LampTranslationCoverage.landing(book: 40, chapter: 5, chapterCounts: septuagint)! == (1, 1))
        #expect(LampTranslationCoverage.landing(book: 1, chapter: 3, chapterCounts: newTestament)! == (40, 1))
        #expect(LampTranslationCoverage.landing(book: 1, chapter: 3, chapterCounts: [:]) == nil)
    }

    @Test func anAlternativeIsInTheSameLanguageFirst() {
        struct Translation { let id: String; let language: String?; let books: Set<Int> }
        let candidates = [
            Translation(id: "KJV", language: "en", books: [1, 40]),
            Translation(id: "LXX", language: "grc", books: [1]),
            Translation(id: "RV", language: "es-ES", books: [1, 40]),
        ]
        func pick(_ book: Int, near language: String?) -> String? {
            LampTranslationCoverage.alternative(
                having: book, near: language, among: candidates,
                language: \.language, covers: { $0.books.contains(book) }
            )?.id
        }
        // "es" and "es-ES" are one language.
        #expect(pick(40, near: "es") == "RV")
        #expect(pick(40, near: "fr") == "KJV")
        #expect(pick(40, near: nil) == "KJV")
        #expect(pick(19, near: "en") == nil)
    }

    @Test func languagesAreNamedAsAReaderKnowsThem() {
        let english = Locale(identifier: "en_US")
        #expect(LampTranslationLanguages.name(of: "grc", locale: english) == "Greek")
        #expect(LampTranslationLanguages.name(of: "hbo", locale: english) == "Hebrew")
        #expect(LampTranslationLanguages.name(of: "grc-x-koine", locale: english) == "Greek")
        #expect(LampTranslationLanguages.name(of: "es-ES", locale: english) == "Spanish")
        #expect(LampTranslationLanguages.name(of: nil, locale: english) == nil)
        #expect(LampTranslationLanguages.name(of: " ", locale: english) == nil)
    }

    @Test(arguments: [
        ("grc", LampTranslationLanguages.StrongsSide.greek), ("el", .greek), ("Koine Greek", .greek),
        ("GREEK", .greek), ("grc-x-koine", .greek),
        ("hbo", .hebrew), ("he", .hebrew), ("heb", .hebrew), ("Hebrew", .hebrew), ("Aramaic", .hebrew),
        ("arc", .hebrew),
    ])
    func originalLanguagesSitOnTheirSideOfStrongs(declared: String, side: LampTranslationLanguages.StrongsSide) {
        #expect(LampTranslationLanguages.strongsSide(of: declared) == side)
    }

    @Test func otherLanguagesSitOnNeither() {
        for declared in ["en", "es", "English", "", nil] as [String?] {
            #expect(LampTranslationLanguages.strongsSide(of: declared) == nil)
        }
    }
}
