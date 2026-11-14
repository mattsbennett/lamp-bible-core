import Foundation
import GRDB
import LampModuleKit
import Testing
@testable import LampCore

struct LampBookGenreTests {
    private let catalog = [
        LampBookGenre(id: "first-principles", name: "First Principles", groupID: "faith", groupName: "Bible and Faith", sortOrder: 0),
        LampBookGenre(id: "exposition", name: "Bible Exposition", groupID: "faith", groupName: "Bible and Faith", sortOrder: 1),
        LampBookGenre(id: "history", name: "History", groupID: "wider", groupName: "Wider Reading", sortOrder: 2),
    ]

    @Test func booksFileUnderTheirGenresInCatalogOrder() {
        let books: [(title: String, genre: String?)] = [
            ("Sapiens", "history"), ("Elpis Israel", "first-principles"), ("Old Book", nil),
            ("Eureka", "exposition"), ("Mystery", "unknown-genre"), ("Christendom Astray", "first-principles"),
        ]
        let sections = LampBookGenre.grouped(books, genre: \.genre, catalog: catalog)
        #expect(sections.map(\.title) == ["First Principles", "Bible Exposition", "History", "Other Books"])
        #expect(sections.map(\.group) == ["Bible and Faith", "Bible and Faith", "Wider Reading", nil])
        #expect(sections[0].books.map(\.title) == ["Elpis Israel", "Christendom Astray"])
        // Never hidden for want of a genre the catalog knows.
        #expect(sections.last?.books.map(\.title) == ["Old Book", "Mystery"])
        #expect(LampBookGenre.grouped(books, genre: \.genre, catalog: []).map(\.title) == ["Other Books"])
    }

    @Test func theCatalogIsReadFromTheBundleInItsOrder() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE book_genres (id TEXT, name TEXT, group_id TEXT, group_name TEXT, sort_order INTEGER)")
            try db.execute(sql: "INSERT INTO book_genres VALUES ('history', 'History', 'wider', 'Wider Reading', 1), ('first-principles', 'First Principles', 'faith', 'Bible and Faith', 0)")
        }
        #expect(try queue.read { try LampBookGenre.catalog(in: $0) }.map(\.id) == ["first-principles", "history"])
        #expect(try DatabaseQueue().read { try LampBookGenre.catalog(in: $0) }.isEmpty)
    }

    @Test func sourcesNestedUnderTheSchemasManuscriptTextsAreRead() {
        let json = #"{"nt": ["Nestle-Aland"], "annotations": [{"part": "forms", "source": "an earlier module"}]}"#
        #expect(LampTranslationSource.parsed(json) == [.init(part: .forms, source: "an earlier module")])
        #expect(LampTranslationSource.parsed(#"{"ot": ["BHS"], "nt": ["NA28"]}"#).isEmpty)
    }
}

struct TranslationStrongsFeatureTests {
    @Test func aTranslationIsMarkedTaggedOnlyWhereItDeclaresIt() async throws {
        #expect(LampInstalledModule.declaresStrongs(#"{"strongs": true, "morphology": false}"#))
        #expect(!LampInstalledModule.declaresStrongs(#"{"strongs": false}"#))
        #expect(!LampInstalledModule.declaresStrongs(nil))

        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-feature-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let library = LampLibrary(rootURL: fixture.appendingPathComponent("Library"))
        for (id, strongs) in [("T", true), ("U", false)] {
            let moduleURL = fixture.appendingPathComponent("\(id).lamp")
            let meta: String = #"{"schemaVersion": "1.0", "id": "\#(id)", "type": "translation", "name": "Test \#(id)", "abbreviation": "\#(id)", "language": "en", "features": {"strongs": \#(strongs)}}"#
            let books: String = #"[{"id": "John", "name": "John", "number": 43, "testament": "NT", "chapters": [{"chapter": 1, "verses": [{"v": 1, "content": {"text": "In the beginning"}}]}]}]"#
            let document: String = #"{"meta": \#(meta), "books": \#(books)}"#
            _ = try LampModuleCompiler().compile(data: Data(document.utf8), sourceFilename: "\(id).json", destinationURL: moduleURL)
            _ = try await library.install(from: moduleURL)
        }
        let modules = try await library.installedModules()
        #expect(modules.first { $0.id == "T" }?.tagsStrongs == true)
        #expect(modules.first { $0.id == "U" }?.tagsStrongs == false)
    }

    @Test func aTranslationHoldsTheWholeBibleOnlyWithEveryBook() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-whole-bible-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let library = LampLibrary(rootURL: fixture.appendingPathComponent("Library"))
        // One without Nehemiah, as the Septuagint is, and one with all 66.
        for (id, numbers) in [("Whole", Array(1...66)), ("Part", Array(1...66).filter { $0 != 16 })] {
            let moduleURL = fixture.appendingPathComponent("\(id).lamp")
            let meta: String = #"{"schemaVersion": "1.0", "id": "\#(id)", "type": "translation", "name": "Test \#(id)", "abbreviation": "\#(id)", "language": "en"}"#
            let books = numbers.map { number -> String in
                let book = LampCanonicalBooks.book(number)!
                return #"{"id": "\#(book.osisID)", "name": "\#(book.name)", "number": \#(number), "testament": "\#(book.testament)", "chapters": [{"chapter": 1, "verses": [{"v": 1, "content": {"text": "Text"}}]}]}"#
            }.joined(separator: ", ")
            let document: String = #"{"meta": \#(meta), "books": [\#(books)]}"#
            _ = try LampModuleCompiler().compile(data: Data(document.utf8), sourceFilename: "\(id).json", destinationURL: moduleURL)
            _ = try await library.install(from: moduleURL)
        }
        let modules = try await library.installedModules()
        #expect(modules.first { $0.id == "Whole" }?.holdsWholeBible == true)
        #expect(modules.first { $0.id == "Part" }?.holdsWholeBible == false)
        #expect(modules.first { $0.id == "Part" }?.coveredBooks.count == 65)
        #expect(modules.first { $0.id == "Part" }?.coveredBooks[43] == 1)
        #expect(modules.first { $0.id == "Part" }?.coveredBooks[16] == nil)
    }

    @Test func coverageReadsTheBundlesLayoutByTranslation() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE translation_books (translation_id TEXT, book_number INTEGER, book_id TEXT, name TEXT, testament TEXT, chapter_count INTEGER)")
            try db.execute(sql: "INSERT INTO translation_books VALUES ('NT', 40, 'Matt', 'Matthew', 'NT', 28), ('NT', 66, 'Rev', 'Revelation', 'NT', 22), ('OT', 1, 'Gen', 'Genesis', 'OT', 50)")
            // The bundle's canonical book list, beside it, counts no chapters.
            try db.execute(sql: "CREATE TABLE books (id INTEGER, genre TEXT, name TEXT, osis_id TEXT, osis_paratext_abbreviation TEXT, testament TEXT)")
            try db.execute(sql: "INSERT INTO books VALUES (1, 'law', 'Genesis', 'Gen', 'GEN', 'OT')")
        }
        let (nt, missing, all) = try queue.read { db in
            (
                try LampTranslationCoverage.chapterCounts(in: db, translationID: "NT"),
                try LampTranslationCoverage.chapterCounts(in: db, translationID: "Missing"),
                try LampTranslationCoverage.chapterCountsByTranslation(in: db)
            )
        }
        #expect(nt == [40: 28, 66: 22])
        #expect(missing.isEmpty)
        #expect(all == ["NT": [40: 28, 66: 22], "OT": [1: 50]])
        let empty = try DatabaseQueue().read { try LampTranslationCoverage.chapterCounts(in: $0, translationID: "NT") }
        #expect(empty.isEmpty)
        // Asked of the bundle without a translation, the canonical list is
        // not mistaken for one's books.
        let unnamed = try queue.read { try LampTranslationCoverage.chapterCounts(in: $0, translationID: nil) }
        #expect(unnamed.isEmpty)
    }
}
