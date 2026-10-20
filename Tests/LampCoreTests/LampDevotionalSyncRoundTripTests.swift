import Foundation
import GRDB
import LampCore
import LampModuleKit
import Testing

/// Publishing a writing and reading the very same file back is what happens on
/// every sync where nothing changed. It has to be a no-op, because a sync that
/// quietly rewrites a record while keeping its change time leaves this device
/// holding bytes no other device has, at a timestamp that says they agree —
/// which is exactly the standoff sync cannot resolve.
struct LampDevotionalSyncRoundTripTests {
    private func library(_ root: URL) -> LampLibrary { LampLibrary(rootURL: root) }

    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-devotional-roundtrip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    /// Markdown that exercises the shapes a flattener mangles: an image, a
    /// footnote, a nested list, a quote and a table.
    private let body = """
        This is a test. Test. Another test.

        ![Caption](media/32D89C7E-7EB3-45F7-9D24-8E8CC8EC0679)

        Asdf Handbag[^1]

        1. Test
        2. Test
           - Nest[^2]
        3. Test

        | One | Two |
        | --- | --- |
        | a | b |

        [^1]: First
        [^2]: Second
        """

    private func writing(_ content: String, modified: Int) -> LampDevotional {
        LampDevotional(
            id: "W1", moduleID: "personal-devotionals", moduleName: "My Writing",
            title: "Test Title", subtitle: "Subtitle", date: "2026-01-24",
            category: "exhortation", content: content, footnotes: "One\n\nTwo",
            created: Date(timeIntervalSince1970: 1_769_317_935),
            lastModified: Date(timeIntervalSince1970: TimeInterval(modified))
        )
    }

    /// What the Mac uploads to the sync folder.
    private func publish(_ library: LampLibrary, to root: URL) async throws -> URL {
        let exported = root.appendingPathComponent("export.lamp")
        try await library.exportPersonalModule(.writing, format: .lamp, to: exported)
        let wire = root.appendingPathComponent("wire.lamp")
        try LampWebDAVPersonalArchiveAdapter.archive(
            Data(contentsOf: exported),
            replacingModuleIDWith: "devotionals",
            kind: .devotionals,
            mediaRootURL: library.rootURL,
            fileManager: .default
        ).write(to: wire)
        return wire
    }

    /// Under per-file sync, "should I upload this?" compares this export with
    /// the last one uploaded. So an unchanged library has to export the same
    /// bytes every time, even after a row tied with others on every sort
    /// column has moved in its table. Otherwise the whole module uploads again
    /// for no change. Every export query needs a total order to keep this.
    @Test(arguments: LampPersonalModule.allCases)
    func anUnchangedLibraryExportsTheSameBytes(_ module: LampPersonalModule) async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryRoot = root.appendingPathComponent("Library")
        let library = library(libraryRoot)
        let time = Date(timeIntervalSince1970: 1_788_132_249)
        let table: String
        // Six rows tied on every column the export sorts by except `id`.
        for index in 1...6 {
            switch module {
            case .writing:
                // Untitled drafts: one title, no series, no date.
                try await library.savePersonalDevotional(LampDevotional(
                    id: "tie-\(index)", moduleID: module.rawValue, moduleName: "My Writing",
                    title: "New Writing", content: "Draft \(index)", created: time, lastModified: time
                ), preserveLastModified: true)
            case .notes:
                try await library.saveVerseNote(LampVerseNote(
                    id: "tie-\(index)", reference: 1_001_001, content: "Note \(index)", lastModified: time
                ))
            case .highlights:
                _ = try await library.saveHighlightSet(LampHighlightSet(
                    id: "tie-\(index)", name: "Highlights", translationID: "KJV", created: time
                ))
            }
        }
        table = switch module {
        case .writing: "personal_devotionals"
        case .notes: "personal_notes"
        case .highlights: "highlight_sets"
        }
        func exportDigest(_ name: String) async throws -> String {
            let url = root.appendingPathComponent(name)
            try await library.exportPersonalModule(module, format: .lamp, to: url)
            return try LampSyncContentRevision.digest(forFileAt: url)
        }
        let first = try await exportDigest("first.lamp")
        #expect(try await exportDigest("again.lamp") == first)

        // Delete one row and insert it again with every value unchanged, so
        // only its place in the table moves.
        let database = try DatabaseQueue(path: libraryRoot.appendingPathComponent("UserData.sqlite").path)
        try await database.write { db in
            let row = try #require(try Row.fetchOne(db, sql: "SELECT * FROM \(table) WHERE id = 'tie-2'"))
            let columns = Array(row.columnNames)
            try db.execute(sql: "DELETE FROM \(table) WHERE id = 'tie-2'")
            try db.execute(
                sql: "INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(columns.map { _ in "?" }.joined(separator: ", ")))",
                arguments: StatementArguments(row.databaseValues)
            )
        }
        try database.close()
        #expect(try await exportDigest("moved.lamp") == first)
    }

    @Test func readingOurOwnPublishedFileBackChangesNothing() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = library(root.appendingPathComponent("Library"))
        try await library.savePersonalDevotional(
            writing(body, modified: 1_788_132_249), preserveLastModified: true
        )
        let before = try #require(try await library.personalDevotionals().first)

        let wire = try await publish(library, to: root)
        _ = try await library.importPersonalDevotional(from: wire, forSync: true)

        let after = try #require(try await library.personalDevotionals().first)
        #expect(after.content == before.content)
        #expect(after.lastModified == before.lastModified)
        // The body travels in the column iOS reads as content; it is not a
        // structured representation and must not be stored as one.
        #expect(after.contentJSON == nil)
        #expect(try await library.pendingSyncConflicts().isEmpty)
    }

    /// The body is what the other device must receive — intact, not flattened
    /// into something that has lost its image and its table.
    @Test func thePublishedBodyIsTheAuthoredMarkdown() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = library(root.appendingPathComponent("Library"))
        try await library.savePersonalDevotional(
            writing(body, modified: 1_788_132_249), preserveLastModified: true
        )
        let wire = try await publish(library, to: root)
        let onTheWire = try #require(
            try await library.personalDevotionalCandidates(from: wire).first
        )
        #expect(onTheWire.content == body)
        #expect(onTheWire.contentJSON == nil)
    }

    /// The single-writing JSON document is the other way a copy comes home.
    /// Export wraps a body with no blocks in one paragraph so iOS can read it;
    /// reading that wrapper back as structure is what rewrote the record in
    /// place, with its change time left alone.
    @Test func readingOurOwnPublishedDocumentBackChangesNothing() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = library(root.appendingPathComponent("Library"))
        try await library.savePersonalDevotional(
            writing(body, modified: 1_788_132_249), preserveLastModified: true
        )
        let before = try #require(try await library.personalDevotionals().first)

        let document = root.appendingPathComponent("writing.json")
        try await library.personalDevotionalDocument(id: "W1").jsonData.write(to: document)
        let incoming = try #require(
            try await library.personalDevotionalCandidates(from: document).first
        )
        #expect(incoming.content == body)
        #expect(incoming.contentJSON == nil)

        _ = try await library.importPersonalDevotional(from: document, forSync: true)
        let after = try #require(try await library.personalDevotionals().first)
        #expect(after.content == before.content)
        #expect(after.contentJSON == nil)
        #expect(after.lastModified == before.lastModified)
        #expect(try await library.pendingSyncConflicts().isEmpty)
    }

    /// Genuine rich content from a client that has it still arrives as blocks;
    /// the fix must not throw structure away.
    @Test func realBlocksAreStillCarriedAsBlocks() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = library(root.appendingPathComponent("Library"))
        let blocks = #"[{"annotations":[],"content":{"text":"Rich body."},"type":"paragraph"}]"#
        var rich = writing("Rich body.", modified: 1_788_132_249)
        rich.contentJSON = blocks
        try await library.savePersonalDevotional(rich, preserveLastModified: true)

        let wire = try await publish(library, to: root)
        let onTheWire = try #require(
            try await library.personalDevotionalCandidates(from: wire).first
        )
        #expect(onTheWire.content == "Rich body.")
        _ = try await library.importPersonalDevotional(from: wire, forSync: true)
        #expect(try await library.pendingSyncConflicts().isEmpty)
        let after = try #require(try await library.personalDevotionals().first)
        #expect(after.lastModified == Date(timeIntervalSince1970: 1_788_132_249))
    }
}
