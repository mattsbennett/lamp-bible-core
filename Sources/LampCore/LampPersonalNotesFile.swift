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
    public static func write(_ notes: [LampVerseNote], into db: Database) throws {
        try db.execute(sql: """
            INSERT INTO module_meta (id, name, version, is_editable)
            VALUES (?, ?, ?, 1)
            """, arguments: [
                LampPersonalModule.notes.id,
                LampPersonalModule.notes.name,
                LampModuleCompiler.formatVersion,
            ])
        for note in notes {
            try write(note, into: db)
        }
    }

    /// One note's row, which is the unit the two apps have to agree on.
    public static func write(_ note: LampVerseNote, into db: Database) throws {
        let components = LampBibleReferenceFormatter.components(of: note.reference)
        let footnotes = note.footnotes.map { footnote -> [String: String] in
            var value = ["id": footnote.id, "content": footnote.content]
            if let kind = footnote.kind { value["type"] = kind }
            return value
        }
        try db.execute(sql: """
            INSERT INTO note_entries (
                id, module_id, verse_id, book, chapter, verse, title, content,
                verse_refs_json, last_modified, footnotes_json, search_text,
                record_change_tag, media_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?)
            """, arguments: [
                note.id,
                LampPersonalModule.notes.id,
                note.reference,
                components.book,
                components.chapter,
                components.verse,
                note.title,
                note.content,
                try jsonFragment(note.verseReferences),
                Int(note.lastModified.timeIntervalSince1970),
                try jsonFragment(footnotes),
                searchText(for: note),
                // Without this the file that syncs says a note has a
                // picture — its text holds `media/<id>` — and nothing says
                // which file that is. The other device then had no way to
                // ask for it, so a note's pictures only ever showed on the
                // device they were attached on (found by ios-56).
                note.mediaJSON,
            ])
    }

    /// What a search of the file matches on.
    public static func searchText(for note: LampVerseNote) -> String {
        [note.title, note.content].compactMap { $0 }.joined(separator: " ")
    }

    /// JSON written the one way, since the bytes are compared across
    /// devices: keys sorted, slashes unescaped, a bare value allowed.
    ///
    /// Two apps spelling the same record differently is not a cosmetic
    /// difference here — it is each of them deciding the other's file is new
    /// and uploading its own in reply.
    public static func jsonFragment(_ value: Any?) throws -> String? {
        guard let value else { return nil }
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }
}
