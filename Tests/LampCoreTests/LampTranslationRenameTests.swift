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

    /// A dictionary that happens to have the other spelling of a renamed
    /// translation's ID.
    private func installDictionary(id: String, into library: LampLibrary, at root: URL) async throws {
        let folder = root.appendingPathComponent("dictionaries", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let archive = folder.appendingPathComponent("\(id).lamp")
        _ = try LampModuleCompiler().compile(
            data: Data(#"""
            {"meta": {"schemaVersion": "2.1", "id": "\#(id)", "type": "dictionary", "name": "Lexicon"},
             "entries": [{"key": "G26", "lemma": "ἀγάπη", "senses": [{"shortDefinition": "love"}]}]}
            """#.utf8),
            sourceFilename: "\(id).json", destinationURL: archive
        )
        _ = try await library.install(from: archive)
    }

    /// A rename is a translation's: another kind of module with the other
    /// spelling is neither read nor allowed in its place.
    @Test func anotherKindWithTheOtherSpellingIsNotTheTranslation() async throws {
        let (library, root) = try await library(installing: [("ESVs", "the old import")])
        defer { try? FileManager.default.removeItem(at: root) }
        try await installDictionary(id: "ESV", into: library, at: root)

        #expect(try await library.chapter(moduleID: "ESV", bookNumber: 43, chapterNumber: 1).verses.first?.text
            == "the old import")

        let (other, otherRoot) = try await self.library(installing: [])
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        try await installDictionary(id: "ESV", into: other, at: otherRoot)
        let agent = LampAgentLibrary(library: other, policy: LampAgentAccessPolicy(allowedModuleIDs: ["ESVs"]))
        #expect(try await agent.listModules().isEmpty)
    }

    /// A translation installed after the first renamed lookup is found by
    /// the next.
    @Test func aTranslationInstalledLaterIsFound() async throws {
        let (library, root) = try await library(installing: [])
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: (any Error).self) {
            _ = try await library.chapter(moduleID: "ESV", bookNumber: 43, chapterNumber: 1)
        }
        let archive = root.appendingPathComponent("ESVs.lamp")
        _ = try LampModuleCompiler().compile(
            data: Data(translation(id: "ESVs", abbreviation: "ESV", text: "installed later").utf8),
            sourceFilename: "ESVs.json", destinationURL: archive
        )
        _ = try await library.install(from: archive)
        #expect(try await library.chapter(moduleID: "ESV", bookNumber: 43, chapterNumber: 1).verses.first?.text
            == "installed later")
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

    /// Access given to a translation before it was renamed holds after;
    /// with both spellings installed, only the one allowed is.
    @Test func accessGivenBeforeTheRenameHoldsAfter() {
        let policy = LampAgentAccessPolicy(allowedModuleIDs: ["KJVs", "ESVs"])
        #expect(policy.allowedModuleIDs(holding: ["KJV", "BSB"]) == ["KJV", "ESVs"])
        #expect(policy.allowedModuleIDs(holding: ["ESVs", "ESV"])?.contains("ESV") == false)
        #expect(policy.allowedModuleIDs(holding: ["ESVs", "ESV"])?.contains("ESVs") == true)
        #expect(LampAgentAccessPolicy().allowedModuleIDs(holding: ["ESV"]) == nil)
    }

    /// An agent reads a translation asked for by its old ID, and with both
    /// installed is refused the one it was not given.
    @Test func anAgentFindsATranslationByEitherIDButOnlyTheOneAllowed() async throws {
        let (library, root) = try await library(installing: [("ESVs", "the old import"), ("KJV", "the new bundle")])
        defer { try? FileManager.default.removeItem(at: root) }
        let open = LampAgentLibrary(library: library, policy: LampAgentAccessPolicy(allowedModuleIDs: ["KJVs", "ESVs"]))
        let kjv = try await open.readPassage(reference: "John 1:1", translationIDs: ["KJVs"])
        #expect(kjv.flatMap(\.verses).map(\.text) == ["the new bundle"])

        let (both, bothRoot) = try await self.library(installing: [("ESVs", "the old import"), ("ESV", "the new import")])
        defer { try? FileManager.default.removeItem(at: bothRoot) }
        let narrow = LampAgentLibrary(library: both, policy: LampAgentAccessPolicy(allowedModuleIDs: ["ESVs"]))
        await #expect(throws: LampAgentError.self) {
            _ = try await narrow.readPassage(reference: "John 1:1", translationIDs: ["ESV"])
        }
        #expect(try await narrow.readPassage(reference: "John 1:1", translationIDs: ["ESVs"]).flatMap(\.verses).map(\.text)
            == ["the old import"])
        #expect(try await narrow.readPassage(reference: "John 1:1").map(\.translationID) == ["ESVs"])
    }

    /// A saved order names the translation it was saved for under its new
    /// ID, and a list naming one translation twice keeps it once.
    @Test func aSavedOrderHoldsAfterTheRename() {
        #expect(LampModuleSelection.ordered(["NASB", "BSB"], preferredIDs: ["BSBs"], id: { $0 }) == ["BSB", "NASB"])
        #expect(LampModuleSelection.ordered(["NASB", "BSBs", "BSB"], preferredIDs: ["BSB"], id: { $0 })
            == ["BSB", "NASB", "BSBs"])
        // A preference for a hidden one goes with it.
        #expect(LampModuleSelection.visible(["NASB", "ESVs", "ESV"], hiddenIDs: ["ESV"], preferredIDs: ["ESV"], id: { $0 })
            == ["NASB", "ESVs"])
    }

    /// With both installed, a translation's highlights are one set, shown
    /// and removed under either: they belong to the translation.
    @Test func bothSpellingsInstalledShareTheTranslationsHighlights() async throws {
        let (library, root) = try await library(installing: [("ESVs", "the old import"), ("ESV", "the new import")])
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await library.saveVerseHighlight(translationID: "ESV", reference: 43_001_001, startOffset: 0, endOffset: 3)
        _ = try await library.saveVerseHighlight(translationID: "ESVs", reference: 43_001_001, startOffset: 4, endOffset: 7)
        #expect(try await library.highlightSets().map(\.id) == ["personal-highlights:ESVs"])
        #expect(try await library.verseHighlights(translationID: "ESV", reference: 43_001_001).count == 2)
        try await library.deleteVerseHighlights(translationID: "ESV", reference: 43_001_001)
        #expect(try await library.verseHighlights(translationID: "ESVs", reference: 43_001_001).isEmpty)
    }

    /// A shared database, as the bundle and the phone's are, answers for a
    /// translation under the ID it lists, whichever the caller has.
    @Test func aSharedDatabaseAnswersUnderTheIDItLists() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE translations (id TEXT, name TEXT, abbreviation TEXT, language TEXT,
                    versification TEXT, source_texts_json TEXT);
                INSERT INTO translations VALUES ('KJVs', 'King James', 'KJV', 'en', 'org', NULL);
                CREATE TABLE translation_verses (translation_id TEXT, ref INTEGER, book INTEGER,
                    chapter INTEGER, verse INTEGER, text TEXT, annotations_json TEXT);
                INSERT INTO translation_verses VALUES ('KJVs', 43001001, 43, 1, 1, 'In the beginning was the Word', NULL);
                """)
        }
        let found = try queue.read { db in
            (try LampVersification.declared(in: db, translationID: "KJV").scheme,
             try LampVersification.declared(in: db, translationID: "KJVs").scheme,
             try LampStrongsAnalysisReader.VerseSource.find(in: db, translationID: "KJV")?.translationID,
             try LampModuleSearch.verses(in: db, translations: ["KJV"], query: LampSearchQuery("beginning"), limit: 5)
                .map(\.translationID))
        }
        #expect(found.0 == .original)
        #expect(found.1 == .original)
        #expect(found.2 == "KJVs")
        #expect(found.3 == ["KJVs"])
    }

    /// The shared writer records a set's translation by its first ID,
    /// whichever the caller gives, so both apps publish the same file.
    @Test func aHighlightsFileRecordsTheFirstID() throws {
        let document = try LampPersonalHighlightsFile.document(for: .init(
            id: "personal-highlights:BSBs", moduleID: "personal-highlights-BSBs", name: "Mine", translationID: "BSB",
            highlights: []
        ))
        let meta = try #require(document["meta"] as? [String: Any])
        #expect(meta["translationId"] as? String == "BSBs")
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
