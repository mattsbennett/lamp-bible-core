import CryptoKit
import Foundation
import GRDB
import Testing
@testable import LampModuleKit

/// What today's commentary JSON compiles to, row by row, held still.
///
/// The richer commentary format (Documentation/RichModulesPlan.md) adds
/// blocks, media and front matter beside what a commentary stores today, and
/// must not change what it stores for a commentary that uses none of them. So
/// the two published examples are compiled and every row they give is
/// compared with what they gave before the work began: the row's own fields
/// as written, and each JSON or text column by a digest of its bytes, so a
/// change anywhere in one shows up as a change here.
struct CommentaryCompiledShapeTests {
    @Test(arguments: [
        ("commentary_example.json", CommentaryCompiledShapeTests.fullExample),
        ("commentary_simple_example.json", CommentaryCompiledShapeTests.simpleExample),
    ])
    func anexampleCompilesToTheRowsItAlwaysHas(_ name: String, _ expected: [String]) throws {
        let rows = try Self.compiledRows(name)
        #expect(rows == expected, "compiled:\n\(rows.map { "\"\($0)\"," }.joined(separator: "\n"))")
    }

    /// The examples hold no front matter, abbreviations or indices, so a
    /// volume that does is pinned as well: those are stored whole in
    /// `commentary_books`, and the richer format changes what goes there.
    /// Found by Codex, reviewing the pin.
    @Test func avolumeWithFrontMatterCompilesToTheRowsItAlwaysHas() throws {
        let rows = try Self.compiledRows(data: Data(Self.frontMatterVolume.utf8), name: "FM_Gen.json")
        #expect(
            rows == Self.frontMatterExample,
            "compiled:\n\(rows.map { "\"\($0)\"," }.joined(separator: "\n"))"
        )
    }

    /// A source-tracked volume, whose entries each carry a range of their own
    /// — one reaching into the next chapter, one discussed before an earlier
    /// passage — becomes rows filed by those ranges, in printed order. The
    /// richer format puts blocks on such entries, so how they are filed is
    /// pinned too. Found by Codex, reviewing the pin.
    @Test func asourceTrackedVolumeCompilesToTheRowsItAlwaysHas() throws {
        let rows = try Self.compiledRows(data: Data(Self.sourceTrackedVolume.utf8), name: "ST_Gen.json")
        #expect(
            rows == Self.sourceTrackedExample,
            "compiled:\n\(rows.map { "\"\($0)\"," }.joined(separator: "\n"))"
        )
    }

    static let sourceTrackedVolume = #"""
    {
      "meta": {"schemaVersion": "2.2", "id": "ST_Gen", "seriesAbbrev": "ST", "seriesFull": "Source Notes", "title": "Genesis"},
      "book": "Gen", "bookNumber": 1, "extraction": {"sourceTracked": true},
      "chapters": [
        {"chapter": 1, "pericopae": [{"id": "days", "sourceOrder": 20, "title": "The Days", "sv": 1001001, "ev": 1002003, "content": [
          {"type": "heading", "source": {"volumeId": "ST_Gen", "sourceFile": "genesis.txt", "lineStart": 1, "lineEnd": 1}, "content": {"text": "The First Day"}},
          {"type": "commentary", "source": {"volumeId": "ST_Gen", "sourceFile": "genesis.txt", "lineStart": 2, "lineEnd": 2}, "sv": 1001003, "ev": 1001005, "content": {"text": "Light, and the first evening."}},
          {"type": "commentary", "source": {"volumeId": "ST_Gen", "sourceFile": "genesis.txt", "lineStart": 3, "lineEnd": 3}, "sv": 1002001, "ev": 1002003, "content": {"text": "The seventh day, in the next chapter."}},
          {"type": "commentary", "source": {"volumeId": "ST_Gen", "sourceFile": "genesis.txt", "lineStart": 4, "lineEnd": 4}, "content": {"text": "No range of its own."}}
        ]}]},
        {"chapter": 2, "pericopae": [{"id": "garden", "sourceOrder": 10, "title": "The Garden", "sv": 1002004, "content": [
          {"type": "commentary", "source": {"volumeId": "ST_Gen", "sourceFile": "genesis.txt", "lineStart": 5, "lineEnd": 5}, "sv": 1002008, "content": {"text": "Planted eastward."}}
        ]}]}
      ]
    }
    """#

    static let sourceTrackedExample: [String] = [
        "book s:ST_Gen:1|s:ST_Gen|i:1|s:Source Notes|s:ST|s:Genesis|∅|∅|∅|∅|∅|∅|∅|∅",
        "unit s:ST_Gen:1:pericope:2:0|s:ST_Gen|i:1|i:2|i:1002004|∅|s:pericope|i:1|∅|s:The Garden|∅|i:0|∅|∅|∅|∅|e82bb2369e2e|e3b0c44298fc",
        "unit s:ST_Gen:1:verse:2:1|s:ST_Gen|i:1|i:2|i:1002008|∅|s:verse|i:1|s:ST_Gen:1:pericope:2:0|∅|∅|i:1|∅|∅|f841d4a0d8ea|∅|4c80226fcec9|e3b0c44298fc",
        "unit s:ST_Gen:1:pericope:1:2|s:ST_Gen|i:1|i:1|i:1001001|i:1002003|s:pericope|i:1|∅|s:The Days|∅|i:2|∅|∅|∅|∅|90726c8b1816|e3b0c44298fc",
        "unit s:ST_Gen:1:section:1:3|s:ST_Gen|i:1|i:1|i:1001001|i:1002003|s:section|i:2|s:ST_Gen:1:pericope:1:2|s:The First Day|∅|i:3|∅|∅|∅|∅|7c6eac95903e|e3b0c44298fc",
        "unit s:ST_Gen:1:verse:1:4|s:ST_Gen|i:1|i:1|i:1001003|i:1001005|s:verse|i:1|s:ST_Gen:1:pericope:1:2|∅|∅|i:4|∅|∅|6f7568afd2d6|∅|210369f94a04|e3b0c44298fc",
        "unit s:ST_Gen:1:verse:2:5|s:ST_Gen|i:1|i:2|i:1002001|i:1002003|s:verse|i:1|s:ST_Gen:1:pericope:1:2|∅|∅|i:5|∅|∅|7b7cc686b3f0|∅|98bcbdbfd42a|e3b0c44298fc",
        "unit s:ST_Gen:1:pericope:1:6|s:ST_Gen|i:1|i:1|i:1001001|i:1002003|s:pericope|i:1|s:ST_Gen:1:pericope:1:2|∅|∅|i:6|∅|∅|7203833e097b|∅|347f8ec86248|e3b0c44298fc",
    ]

    static let frontMatterVolume = #"""
    {
      "meta": {"schemaVersion": "2.2", "id": "FM_Gen", "seriesAbbrev": "FM", "seriesFull": "Front Matter Notes",
               "title": "Notes on Genesis", "author": "An Author", "editor": "An Editor",
               "publisher": "A Press", "year": 2001},
      "book": "Gen", "bookNumber": 1,
      "abbreviations": [{"abbrev": "LXX", "expansion": "Septuagint"}],
      "frontMatter": {
        "dedication": "For the reader.",
        "introduction": {"text": "Genesis opens the canon; see Exodus 1:1.",
                         "annotations": [{"type": "scripture", "start": 28, "end": 38, "data": {"sv": 2001001}}]},
        "bibliography": [{"subsection": "Commentaries", "content": {"text": "Wenham, Genesis."}}]
      },
      "chapters": [{
        "chapter": 1,
        "sections": [{
          "id": "creation", "title": "Creation", "introduction": {"text": "The account of the heavens and the earth."}, "sv": 1001001, "ev": 1002003, "level": 1,
          "pericopae": [{
            "id": "six-days", "title": "The Six Days", "introduction": {"text": "Six days, and a seventh."}, "sv": 1001001, "ev": 1001031,
            "verses": [{"sv": 1001001, "commentary": {"text": "In the beginning, God.", "annotations": [{"type": "italic", "start": 0, "end": 16}]}}]
          }]
        }]
      }],
      "footnotes": [{"id": "1", "content": {"text": "A footnote."}}],
      "indices": {"subjects": {"creation": ["1:1"]}}
    }
    """#

    /// A chapter given twice, each with an introduction, compiles: the first
    /// keeps the ID it always had, and the second is told apart by its place.
    /// Found by Codex, reviewing the series compiler.
    @Test func achapterIntroducedTwiceStillCompiles() throws {
        let rows = try Self.compiledRows(data: Data(#"""
        {"meta": {"schemaVersion": "2.2", "id": "TWICE_Gen", "seriesAbbrev": "TW", "seriesFull": "Twice", "title": "Genesis"},
         "book": "Gen", "bookNumber": 1, "chapters": [
           {"chapter": 1, "introduction": {"text": "First."}, "verses": [{"sv": 1001001, "commentary": {"text": "One."}}]},
           {"chapter": 1, "introduction": {"text": "Again."}}
         ]}
        """#.utf8), name: "TWICE_Gen.json")
        let ids = rows.filter { $0.contains("chapter_intro") }.map { $0.split(separator: "|")[0] }
        #expect(ids == ["unit s:TWICE_Gen:1:chapter_intro:1", "unit s:TWICE_Gen:1:chapter_intro:1:2"], "\(ids)")
    }

    // MARK: Compiling

    static func compiledRows(_ name: String) throws -> [String] {
        let source = SchemaFilesTests.schemasURL.appendingPathComponent(name)
        return try compiledRows(data: try Data(contentsOf: source), name: name)
    }

    static func compiledRows(data: Data, name: String) throws -> [String] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-commentary-shape-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try ModuleJSONInspector().inspect(data, sourceFilename: name).metadata.id ?? "example"
        let archive = directory.appendingPathComponent("\(id).lamp")
        _ = try LampModuleCompiler().compile(data: data, sourceFilename: name, destinationURL: archive)
        let database = directory.appendingPathComponent("example.sqlite")
        try ((Data(contentsOf: archive) as NSData).decompressed(using: .zlib) as Data).write(to: database)
        let queue = try DatabaseQueue(path: database.path)
        return try queue.read { db in
            let books = try Row.fetchAll(db, sql: "SELECT * FROM commentary_books ORDER BY rowid").map { row in
                "book " + [
                    field(row, "id"), field(row, "module_id"), field(row, "book_number"),
                    field(row, "series_full"), field(row, "series_abbrev"), field(row, "title"),
                    field(row, "description"), field(row, "author"), field(row, "editor"),
                    field(row, "publisher"), field(row, "year"),
                    digest(row, "abbreviations_json"), digest(row, "front_matter_json"),
                    digest(row, "indices_json"),
                ].joined(separator: "|")
            }
            let units = try Row.fetchAll(db, sql: "SELECT * FROM commentary_units ORDER BY rowid").map { row in
                "unit " + [
                    field(row, "id"), field(row, "module_id"), field(row, "book"), field(row, "chapter"),
                    field(row, "sv"), field(row, "ev"), field(row, "unit_type"), field(row, "level"),
                    field(row, "parent_id"), field(row, "title"), field(row, "suffix"),
                    field(row, "order_index"),
                    digest(row, "introduction_json"), digest(row, "translation_json"),
                    digest(row, "commentary_json"), digest(row, "footnotes_json"),
                    digest(row, "search_text"), digest(row, "footnotes_text"),
                ].joined(separator: "|")
            }
            return books + units
        }
    }

    /// A column's value as stored, every kind tagged — `s:` text, `i:`
    /// integer, `r:` real, `b:` blob, `∅` NULL — so an integer turned to text,
    /// `2001` to `"2001"`, shows, and no text can read as another kind.
    /// Found by Codex, reviewing the pin.
    private static func field(_ row: Row, _ column: String) -> String {
        let value: DatabaseValue = row[column]
        switch value.storage {
        case .null: return "∅"
        // `\` and `|` escaped, so a value holding the separator cannot
        // read as two.
        case .string(let text):
            return "s:" + text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "|", with: "\\|")
        case .int64(let number): return "i:\(number)"
        case .double(let number): return "r:\(number)"
        case .blob(let data):
            return "b:" + SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// The first twelve hex digits of a column's SHA-256, or ∅ for NULL.
    private static func digest(_ row: Row, _ column: String) -> String {
        guard let text: String = row[column] else { return "∅" }
        return SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: What they compiled to before the work began

    static let fullExample: [String] = [
        "book s:EXC_Matt:40|s:EXC_Matt|i:40|s:Example Commentary|s:EXC|s:Matthew|∅|s:An Example Author|∅|∅|∅|bccd65049ea9|∅|∅",
        "unit s:EXC_Matt:40:section:1:0|s:EXC_Matt|i:40|i:1|i:40001001|i:40004011|s:section|i:1|∅|s:The Coming of the Messiah|∅|i:0|∅|∅|∅|∅|e057a3083cf5|e3b0c44298fc",
        "unit s:EXC_Matt:40:section:1:1|s:EXC_Matt|i:40|i:1|i:40001001|i:40001017|s:section|i:2|s:EXC_Matt:40:section:1:0|s:Where Jesus Comes From|∅|i:1|∅|∅|∅|∅|387ad8cb4aad|e3b0c44298fc",
        "unit s:EXC_Matt:40:pericope:1:2|s:EXC_Matt|i:40|i:1|i:40001001|i:40001017|s:pericope|i:1|s:EXC_Matt:40:section:1:1|s:The Genealogy of Jesus|∅|i:2|∅|c7c042673225|∅|fbd310c17892|c42e78cf16c9|a54f7afb5b52",
        "unit s:EXC_Matt:40:verse:1:3:40001001|s:EXC_Matt|i:40|i:1|i:40001001|∅|s:verse|i:1|s:EXC_Matt:40:pericope:1:2|∅|∅|i:3|∅|∅|a9e7601f4406|fbd310c17892|e683c8dcdfbe|a54f7afb5b52",
        "unit s:EXC_Matt:40:verse:1:4:40001002a|s:EXC_Matt|i:40|i:1|i:40001002|i:40001006|s:verse|i:1|s:EXC_Matt:40:pericope:1:2|∅|s:a|i:4|∅|∅|fd577326b073|fbd310c17892|9fef31d5ca9d|a54f7afb5b52",
    ]

    static let frontMatterExample: [String] = [
        "book s:FM_Gen:1|s:FM_Gen|i:1|s:Front Matter Notes|s:FM|s:Notes on Genesis|∅|s:An Author|s:An Editor|s:A Press|i:2001|49ca15ebb961|a1c7b62e22cd|7eb4384df2f2",
        "unit s:FM_Gen:1:section:1:0|s:FM_Gen|i:1|i:1|i:1001001|i:1002003|s:section|i:1|∅|s:Creation|∅|i:0|442b1c9af46a|∅|∅|∅|8dcd24d7e7ec|e3b0c44298fc",
        "unit s:FM_Gen:1:pericope:1:1|s:FM_Gen|i:1|i:1|i:1001001|i:1001031|s:pericope|i:1|s:FM_Gen:1:section:1:0|s:The Six Days|∅|i:1|d05c754ee75b|∅|∅|∅|eb6c2e7cf454|e3b0c44298fc",
        "unit s:FM_Gen:1:verse:1:2:1001001|s:FM_Gen|i:1|i:1|i:1001001|∅|s:verse|i:1|s:FM_Gen:1:pericope:1:1|∅|∅|i:2|∅|∅|fffe5c5f8036|∅|78459739779d|e3b0c44298fc",
    ]

    static let simpleExample: [String] = [
        "book s:Notes_Matt:40|s:Notes_Matt|i:40|s:Simple Study Notes|s:Notes|s:Study Notes on Matthew|∅|∅|∅|∅|∅|∅|∅|∅",
        "unit s:Notes_Matt:40:verse:1:0:40001001|s:Notes_Matt|i:40|i:1|i:40001001|∅|s:verse|i:1|∅|∅|∅|i:0|∅|∅|43ed9a6bfa05|∅|85b65a9794be|e3b0c44298fc",
        "unit s:Notes_Matt:40:verse:1:1:40001002|s:Notes_Matt|i:40|i:1|i:40001002|i:40001006|s:verse|i:1|∅|∅|∅|i:1|∅|∅|21ded7d9c573|∅|a55c142b46f0|e3b0c44298fc",
        "unit s:Notes_Matt:40:verse:1:2:40001016|s:Notes_Matt|i:40|i:1|i:40001016|∅|s:verse|i:1|∅|∅|∅|i:2|∅|∅|323d7f04c11b|∅|70f2c53f31e8|e3b0c44298fc",
    ]
}
