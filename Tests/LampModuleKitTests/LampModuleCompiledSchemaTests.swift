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
            // than copying columns, so they declare nothing — and must not
            // start declaring something without a fixture to hold it to.
            #expect(declared.isEmpty, "\(kind.rawValue) declares tables with no fixture to check them against")
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
