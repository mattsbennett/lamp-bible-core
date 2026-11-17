import Foundation
import GRDB
import LampModuleKit
import Testing
@testable import LampCore

/// A library reading translations under either of their IDs, while a bundle,
/// an import and saved data each may use the other.
struct LampTranslationRenameTests {
    private func translation(id: String, abbreviation: String, text: String) -> String {
        #"""
        {"meta":{"schemaVersion":"1.0","id":"\#(id)","type":"translation","name":"\#(abbreviation) Test","abbreviation":"\#(abbreviation)","language":"en","versification":"eng"},
         "books":[{"id":"John","name":"John","number":43,"testament":"NT","chapters":[{"chapter":1,"verses":[
           {"v":1,"content":{"text":"\#(text)"}}
         ]}]}]}
        """#
    }

    private func library(installing modules: [(id: String, text: String)]) async throws -> (LampLibrary, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lamp-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        for module in modules {
            let archive = root.appendingPathComponent("\(module.id).lamp")
            _ = try LampModuleCompiler().compile(
                data: Data(translation(id: module.id, abbreviation: "ESV", text: module.text).utf8),
                sourceFilename: "\(module.id).json", destinationURL: archive
            )
            _ = try await library.install(from: archive)
        }
        return (library, root)
    }

    /// An import made before the rename is read by the ID the apps now use,
    /// and answers to the ID it was asked by.
    @Test func aTranslationImportedBeforeTheRenameIsReadByItsNewID() async throws {
        let (library, root) = try await library(installing: [("ESVs", "In the beginning was the Word")])
        defer { try? FileManager.default.removeItem(at: root) }

        let chapter = try await library.chapter(moduleID: "ESV", bookNumber: 43, chapterNumber: 1)
        #expect(chapter.translationID == "ESV")
        #expect(chapter.verses.first?.text == "In the beginning was the Word")
        #expect(try await library.translationBooks(moduleID: "ESV").map(\.id) == [43])
        let found = try await library.searchTranslations(query: "beginning", moduleIDs: ["ESV"])
        #expect(found.map(\.translationID) == ["ESVs"])
    }

    /// Both spellings installed are two modules: each is read as itself.
    @Test func bothSpellingsInstalledAreNeverMerged() async throws {
        let (library, root) = try await library(installing: [("ESVs", "the old import"), ("ESV", "the new import")])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try await library.chapter(moduleID: "ESVs", bookNumber: 43, chapterNumber: 1).verses.first?.text
            == "the old import")
        #expect(try await library.chapter(moduleID: "ESV", bookNumber: 43, chapterNumber: 1).verses.first?.text
            == "the new import")
        #expect(try await library.installedModules().filter { $0.kind == .translation }.map(\.id).sorted()
            == ["ESV", "ESVs"])
    }

    /// A translation's default highlight set is named, and records it, by its
    /// first ID, whichever ID it was highlighted under; it is found under
    /// either.
    @Test func highlightsKeepTheFirstIDAndAreFoundUnderEither() async throws {
        let (library, root) = try await library(installing: [])
        defer { try? FileManager.default.removeItem(at: root) }

        let saved = try await library.saveVerseHighlight(
            translationID: "BSB", reference: 43_001_001, startOffset: 0, endOffset: 4
        )
        #expect(saved.setID == "personal-highlights:BSBs")
        #expect(try await library.highlightSets().map(\.translationID) == ["BSBs"])
        #expect(try await library.verseHighlights(translationID: "BSB", reference: 43_001_001).count == 1)
        #expect(try await library.verseHighlights(translationID: "BSBs", reference: 43_001_001).count == 1)
        #expect(try await library.highlightSets(translationID: "BSB").count == 1)

        // Highlighted again under the other ID, it is the same set.
        let again = try await library.saveVerseHighlight(
            translationID: "BSBs", reference: 43_001_002, startOffset: 0, endOffset: 4
        )
        #expect(again.setID == saved.setID)
        #expect(try await library.highlightSets().count == 1)
        #expect(LampLibrary.canonicalHighlightSetID("personal-highlights-BSB", translationID: "BSB")
            == "personal-highlights:BSBs")
    }

    /// A translation hidden before it was renamed stays hidden after; with
    /// both installed, only the one hidden is.
    @Test func aHiddenTranslationStaysHiddenUnderItsNewID() {
        let renamed = LampModuleSelection.visible(["BSB", "NASB"], hiddenIDs: ["BSBs"], id: { $0 })
        #expect(renamed == ["NASB"])
        let both = LampModuleSelection.visible(["BSBs", "BSB", "NASB"], hiddenIDs: ["BSBs"], id: { $0 })
        #expect(both.sorted() == ["BSB", "NASB"])
    }

    /// Access given to a translation under one of its IDs holds under the
    /// other.
    @Test func accessGivenBeforeTheRenameHoldsAfter() {
        let policy = LampAgentAccessPolicy(allowedModuleIDs: ["KJVs"])
        #expect(policy.allows(moduleID: "KJV"))
        #expect(policy.allows(moduleID: "KJVs"))
        #expect(!policy.allows(moduleID: "BSB"))
    }

    /// A bundle built with either spelling lists its books under the ID asked.
    @Test func aBundlesBooksAreFoundUnderEitherID() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE translation_books (translation_id TEXT, book_number INTEGER, book_id TEXT, name TEXT, chapter_count INTEGER);
                INSERT INTO translation_books VALUES ('KJVs', 43, 'John', 'John', 21);
                """)
        }
        let found = try queue.read { db in
            (try LampTranslationCoverage.chapterCounts(in: db, translationID: "KJV"),
             try LampTranslationCoverage.chapterCounts(in: db, translationID: "KJVs"),
             try LampTranslationCoverage.bookNames(in: db, translationID: "KJV"))
        }
        #expect(found.0 == [43: 21])
        #expect(found.1 == [43: 21])
        #expect(found.2 == [43: "John"])
    }
}
