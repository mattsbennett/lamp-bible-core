import Foundation
import GRDB
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
