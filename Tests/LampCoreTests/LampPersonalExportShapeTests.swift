import Foundation
import GRDB
@testable import LampCore
import LampModuleKit
import Testing

/// The files the reader's own content leaves a device in, held to what core
/// declares for them.
///
/// **Two writers produce each of these files** — core's, for the Mac, and
/// the phone's own — and a column one writes and the other does not is a
/// note's pictures arriving on one device and not the other, which is what
/// happened. ios-56 pins the phone's exporters against the same
/// declarations; this is the half on this side.
///
/// Not `LampModuleCompiledSchema.tables(for:)`, which is what a *compiler*
/// writes. A kind can have both and they differ.
struct LampPersonalExportShapeTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-export-shape-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    /// Exports `module` and returns the tables it actually wrote.
    private func exportedTables(
        of module: LampPersonalModule, from library: LampLibrary, in root: URL
    ) async throws -> [String: Set<String>] {
        let file = root.appendingPathComponent("\(module.id).lamp")
        try await library.exportPersonalModule(module, format: .lamp, to: file)
        let body = try (Data(contentsOf: file) as NSData).decompressed(using: .zlib) as Data
        let databaseURL = root.appendingPathComponent("\(module.id).sqlite")
        try body.write(to: databaseURL)
        let queue = try DatabaseQueue(path: databaseURL.path)
        defer { try? queue.close() }
        return try await queue.read { db in
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                """)
            return Dictionary(uniqueKeysWithValues: try tables.map { table in
                (table, Set(try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
                    .compactMap { $0["name"] as String? }))
            })
        }
    }

    @Test(arguments: [LampPersonalModule.notes, .writing, .highlights])
    func theExportedFileIsTheShapeDeclared(module: LampPersonalModule) async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root)

        // Something of each kind, so every declared table has a row and the
        // export is not empty.
        _ = try await library.setPersonalVerseNote(
            reference: 43_011_035, content: "He wept.",
            mediaJSON: #"[{"id":"8A1F","type":"image","filename":"tomb.png","mimeType":"image/png"}]"#
        )
        _ = try await library.savePersonalDevotional(LampDevotional(
            id: "w-1", moduleID: "personal-devotionals", moduleName: "My Writing",
            title: "A Writing", content: "Text."
        ))
        // The default set, made by the highlight rather than by hand: its
        // id holds a colon, which the identifier rule refuses from a caller.
        let highlight = try await library.saveVerseHighlight(
            translationID: "KJV", reference: 43_003_016,
            startOffset: 0, endOffset: 5, color: "#ffcc00"
        )
        _ = try await library.saveHighlightTheme(LampHighlightTheme(
            setID: highlight.setID, color: "FFCC00", style: .highlight, name: "Promises"
        ))

        let written = try await exportedTables(of: module, from: library, in: root)
        for shape in LampPersonalExportSchema.exportedTables(for: module) {
            let actual = try #require(
                written[shape.table],
                "\(module.id) exports no \(shape.table), which it declares"
            )
            #expect(
                actual == Set(shape.columns),
                """
                \(module.id)/\(shape.table): declared \(Set(shape.columns).sorted()) \
                but the export writes \(actual.sorted()). Both writers of this file have \
                to agree, so a column added here must be declared and added on the phone.
                """
            )
        }
    }
}
