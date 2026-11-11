import Foundation
import LampModuleKit

/// What the reader's own content is written as when it leaves a device.
///
/// Kept apart from `LampModuleCompiledSchema.tables(for:)`, which describes
/// what a *compiler* writes. A kind can have both and they differ: a notes
/// module someone authored is compiled by `NotesModuleCompiler`, while your
/// own notes are written by `LampLibrary.createPersonalNotesDatabase`.
/// Conflating the two is a mistake I made and undid; keeping them in
/// separate types is what stops it happening again.
public enum LampPersonalExportSchema {
    public static func exportedTables(for module: LampPersonalModule) -> [LampModuleTableShape] {
        switch module {
        case .notes: [
            LampModuleTableShape(
                table: "note_entries",
                columns: [
                    "id", "module_id", "verse_id", "book", "chapter", "verse",
                    "title", "content", "verse_refs_json", "last_modified",
                    "footnotes_json", "search_text", "record_change_tag", "media_json",
                ],
                // A file written before notes carried media has no column,
                // and that is not an empty list: the reader keeps its own.
                mayBeAbsent: ["media_json"],
                mayBeNull: [
                    "title", "verse_refs_json", "footnotes_json",
                    "record_change_tag", "media_json",
                ]
            ),
        ]

        case .writing: [
            LampModuleTableShape(
                table: "devotional_entries",
                columns: [
                    "id", "module_id", "title", "subtitle", "author", "date",
                    "tags", "category", "series_id", "series_name", "series_order",
                    "key_scriptures_json", "summary_json", "content_json",
                    "footnotes_json", "related_ids", "created", "last_modified",
                    "search_text", "record_change_tag", "subscription_id",
                    "is_read_only", "media_json",
                ],
                mayBeAbsent: ["media_json", "subscription_id", "is_read_only"],
                mayBeNull: [
                    "subtitle", "author", "date", "tags", "category", "series_id",
                    "series_name", "series_order", "key_scriptures_json",
                    "summary_json", "footnotes_json", "related_ids", "last_modified",
                    "search_text", "record_change_tag", "subscription_id",
                    "is_read_only", "media_json",
                ]
            ),
        ]

        // **The whole library's highlights in one file, which is *not* what
        // syncs.** `exportPersonalModule(.highlights)` writes this, for a
        // manual export or a backup. A sync publishes one set per file and
        // compiles it (`exportHighlights` on the Mac, through
        // `LampModuleCompiler`), so that file is the compiled shape —
        // `LampModuleCompiledSchema.tables(for: .highlights)` — with
        // `highlight_meta` and no `set_id`, the set's identity being the
        // module's. Notes and writings have no such split: their sync file
        // is this file. Spotted by ios-56 when its pin would not fit.
        case .highlights: [
            LampModuleTableShape(
                table: "highlight_sets",
                columns: [
                    "id", "name", "description", "translation_id",
                    "created", "last_modified",
                ],
                mayBeNull: ["description"]
            ),
            LampModuleTableShape(
                table: "highlights",
                columns: ["id", "set_id", "ref", "sc", "ec", "style", "color"],
                mayBeNull: ["color"]
            ),
            LampModuleTableShape(
                table: "highlight_themes",
                columns: ["set_id", "color", "style", "name", "description"],
                mayBeNull: ["description"]
            ),
        ]
        }
    }
    }
