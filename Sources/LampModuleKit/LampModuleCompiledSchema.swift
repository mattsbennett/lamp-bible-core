import Foundation

/// One table of a compiled module, as a client that copies it column by
/// column has to handle it.
public struct LampModuleTableShape: Sendable, Equatable {
    public let table: String

    /// Every column the compilers write today.
    public let columns: [String]

    /// Columns added after the format was in use, which a module built by an
    /// older Lamp will not have. Copy one only where the source carries it
    /// and the destination can hold it, and never require one, or an older
    /// module stops importing. The iPhone's `copyCompiled` does that for
    /// every kind declared here.
    public let mayBeAbsent: [String]

    /// Columns the compiler leaves NULL when the author supplies only what
    /// the published schema requires.
    ///
    /// **A client's own column must allow NULL.** This is the quiz bug: the
    /// iPhone declared `quiz_modules.questions_per_reading` NOT NULL DEFAULT
    /// 0 and copied the column explicitly, and SQLite does not apply a
    /// DEFAULT to an explicitly inserted NULL, so a quiz whose author left
    /// `questionsPerReading` out rolled the whole import back — on a module
    /// the Mac installs without complaint, because the Mac copies the file
    /// and never names a column.
    public let mayBeNull: [String]

    public init(table: String, columns: [String], mayBeAbsent: [String] = [], mayBeNull: [String] = []) {
        self.table = table
        self.columns = columns
        self.mayBeAbsent = mayBeAbsent
        self.mayBeNull = mayBeNull
    }
}

/// What a compiled module holds, declared per kind, so the two apps stop
/// describing the same shape by hand in three places.
///
/// **Why this exists.** A module's shape is written by the compilers in this
/// module, and read by two importers that could not be less alike: the Mac
/// writes the whole decompressed archive into its library and never names a
/// column, so a new column reaches it for free; the iPhone copies rows into
/// one combined database through SQL that names every column, so a new
/// column reaches it only if someone edits that SQL. Nothing tied the two
/// together, and a Codex review of the interfaces against both import paths
/// (2026-11-11) found a column dropped on the phone, a NULL that failed an
/// import outright, and two fields a whitelist discarded before either app
/// saw them.
///
/// Sharing a list was not enough on its own — `bookModuleColumns` was shared
/// and went stale anyway, because nothing checked it against the compiler
/// that writes the table. So this declaration is **pinned**:
/// `LampModuleCompiledSchemaTests` compiles the smallest valid module of each
/// kind and compares the real tables against what is declared here. A column
/// added to a compiler and declared nowhere fails core's suite, instead of
/// going quietly missing on one app.
///
/// **Not declared here:**
/// - `notes` and `devotional`, whose import reconciles through typed records
///   (`NoteEntry`, `DevotionalEntry`) decoded by name rather than copying
///   columns. Add them if that ever changes.
/// - `search_words` and `search_word_lists`, which each client builds for
///   itself from the text it holds; copying a source's would describe
///   another database's indexes.
/// - `module_format`, written by `createFormatMetadata` for every kind.
public enum LampModuleCompiledSchema {
    public static func tables(for kind: LampModuleKind) -> [LampModuleTableShape] {
        switch kind {
        case .book: [
            LampModuleTableShape(
                table: "book_modules",
                columns: LampPortableModuleInspector.bookModuleColumns
                    + LampPortableModuleInspector.bookModuleOptionalColumns,
                mayBeAbsent: LampPortableModuleInspector.bookModuleOptionalColumns,
                mayBeNull: [
                    "subtitle", "description", "author", "editor", "publisher",
                    "year", "edition", "isbn", "copyright", "license", "version",
                    "tags_json", "cover_media_id", "created", "last_modified",
                    "footnotes_json", "media_json", "genre",
                ]
            ),
            LampModuleTableShape(
                table: "book_sections",
                columns: LampPortableModuleInspector.bookSectionColumns
                    + LampPortableModuleInspector.bookSectionOptionalColumns,
                mayBeAbsent: LampPortableModuleInspector.bookSectionOptionalColumns,
                mayBeNull: ["parent_id", "number", "subtitle", "key_scriptures_json"]
            ),
        ]

        case .commentary: [
            LampModuleTableShape(
                table: "commentary_books",
                columns: [
                    "id", "module_id", "book_number", "series_full", "series_abbrev",
                    "title", "description", "author", "editor", "publisher", "year",
                    "abbreviations_json", "front_matter_json", "indices_json",
                ],
                // Stored from 2026-11-11; a volume built before has none.
                mayBeAbsent: ["description"],
                mayBeNull: [
                    "description", "author", "editor", "publisher", "year",
                    "abbreviations_json", "front_matter_json", "indices_json",
                ]
            ),
            LampModuleTableShape(
                table: "commentary_units",
                columns: [
                    "id", "module_id", "book", "chapter", "sv", "ev", "unit_type",
                    "level", "parent_id", "title", "suffix", "introduction_json",
                    "translation_json", "commentary_json", "footnotes_json",
                    "search_text", "order_index", "footnotes_text",
                ],
                // The commentary's footnotes joined the search indexes in
                // modules a2ea856; a volume built before that has no column.
                mayBeAbsent: ["footnotes_text"],
                mayBeNull: [
                    "ev", "parent_id", "title", "suffix", "introduction_json",
                    "translation_json", "commentary_json", "footnotes_json",
                ]
            ),
        ]

        case .dictionary: [
            LampModuleTableShape(
                table: "module_metadata",
                columns: [
                    "id", "name", "description", "author", "version", "key_type",
                    "schema_version", "type", "series_abbrev", "series_full",
                    "editor", "publisher", "year", "isbn", "language",
                ],
                mayBeNull: [
                    "description", "author", "version", "key_type", "series_abbrev",
                    "series_full", "editor", "publisher", "year", "isbn", "language",
                ]
            ),
            LampModuleTableShape(
                table: "dictionary_entries",
                columns: [
                    "id", "module_id", "key", "lemma", "transliteration",
                    "pronunciation", "senses_json", "metadata_json", "search_text",
                ],
                // senses_json is NULL for an entry with an empty `senses`
                // and no legacy definition fields: JSONSupport.jsonString
                // gives nothing back for an empty array.
                mayBeNull: [
                    "transliteration", "pronunciation", "senses_json", "metadata_json",
                ]
            ),
        ]

        case .translation: [
            LampModuleTableShape(
                table: "translation_meta",
                columns: [
                    "id", "name", "abbreviation", "description", "language",
                    "language_name", "text_direction", "translation_philosophy",
                    "year", "publisher", "copyright", "copyright_year", "license",
                    "source_texts_json", "features_json", "versification",
                    "versification_mappings",
                ],
                // Departures were the bundle's alone until core f5ff285.
                mayBeAbsent: ["versification_mappings"],
                mayBeNull: [
                    "description", "language_name", "translation_philosophy",
                    "year", "publisher", "copyright", "copyright_year", "license",
                    "source_texts_json", "features_json", "versification_mappings",
                ]
            ),
            LampModuleTableShape(
                table: "books",
                columns: ["id", "book_id", "name", "testament", "chapter_count"]
            ),
            LampModuleTableShape(
                table: "verses",
                columns: [
                    "id", "ref", "book", "chapter", "verse", "text",
                    "annotations_json", "footnotes_json", "footnote_refs_json",
                    "paragraph", "poetry_json",
                ],
                // Standalone translations written before modules 8c2a7f6 have
                // no footnote_refs_json, and the iPhone still accommodates
                // those files; requiring it would reject a module that
                // imports today.
                mayBeAbsent: ["footnote_refs_json"],
                mayBeNull: [
                    "annotations_json", "footnotes_json",
                    "footnote_refs_json", "poetry_json",
                ]
            ),
            LampModuleTableShape(
                table: "headings",
                columns: ["id", "book", "chapter", "before_verse", "level", "text"]
            ),
        ]

        case .plan: [
            LampModuleTableShape(
                table: "plans",
                columns: [
                    "id", "name", "description", "author", "full_description",
                    "duration", "readings_per_day", "source", "license",
                ],
                // The source work and its licence, stored from 2026-11-11.
                mayBeAbsent: ["source", "license"],
                // readings_per_day is taken from the first day when the
                // author gives no count, so a plan with no days has none.
                mayBeNull: [
                    "description", "author", "full_description",
                    "readings_per_day", "source", "license",
                ]
            ),
            LampModuleTableShape(
                table: "plan_days",
                columns: ["plan_id", "day", "readings_json"]
            ),
        ]

        case .quiz: [
            LampModuleTableShape(
                table: "quiz_modules",
                columns: [
                    "id", "plan_id", "name", "description",
                    "questions_per_reading", "age_groups_json",
                ],
                mayBeNull: ["description", "questions_per_reading"]
            ),
            LampModuleTableShape(
                table: "quiz_questions",
                columns: [
                    "id", "quiz_module_id", "day", "sv", "ev", "age_group",
                    "question_index", "question_json", "answer_json", "theme",
                    "christ_focused", "references_json", "cross_references_json",
                ],
                mayBeNull: ["references_json", "cross_references_json"]
            ),
        ]

        case .highlights: [
            LampModuleTableShape(
                table: "highlight_meta",
                columns: ["id", "name", "description", "translation_id", "created", "last_modified"],
                // `created` and `lastModified` are the author's own fields and
                // the schema asks for neither, so both arrive empty from a
                // hand-written set. A client comparing times must decide what
                // no time means rather than read it as zero.
                mayBeNull: ["description", "created", "last_modified"]
            ),
            LampModuleTableShape(
                table: "highlights",
                columns: ["id", "ref", "sc", "ec", "style", "color"],
                mayBeNull: ["color"]
            ),
            LampModuleTableShape(
                table: "highlight_themes",
                columns: ["color", "style", "name", "description"],
                mayBeNull: ["description", "questions_per_reading"]
            ),
        ]

        // **The exported shape, not a copied one.** Notes are not taken in
        // column by column — both apps decode typed records — so this is not
        // here for a copy to be held to. It is here because two writers
        // produce this file, core's `createPersonalNotesDatabase` and the
        // phone's own exporter, and a column one writes and the other does
        // not is a note's pictures arriving on one device and not the other.
        // Each side pins its exporter against this (ios-56's shape).
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

        case .devotional: []
        }
    }
}
