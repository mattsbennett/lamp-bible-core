import Foundation
import GRDB
import LampModuleKit

/// The file the reader's own notes travel in, written from records alone.
///
/// The first of the three personal kinds to be moved here. Until now each
/// app wrote this file itself — this one from `LampLibrary`, the phone from
/// `exportNoteModuleToSQLite` — against a shape neither could see the other
/// keeping. That is how a note's pictures came to be missing from the file
/// that syncs: the column was absent from *both* writers, and a pin only
/// helps once somebody has declared the thing.
///
/// Records in, a file out, and nothing of a library in between, so the Mac
/// and the phone can hand it the notes they each hold and get the same
/// bytes. Determinism is the point rather than a nicety: a file whose bytes
/// depend on which device wrote it is re-uploaded by the other device on
/// every pass, for ever.
///
/// What it writes is pinned by `LampPersonalExportShapeTests` against
/// `LampPersonalExportSchema.exportedTables(for: .notes)`.
public enum LampPersonalNotesFile {
    /// The tables as this writes them. Column order is part of the file, so
    /// this text is the declaration rather than a description of one.
    public static let schema = """
        CREATE TABLE note_entries (
            id TEXT PRIMARY KEY, module_id TEXT NOT NULL, verse_id INTEGER NOT NULL,
            book INTEGER NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL,
            title TEXT, content TEXT NOT NULL, verse_refs_json TEXT,
            last_modified INTEGER, footnotes_json TEXT, search_text TEXT,
            record_change_tag TEXT, media_json TEXT
        );
        CREATE INDEX idx_note_module ON note_entries(module_id);
        CREATE INDEX idx_note_verse ON note_entries(verse_id);
        CREATE INDEX idx_note_chapter ON note_entries(book, chapter, verse);
        """

    /// Writes the metadata row and one row per note.
    ///
    /// The notes are written in the order given: a caller that wants the
    /// same bytes twice hands them over in the same order twice. The Mac
    /// reads them `ORDER BY book, chapter, verse, last_modified, id`, which
    /// a second device can sort by without having read anything.
    /// The whole published file, compressed, under the name it travels as.
    ///
    /// `moduleID` is the reader's collection on the server (`notes` /
    /// `devotionals`), the local backup's name (`personal-notes` /
    /// `personal-writing`), or a module of the reader's own making. Writing
    /// it in from the start is what lets a file be published without being
    /// decompressed, rewritten and compressed again afterwards.
    ///
    /// `description` goes with it, and travels for the same reason: a
    /// reader-made module's description was staying on the device that set
    /// it, because this wrote `module_meta` without the column.
    ///
    /// `name` goes with it, and defaults apart from it on purpose. A
    /// receiving app takes `module_meta.name` as what to call the module, so
    /// a file published under its own id and the collection's *name* would
    /// show the reader every module of their own making renamed "My Notes"
    /// on their other device. Caught by ios-56 while adopting this.
    public static func archive(
        _ notes: [LampVerseNote],
        moduleID: String = LampPersonalModule.notes.id,
        name: String = LampPersonalModule.notes.name,
        description: String? = nil,
        author: String? = nil,
        version: String? = nil,
        fileManager: FileManager = .default
    ) throws -> Data {
        try LampPersonalFile.archive(
            kind: LampPersonalModule.notes.kind,
            moduleID: moduleID,
            schema: """
                \(LampPersonalFile.metaSchema)
                \(schema)
                """,
            fileManager: fileManager
        ) { db in
            try write(
                notes, moduleID: moduleID, name: name,
                description: description, author: author, version: version, into: db
            )
        }
    }

    /// The whole published file from rows, for an app whose notes this
    /// app's model cannot hold.
    ///
    /// One entry point rather than a container and a row writer a second
    /// app composes itself, for the same reason as writings: core's code in
    /// that app's sequence drifts the first time a step is added here.
    public static func archive(
        rows: [Row],
        moduleID: String = LampPersonalModule.notes.id,
        name: String = LampPersonalModule.notes.name,
        description: String? = nil,
        author: String? = nil,
        version: String? = nil,
        fileManager: FileManager = .default
    ) throws -> Data {
        try LampPersonalFile.archive(
            kind: LampPersonalModule.notes.kind,
            moduleID: moduleID,
            schema: """
                \(LampPersonalFile.metaSchema)
                \(schema)
                """,
            fileManager: fileManager
        ) { db in
            try writeMetadata(moduleID: moduleID, name: name, description: description, author: author, version: version, into: db)
            for row in rows { try write(row, into: db) }
        }
    }

    public static func write(
        _ notes: [LampVerseNote],
        moduleID: String = LampPersonalModule.notes.id,
        name: String = LampPersonalModule.notes.name,
        description: String? = nil,
        author: String? = nil,
        version: String? = nil,
        into db: Database
    ) throws {
        try writeMetadata(moduleID: moduleID, name: name, description: description, author: author, version: version, into: db)
        for note in notes {
            try write(note, moduleID: moduleID, into: db)
        }
    }

    /// One row of the file, as stored values.
    ///
    /// The unit the two apps agree on is **the row**, not either app's
    /// model of a note. `LampVerseNote` flattens a footnote to plain text,
    /// so a note whose footnote carries scripture links or Strong's
    /// annotations lost them on the way through — the phone's annotations
    /// reached the file as text and never came back. Writings learned this
    /// first; notes should have learned it at the same time rather than
    /// waiting for the second instance.
    public struct Row: Sendable {
        public var id: String
        public var moduleID: String
        public var reference: Int
        public var title: String?
        public var content: String
        /// JSON written as JSON, verbatim — this writes what it is given.
        public var verseReferencesJSON: String?
        public var footnotesJSON: String?
        public var mediaJSON: String?
        /// Seconds.
        public var lastModified: Int?
        public var recordChangeTag: String?

        public init(
            id: String,
            moduleID: String,
            reference: Int,
            title: String? = nil,
            content: String,
            verseReferencesJSON: String? = nil,
            footnotesJSON: String? = nil,
            mediaJSON: String? = nil,
            lastModified: Int? = nil,
            recordChangeTag: String? = nil
        ) {
            self.id = id
            self.moduleID = moduleID
            self.reference = reference
            self.title = title
            self.content = content
            self.verseReferencesJSON = verseReferencesJSON
            self.footnotesJSON = footnotesJSON
            self.mediaJSON = mediaJSON
            self.lastModified = lastModified
            self.recordChangeTag = recordChangeTag
        }
    }

    /// Writes a row exactly as given, except `search_text`, which is
    /// derived here so that no sender can disagree about it.
    public static func write(_ row: Row, into db: Database) throws {
        let components = LampBibleReferenceFormatter.components(of: row.reference)
        try db.execute(sql: """
            INSERT INTO note_entries (
                id, module_id, verse_id, book, chapter, verse, title, content,
                verse_refs_json, last_modified, footnotes_json, search_text,
                record_change_tag, media_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                row.id,
                row.moduleID,
                row.reference,
                components.book,
                components.chapter,
                components.verse,
                row.title,
                row.content,
                row.verseReferencesJSON,
                row.lastModified,
                row.footnotesJSON,
                LampPersonalFile.searchText([
                    row.title,
                    row.content,
                    // A note's footnotes are searchable, which they were
                    // not here before: the phone searched them and this app
                    // did not, so the same note was findable on one device
                    // and not the other.
                    LampPersonalFile.searchableText(in: row.footnotesJSON),
                ]),
                row.recordChangeTag,
                row.mediaJSON,
            ])
    }

    /// This app's note as a row of the file.
    public static func row(
        for note: LampVerseNote,
        moduleID: String = LampPersonalModule.notes.id
    ) throws -> Row {
        let footnotes = note.footnotes.map { footnote -> [String: String] in
            var value = ["id": footnote.id, "content": footnote.content]
            if let kind = footnote.kind { value["type"] = kind }
            return value
        }
        return Row(
            id: note.id,
            moduleID: moduleID,
            reference: note.reference,
            title: note.title,
            content: note.content,
            verseReferencesJSON: try LampPersonalFile.jsonFragment(note.verseReferences),
            footnotesJSON: try LampPersonalFile.jsonFragment(footnotes),
            mediaJSON: note.mediaJSON,
            lastModified: Int(note.lastModified.timeIntervalSince1970),
            recordChangeTag: nil
        )
    }

    /// One note, through the row above.
    public static func write(
        _ note: LampVerseNote,
        moduleID: String = LampPersonalModule.notes.id,
        into db: Database
    ) throws {
        try write(try row(for: note, moduleID: moduleID), into: db)
    }

    /// The one metadata row, which every way of writing this file shares.
    public static func writeMetadata(
        moduleID: String = LampPersonalModule.notes.id,
        name: String = LampPersonalModule.notes.name,
        description: String? = nil,
        author: String? = nil,
        version: String? = nil,
        into db: Database
    ) throws {
        try db.execute(sql: """
            INSERT INTO module_meta (id, name, description, author, version, is_editable)
            VALUES (?, ?, ?, ?, ?, 1)
            """, arguments: [
                moduleID,
                name,
                description,
                author,
                // A module of the reader's own making carries the version
                // they gave it; the collection has none of its own and
                // takes the format's, as it always did.
                version ?? LampModuleCompiler.formatVersion,
            ])
    }

    /// What a search of the file matches on.
    public static func searchText(for note: LampVerseNote) -> String {
        [note.title, note.content].compactMap { $0 }.joined(separator: " ")
    }
}
