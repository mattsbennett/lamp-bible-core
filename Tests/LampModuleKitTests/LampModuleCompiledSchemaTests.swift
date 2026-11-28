import Foundation
import GRDB
import Testing
@testable import LampModuleKit

/// Whether `LampModuleCompiledSchema` still describes what the compilers
/// write.
///
/// A shared list is not a source of truth by itself — `bookModuleColumns` was
/// shared between core and the iPhone and went stale anyway, because nothing
/// compared it with the table it claimed to describe, and a book's `genre`
/// went missing on one app as a result. So every kind here is **compiled**,
/// from the smallest module its own inspector accepts, and the declaration is
/// checked against the real thing: the columns it has, and which of them a
/// module carrying only the required fields leaves NULL.
///
/// The fixtures are deliberately minimal. That is what makes `mayBeNull`
/// meaningful: it is the shape that arrives when an author fills in nothing
/// optional, which is the module most likely to break an importer.
struct LampModuleCompiledSchemaTests {
    /// The smallest module of each kind that `ModuleJSONInspector` accepts.
    /// Fields beyond the required ones are left out on purpose.
    private static let minimalSources: [LampModuleKind: String] = [
        .book: #"""
        {
          "meta": {
            "schemaVersion": "1.0", "id": "shape_book", "type": "book",
            "title": "B", "language": "en"
          },
          "sections": [{
            "id": "one", "type": "chapter", "title": "One",
            "content": [{"type": "paragraph", "content": {"text": "T."}}]
          }]
        }
        """#,
        .commentary: #"""
        {
          "meta": {"schemaVersion": "2.2", "seriesAbbrev": "TST", "seriesFull": "Test", "title": "Genesis"},
          "book": "Gen", "bookNumber": 1,
          "chapters": [{"chapter": 1, "sections": [{
            "title": "C", "sv": 1001001, "ev": 1001002,
            "pericopae": [{"title": "B", "sv": 1001001, "ev": 1001002,
              "verses": [{"sv": 1001001, "commentary": [{"type": "paragraph", "text": "A note"}]}]}]
          }]}]
        }
        """#,
        .dictionary: #"""
        {
          "meta": {
            "schemaVersion": "2.1", "id": "shape_dictionary",
            "type": "dictionary", "name": "D", "keyType": "strongs"
          },
          "entries": [{"key": "G1", "lemma": "alpha", "senses": [{"definition": "first"}]}]
        }
        """#,
        .translation: #"""
        {
          "meta": {
            "schemaVersion": "1.0", "id": "shape_translation", "type": "translation",
            "name": "T", "abbreviation": "TST", "language": "en"
          },
          "books": [{
            "id": "Gen", "name": "Genesis", "number": 1, "testament": "OT",
            "chapters": [{
              "chapter": 1,
              "headings": [{"beforeVerse": 1, "level": 1, "text": "Creation"}],
              "verses": [{"v": 1, "ref": 1001001, "content": {"text": "In the beginning"}}]
            }]
          }]
        }
        """#,
        .plan: #"""
        {
          "meta": {"schemaVersion": "1.0", "id": "shape_plan", "type": "plan", "name": "P"},
          "days": [{"day": 1, "readings": [{"sv": 1001001, "ev": 1001999}]}]
        }
        """#,
        .quiz: #"""
        {
          "meta": {
            "schemaVersion": "1.0", "id": "shape_quiz", "type": "quiz",
            "planId": "shape_plan", "name": "Q",
            "ageGroups": [{"id": "adult", "label": "Adult", "ageRange": "18+"}]
          },
          "days": [{"day": 1, "readings": [{"sv": 1001001, "ev": 1001999,
            "quizzes": {"adult": [{
              "question": {"text": "Who?"}, "answer": "God.",
              "theme": "doctrine", "christFocused": false, "references": [1001001]
            }]}
          }]}]
        }
        """#,
        .highlights: #"""
        {
          "meta": {
            "schemaVersion": "1.0", "id": "shape_highlights", "type": "highlights",
            "translationId": "ESV",
            "themes": [{"color": "#ffcc00", "style": 0, "name": "P"}]
          },
          "verses": [{"ref": 43003016, "highlights": [{"sc": 0, "ec": 3, "style": 0, "color": "#ffcc00"}]}]
        }
        """#,
    ]

    @Test(arguments: LampModuleKind.allCases)
    func theDeclaredShapeIsTheCompiledShape(kind: LampModuleKind) throws {
        let declared = LampModuleCompiledSchema.tables(for: kind)
        guard let source = Self.minimalSources[kind] else {
            // notes and devotional reconcile through typed records rather
            // than copying columns, so they declare nothing here — and must
            // not start declaring something without a fixture to hold it to.
            // What the reader's *own* notes and writings are written as is a
            // different file and a different declaration,
            // `exportedTables(for:)`, pinned by exporting one.
            #expect(
                declared.isEmpty,
                "\(kind.rawValue) declares tables with no fixture to check them against"
            )
            return
        }
        #expect(!declared.isEmpty, "\(kind.rawValue) has a fixture but declares no tables")

        let fixture = try ShapeFixture()
        defer { fixture.remove() }
        let id = "shape_\(kind.rawValue)"
        let outputURL = fixture.url.appendingPathComponent("\(id).lamp")
        _ = try LampModuleCompiler().compile(
            data: Data(source.utf8), sourceFilename: "\(id).json", destinationURL: outputURL
        )

        let queue = try fixture.openLamp(outputURL)
        try queue.read { db in
            for shape in declared {
                let info = try Row.fetchAll(db, sql: "PRAGMA table_info(\(shape.table))")
                let actual = Set(info.compactMap { $0["name"] as String? })
                #expect(
                    actual == Set(shape.columns),
                    """
                    \(kind.rawValue)/\(shape.table): declared \(Set(shape.columns).sorted()) \
                    but the compiler writes \(actual.sorted()). A column added to a compiler \
                    must be declared here, and as mayBeAbsent if an older module lacks it, \
                    or the iPhone's copy drops it silently.
                    """
                )
                #expect(
                    Set(shape.mayBeAbsent).isSubset(of: Set(shape.columns)),
                    "\(kind.rawValue)/\(shape.table): mayBeAbsent names a column that is not written"
                )

                // Which columns a module holding only the required fields
                // leaves empty. A client must allow NULL in exactly these.
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(shape.table)")
                // A table an older module may lack may be empty in a minimal
                // one: its rows are held by the rich commentary's own test.
                if rows.isEmpty, shape.tableMayBeAbsent { continue }
                guard !rows.isEmpty else {
                    Issue.record("\(kind.rawValue)/\(shape.table): the fixture wrote no rows, so NULLs cannot be read")
                    continue
                }
                var empty: Set<String> = []
                for row in rows {
                    for column in shape.columns where row[column] == nil {
                        empty.insert(column)
                    }
                }
                // A **subset**, not an equality. The fixture is one valid
                // input, not every one: a sense list can be empty, a
                // highlight can omit its colour, a plan can give no day, and
                // each of those leaves a column NULL that this module fills.
                // So the fixture proves a column *can* be NULL, never that
                // another cannot, and the declaration is allowed to be wider
                // than what one compile shows.
                //
                // The direction matters. Over-declaring costs a client a
                // column that permits NULL and never holds one; under-
                // declaring invites it to write NOT NULL and fail on a module
                // the schema permits, which is the quiz bug exactly — SQLite
                // does not apply a DEFAULT to an explicitly inserted NULL.
                // An equality check here read as rigour and quietly enforced
                // the dangerous direction, missing five columns when it was
                // written.
                #expect(
                    empty.isSubset(of: Set(shape.mayBeNull)),
                    """
                    \(kind.rawValue)/\(shape.table): a minimal module leaves \
                    \(empty.subtracting(Set(shape.mayBeNull)).sorted()) empty, which is not \
                    declared. A client's column must allow NULL in each.
                    """
                )
            }
        }
    }
}

extension LampModuleCompiledSchemaTests {
    /// A 2.3 volume fills what a 2.2 one leaves empty: a unit's blocks and
    /// declared id, the volume's media, its front-matter rows. Compiled by
    /// the commentary compiler itself, since a 2.3 volume is not yet one the
    /// module compiler takes. The columns are the declared ones, and those
    /// left NULL are declared so.
    @Test func aRichCommentaryFillsTheDeclaredShape() throws {
        let volume = #"""
        {"meta": {"schemaVersion": "2.3", "id": "R", "type": "commentary", "seriesAbbrev": "R", "seriesFull": "Rich", "title": "Rich"},
         "book": "John", "bookNumber": 43,
         "media": [{"id": "m1", "type": "image", "filename": "one.png", "mimeType": "image/png"}],
         "frontMatter": {"sections": [{"id": "intro", "title": "Introduction", "blocks": [{"type": "image", "mediaId": "m1"}],
                                       "sections": [{"id": "date", "title": "Date", "blocks": [{"type": "paragraph", "content": {"text": "Late."}}]}]}]},
         "chapters": [{"chapter": 1, "sections": [{"id": "prologue", "title": "Prologue", "sv": 43001001,
                                                   "blocks": [{"type": "paragraph", "content": {"text": "In the beginning."}}]}]}]}
        """#
        let root = try #require(try JSONSerialization.jsonObject(with: Data(volume.utf8)) as? [String: Any])
        let fixture = try ShapeFixture()
        defer { fixture.remove() }
        let url = fixture.url.appendingPathComponent("rich.sqlite")
        _ = try LampModuleCompiler().compileCommentary(root: root, databaseURL: url, moduleID: "R")
        let queue = try DatabaseQueue(path: url.path)
        try queue.read { db in
            for shape in LampModuleCompiledSchema.tables(for: .commentary) {
                let actual = Set(try Row.fetchAll(db, sql: "PRAGMA table_info(\(shape.table))").compactMap { $0["name"] as String? })
                #expect(actual == Set(shape.columns), "\(shape.table): \(actual.sorted())")
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(shape.table)")
                #expect(!rows.isEmpty, "\(shape.table) is empty")
                let empty = Set(rows.flatMap { row in shape.columns.filter { row[$0] == nil } })
                #expect(empty.isSubset(of: Set(shape.mayBeNull)), "\(shape.table) leaves \(empty.subtracting(shape.mayBeNull).sorted()) empty")
            }
            let book = try #require(try Row.fetchOne(db, sql: "SELECT media_json, front_matter_json FROM commentary_books"))
            #expect((book["media_json"] as String?)?.contains("one.png") == true)
            #expect((book["front_matter_json"] as String?) == nil)
            let unit = try #require(try Row.fetchOne(db, sql: "SELECT blocks_json, declared_id FROM commentary_units WHERE declared_id IS NOT NULL"))
            #expect((unit["declared_id"] as String?) == "prologue")
            #expect((unit["blocks_json"] as String?)?.contains("In the beginning.") == true)
            let front = try Row.fetchAll(db, sql: "SELECT id, section_id, parent_id, depth, order_index FROM commentary_front_matter ORDER BY order_index")
            #expect(front.map { $0["id"] as String } == ["R:43:front:intro", "R:43:front:date"])
            #expect(front.map { $0["parent_id"] as String? } == [nil, "R:43:front:intro"])
            #expect(front.map { $0["depth"] as Int } == [0, 1])
            // Its search index finds a section by its words.
            let found = try String.fetchAll(db, sql: """
                SELECT f.section_id FROM commentary_front_matter_fts JOIN commentary_front_matter f ON f.rowid = commentary_front_matter_fts.rowid
                WHERE commentary_front_matter_fts MATCH 'late'
                """)
            #expect(found == ["date"])
        }
        // A front-matter row claiming another module is refused, as a
        // unit's is. Found by Codex.
        try queue.write { db in try db.execute(sql: "UPDATE commentary_front_matter SET module_id = 'OTHER' WHERE section_id = 'date'") }
        #expect(throws: LampPortableModuleInspector.InspectionError.foreignRows("commentary_front_matter")) {
            try LampPortableModuleInspector.validateOwnership(databaseURL: url, expectedID: "R", kind: .commentary, verifyIntegrity: false)
        }
        // A series names its front matter by the series, not each volume's
        // abbreviation. Found by Codex.
        var inSeries = CommentaryUnitBuilder(moduleID: "ABBR", bookNumber: 43, rich: true)
        inSeries.frontMatterOwner = "SERIES"
        inSeries.append(frontMatter: ["sections": [["id": "intro", "title": "I"]]], media: nil)
        #expect(inSeries.frontMatterRows.map(\.id) == ["SERIES:43:front:intro"])
    }
}

private struct ShapeFixture {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-shape-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    func openLamp(_ lampURL: URL) throws -> DatabaseQueue {
        let compressed = try Data(contentsOf: lampURL)
        let body = try (compressed as NSData).decompressed(using: .zlib) as Data
        let databaseURL = url.appendingPathComponent("\(UUID().uuidString).sqlite")
        try body.write(to: databaseURL)
        var configuration = Configuration()
        configuration.readonly = true
        return try DatabaseQueue(path: databaseURL.path, configuration: configuration)
    }
}
