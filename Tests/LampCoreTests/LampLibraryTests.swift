import Foundation
import GRDB
import LampCore
import LampModuleKit
import Testing

struct LampLibraryTests {
    @Test func installsLegacyCompactHighlightsWithoutUsingSetIDAsModuleID() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-legacy-highlight-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("source.sqlite")
        let archiveURL = root.appendingPathComponent("highlight-module.lamp")
        let queue = try DatabaseQueue(path: databaseURL.path)
        try await queue.write { db in
            try db.execute(sql: "CREATE TABLE highlight_meta (id TEXT, name TEXT, translation_id TEXT)")
            try db.execute(sql: "INSERT INTO highlight_meta VALUES ('set-uuid', 'My Set', 'TEST')")
            try db.execute(sql: """
                CREATE TABLE highlights (
                    id INTEGER, ref INTEGER, sc INTEGER, ec INTEGER, style INTEGER, color TEXT
                )
                """)
            try db.execute(sql: "INSERT INTO highlights VALUES (1, 43003016, 0, 4, 0, 'FFCC00')")
        }
        let archive = try (Data(contentsOf: databaseURL) as NSData).compressed(using: .zlib) as Data
        try archive.write(to: archiveURL)
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let installed = try await library.install(from: archiveURL)
        #expect(installed.id == "highlight-module")
        #expect(installed.kind == .highlights)
        let highlights = try await library.moduleVerseHighlights(
            moduleID: "highlight-module", reference: 43_003_016
        )
        #expect(highlights.first?.setID == "set-uuid")
    }

    @Test func personalStudyImportRejectsForeignOwnedArchiveRows() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-personal-ownership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = LampLibrary(rootURL: root.appendingPathComponent("Source"))
        let target = LampLibrary(rootURL: root.appendingPathComponent("Target"))
        try await source.saveVerseNote(LampVerseNote(
            id: "personal-notes:43003016", reference: 43_003_016,
            content: "Remote note", lastModified: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        _ = try await source.saveVerseHighlight(
            translationID: "TEST", reference: 43_003_016,
            startOffset: 0, endOffset: 4, color: "#ffcc00"
        )

        for (module, corruptSQL) in [
            (LampPersonalModule.notes, "UPDATE note_entries SET module_id = 'foreign'"),
            (LampPersonalModule.highlights, "UPDATE module_meta SET id = 'foreign'")
        ] {
            let archiveURL = root.appendingPathComponent("\(module.id).lamp")
            let databaseURL = root.appendingPathComponent("\(module.id).sqlite")
            try await source.exportPersonalModule(module, format: .lamp, to: archiveURL)
            let databaseData = try (Data(contentsOf: archiveURL) as NSData)
                .decompressed(using: .zlib) as Data
            try databaseData.write(to: databaseURL)
            let queue = try DatabaseQueue(path: databaseURL.path)
            try await queue.write { db in
                try db.execute(sql: corruptSQL)
            }
            let corruptArchive = try (Data(contentsOf: databaseURL) as NSData)
                .compressed(using: .zlib) as Data
            try corruptArchive.write(to: archiveURL)

            await #expect(throws: LampPortableModuleInspector.InspectionError.self) {
                _ = try await target.importPersonalStudyData(from: archiveURL)
            }
        }
        #expect(try await target.verseNotes(reference: 43_003_016).isEmpty)
        #expect(try await target.verseHighlights(
            translationID: "TEST", reference: 43_003_016
        ).isEmpty)

        // Mac downloads into a temporary filename. A legacy notes archive
        // without module_format must use module_meta rather than that name.
        let legacyURL = root.appendingPathComponent("random-download-name.lamp")
        let legacyDatabaseURL = root.appendingPathComponent("legacy-notes.sqlite")
        try await source.exportPersonalModule(.notes, format: .lamp, to: legacyURL)
        let legacyData = try (Data(contentsOf: legacyURL) as NSData)
            .decompressed(using: .zlib) as Data
        try legacyData.write(to: legacyDatabaseURL)
        let legacyQueue = try DatabaseQueue(path: legacyDatabaseURL.path)
        try await legacyQueue.write { db in
            try db.execute(sql: "DROP TABLE module_format")
        }
        let legacyArchive = try (Data(contentsOf: legacyDatabaseURL) as NSData)
            .compressed(using: .zlib) as Data
        try legacyArchive.write(to: legacyURL)
        #expect(try await target.importPersonalStudyData(from: legacyURL).importedCount == 1)
        #expect(try await target.verseNotes(reference: 43_003_016).first?.content == "Remote note")
    }

    @Test func installRejectsForeignOwnedRowsBeforeReplacingModule() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-owned-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.sqlite")
        let archiveURL = root.appendingPathComponent("selected.lamp")
        let queue = try DatabaseQueue(path: sourceURL.path)
        try await queue.write { db in
            try db.execute(sql: "CREATE TABLE module_format (module_id TEXT, module_type TEXT)")
            try db.execute(sql: "INSERT INTO module_format VALUES ('selected', 'dictionary')")
            try db.execute(sql: "CREATE TABLE module_metadata (id TEXT, name TEXT, language TEXT)")
            try db.execute(sql: "INSERT INTO module_metadata VALUES ('selected', 'Installed dictionary', 'en')")
            try db.execute(sql: "CREATE TABLE dictionary_entries (id TEXT, module_id TEXT)")
            try db.execute(sql: "INSERT INTO dictionary_entries VALUES ('selected:G1', 'selected')")
        }
        let installedArchive = try (Data(contentsOf: sourceURL) as NSData)
            .compressed(using: .zlib) as Data
        try installedArchive.write(to: archiveURL)
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        _ = try await library.install(from: archiveURL)

        try await queue.write { db in
            try db.execute(sql: "UPDATE dictionary_entries SET module_id = 'foreign'")
        }
        let mixedArchive = try (Data(contentsOf: sourceURL) as NSData)
            .compressed(using: .zlib) as Data
        try mixedArchive.write(to: archiveURL)
        await #expect(throws: LampPortableModuleInspector.InspectionError.self) {
            _ = try await library.install(from: archiveURL)
        }
        let installedURL = try #require(FileManager.default.contentsOfDirectory(
            at: library.rootURL.appendingPathComponent("Modules", isDirectory: true),
            includingPropertiesForKeys: nil
        ).first { $0.pathExtension == "lamp" })
        #expect(try Data(contentsOf: installedURL) == installedArchive)
        #expect(try await library.installedModules().first?.name == "Installed dictionary")
    }

    @Test func equalTimePersonalEditsStopPortableImport() async throws {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-equal-time-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        let source = LampLibrary(rootURL: fixtureURL.appendingPathComponent("Source"))
        let target = LampLibrary(rootURL: fixtureURL.appendingPathComponent("Target"))
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

        try await source.saveVerseNote(LampVerseNote(
            id: "personal-notes:43003016",
            reference: 43_003_016,
            content: "remote note",
            lastModified: timestamp
        ))
        try await target.saveVerseNote(LampVerseNote(
            id: "personal-notes:43003016",
            reference: 43_003_016,
            content: "local note",
            lastModified: timestamp
        ))
        let noteDocument = try await source.personalNotesDocument(bookNumber: 43)
        let noteURL = fixtureURL.appendingPathComponent(noteDocument.suggestedJSONFilename)
        try noteDocument.jsonData.write(to: noteURL)
        do {
            _ = try await target.importPersonalStudyData(from: noteURL)
            Issue.record("Equal-time note edits must stop the import")
        } catch LampLibraryError.syncConflict(_) {
            #expect(try await target.verseNotes(reference: 43_003_016).first?.content == "local note")
        }

        let remoteDevotional = LampDevotional(
            id: "equal-time-devotional",
            moduleID: "personal-devotionals",
            moduleName: "My Writing",
            title: "Remote title",
            content: "Same body",
            created: timestamp,
            lastModified: timestamp
        )
        let localDevotional = LampDevotional(
            id: "equal-time-devotional",
            moduleID: "personal-devotionals",
            moduleName: "My Writing",
            title: "Local title",
            content: "Same body",
            created: timestamp,
            lastModified: timestamp
        )
        try await source.savePersonalDevotional(remoteDevotional, preserveLastModified: true)
        try await target.savePersonalDevotional(localDevotional, preserveLastModified: true)
        let devotionalDocument = try await source.personalDevotionalDocument(id: remoteDevotional.id)
        let devotionalURL = fixtureURL.appendingPathComponent(devotionalDocument.suggestedJSONFilename)
        try devotionalDocument.jsonData.write(to: devotionalURL)
        do {
            _ = try await target.importPersonalDevotional(from: devotionalURL)
            Issue.record("Equal-time devotional edits must stop the import")
        } catch LampLibraryError.syncConflict(_) {
            #expect(try await target.personalDevotionals().first?.title == "Local title")
        }
    }

    @Test func importsPersonalNotesAndDevotionalsFromMarkdown() async throws {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-markdown-import-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        let library = LampLibrary(rootURL: fixtureURL.appendingPathComponent("Library"))

        let notesURL = fixtureURL.appendingPathComponent("John.md")
        try Data(#"""
        ---
        book: John
        ---

        ## Chapter 1

        ### 1:1

        The Word is eternal.

        ### Verses 2-3

        The Word is with God and creates.
        """#.utf8).write(to: notesURL)
        let notesResult = try await library.importPersonalMarkdown(from: notesURL, as: .notes)
        #expect(notesResult.importedCount == 2)
        let notes = try await library.verseNotes(bookNumber: 43, chapterNumber: 1)
        #expect(notes.map(\.reference) == [43_001_001, 43_001_002])
        #expect(notes.last?.verseReferences == [43_001_002, 43_001_003])

        let devotionalURL = fixtureURL.appendingPathComponent("hope.md")
        try Data(#"""
        ---
        title: Living Hope
        date: 08-09
        tags: hope, grace
        author: A Reader
        ---

        Hope does not disappoint.
        """#.utf8).write(to: devotionalURL)
        let devotionalResult = try await library.importPersonalMarkdown(
            from: devotionalURL,
            as: .devotionals
        )
        #expect(devotionalResult.importedCount == 1)
        let devotionals = try await library.personalDevotionals()
        #expect(devotionals.first?.title == "Living Hope")
        #expect(devotionals.first?.author == "A Reader")
        #expect(devotionals.first?.tags == ["hope", "grace"])
        #expect(devotionals.first?.content == "Hope does not disappoint.")
    }

    @Test func planCalendarRoundTripsStableLeapDaySlots() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

        let augustSixth = try #require(LampPlanCalendar.date(
            forDayNumber: 219,
            year: 2026,
            calendar: calendar
        ))
        #expect(calendar.dateComponents([.year, .month, .day], from: augustSixth)
            == DateComponents(year: 2026, month: 8, day: 6))
        #expect(LampPlanCalendar.dayNumber(for: augustSixth, calendar: calendar) == 219)

        #expect(LampPlanCalendar.date(forDayNumber: 60, year: 2026, calendar: calendar) == nil)
        let marchFirst = try #require(LampPlanCalendar.date(
            forDayNumber: 61,
            year: 2026,
            calendar: calendar
        ))
        #expect(calendar.dateComponents([.month, .day], from: marchFirst)
            == DateComponents(month: 3, day: 1))

        let leapDay = try #require(LampPlanCalendar.date(
            forDayNumber: 60,
            year: 2024,
            calendar: calendar
        ))
        #expect(calendar.dateComponents([.month, .day], from: leapDay)
            == DateComponents(month: 2, day: 29))
        #expect(LampPlanCalendar.dayNumber(for: leapDay, calendar: calendar) == 60)
    }

    @Test func installsAndReadsCompiledTranslation() async throws {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-library-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let moduleURL = fixtureURL.appendingPathComponent("TEST.lamp")
        _ = try LampModuleCompiler().compile(
            data: Data(#"""
            {
              "meta": {
                "schemaVersion": "1.0",
                "id": "TEST",
                "type": "translation",
                "name": "Test Translation",
                "abbreviation": "TST",
                "language": "en"
              },
              "books": [{
                "id": "Gen",
                "name": "Genesis",
                "number": 1,
                "testament": "OT",
                "chapters": [{
                  "chapter": 1,
                  "headings": [{"beforeVerse": 1, "level": 1, "text": "Creation"}],
                  "verses": [
                    {
                      "v": 1, "ref": 1001001,
                      "content": {
                        "text": "In the beginning",
                        "annotations": [{
                          "type": "strongs", "start": 0, "end": 2,
                          "data": {"strongs": "H7225", "lemma": "רֵאשִׁית", "morphology": "N-fs"}
                        }],
                        "footnote_refs": [{"id": "a", "offset": 2}]
                      },
                      "footnotes": [{
                        "id": "a", "type": "alternate",
                        "content": {"text": "Or, When God began to create"}
                      }],
                      "paragraph": true,
                      "poetry": {"indent": 1, "stanzaBreak": true}
                    },
                    {
                      "v": 2, "ref": 1001002,
                      "content": {
                        "text": "The earth was formless",
                        "annotations": [{"type": "added", "start": 10, "end": 13}]
                      }
                    }
                  ]
                }]
              }]
            }
            """#.utf8),
            sourceFilename: "TEST.json",
            destinationURL: moduleURL
        )

        let library = LampLibrary(rootURL: fixtureURL.appendingPathComponent("Library"))
        let installed = try await library.install(from: moduleURL)
        #expect(installed.id == "TEST")
        #expect(installed.kind == .translation)

        let modules = try await library.installedModules()
        #expect(modules == [installed])
        #expect(try await library.supportedExportFormats(moduleID: "TEST") == [.lamp])
        let exportedModuleURL = fixtureURL.appendingPathComponent("TEST-exported.lamp")
        try await library.exportModule(moduleID: "TEST", format: .lamp, to: exportedModuleURL)
        #expect(try Data(contentsOf: exportedModuleURL) == Data(contentsOf: moduleURL))

        let books = try await library.translationBooks(moduleID: "TEST")
        #expect(books.count == 1)
        #expect(books.first?.name == "Genesis")

        let chapter = try await library.chapter(
            moduleID: "TEST",
            bookNumber: 1,
            chapterNumber: 1
        )
        #expect(chapter.verses.count == 2)
        #expect(chapter.verses.first?.beginsParagraph == true)
        #expect(chapter.verses.first?.annotations.first?.strongs == "H7225")
        #expect(chapter.verses.first?.hasFootnotes == true)
        #expect(chapter.verses.first?.poetry == LampVersePoetry(indent: 1, stanzaBreak: true))
        #expect(chapter.verses.last?.annotations.first?.kind == "added")
        #expect(chapter.verses.last?.annotations.first?.text == "was")
        #expect(chapter.headings.first?.text == "Creation")
        #expect(try await library.translationWordCount(
            moduleID: "TEST",
            startReference: 1_001_001,
            endReference: 1_001_002
        ) == 7)

        let studyData = try #require(try await library.verseStudyData(
            moduleID: "TEST",
            reference: 1_001_001
        ))
        #expect(studyData.lexicalAnnotations.first?.strongs == "H7225")
        #expect(studyData.lexicalAnnotations.first?.lemma == "רֵאשִׁית")
        #expect(studyData.lexicalAnnotations.first?.text == "In")
        #expect(studyData.footnotes.first?.content == "Or, When God began to create")
        #expect(studyData.footnoteReferences.first?.offset == 2)

        let searchResults = try await library.searchTranslations(query: "formless")
        #expect(searchResults.count == 1)
        #expect(searchResults.first?.displayReference == "Genesis 1:2")
        #expect(searchResults.first?.translationID == "TEST")
        #expect(try await library.searchTranslations(query: "   ").isEmpty)

        let dictionaryURL = fixtureURL.appendingPathComponent("TEST_DICT.lamp")
        _ = try LampModuleCompiler().compile(
            data: Data(#"""
            {
              "meta": {
                "schemaVersion": "2.1", "id": "TEST_DICT",
                "type": "dictionary", "name": "Test Dictionary"
              },
              "entries": [{
                "key": "G1", "lemma": "alpha", "transliteration": "a",
                "senses": [{
                  "partOfSpeech": "noun", "shortDefinition": "first letter",
                  "definition": [{
                    "type": "paragraph",
                    "text": "The first letter of the Greek alphabet. See John 1:1.",
                    "annotations": [{
                      "type": "scripture", "start": 44, "end": 52,
                      "text": "John 1:1", "data": {"sv": 43001001}
                    }]
                  }],
                  "derivation": {
                    "text": "from G25 (ἀγαπάω)",
                    "annotations": [{
                      "type": "strongs", "start": 5, "end": 17,
                      "text": "G25 (ἀγαπάω)", "data": {"strongs": "G25"}
                    }]
                  },
                  "references": [{"sv": 43001002, "ev": 43001003}]
                }]
              }]
            }
            """#.utf8),
            sourceFilename: "TEST_DICT.json",
            destinationURL: dictionaryURL
        )
        _ = try await library.install(from: dictionaryURL)
        let dictionaryResults = try await library.searchDictionaries(query: "alpha")
        #expect(dictionaryResults.first?.key == "G1")
        #expect(dictionaryResults.first?.senses.first?.definition == "The first letter of the Greek alphabet. See John 1:1.")
        let dictionarySense = try #require(dictionaryResults.first?.senses.first)
        #expect(dictionarySense.derivation == "from G25 (ἀγαπάω)")
        #expect(dictionarySense.dictionaryLinks == [
            LampDictionaryLink(text: "G25 (ἀγαπάω)", key: "G25"),
        ])
        #expect(dictionarySense.scriptureLinks.contains {
            $0.text == "John 1:1" && $0.startReference == 43_001_001
        })
        #expect(dictionarySense.scriptureLinks.contains {
            $0.text == nil
                && $0.startReference == 43_001_002
                && $0.endReference == 43_001_003
        })

        let commentaryURL = fixtureURL.appendingPathComponent("TEST_COMM.lamp")
        _ = try LampModuleCompiler().compile(
            data: Data(#"""
            {
              "meta": {
                "schemaVersion": "2.1", "id": "TEST_COMM",
                "seriesAbbrev": "TC", "seriesFull": "Test Commentary",
                "title": "Genesis"
              },
              "book": "Gen", "bookNumber": 1,
              "chapters": [{
                "chapter": 1,
                "verses": [{
                  "sv": 1001001,
                  "commentary": {
                    "text": "A comment on creation. See John 1:1-3.",
                    "annotations": [{
                      "type": "scripture", "start": 27, "end": 37,
                      "text": "John 1:1-3", "data": {"sv": 43001001, "ev": 43001003}
                    }]
                  }
                }]
              }]
            }
            """#.utf8),
            sourceFilename: "TEST_COMM.json",
            destinationURL: commentaryURL
        )
        _ = try await library.install(from: commentaryURL)
        let commentary = try await library.commentary(
            bookNumber: 1,
            chapterNumber: 1,
            reference: 1_001_001
        )
        #expect(commentary.first?.seriesAbbreviation == "TC")
        #expect(commentary.first?.commentary == "A comment on creation. See John 1:1-3.")
        #expect(commentary.first?.scriptureLinks.first?.displayDescription == "John 1:1-3")
        #expect(commentary.first?.scriptureLinks.first?.startReference == 43_001_001)

        try await library.remove(moduleID: "TEST")
        try await library.remove(moduleID: "TEST_DICT")
        try await library.remove(moduleID: "TEST_COMM")
        #expect(try await library.installedModules().isEmpty)
    }

    @Test func searchesFullTranslationSchema() async throws {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-full-schema-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let databaseURL = fixtureURL.appendingPathComponent("FULL.sqlite")
        do {
            let queue = try DatabaseQueue(path: databaseURL.path)
            try await queue.write { db in
                try db.execute(sql: """
                    CREATE TABLE translations (
                        id TEXT PRIMARY KEY, name TEXT NOT NULL,
                        abbreviation TEXT, language TEXT
                    );
                    CREATE TABLE translation_books (
                        id TEXT PRIMARY KEY, translation_id TEXT NOT NULL,
                        book_number INTEGER NOT NULL, book_id TEXT NOT NULL,
                        name TEXT NOT NULL, testament TEXT NOT NULL,
                        chapter_count INTEGER NOT NULL
                    );
                    CREATE TABLE translation_verses (
                        id INTEGER PRIMARY KEY, translation_id TEXT NOT NULL,
                        ref INTEGER NOT NULL, book INTEGER NOT NULL,
                        chapter INTEGER NOT NULL, verse INTEGER NOT NULL,
                        text TEXT NOT NULL, paragraph INTEGER DEFAULT 0
                    );
                    CREATE VIRTUAL TABLE translation_verses_fts USING fts5(
                        text, content='translation_verses', content_rowid='id'
                    );
                    INSERT INTO translations VALUES ('FULL', 'Full Translation', 'FUL', 'en');
                    INSERT INTO translation_books VALUES ('FULL:43', 'FULL', 43, 'John', 'John', 'NT', 21);
                    INSERT INTO translation_verses VALUES (1, 'FULL', 43001005, 43, 1, 5, 'The light shines in the darkness', 1);
                    INSERT INTO translation_verses_fts(translation_verses_fts) VALUES('rebuild');
                    """)
            }
        }

        let databaseData = try Data(contentsOf: databaseURL)
        let compressedData = try (databaseData as NSData).compressed(using: .zlib) as Data
        let moduleURL = fixtureURL.appendingPathComponent("FULL.lamp")
        try compressedData.write(to: moduleURL)

        let library = LampLibrary(rootURL: fixtureURL.appendingPathComponent("Library"))
        _ = try await library.install(from: moduleURL)
        let results = try await library.searchTranslations(query: "light darkness")
        #expect(results.first?.displayReference == "John 1:5")

        let chapter = try await library.chapter(
            moduleID: "FULL",
            bookNumber: 43,
            chapterNumber: 1
        )
        #expect(chapter.verses.first?.text == "The light shines in the darkness")
        let studyData = try #require(try await library.verseStudyData(
            moduleID: "FULL",
            reference: 43_001_005
        ))
        #expect(studyData.isEmpty)
    }

    @Test func installsReadsAndTracksReadingPlan() async throws {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-plan-library-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let moduleURL = fixtureURL.appendingPathComponent("TEST_PLAN.lamp")
        _ = try LampModuleCompiler().compile(
            data: Data(#"""
            {
              "meta": {
                "schemaVersion": "1.0", "id": "TEST_PLAN", "type": "plan",
                "name": "Test Plan", "description": "Read every day",
                "author": "Lamp Bible", "duration": 2, "readingsPerDay": 2
              },
              "days": [{
                "day": 1,
                "readings": [
                  {"sv": 1001001, "ev": 1001999},
                  {"sv": 43003016, "ev": 43003016}
                ]
              }]
            }
            """#.utf8),
            sourceFilename: "TEST_PLAN.json",
            destinationURL: moduleURL
        )

        let library = LampLibrary(rootURL: fixtureURL.appendingPathComponent("Library"))
        let installed = try await library.install(from: moduleURL)
        #expect(installed.kind == .plan)

        let plans = try await library.readingPlans()
        #expect(plans.first?.name == "Test Plan")
        #expect(plans.first?.duration == 2)

        let day = try #require(try await library.readingPlanDay(moduleID: "TEST_PLAN", day: 1))
        #expect(day.readings.count == 2)
        #expect(day.readings.first?.displayDescription == "Genesis 1")
        #expect(day.readings.last?.displayDescription == "John 3:16")

        try await library.setPlanSelected(moduleID: "TEST_PLAN", selected: true)
        #expect(try await library.selectedPlanIDs() == ["TEST_PLAN"])
        try await library.setReadingCompleted(
            planID: "TEST_PLAN",
            day: 1,
            readingIndex: 0,
            year: 2026,
            completed: true
        )
        let completed = try await library.completedReadings(planID: "TEST_PLAN", year: 2026)
        #expect(completed.count == 1)
        #expect(completed.first?.id == "TEST_PLAN_1_r0_2026")

        try await library.setReadingCompleted(
            planID: "TEST_PLAN",
            day: 1,
            readingIndex: 0,
            year: 2026,
            completed: false
        )
        #expect(try await library.completedReadings().isEmpty)
        try await library.remove(moduleID: "TEST_PLAN")
        #expect(try await library.selectedPlanIDs().isEmpty)
    }

    @Test func persistsPersonalVerseNotesAndHighlights() async throws {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-study-data-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let library = LampLibrary(rootURL: fixtureURL.appendingPathComponent("Library"))
        let reference = 43_003_016

        let savedNote = try #require(try await library.setPersonalVerseNote(
            reference: reference,
            content: "God's love is the center of this verse."
        ))
        #expect(savedNote.id == "personal-notes:\(reference)")
        #expect(savedNote.bookNumber == 43)
        #expect(savedNote.chapterNumber == 3)
        #expect(try await library.verseNotes(reference: reference).first?.content == savedNote.content)
        #expect(try await library.verseNotes(bookNumber: 43, chapterNumber: 3).count == 1)

        _ = try await library.setPersonalVerseNote(
            reference: reference,
            title: "Gospel",
            content: "An updated observation.",
            verseReferences: [reference, reference + 1],
            footnotes: [LampVerseFootnote(id: "1", kind: "study", content: "A supporting note.")]
        )
        let updatedNote = try #require(try await library.verseNotes(reference: reference).first)
        #expect(updatedNote.title == "Gospel")
        #expect(updatedNote.content == "An updated observation.")
        #expect(updatedNote.verseReferences == [reference, reference + 1])
        #expect(updatedNote.footnotes.first?.content == "A supporting note.")

        let customSet = try await library.saveHighlightSet(LampHighlightSet(
            id: "sermon-highlights",
            name: "Sermon Notes",
            description: "Highlights for sermon preparation",
            translationID: "TEST"
        ))
        #expect(try await library.highlightSets(translationID: "TEST") == [customSet])

        let highlight = try await library.saveVerseHighlight(
            translationID: "TEST",
            reference: reference,
            startOffset: 0,
            endOffset: 12,
            style: .highlight,
            color: "#ffcc00"
        )
        #expect(highlight.color == "FFCC00")
        #expect(highlight.setID == "personal-highlights:TEST")
        let customHighlight = try await library.saveVerseHighlight(
            translationID: "TEST",
            reference: reference,
            startOffset: 13,
            endOffset: 18,
            style: .underlineDashed,
            color: "34C759",
            setID: customSet.id
        )
        #expect(try await library.verseHighlights(
            translationID: "TEST",
            reference: reference
        ) == [highlight, customHighlight])
        #expect(try await library.verseHighlights(
            translationID: "TEST",
            bookNumber: 43,
            chapterNumber: 3
        ) == [highlight, customHighlight])
        #expect(try await library.verseHighlights(
            translationID: "OTHER",
            reference: reference
        ).isEmpty)

        try await library.deleteVerseHighlight(id: highlight.id)
        #expect(try await library.verseHighlights(
            translationID: "TEST",
            reference: reference
        ) == [customHighlight])

        try await library.deleteHighlightSet(id: customSet.id)
        #expect(try await library.highlightSets(translationID: "TEST").count == 1)
        #expect(try await library.verseHighlights(
            translationID: "TEST",
            reference: reference
        ).isEmpty)

        _ = try await library.setPersonalVerseNote(reference: reference, content: "")
        #expect(try await library.verseNotes(reference: reference).isEmpty)
    }

    @Test func exportsAndImportsPortableLibraryBackup() async throws {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-backup-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let source = LampLibrary(rootURL: fixtureURL.appendingPathComponent("Source"))
        _ = try await source.setPersonalVerseNote(
            reference: 43_003_016,
            title: "Love",
            content: "A synced note."
        )
        _ = try await source.saveVerseHighlight(
            translationID: "TEST",
            reference: 43_003_016,
            startOffset: 0,
            endOffset: 4,
            color: "FFCC00"
        )
        let customSet = try await source.saveHighlightSet(LampHighlightSet(
            id: "sermon-preparation",
            name: "Sermon Preparation",
            translationID: "TEST"
        ))
        _ = try await source.saveHighlightTheme(LampHighlightTheme(
            setID: customSet.id,
            color: "34C759",
            style: .underlineDotted,
            name: "Promises",
            description: "Promises to revisit"
        ))
        _ = try await source.saveVerseHighlight(
            translationID: "TEST",
            reference: 43_003_016,
            startOffset: 5,
            endOffset: 9,
            style: .underlineDotted,
            color: "34C759",
            setID: customSet.id
        )
        let attachment = fixtureURL.appendingPathComponent(".image.png")
        let attachmentData = Data("portable image".utf8)
        try attachmentData.write(to: attachment)
        let storedAttachment = try await source.storePersonalDevotionalMedia(
            from: attachment,
            devotionalID: "synced-devotional"
        )
        #expect(storedAttachment.lastPathComponent.hasPrefix(".image-"))
        let devotionalContent = "![Image](lamp-media://synced-devotional/\(storedAttachment.lastPathComponent))"
        let mediaMetadata = """
        [{"id":"lamp-media://synced-devotional/\(storedAttachment.lastPathComponent)",
          "type":"image","filename":"\(storedAttachment.lastPathComponent)",
          "mimeType":"image/png","alt":"Portable image description"}]
        """
        _ = try await source.savePersonalDevotional(LampDevotional(
            id: "synced-devotional",
            moduleID: "personal-devotionals",
            moduleName: "My Writing",
            title: "Synced Devotional",
            content: devotionalContent,
            mediaJSON: mediaMetadata
        ))

        let backupURL = fixtureURL.appendingPathComponent("Backup", isDirectory: true)
        let summary = try await source.exportPortableBackup(to: backupURL)
        #expect(summary.noteDocumentCount == 1)
        #expect(summary.highlightDocumentCount == 2)
        #expect(summary.devotionalDocumentCount == 1)
        #expect(FileManager.default.fileExists(atPath: backupURL.appendingPathComponent("manifest.json").path))
        let portableAttachmentPath = "Media/Devotionals/synced-devotional/\(storedAttachment.lastPathComponent)"
        let portableAttachment = backupURL.appendingPathComponent(portableAttachmentPath)
        #expect(try Data(contentsOf: portableAttachment) == attachmentData)
        let archive = try LampSyncArchive.create(from: backupURL)
        #expect(archive.entries.first { $0.path == portableAttachmentPath }?.data == attachmentData)

        let destination = LampLibrary(rootURL: fixtureURL.appendingPathComponent("Destination"))
        let imported = try await destination.importPortableBackup(from: backupURL)
        #expect(imported.importedStudyEntries == 3)
        #expect(imported.importedDevotionals == 1)
        #expect(try await destination.verseNotes(reference: 43_003_016).first?.content == "A synced note.")
        #expect(try await destination.verseHighlights(
            translationID: "TEST",
            reference: 43_003_016
        ).count == 2)
        #expect(try await destination.highlightSets(translationID: "TEST")
            .contains { $0.name == "Sermon Preparation" })
        let syncedCustomSet = try #require(try await destination.highlightSets(translationID: "TEST")
            .first { $0.name == "Sermon Preparation" })
        #expect(try await destination.highlightThemes(setID: syncedCustomSet.id).first?.name == "Promises")
        #expect(try await destination.personalDevotionals().first?.title == "Synced Devotional")
        #expect(try await destination.personalDevotionals().first?.content == devotionalContent)
        #expect(try await destination.personalDevotionals().first?.mediaReferences.first?.alt
            == "Portable image description")
        #expect(try Data(contentsOf: fixtureURL.appendingPathComponent("Destination").appendingPathComponent(portableAttachmentPath)) == attachmentData)

        try FileManager.default.createSymbolicLink(
            at: backupURL.appendingPathComponent("Media/Devotionals/synced-devotional/linked.png"),
            withDestinationURL: attachment
        )
        do {
            _ = try await destination.importPortableBackup(from: backupURL)
            Issue.record("Media symlink should stop portable backup import")
        } catch LampLibraryError.syncConflict(let reason) {
            #expect(reason == "Media backup contains a symbolic link.")
        }
    }

    @Test func installsAndReadsPortableStudyModules() async throws {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-study-module-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let notesURL = fixtureURL.appendingPathComponent("portable_notes.lamp")
        _ = try LampModuleCompiler().compile(
            data: Data(#"""
            {
              "meta": {
                "schemaVersion": "1.1", "id": "portable_notes",
                "type": "notes", "name": "Portable Notes"
              },
              "book": "John", "bookNumber": 43,
              "chapters": [{
                "chapter": 3,
                "verses": [{
                  "sv": 43003016, "commentary": "A portable observation.",
                  "lastModified": 1700000000
                }]
              }]
            }
            """#.utf8),
            sourceFilename: "portable_notes.json",
            destinationURL: notesURL
        )
        let highlightsURL = fixtureURL.appendingPathComponent("portable_highlights.lamp")
        _ = try LampModuleCompiler().compile(
            data: Data(#"""
            {
              "meta": {
                "schemaVersion": "1.0", "id": "portable_highlights",
                "type": "highlights", "name": "Portable Highlights",
                "translationId": "TEST"
              },
              "verses": [{
                "ref": 43003016,
                "highlights": [{"sc": 0, "ec": 8, "style": 0, "color": "FFCC00"}]
              }]
            }
            """#.utf8),
            sourceFilename: "portable_highlights.json",
            destinationURL: highlightsURL
        )

        let library = LampLibrary(rootURL: fixtureURL.appendingPathComponent("Library"))
        let notesModule = try await library.install(from: notesURL)
        let highlightsModule = try await library.install(from: highlightsURL)
        #expect(notesModule.kind == .notes)
        #expect(notesModule.name == "Portable Notes")
        #expect(highlightsModule.kind == .highlights)
        #expect(highlightsModule.name == "Portable Highlights")

        let notes = try await library.moduleVerseNotes(
            moduleID: "portable_notes",
            reference: 43_003_016
        )
        #expect(notes.first?.content == "A portable observation.")
        let highlights = try await library.moduleVerseHighlights(
            moduleID: "portable_highlights",
            reference: 43_003_016
        )
        #expect(highlights.first?.translationID == "TEST")
        #expect(highlights.first?.endOffset == 8)
        #expect(try await library.supportedExportFormats(moduleID: "portable_notes")
            == [.lamp, .markdown])
        #expect(try await library.supportedExportFormats(moduleID: "portable_highlights")
            == [.lamp])
        let markdownURL = fixtureURL.appendingPathComponent("portable_notes.md")
        try await library.exportModule(
            moduleID: "portable_notes",
            format: .markdown,
            to: markdownURL
        )
        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        #expect(markdown.contains("# Portable Notes"))
        #expect(markdown.contains("## John 3:16"))
        #expect(markdown.contains("A portable observation."))
        #expect(try await library.installedModules().map(\.kind) == [.highlights, .notes])
    }

    @Test func createsSearchesExportsAndDeletesPersonalDevotionals() async throws {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-personal-devotional-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let library = LampLibrary(rootURL: fixtureURL.appendingPathComponent("Library"))
        let saved = try await library.savePersonalDevotional(LampDevotional(
            id: "morning-hope",
            moduleID: "personal-devotionals",
            moduleName: "My Writing",
            title: "Morning Hope",
            subtitle: "Beginning well",
            author: "Author",
            date: "2026-08-03",
            tags: ["hope", "morning"],
            category: "reflection",
            seriesName: "Daily Hope",
            seriesOrder: 1,
            keyScriptures: [LampScriptureLink(
                text: "Genesis 1:1",
                startReference: 1_001_001
            )],
            summary: "God gives hope.",
            content: "Begin the day remembering creation.",
            footnotes: "A footnote"
        ))

        #expect(saved.isEditable)
        #expect(saved.moduleID == "personal-devotionals")
        #expect(saved.moduleName == "My Writing")
        #expect(try await library.personalDevotionals(query: "creation").first?.id == saved.id)
        #expect(try await library.devotionals().first?.title == "Morning Hope")
        let searchResults = try await library.searchModules(
            query: "creation",
            kinds: [.devotional]
        )
        #expect(searchResults.first?.moduleID == "personal-devotionals")

        let document = try await library.personalDevotionalDocument(id: saved.id)
        #expect(document.kind == .devotional)
        let outputURL = fixtureURL.appendingPathComponent("morning-hope.lamp")
        let build = try LampModuleCompiler().compile(
            data: document.jsonData,
            sourceFilename: document.suggestedJSONFilename,
            destinationURL: outputURL
        )
        #expect(build.kind == .devotional)
        #expect(build.tableCounts["devotional_entries"] == 1)

        let attachmentSource = fixtureURL.appendingPathComponent("photo.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: attachmentSource)
        let storedAttachment = try await library.storePersonalDevotionalMedia(
            from: attachmentSource,
            devotionalID: saved.id
        )
        #expect(FileManager.default.fileExists(atPath: storedAttachment.path))
        #expect(storedAttachment.path.contains("Media/Devotionals/morning-hope"))

        try await library.deletePersonalDevotional(id: saved.id)
        #expect(try await library.personalDevotionals().isEmpty)

        let jsonURL = fixtureURL.appendingPathComponent(document.suggestedJSONFilename)
        try document.jsonData.write(to: jsonURL)
        #expect(try await library.importPersonalDevotional(from: jsonURL).first?.id == saved.id)
        try await library.deletePersonalDevotional(id: saved.id)
        #expect(try await library.importPersonalDevotional(from: outputURL).first?.title == saved.title)
    }

    @Test func savesPartiallyAuthoredPersonalDevotionals() async throws {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-partial-devotional-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let library = LampLibrary(rootURL: fixtureURL.appendingPathComponent("Library"))
        let bodyOnly = try await library.savePersonalDevotional(LampDevotional(
            id: "body-only",
            moduleID: "personal-devotionals",
            moduleName: "My Writing",
            title: "",
            content: "A thought that does not have a title yet."
        ))
        #expect(bodyOnly.title == "Untitled")
        #expect(bodyOnly.content == "A thought that does not have a title yet.")

        let titleOnly = try await library.savePersonalDevotional(LampDevotional(
            id: "title-only",
            moduleID: "personal-devotionals",
            moduleName: "My Writing",
            title: "An Outline",
            content: ""
        ))
        #expect(titleOnly.title == "An Outline")
        #expect(titleOnly.content.isEmpty)

        let titleOnlyDocument = try await library.personalDevotionalDocument(id: titleOnly.id)
        let titleOnlyURL = fixtureURL.appendingPathComponent("title-only.json")
        try titleOnlyDocument.jsonData.write(to: titleOnlyURL)
        try await library.deletePersonalDevotional(id: titleOnly.id)
        let importedTitleOnly = try #require(
            try await library.importPersonalDevotional(from: titleOnlyURL).first
        )
        #expect(importedTitleOnly.title == "An Outline")
        #expect(importedTitleOnly.content.isEmpty)
    }

    @Test func exportsPersonalStudyDataThroughPortableFormats() async throws {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-study-export-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let sourceLibrary = LampLibrary(rootURL: fixtureURL.appendingPathComponent("SourceLibrary"))
        try await sourceLibrary.saveVerseNote(LampVerseNote(
            id: "personal-notes:43003016",
            reference: 43_003_016,
            title: "The Gospel",
            content: "A saved observation for export.",
            verseReferences: [43_003_016, 43_003_017],
            footnotes: [LampVerseFootnote(id: "1", kind: "explanation", content: "A saved footnote.")],
            lastModified: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        _ = try await sourceLibrary.saveVerseHighlight(
            translationID: "TEST",
            reference: 43_003_016,
            startOffset: 2,
            endOffset: 11,
            style: .underlineSolid,
            color: "#34c759"
        )
        _ = try await sourceLibrary.saveHighlightSet(LampHighlightSet(
            id: "personal-highlights-ALT",
            name: "Alternate Translation Highlights",
            translationID: "ALT",
            created: Date(timeIntervalSince1970: 1_700_000_000),
            lastModified: Date(timeIntervalSince1970: 1_700_000_001)
        ))
        _ = try await sourceLibrary.saveVerseHighlight(
            translationID: "ALT",
            reference: 43_003_017,
            startOffset: 0,
            endOffset: 4,
            color: "#ffcc00",
            setID: "personal-highlights-ALT"
        )
        _ = try await sourceLibrary.saveHighlightTheme(LampHighlightTheme(
            setID: "personal-highlights-ALT",
            color: "FFCC00",
            style: .highlight,
            name: "Promises"
        ))
        _ = try await sourceLibrary.savePersonalDevotional(LampDevotional(
            id: "personal-writing-export",
            moduleID: LampPersonalModule.writing.id,
            moduleName: LampPersonalModule.writing.name,
            title: "Portable Writing",
            tags: ["export"],
            content: "A personal writing entry for export.",
            created: Date(timeIntervalSince1970: 1_700_000_000),
            lastModified: Date(timeIntervalSince1970: 1_700_000_001)
        ))

        #expect(LampLibrary.supportedExportFormats(for: .writing) == [.lamp, .markdown])
        #expect(LampLibrary.supportedExportFormats(for: .notes) == [.lamp, .markdown])
        #expect(LampLibrary.supportedExportFormats(for: .highlights) == [.lamp])
        let personalWritingURL = fixtureURL.appendingPathComponent("personal-devotionals.lamp")
        let personalNotesURL = fixtureURL.appendingPathComponent("personal-notes.lamp")
        let personalHighlightsURL = fixtureURL.appendingPathComponent("personal-highlights.lamp")
        let personalWritingMarkdownURL = fixtureURL.appendingPathComponent("personal-devotionals.md")
        let personalNotesMarkdownURL = fixtureURL.appendingPathComponent("personal-notes.md")
        try await sourceLibrary.exportPersonalModule(.writing, format: .lamp, to: personalWritingURL)
        try await sourceLibrary.exportPersonalModule(.notes, format: .lamp, to: personalNotesURL)
        try await sourceLibrary.exportPersonalModule(.highlights, format: .lamp, to: personalHighlightsURL)
        try await sourceLibrary.exportPersonalModule(
            .writing,
            format: .markdown,
            to: personalWritingMarkdownURL
        )
        try await sourceLibrary.exportPersonalModule(
            .notes,
            format: .markdown,
            to: personalNotesMarkdownURL
        )
        #expect(try String(contentsOf: personalWritingMarkdownURL, encoding: .utf8)
            .contains("## Portable Writing"))
        #expect(try String(contentsOf: personalNotesMarkdownURL, encoding: .utf8)
            .contains("## John 3:16–17"))

        let personalImportLibrary = LampLibrary(
            rootURL: fixtureURL.appendingPathComponent("PersonalImportLibrary")
        )
        #expect(try await personalImportLibrary.importPersonalDevotional(
            from: personalWritingURL
        ).first?.title == "Portable Writing")
        #expect(try await personalImportLibrary.importPersonalStudyData(
            from: personalNotesURL
        ).importedCount == 1)
        #expect(try await personalImportLibrary.importPersonalStudyData(
            from: personalHighlightsURL
        ).importedCount == 2)
        #expect(try await personalImportLibrary.highlightSets().contains {
            $0.id == "personal-highlights-ALT"
                && $0.name == "Alternate Translation Highlights"
                && $0.translationID == "ALT"
        })
        #expect(try await personalImportLibrary.highlightThemes(
            setID: "personal-highlights-ALT"
        ).first?.name == "Promises")

        let notesDocument = try await sourceLibrary.personalNotesDocument(bookNumber: 43)
        let highlightsDocument = try await sourceLibrary.personalHighlightsDocument(
            translationID: "TEST"
        )
        #expect(notesDocument.suggestedJSONFilename == "personal-notes-john.json")
        #expect(highlightsDocument.suggestedModuleFilename == "personal-highlights-TEST.lamp")

        let inspector = ModuleJSONInspector()
        let notesInspection = try inspector.inspect(notesDocument.jsonData)
        let highlightsInspection = try inspector.inspect(highlightsDocument.jsonData)
        #expect(notesInspection.canCompile)
        #expect(notesInspection.statistics["notes"] == 1)
        #expect(highlightsInspection.canCompile)
        #expect(highlightsInspection.statistics["highlights"] == 1)
        let notesJSON = try #require(
            JSONSerialization.jsonObject(with: notesDocument.jsonData) as? [String: Any]
        )
        let chapters = try #require(notesJSON["chapters"] as? [[String: Any]])
        let verses = try #require(chapters.first?["verses"] as? [[String: Any]])
        #expect(verses.first?["title"] as? String == "The Gospel")
        #expect(verses.first?["ev"] as? Int == 43_003_017)

        let notesJSONURL = fixtureURL.appendingPathComponent(notesDocument.suggestedJSONFilename)
        let highlightsJSONURL = fixtureURL.appendingPathComponent(highlightsDocument.suggestedJSONFilename)
        try notesDocument.jsonData.write(to: notesJSONURL)
        try highlightsDocument.jsonData.write(to: highlightsJSONURL)
        let editableLibrary = LampLibrary(rootURL: fixtureURL.appendingPathComponent("EditableLibrary"))
        let notesImport = try await editableLibrary.importPersonalStudyData(from: notesJSONURL)
        let highlightsImport = try await editableLibrary.importPersonalStudyData(from: highlightsJSONURL)
        #expect(notesImport.importedCount == 1)
        #expect(highlightsImport.importedCount == 1)
        let editableNote = try #require(try await editableLibrary.verseNotes(
            reference: 43_003_016
        ).first)
        #expect(editableNote.title == "The Gospel")
        #expect(editableNote.footnotes.first?.content == "A saved footnote.")
        #expect(try await editableLibrary.verseHighlights(
            translationID: "TEST",
            reference: 43_003_016
        ).first?.style == .underlineSolid)
        let duplicateNotesImport = try await editableLibrary.importPersonalStudyData(from: notesJSONURL)
        let duplicateHighlightsImport = try await editableLibrary.importPersonalStudyData(
            from: highlightsJSONURL
        )
        #expect(duplicateNotesImport.importedCount == 0)
        #expect(duplicateNotesImport.skippedCount == 1)
        #expect(duplicateHighlightsImport.importedCount == 0)
        #expect(duplicateHighlightsImport.skippedCount == 1)
        try await sourceLibrary.saveVerseNote(LampVerseNote(
            id: "personal-notes:43003016",
            reference: 43_003_016,
            title: "The Gospel",
            content: "A newer imported observation.",
            lastModified: Date(timeIntervalSince1970: 1_700_000_001)
        ))
        let updatedNotesDocument = try await sourceLibrary.personalNotesDocument(bookNumber: 43)
        let updatedNotesURL = fixtureURL.appendingPathComponent("updated-notes.json")
        try updatedNotesDocument.jsonData.write(to: updatedNotesURL)
        let updatedImport = try await editableLibrary.importPersonalStudyData(from: updatedNotesURL)
        #expect(updatedImport.importedCount == 1)
        #expect(try await editableLibrary.verseNotes(
            reference: 43_003_016
        ).first?.content == "A newer imported observation.")

        let notesURL = fixtureURL.appendingPathComponent(notesDocument.suggestedModuleFilename)
        let highlightsURL = fixtureURL.appendingPathComponent(highlightsDocument.suggestedModuleFilename)
        _ = try LampModuleCompiler().compile(
            data: notesDocument.jsonData,
            sourceFilename: notesDocument.suggestedJSONFilename,
            destinationURL: notesURL
        )
        _ = try LampModuleCompiler().compile(
            data: highlightsDocument.jsonData,
            sourceFilename: highlightsDocument.suggestedJSONFilename,
            destinationURL: highlightsURL
        )

        let targetLibrary = LampLibrary(rootURL: fixtureURL.appendingPathComponent("TargetLibrary"))
        _ = try await targetLibrary.install(from: notesURL)
        _ = try await targetLibrary.install(from: highlightsURL)
        let importedNote = try #require(try await targetLibrary.moduleVerseNotes(
            moduleID: notesDocument.moduleID,
            reference: 43_003_016
        ).first)
        let importedHighlight = try #require(try await targetLibrary.moduleVerseHighlights(
            moduleID: highlightsDocument.moduleID,
            reference: 43_003_016
        ).first)
        #expect(importedNote.title == "The Gospel")
        #expect(importedNote.content == "A saved observation for export.")
        #expect(importedHighlight.style == .underlineSolid)
        #expect(importedHighlight.color == "34C759")

        let lampImportLibrary = LampLibrary(rootURL: fixtureURL.appendingPathComponent("LampImportLibrary"))
        let notesLampImport = try await lampImportLibrary.importPersonalStudyData(from: notesURL)
        let highlightsLampImport = try await lampImportLibrary.importPersonalStudyData(from: highlightsURL)
        #expect(notesLampImport.importedCount == 1)
        #expect(highlightsLampImport.importedCount == 1)
        #expect(try await lampImportLibrary.verseNotes(reference: 43_003_016).first?.title == "The Gospel")
        #expect(try await lampImportLibrary.verseHighlights(
            translationID: "TEST",
            reference: 43_003_016
        ).first?.color == "34C759")
    }

    @Test func readsCombinedBundledModulesAndRemainingModuleKinds() async throws {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-bundled-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let databaseURL = fixtureURL.appendingPathComponent("bundled.sqlite")
        do {
            let queue = try DatabaseQueue(path: databaseURL.path)
            try await queue.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA journal_mode = DELETE")
                try db.execute(sql: #"""
                    CREATE TABLE translations (
                        id TEXT PRIMARY KEY, name TEXT NOT NULL, abbreviation TEXT,
                        language TEXT, description TEXT
                    );
                    CREATE TABLE translation_books (
                        id INTEGER PRIMARY KEY, translation_id TEXT, book_number INTEGER,
                        book_id TEXT, name TEXT, testament TEXT, chapter_count INTEGER
                    );
                    CREATE TABLE translation_verses (
                        id INTEGER PRIMARY KEY, translation_id TEXT, ref INTEGER,
                        book INTEGER, chapter INTEGER, verse INTEGER, text TEXT,
                        paragraph INTEGER, annotations_json TEXT, footnotes_json TEXT,
                        footnote_refs_json TEXT, poetry_json TEXT
                    );
                    CREATE TABLE lexicons (
                        id TEXT PRIMARY KEY, name TEXT, language TEXT
                    );
                    CREATE TABLE dictionary_entries (
                        id INTEGER PRIMARY KEY, module_id TEXT, key TEXT, lemma TEXT,
                        transliteration TEXT, pronunciation TEXT, senses_json TEXT,
                        metadata_json TEXT, search_text TEXT
                    );
                    CREATE TABLE lexicon_mappings (
                        id INTEGER PRIMARY KEY AUTOINCREMENT, mapping_id TEXT,
                        source_key TEXT, target_keys_json TEXT
                    );
                    CREATE TABLE modules (
                        id TEXT PRIMARY KEY, type TEXT, name TEXT, series_abbrev TEXT
                    );
                    CREATE TABLE commentary_units (
                        id TEXT PRIMARY KEY, module_id TEXT, book INTEGER, chapter INTEGER,
                        sv INTEGER, ev INTEGER, unit_type TEXT, level INTEGER, title TEXT,
                        introduction_json TEXT, translation_json TEXT, commentary_json TEXT,
                        footnotes_json TEXT, order_index INTEGER
                    );
                    CREATE TABLE devotional_entries (
                        id TEXT PRIMARY KEY, module_id TEXT, title TEXT, subtitle TEXT,
                        author TEXT, date TEXT, tags TEXT, category TEXT, series_name TEXT,
                        series_order INTEGER, key_scriptures_json TEXT, summary_json TEXT,
                        content_json TEXT, footnotes_json TEXT, created INTEGER,
                        last_modified INTEGER, search_text TEXT
                    );
                    CREATE TABLE plans (
                        id TEXT PRIMARY KEY, name TEXT, description TEXT, author TEXT,
                        full_description TEXT, duration INTEGER, readings_per_day INTEGER
                    );
                    CREATE TABLE plan_days (
                        plan_id TEXT, day INTEGER, readings_json TEXT
                    );
                    CREATE TABLE quiz_modules (
                        id TEXT PRIMARY KEY, plan_id TEXT, name TEXT, description TEXT,
                        questions_per_reading INTEGER, age_groups_json TEXT
                    );
                    CREATE TABLE quiz_questions (
                        id INTEGER PRIMARY KEY, quiz_module_id TEXT, day INTEGER,
                        sv INTEGER, ev INTEGER, age_group TEXT, question_index INTEGER,
                        question_json TEXT, answer_json TEXT, theme TEXT,
                        christ_focused INTEGER, references_json TEXT,
                        cross_references_json TEXT
                    );

                    INSERT INTO translations VALUES ('BIBLE', 'Bundled Bible', 'BB', 'en', NULL);
                    INSERT INTO translation_books VALUES (1, 'BIBLE', 1, 'Gen', 'Genesis', 'OT', 1);
                    INSERT INTO translation_verses VALUES (
                        1, 'BIBLE', 1001001, 1, 1, 1, 'In the beginning', 1,
                        NULL, NULL, NULL, NULL
                    );
                    INSERT INTO lexicons VALUES ('DICT', 'Bundled Dictionary', 'en');
                    INSERT INTO dictionary_entries VALUES (
                        1, 'DICT', 'G1', 'alpha', NULL, NULL,
                        '[{"definition":"first"}]', NULL, 'first'
                    );
                    INSERT INTO dictionary_entries VALUES (
                        2, 'DICT', 'BDB3', 'ab', NULL, NULL,
                        '[{"definition":"BDB first"}]', NULL, 'BDB first'
                    );
                    INSERT INTO dictionary_entries VALUES (
                        3, 'DICT', 'BDB9264', 'ab', NULL, NULL,
                        '[{"definition":"BDB second"}]', NULL, 'BDB second'
                    );
                    INSERT INTO lexicon_mappings (mapping_id, source_key, target_keys_json)
                    VALUES ('strongs_hebrew_to_bdb', 'H3', '["BDB3","BDB9264"]');
                    INSERT INTO modules VALUES ('COMM', 'commentary', 'Bundled Commentary', 'BC');
                    INSERT INTO modules VALUES ('DEV', 'devotional', 'Bundled Devotionals', NULL);
                    INSERT INTO commentary_units VALUES (
                        'c1', 'COMM', 1, 1, 1001001, NULL, 'verse', 1, NULL,
                        NULL, NULL, '"Creation commentary"', NULL, 0
                    );
                    INSERT INTO devotional_entries VALUES (
                        'dev1', 'DEV', 'Creation Hope', NULL, 'Author', '2026-08-02',
                        'hope', 'reflection', NULL, NULL,
                        '[{"sv":1001001,"label":"Genesis 1:1"}]',
                        '"A summary"',
                        '[{"type":"paragraph","content":{"text":"A devotional body"}}]',
                        NULL, 1700000000, 1700000001, 'Creation Hope A devotional body'
                    );
                    INSERT INTO plans VALUES ('PLAN', 'Bundled Plan', NULL, NULL, NULL, 1, 1);
                    INSERT INTO plan_days VALUES ('PLAN', 1, '[{"sv":1001001,"ev":1001999}]');
                    INSERT INTO quiz_modules VALUES (
                        'QUIZ', 'PLAN', 'Bundled Quiz', NULL, 1,
                        '[{"id":"adult","label":"Adult","ageRange":"18+"}]'
                    );
                    INSERT INTO quiz_questions VALUES (
                        1, 'QUIZ', 1, 1001001, 1001999, 'adult', 0,
                        '{"text":"Who created?","annotations":[{"type":"scripture","start":0,"end":3,"text":"Who","data":{"sv":1001001,"ev":1001002}}]}',
                        '{"text":"God created.","annotations":[{"type":"scripture","start":0,"end":3,"text":"God","data":{"sv":1001003}}]}',
                        'doctrine', 0,
                        '[1001001]', '[]'
                    );
                    """#)
            }
        }

        let archiveURL = fixtureURL.appendingPathComponent("bundled_modules.db.zlib")
        let databaseData = try Data(contentsOf: databaseURL)
        let compressedData = try (databaseData as NSData).compressed(using: .zlib) as Data
        try compressedData.write(to: archiveURL)
        let library = LampLibrary(
            rootURL: fixtureURL.appendingPathComponent("Library"),
            bundledModulesArchiveURL: archiveURL
        )

        let modules = try await library.installedModules()
        #expect(modules.count == 6)
        #expect(modules.filter { !$0.isBundled }.isEmpty)
        #expect(try await library.chapter(moduleID: "BIBLE", bookNumber: 1, chapterNumber: 1)
            .verses.first?.text == "In the beginning")
        #expect(try await library.searchDictionaries(query: "alpha").first?.moduleID == "DICT")
        #expect(try await library.lexiconMappings(sourceKey: "h0003") == ["BDB3", "BDB9264"])
        let mappedEntries = try await library.dictionaryEntries(
            keys: try await library.lexiconMappings(sourceKey: "H3")
        )
        #expect(mappedEntries.map(\.key) == ["BDB3", "BDB9264"])
        #expect(try await library.commentary(bookNumber: 1, chapterNumber: 1).first?.moduleID == "COMM")
        #expect(try await library.devotionals().first?.content == "A devotional body")
        #expect(try await library.readingPlans().first?.id == "PLAN")
        #expect(try await library.quizModules(planID: "PLAN").first?.id == "QUIZ")
        let questions = try await library.quizQuestions(moduleID: "QUIZ", day: 1, ageGroup: "adult")
        #expect(questions.first?.question == "Who created?")
        #expect(questions.first?.answer == "God created.")
        #expect(questions.first?.questionAnnotations.first?.startReference == 1_001_001)
        #expect(questions.first?.questionAnnotations.first?.endReference == 1_001_002)
        #expect(questions.first?.answerAnnotations.first?.startReference == 1_001_003)

        let creationResults = try await library.searchModules(query: "Creation")
        #expect(creationResults.contains { $0.kind == .commentary && $0.moduleID == "COMM" })
        #expect(creationResults.contains { $0.kind == .devotional && $0.moduleID == "DEV" })
        let quizResults = try await library.searchModules(query: "God", kinds: [.quiz])
        #expect(quizResults.first?.moduleID == "QUIZ")
        #expect(quizResults.first?.startReference == 1_001_001)
        let planResults = try await library.searchModules(query: "Bundled", kinds: [.plan])
        #expect(planResults.first?.moduleID == "PLAN")
    }
}
