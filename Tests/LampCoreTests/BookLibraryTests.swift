import Foundation
import LampCore
import LampModuleKit
import Testing

struct BookLibraryTests {
    @Test func installsReadsAndSearchesBookModule() async throws {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-book-library-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let moduleURL = fixtureURL.appendingPathComponent("TEST_BOOK.lamp")
        _ = try LampModuleCompiler().compile(
            data: Data(#"""
            {
              "meta": {
                "schemaVersion": "1.0", "id": "TEST_BOOK", "type": "book",
                "title": "A Test Book", "subtitle": "Reading support",
                "author": "Example Author", "language": "en",
                "tags": ["study"]
              },
              "sections": [{
                "id": "part-one", "type": "part", "title": "Part One",
                "sections": [{
                  "id": "chapter-one", "type": "chapter", "number": 1,
                  "title": "Creation and Grace",
                  "keyScriptures": [{"sv": 1001001, "ev": 1001003, "label": "Genesis 1:1–3"}],
                  "content": [{
                    "type": "paragraph",
                    "content": {"text": "Light shines at the beginning of creation."}
                  }]
                }]
              }]
            }
            """#.utf8),
            sourceFilename: "TEST_BOOK.json",
            destinationURL: moduleURL
        )

        let library = LampLibrary(rootURL: fixtureURL.appendingPathComponent("Library"))
        let installed = try await library.install(from: moduleURL)
        #expect(installed.kind == .book)
        #expect(installed.name == "A Test Book")

        let books = try await library.bookModules()
        #expect(books.count == 1)
        #expect(books.first?.author == "Example Author")
        #expect(books.first?.tags == ["study"])

        let sections = try await library.bookSections(moduleID: "TEST_BOOK")
        #expect(sections.count == 2)
        #expect(sections.last?.parentID == "TEST_BOOK:part-one")
        #expect(sections.last?.content.contains("beginning of creation") == true)
        #expect(sections.last?.keyScriptures.first?.displayDescription == "Genesis 1:1–3")

        let results = try await library.searchModules(query: "shines", kinds: [.book])
        #expect(results.count == 1)
        #expect(results.first?.kind == .book)
        #expect(results.first?.title == "Creation and Grace")
        #expect(results.first?.startReference == 1_001_001)
    }
}
