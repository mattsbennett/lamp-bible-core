import CryptoKit
import Foundation
import GRDB
import Testing
@testable import LampModuleKit

/// A commentary series compiled in core: what the modules repository's
/// Python wrote, now written once, beside every single volume.
///
/// The two-volume fixture below was compiled by both writers and compared row
/// by row before this file was written (Documentation/RichModulesPlan.md,
/// step 2): every table, column and row matched but for three things that
/// were the Python port having fallen behind core's builder — verse and
/// chapter-introduction IDs, a pericope's undeclared `commentary`, and search
/// text joined by newlines rather than spaces. What core writes is pinned
/// here, as `CommentaryCompiledShapeTests` pins a volume.
struct CommentarySeriesCompilerTests {
    static let series = #"""
    {"meta": {"schemaVersion": "1.0", "id": "TWO", "type": "commentary-series", "name": "Two Volume Notes", "abbreviation": "TWO", "description": "A test series", "editor": "An Editor", "publisher": "A Press", "testament": "OT", "language": "en"}, "editorPreface": "The editor's preface.", "introduction": {"text": "An introduction to the series."}, "abbreviations": [{"abbrev": "LXX", "expansion": "Septuagint"}], "bibliography": [{"subsection": "General", "content": {"text": "A book."}}], "volumes": [{"id": "TWO_Exod", "book": "Exod", "bookNumber": 2, "title": "Exodus"}, {"id": "TWO_Gen", "book": "Gen", "bookNumber": 1, "title": "Genesis", "year": 2001}]}
    """#
    static let genesis = #"""
    {"meta": {"schemaVersion": "2.2", "id": "TWO_Gen", "type": "commentary", "seriesAbbrev": "TWO", "seriesFull": "Two Volume Notes", "title": "Notes on Genesis", "author": "An Author", "editor": "An Editor", "publisher": "A Press", "year": 2001}, "book": "Gen", "bookNumber": 1, "abbreviations": [{"abbrev": "MT", "expansion": "Masoretic Text"}], "frontMatter": {"dedication": "For the reader.", "introduction": {"text": "Genesis opens the canon; see Exodus 1:1.", "annotations": [{"type": "scripture", "start": 28, "end": 38, "data": {"sv": 2001001}}]}}, "chapters": [{"chapter": 1, "introduction": {"text": "The first chapter."}, "sections": [{"id": "creation", "title": "Creation", "introduction": {"text": "The heavens and the earth."}, "sv": 1001001, "ev": 1002003, "level": 1, "subsections": [{"id": "days", "title": "The Days", "sv": 1001001, "ev": 1001031, "pericopae": [{"id": "six", "title": "Six Days", "sv": 1001001, "ev": 1001031, "introduction": {"text": "Six days, and a seventh."}, "translation": {"text": "In the beginning God created."}, "verses": [{"sv": 1001001, "commentary": {"text": "In the beginning, God.", "annotations": [{"type": "italic", "start": 0, "end": 16}], "footnote_refs": [{"id": "1", "offset": 21}]}}, {"sv": 1001002, "ev": 1001005, "suffix": "a", "commentary": {"text": "Formless and void."}}]}]}]}], "verses": [{"sv": 1001026, "commentary": {"text": "Image and likeness."}, "footnotes": [{"id": "2", "content": {"text": "A verse note."}}]}]}, {"chapter": 2, "pericopae": [{"id": "rest", "title": "Rest", "sv": 1002001, "ev": 1002003, "commentary": {"text": "The seventh day."}}]}], "footnotes": [{"id": "1", "content": {"text": "A footnote on God."}}], "indices": {"subjects": {"creation": ["1:1"]}}}
    """#
    static let exodus = #"""
    {"meta": {"schemaVersion": "2.2", "id": "TWO_Exod", "type": "commentary", "seriesAbbrev": "TWO", "seriesFull": "Two Volume Notes", "title": "Exodus"}, "book": "Exod", "bookNumber": 2, "extraction": {"sourceTracked": true}, "footnotes": [{"id": "a", "label": "a", "content": {"text": "Scoped note"}}, {"id": "b", "label": "b", "content": {"text": "Unplaced note"}}], "chapters": [{"chapter": 1, "pericopae": [{"id": "names", "sourceOrder": 20, "title": "The Names", "sv": 2001001, "ev": 2002003, "footnoteIds": ["a", "b"], "content": [{"type": "heading", "source": {"volumeId": "TWO_Exod", "sourceFile": "exod.txt", "lineStart": 1, "lineEnd": 1}, "content": {"text": "The Sons of Israel"}}, {"type": "commentary", "sv": 2001003, "ev": 2001005, "source": {"volumeId": "TWO_Exod", "sourceFile": "exod.txt", "lineStart": 2, "lineEnd": 2}, "content": {"text": "Names, and the house of Jacob.", "footnote_refs": [{"id": "a", "offset": 5}]}}, {"type": "translation", "source": {"volumeId": "TWO_Exod", "sourceFile": "exod.txt", "lineStart": 3, "lineEnd": 3}, "content": {"text": "These are the names."}}, {"type": "commentary", "sv": 2002001, "source": {"volumeId": "TWO_Exod", "sourceFile": "exod.txt", "lineStart": 4, "lineEnd": 4}, "content": {"text": "A man of the house of Levi."}}]}]}, {"chapter": 2, "pericopae": [{"id": "birth", "sourceOrder": 10, "title": "Birth", "sv": 2002004, "content": [{"type": "commentary", "sv": 2002008, "source": {"volumeId": "TWO_Exod", "sourceFile": "exod.txt", "lineStart": 5, "lineEnd": 5}, "content": {"text": "The maid went."}}]}]}]}
    """#

    /// A folder holding the series file and its volumes, each named for its ID.
    private func fixture(
        series: String = Self.series, volumes: [String: String] = ["TWO_Gen": Self.genesis, "TWO_Exod": Self.exodus],
        others: [String: String] = [:]
    ) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-series-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("volumes"), withIntermediateDirectories: true
        )
        try Data(series.utf8).write(to: folder.appendingPathComponent("series.json"))
        for (id, text) in volumes {
            try Data(text.utf8).write(to: folder.appendingPathComponent("volumes/\(id).json"))
        }
        for (path, text) in others {
            let url = folder.appendingPathComponent("volumes/\(path)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return folder
    }

    private func compile(_ folder: URL) throws -> ModuleCompilationResult {
        try LampModuleCompiler().compileSeries(
            seriesURL: folder.appendingPathComponent("series.json"),
            volumesDirectory: folder.appendingPathComponent("volumes", isDirectory: true)
        )
    }

    @Test func aseriesCompilesToTheRowsThePythonWriterHeldItTo() throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try compile(folder)
        #expect(result.moduleID == "TWO")
        #expect(result.outputURL.lastPathComponent == "TWO.lamp")
        #expect(result.tableCounts == ["series_meta": 1, "commentary_books": 2, "commentary_units": 15])

        let compressed = try Data(contentsOf: result.outputURL)
        // A series passes the check an app makes before it installs a file.
        _ = try LampPortableModuleInspector.inspect(compressedData: compressed, requireImportSchema: true)
        let database = folder.appendingPathComponent("TWO.sqlite")
        try ((compressed as NSData).decompressed(using: .zlib) as Data).write(to: database)
        let rows = try DatabaseQueue(path: database.path).read { db in
            try Self.rows(db, "module_format", key: "module_id")
                + Self.rows(db, "series_meta", key: "id")
                + Self.rows(db, "commentary_books", key: "id")
                + Self.rows(db, "commentary_units", key: "rowid")
        }
        #expect(rows == Self.expected, "compiled:\n\(rows.map { "\"\($0)\"," }.joined(separator: "\n"))")
    }

    /// A series file's tables are a volume's, less what names its module —
    /// a unit's `module_id`; a book's `module_id`, series names and
    /// description, which the Python writer never stored — so a column
    /// added to one file is added to both, or this fails. Each column as
    /// declared: name, type, constraint, default, in order.
    @Test func aseriesHoldsAVolumesColumnsLessItsModules() throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try compile(folder)
        let seriesDatabase = folder.appendingPathComponent("TWO.sqlite")
        try ((Data(contentsOf: result.outputURL) as NSData).decompressed(using: .zlib) as Data).write(to: seriesDatabase)
        let volumeURL = folder.appendingPathComponent("TWO_Gen.lamp")
        _ = try LampModuleCompiler().compile(
            data: Data(Self.genesis.utf8), sourceFilename: "TWO_Gen.json", destinationURL: volumeURL
        )
        let volumeDatabase = folder.appendingPathComponent("TWO_Gen.sqlite")
        try ((Data(contentsOf: volumeURL) as NSData).decompressed(using: .zlib) as Data).write(to: volumeDatabase)

        func columns(_ url: URL, _ table: String) throws -> [String] {
            try DatabaseQueue(path: url.path).read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { row in
                    let name: String = row["name"], type: String = row["type"]
                    let notNull: Int = row["notnull"], primary: Int = row["pk"]
                    let fallback: String? = row["dflt_value"]
                    return "\(name) \(type) \(notNull) \(primary) \(fallback ?? "-")"
                }
            }
        }
        let named: [String: Set<String>] = [
            "commentary_units": ["module_id"],
            "commentary_books": ["module_id", "series_full", "series_abbrev", "description"],
        ]
        for (table, modules) in named {
            let volume = try columns(volumeDatabase, table)
            let series = try columns(seriesDatabase, table)
            #expect(!volume.isEmpty)
            #expect(series == volume.filter { !modules.contains(String($0.prefix { $0 != " " })) }, "\(table)")
        }
    }

    @Test func avolumeTheSeriesListsMustBeThere() throws {
        let folder = try fixture(volumes: ["TWO_Gen": Self.genesis])
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: ModuleCompilationError.self) { try compile(folder) }
    }

    @Test func twoVolumesCannotBeOneBook() throws {
        let folder = try fixture(volumes: [
            "TWO_Gen": Self.genesis,
            "TWO_Exod": Self.genesis.replacingOccurrences(of: #""id": "TWO_Gen""#, with: #""id": "TWO_Exod""#),
        ])
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: ModuleCompilationError.self) { try compile(folder) }
    }

    @Test func aseriesFileMustSayItIsOne() throws {
        let folder = try fixture(series: Self.series.replacingOccurrences(of: "commentary-series", with: "commentary"))
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: ModuleCompilationError.self) { try compile(folder) }
    }

    /// A volume in a version this build does not read is refused, so a note
    /// given only as 2.3 blocks is never compiled to an empty unit.
    @Test func avolumeInAnUnreadVersionIsRefused() throws {
        let folder = try fixture(volumes: [
            "TWO_Gen": Self.genesis.replacingOccurrences(of: #""schemaVersion": "2.2""#, with: #""schemaVersion": "2.3""#),
            "TWO_Exod": Self.exodus,
        ])
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: ModuleCompilationError.self) { try compile(folder) }
    }

    /// A volume ID names a file in the folder, and never one outside it.
    @Test func avolumeIDCannotLeaveTheFolder() throws {
        let folder = try fixture(series: Self.series.replacingOccurrences(of: #""id": "TWO_Exod""#, with: #""id": "../TWO_Exod""#))
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: ModuleCompilationError.self) { try compile(folder) }
    }

    /// A series that lists no volumes takes every commentary volume in the
    /// folder, as the cross-reference series are written. Found by Codex.
    @Test func aseriesListingNoVolumesTakesTheFolders() throws {
        let unlisted = Self.series.replacing(#/"volumes": \[.*\]\}$/#, with: #""volumes": []}"#)
        #expect(unlisted != Self.series)
        let folder = try fixture(series: unlisted)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try compile(folder).tableCounts["commentary_books"] == 2)
    }

    /// A list that names no files describes the printed volumes, and the
    /// folder's volumes are built: NIC lists Hamilton's Genesis as two
    /// volumes, kept in one file.
    @Test func alistWithoutIDsDescribesThePrintedVolumes() throws {
        let described = Self.series
            .replacingOccurrences(of: #""id": "TWO_Gen", "#, with: "")
            .replacingOccurrences(of: #""id": "TWO_Exod", "#, with: "")
            .replacingOccurrences(
                of: #"{"book": "Gen", "bookNumber": 1, "title": "Genesis""#,
                with: #"{"book": "Gen", "bookNumber": 1, "title": "Gen 1-17"}, {"book": "Gen", "bookNumber": 1, "title": "Genesis""#
            )
        #expect(described.components(separatedBy: #""bookNumber": 1"#).count == 3)
        #expect(!described.contains(#""id": "TWO_Gen""#) && !described.contains(#""id": "TWO_Exod""#))
        let folder = try fixture(series: described)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try compile(folder).tableCounts["commentary_books"] == 2)
    }

    /// A file swapped for another book's is refused: the series would list
    /// one book and hold another. Found by Codex.
    @Test func avolumeMustBeForTheBookItsEntryNames() throws {
        let folder = try fixture(series: Self.series.replacingOccurrences(
            of: #""id": "TWO_Exod", "book": "Exod", "bookNumber": 2"#,
            with: #""id": "TWO_Exod", "book": "Lev", "bookNumber": 3"#
        ))
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: ModuleCompilationError.self) { try compile(folder) }
    }

    /// A series manifest in a version this build does not read is refused.
    @Test func aseriesInAnUnreadVersionIsRefused() throws {
        let folder = try fixture(series: Self.series.replacingOccurrences(
            of: #""schemaVersion": "1.0", "id": "TWO""#, with: #""schemaVersion": "2.0", "id": "TWO""#
        ))
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: ModuleCompilationError.self) { try compile(folder) }
    }

    /// A volume that gives a name in place of a title keeps it, as it would
    /// compiled alone. Found by Codex.
    @Test func avolumesNameStandsInForItsTitle() throws {
        let folder = try fixture(volumes: [
            "TWO_Gen": Self.genesis,
            "TWO_Exod": Self.exodus.replacingOccurrences(of: #""title": "Exodus"}"#, with: #""name": "Notes on Exodus"}"#),
        ])
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try compile(folder)
        let database = folder.appendingPathComponent("named.sqlite")
        try ((Data(contentsOf: result.outputURL) as NSData).decompressed(using: .zlib) as Data).write(to: database)
        let title = try DatabaseQueue(path: database.path).read { db in
            try String.fetchOne(db, sql: "SELECT title FROM commentary_books WHERE book_number = 2")
        }
        #expect(title == "Notes on Exodus")
    }

    /// A list naming some volumes and not others is refused: building only
    /// the named ones published a series without the rest. Found by Codex.
    @Test func alistNamingOnlySomeVolumesIsRefused() throws {
        let folder = try fixture(series: Self.series.replacingOccurrences(of: #""id": "TWO_Exod", "#, with: ""))
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: ModuleCompilationError.self) { try compile(folder) }
    }

    /// A named volume is read where it is named: other JSON in the folder,
    /// and an older copy deeper in it, are no part of the series. Found by
    /// Codex.
    @Test func anamedVolumeIsReadWhereItIsNamed() throws {
        let folder = try fixture(others: [
            "notes.json": "[1, 2, 3]",
            "old/TWO_Gen.json": Self.genesis.replacingOccurrences(of: "Notes on Genesis", with: "A stale copy"),
        ])
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try compile(folder)
        let database = folder.appendingPathComponent("named.sqlite")
        try ((Data(contentsOf: result.outputURL) as NSData).decompressed(using: .zlib) as Data).write(to: database)
        let title = try DatabaseQueue(path: database.path).read { db in
            try String.fetchOne(db, sql: "SELECT title FROM commentary_books WHERE book_number = 1")
        }
        #expect(title == "Notes on Genesis")
    }

    /// Found by searching the folder, a commentary that does not say its book
    /// is an error, not left out of the series without a word. Found by
    /// Codex.
    @Test func afoundVolumeThatSaysNoBookIsAnError() throws {
        let folder = try fixture(
            series: Self.series
                .replacingOccurrences(of: #""id": "TWO_Gen", "#, with: "")
                .replacingOccurrences(of: #""id": "TWO_Exod", "#, with: ""),
            volumes: [
                "TWO_Gen": Self.genesis,
                "TWO_Exod": Self.exodus.replacingOccurrences(of: #""bookNumber": 2, "#, with: ""),
            ]
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: (any Error).self) { try compile(folder) }
    }

    /// A `volumes` that is not a list of objects is refused, not read as no
    /// list at all. Found by Codex.
    @Test func amalformedVolumesListIsRefused() throws {
        for malformed in [
            Self.series.replacing(#/"volumes": \[.*\]\}$/#, with: #""volumes": {"id": "TWO_Gen"}}"#),
            Self.series.replacing(#/"volumes": \[/#, with: #""volumes": ["TWO_Lev", "#),
        ] {
            #expect(malformed != Self.series)
            let folder = try fixture(series: malformed)
            defer { try? FileManager.default.removeItem(at: folder) }
            #expect(throws: ModuleCompilationError.self) { try compile(folder) }
        }
    }

    /// A volume that is a link to a file outside the folder is refused.
    /// Found by Codex.
    @Test func avolumeLinkedFromOutsideTheFolderIsRefused() throws {
        let folder = try fixture(volumes: ["TWO_Gen": Self.genesis])
        defer { try? FileManager.default.removeItem(at: folder) }
        let outside = folder.appendingPathComponent("elsewhere.json")
        try Data(Self.exodus.utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("volumes/TWO_Exod.json"), withDestinationURL: outside
        )
        #expect(throws: ModuleCompilationError.self) { try compile(folder) }
    }

    /// A series whose ID the importer would refuse is refused before it is
    /// built. Found by Codex.
    @Test func aseriesIDTheImporterRefusesIsRefused() throws {
        let folder = try fixture(series: Self.series.replacingOccurrences(
            of: #""id": "TWO", "type""#, with: #""id": "TW\\O", "type""#
        ))
        defer { try? FileManager.default.removeItem(at: folder) }
        // Refused for its ID, before its output's name is ever checked.
        do {
            _ = try LampModuleCompiler().compileSeries(
                seriesURL: folder.appendingPathComponent("series.json"),
                volumesDirectory: folder.appendingPathComponent("volumes", isDirectory: true),
                destinationURL: folder.appendingPathComponent("TWO.lamp")
            )
            Issue.record("built a series the importer cannot read")
        } catch ModuleCompilationError.validationFailed(let issues) {
            #expect(issues.filter { $0.severity == .error }.map(\.path) == ["/meta/id"])
        }
    }

    /// An `id` or `bookNumber` of the wrong type is refused, not read as
    /// absent: an `id` of 123 sent the build to take the whole folder.
    /// Found by Codex.
    @Test func amistypedEntryIsRefused() throws {
        for mistyped in [
            Self.series.replacingOccurrences(of: #""id": "TWO_Gen""#, with: #""id": 123"#)
                .replacingOccurrences(of: #""id": "TWO_Exod""#, with: #""id": 124"#),
            Self.series.replacingOccurrences(of: #""bookNumber": 2"#, with: #""bookNumber": "2""#),
        ] {
            #expect(mistyped != Self.series)
            let folder = try fixture(series: mistyped)
            defer { try? FileManager.default.removeItem(at: folder) }
            #expect(throws: ModuleCompilationError.self) { try compile(folder) }
        }
    }

    /// Found by searching the folder, a volume that is a link to a file inside
    /// it is the series' too. Found by Codex.
    @Test func alinkedVolumeInsideTheFolderIsTaken() throws {
        let folder = try fixture(
            series: Self.series
                .replacingOccurrences(of: #""id": "TWO_Gen", "#, with: "")
                .replacingOccurrences(of: #""id": "TWO_Exod", "#, with: ""),
            volumes: ["TWO_Gen": Self.genesis],
            others: ["kept/exodus-source.json": Self.exodus]
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("volumes/TWO_Exod.json"),
            withDestinationURL: folder.appendingPathComponent("volumes/kept/exodus-source.json")
        )
        // The linked file and the one it names are one volume read twice, so
        // the folder holds two for Exodus: refused, as two files for one book.
        #expect(throws: ModuleCompilationError.self) { try compile(folder) }
        try FileManager.default.removeItem(at: folder.appendingPathComponent("volumes/kept/exodus-source.json"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("volumes/TWO_Exod.json"))
        try Data(Self.exodus.utf8).write(to: folder.appendingPathComponent("volumes/kept/exodus-source.json"))
        try FileManager.default.moveItem(
            at: folder.appendingPathComponent("volumes/kept"), to: folder.appendingPathComponent("volumes/.kept")
        )
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("volumes/TWO_Exod.json"),
            withDestinationURL: folder.appendingPathComponent("volumes/.kept/exodus-source.json")
        )
        // Kept in a hidden folder, which no search reads, the file is found
        // once, through its link.
        #expect(try compile(folder).tableCounts["commentary_books"] == 2)
    }

    /// What a volume is warned about reaches whoever built the series, named
    /// for its file; and a volume that stops the build says which it is.
    /// Found by Codex.
    @Test func avolumesIssuesAreNamedForItsFile() throws {
        let mixed = Self.exodus.replacingOccurrences(of: #""sourceOrder": 10, "#, with: "")
        #expect(mixed != Self.exodus)
        var folder = try fixture(volumes: ["TWO_Gen": Self.genesis, "TWO_Exod": mixed])
        let result = try compile(folder)
        try? FileManager.default.removeItem(at: folder)
        #expect(result.warnings.contains { $0.path.hasPrefix("TWO_Exod.json: ") }, "\(result.warnings)")

        folder = try fixture(volumes: [
            "TWO_Gen": Self.genesis.replacingOccurrences(of: #""schemaVersion": "2.2""#, with: #""schemaVersion": "2.3""#),
            "TWO_Exod": Self.exodus,
        ])
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            _ = try compile(folder)
            Issue.record("built a volume in an unread version")
        } catch {
            #expect(error.localizedDescription.contains("TWO_Gen.json: /meta/schemaVersion"), "\(error.localizedDescription)")
        }
    }

    /// Each malformed manifest is refused before it chooses a file: a null
    /// list or ID, a book number missing, Boolean, fractional or out of
    /// range. Read loosely, each sent the build to the whole folder or let a
    /// file for another book in. Found by Codex.
    @Test func eachMalformedManifestIsRefused() throws {
        let unnamed = Self.series
            .replacingOccurrences(of: #""id": "TWO_Gen", "#, with: "")
            .replacingOccurrences(of: #""id": "TWO_Exod", "#, with: "")
        let cases = [
            Self.series.replacing(#/"volumes": \[.*\]\}$/#, with: #""volumes": null}"#),
            Self.series.replacingOccurrences(of: #""id": "TWO_Gen""#, with: #""id": null"#)
                .replacingOccurrences(of: #""id": "TWO_Exod""#, with: #""id": null"#),
            Self.series.replacingOccurrences(of: #", "bookNumber": 2"#, with: ""),
            Self.series.replacingOccurrences(of: #""bookNumber": 2"#, with: #""bookNumber": true"#),
            Self.series.replacingOccurrences(of: #""bookNumber": 2"#, with: #""bookNumber": 2.5"#),
            unnamed.replacingOccurrences(of: #""bookNumber": 2"#, with: #""bookNumber": 67"#),
            Self.series.replacingOccurrences(of: #""year": 2001"#, with: #""year": "2001""#),
            Self.series.replacingOccurrences(of: #""book": "Exod", "#, with: ""),
            Self.series.replacingOccurrences(of: #""expansion": "Septuagint""#, with: #""expansion": 70"#),
            Self.series.replacingOccurrences(of: #""subsection": "General""#, with: #""subsection": 1"#),
            // Shared lists are checked though the series lists no volumes.
            Self.series.replacing(#/, "volumes": \[.*\]\}$/#, with: "}")
                .replacingOccurrences(of: #""expansion": "Septuagint""#, with: #""expansion": 70"#),
            Self.series.replacingOccurrences(of: #""editor": "An Editor""#, with: #""editor": ["An Editor"]"#),
            Self.series.replacingOccurrences(
                of: #""introduction": {"text": "An introduction to the series."}"#,
                with: #""introduction": {"words": "An introduction to the series."}"#
            ),
        ]
        for (index, manifest) in cases.enumerated() {
            #expect(manifest != Self.series && manifest != unnamed, "case \(index) changed nothing")
            let folder = try fixture(series: manifest)
            defer { try? FileManager.default.removeItem(at: folder) }
            #expect(throws: ModuleCompilationError.self, "case \(index)") { try compile(folder) }
        }
    }

    /// Found by searching the folder, a file that declares another kind is
    /// none of the series', though it carries series fields as a dictionary
    /// may; and a book number written `2.0` is 2. Found by Codex.
    @Test func otherKindsAreLeftAndWholeBookNumbersRead() throws {
        let folder = try fixture(
            series: Self.series
                .replacingOccurrences(of: #""id": "TWO_Gen", "#, with: "")
                .replacingOccurrences(of: #""id": "TWO_Exod", "#, with: "")
                .replacingOccurrences(of: #""bookNumber": 2"#, with: #""bookNumber": 2.0"#)
                .replacingOccurrences(of: #""year": 2001"#, with: #""year": 2.001e3"#),
            volumes: [
                "TWO_Gen": Self.genesis,
                "TWO_Exod": Self.exodus
                    .replacingOccurrences(of: #""bookNumber": 2"#, with: #""bookNumber": 2e0"#)
                    .replacingOccurrences(of: #""type": "commentary""#, with: #""type": "commentary ""#),
            ],
            others: ["wsd_greek.json": #"{"meta": {"schemaVersion": "1.0", "id": "WSD", "type": "dictionary", "name": "Word Studies", "seriesAbbrev": "WSD", "seriesFull": "Word Studies"}, "entries": []}"#]
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try compile(folder).tableCounts["commentary_books"] == 2)
    }

    /// Found by searching the folder, a file that says it is a commentary but
    /// lacks what one must hold is an error, not left out. Found by Codex.
    @Test func adiscoveredVolumeMissingItsChaptersIsAnError() throws {
        let folder = try fixture(
            series: Self.series
                .replacingOccurrences(of: #""id": "TWO_Gen", "#, with: "")
                .replacingOccurrences(of: #""id": "TWO_Exod", "#, with: ""),
            volumes: [
                "TWO_Gen": Self.genesis,
                "TWO_Exod": #"{"meta": {"schemaVersion": "2.2", "seriesAbbrev": "TWO", "seriesFull": "Two Volume Notes", "title": "Exodus"}, "bookNumber": 2}"#,
            ]
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: (any Error).self) { try compile(folder) }
    }

    /// A series ID a Mac will not install still builds, for the phone takes
    /// it, and says so. Found by Codex.
    @Test func aseriesIDAMacRefusesIsAWarning() throws {
        let issues = LampModuleCompiler.seriesManifestIssues(
            try JSONSerialization.jsonObject(with: Data(Self.series.replacingOccurrences(
                of: #""id": "TWO", "type""#, with: #""id": "TW+O", "type""#
            ).utf8)) as! [String: Any]
        )
        #expect(issues.map(\.severity) == [.warning], "\(issues)")
        #expect(issues.first?.path == "/meta/id")
    }

    /// A named volume's file must be the volume it names: one that gives
    /// itself another ID is a different commentary, though for the same book.
    /// Found by Codex.
    @Test func anamedVolumeMustGiveItsOwnID() throws {
        let folder = try fixture(volumes: [
            "TWO_Gen": Self.genesis.replacingOccurrences(of: #""id": "TWO_Gen""#, with: #""id": "OTHER_Gen""#),
            "TWO_Exod": Self.exodus,
        ])
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: ModuleCompilationError.self) { try compile(folder) }
    }

    /// Found by searching the folder, a linked folder is refused, not passed
    /// over with its volumes. Found by Codex.
    @Test func alinkedFolderIsRefused() throws {
        let folder = try fixture(
            series: Self.series
                .replacingOccurrences(of: #""id": "TWO_Gen", "#, with: "")
                .replacingOccurrences(of: #""id": "TWO_Exod", "#, with: ""),
            volumes: ["TWO_Gen": Self.genesis],
            others: [".nt/TWO_Exod.json": Self.exodus]
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("volumes/NT"),
            withDestinationURL: folder.appendingPathComponent("volumes/.nt")
        )
        #expect(throws: ModuleCompilationError.self) { try compile(folder) }
    }

    // MARK: Rows

    static func rows(_ db: Database, _ table: String, key: String) throws -> [String] {
        let columns = try db.columns(in: table).map(\.name)
        return try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY \(key)").map { row in
            "\(table) " + columns.map { column in
                column.hasSuffix("_json") || column.hasSuffix("_text") || column == "search_text"
                    ? digest(row, column) : field(row, column)
            }.joined(separator: "|")
        }
    }

    private static func field(_ row: Row, _ column: String) -> String {
        let value: DatabaseValue = row[column]
        switch value.storage {
        case .null: return "∅"
        case .string(let text):
            return "s:" + text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "|", with: "\\|")
        case .int64(let number): return "i:\(number)"
        case .double(let number): return "r:\(number)"
        case .blob(let data): return "b:\(data.count)"
        }
    }

    private static func digest(_ row: Row, _ column: String) -> String {
        guard let text: String = row[column] else { return "∅" }
        return SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    static let expected: [String] = [
        "module_format s:1.0|s:commentary|s:TWO",
        "series_meta s:TWO|s:Two Volume Notes|s:TWO|s:A test series|s:An Editor|s:A Press|s:OT|s:en|∅|f52a367b53c3|ff636009c987|49ca15ebb961|3ff1e7514f09|39cd88cf4683",
        "commentary_books s:book_1|i:1|s:Notes on Genesis|s:An Author|s:An Editor|s:A Press|i:2001|f2326301ee1f|bc605df25e8a|7eb4384df2f2",
        "commentary_books s:book_2|i:2|s:Exodus|∅|∅|∅|∅|∅|∅|∅",
        "commentary_units s:TWO:1:chapter_intro:1|i:1|i:1|i:1001001|∅|s:section|i:0|∅|s:Chapter 1 Introduction|∅|10cd6ff47261|∅|∅|∅|37ab9060ed42|i:0|e3b0c44298fc",
        "commentary_units s:TWO:1:section:1:1|i:1|i:1|i:1001001|i:1002003|s:section|i:1|∅|s:Creation|∅|b33b6a129469|∅|∅|∅|baf1ee4ce8a6|i:1|e3b0c44298fc",
        "commentary_units s:TWO:1:section:1:2|i:1|i:1|i:1001001|i:1001031|s:section|i:2|s:TWO:1:section:1:1|s:The Days|∅|∅|∅|∅|∅|90726c8b1816|i:2|e3b0c44298fc",
        "commentary_units s:TWO:1:pericope:1:3|i:1|i:1|i:1001001|i:1001031|s:pericope|i:1|s:TWO:1:section:1:2|s:Six Days|∅|d05c754ee75b|f0056835b4ee|∅|∅|4f0b5cbbaca5|i:3|e3b0c44298fc",
        "commentary_units s:TWO:1:verse:1:4:1001001|i:1|i:1|i:1001001|∅|s:verse|i:1|s:TWO:1:pericope:1:3|∅|∅|∅|∅|ce301661ec96|∅|78459739779d|i:4|e3b0c44298fc",
        "commentary_units s:TWO:1:verse:1:5:1001002a|i:1|i:1|i:1001002|i:1001005|s:verse|i:1|s:TWO:1:pericope:1:3|∅|s:a|∅|∅|697334e07414|∅|aaf027c09407|i:5|e3b0c44298fc",
        "commentary_units s:TWO:1:verse:1:6:1001026|i:1|i:1|i:1001026|∅|s:verse|i:1|∅|∅|∅|∅|∅|0e6ef81f7b9b|038c0aa78df2|7503d8620d58|i:6|002bc44d2504",
        "commentary_units s:TWO:1:pericope:2:7|i:1|i:2|i:1002001|i:1002003|s:pericope|i:1|∅|s:Rest|∅|∅|∅|∅|∅|05863ec2c378|i:7|e3b0c44298fc",
        "commentary_units s:TWO:2:pericope:2:0|i:2|i:2|i:2002004|∅|s:pericope|i:1|∅|s:Birth|∅|∅|∅|∅|∅|32eaeb6f806a|i:0|e3b0c44298fc",
        "commentary_units s:TWO:2:verse:2:1|i:2|i:2|i:2002008|∅|s:verse|i:1|s:TWO:2:pericope:2:0|∅|∅|∅|∅|058c5b25ea73|∅|8e4e9747a2af|i:1|e3b0c44298fc",
        "commentary_units s:TWO:2:pericope:1:2|i:2|i:1|i:2001001|i:2002003|s:pericope|i:1|∅|s:The Names|∅|∅|∅|∅|∅|0cca31a9d4ee|i:2|e3b0c44298fc",
        "commentary_units s:TWO:2:section:1:3|i:2|i:1|i:2001001|i:2002003|s:section|i:2|s:TWO:2:pericope:1:2|s:The Sons of Israel|∅|∅|∅|∅|∅|4de370cdca7b|i:3|e3b0c44298fc",
        "commentary_units s:TWO:2:verse:1:4|i:2|i:1|i:2001003|i:2001005|s:verse|i:1|s:TWO:2:pericope:1:2|∅|∅|∅|∅|7476243f7b61|b100a743e8c4|356b51e24b80|i:4|0bb48801fa70",
        "commentary_units s:TWO:2:pericope:1:5|i:2|i:1|i:2001001|i:2002003|s:pericope|i:1|s:TWO:2:pericope:1:2|∅|∅|∅|0deb49236a5b|∅|∅|005b46fe95b4|i:5|e3b0c44298fc",
        "commentary_units s:TWO:2:verse:2:6|i:2|i:2|i:2002001|i:2002003|s:verse|i:1|s:TWO:2:pericope:1:2|∅|∅|∅|∅|c578c3c0f688|∅|216fa606937b|i:6|e3b0c44298fc",
    ]
}
