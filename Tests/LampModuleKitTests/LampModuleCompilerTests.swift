import Foundation
import GRDB
import Testing
@testable import LampModuleKit

struct LampModuleCompilerTests {
    @Test func compilesCompactTranslationAndPreservesFootnoteReferences() throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        let outputURL = fixture.url.appendingPathComponent("TEST.lamp")

        let result = try LampModuleCompiler().compile(
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
                  "verses": [{
                    "v": 1,
                    "ref": 1001001,
                    "content": {
                      "text": "In the beginning",
                      "annotations": [{"start": 0, "end": 2}],
                      "footnoteRefs": [{"id": "a", "start": 3}]
                    },
                    "footnotes": [{"id": "a", "text": "A note"}],
                    "paragraph": true
                  }]
                }]
              }]
            }
            """#.utf8),
            sourceFilename: "TEST.json",
            destinationURL: outputURL
        )

        #expect(result.kind == .translation)
        #expect(result.tableCounts["verses"] == 1)
        #expect(result.compressedByteCount < result.uncompressedByteCount)
        #expect(result.sha256.count == 64)

        let queue = try fixture.openLamp(outputURL)
        try queue.read { db in
            let translationID = try String.fetchOne(db, sql: "SELECT id FROM translation_meta")
            let headingCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM headings")
            let fetchedRow = try Row.fetchOne(db, sql: "SELECT ref, footnote_refs_json FROM verses")
            let row = try #require(fetchedRow)
            #expect(translationID == "TEST")
            #expect(headingCount == 1)
            #expect(row["ref"] as Int == 1_001_001)
            let references: String? = row["footnote_refs_json"]
            #expect(references?.contains("\"id\":\"a\"") == true)
            let integrity = try String.fetchOne(db, sql: "PRAGMA quick_check")
            #expect(integrity == "ok")
        }
    }

    @Test func compilesDictionaryAndNormalizesLegacySenseKeys() throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        let outputURL = fixture.url.appendingPathComponent("test_dict.lamp")

        let result = try LampModuleCompiler().compile(
            data: Data(#"""
            {
              "meta": {
                "schemaVersion": "2.1",
                "id": "test_dict",
                "type": "dictionary",
                "name": "Test Dictionary",
                "keyType": "strongs"
              },
              "entries": [{
                "key": "G1",
                "lemma": "alpha",
                "senses": [{
                  "short_definition": "first",
                  "part_of_speech": "noun",
                  "translation_usages": ["beginning"]
                }],
                "source": "fixture"
              }]
            }
            """#.utf8),
            sourceFilename: "test_dict.json",
            destinationURL: outputURL
        )

        #expect(result.tableCounts["dictionary_entries"] == 1)
        let queue = try fixture.openLamp(outputURL)
        try queue.read { db in
            let fetchedRow = try Row.fetchOne(db, sql: "SELECT senses_json, metadata_json FROM dictionary_entries")
            let row = try #require(fetchedRow)
            let senses: String? = row["senses_json"]
            let metadata: String? = row["metadata_json"]
            #expect(senses?.contains("\"shortDefinition\":\"first\"") == true)
            #expect(senses?.contains("\"translationUsages\":[\"beginning\"]") == true)
            #expect(metadata?.contains("\"source\":\"fixture\"") == true)
        }
    }

    @Test func compilesHierarchicalCommentary() throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        let outputURL = fixture.url.appendingPathComponent("test_commentary.lamp")

        let result = try LampModuleCompiler().compile(
            data: Data(#"""
            {
              "meta": {
                "schemaVersion": "2.1",
                "seriesAbbrev": "TEST",
                "seriesFull": "Test Commentary",
                "title": "Genesis",
                "author": "Example Author"
              },
              "book": "Gen",
              "bookNumber": 1,
              "chapters": [{
                "chapter": 1,
                "introduction": [{"type": "paragraph", "text": "Chapter introduction"}],
                "sections": [{
                  "title": "Creation",
                  "sv": 1001001,
                  "ev": 1001002,
                  "pericopae": [{
                    "title": "The beginning",
                    "sv": 1001001,
                    "ev": 1001002,
                    "verses": [{
                      "sv": 1001001,
                      "translation": [{"type": "paragraph", "text": "In the beginning"}],
                      "commentary": [{"type": "paragraph", "text": "An explanation"}]
                    }]
                  }]
                }]
              }]
            }
            """#.utf8),
            sourceFilename: "test_commentary.json",
            destinationURL: outputURL
        )

        #expect(result.kind == .commentary)
        #expect(result.tableCounts["commentary_units"] == 4)
        let queue = try fixture.openLamp(outputURL)
        try queue.read { db in
            let moduleID = try String.fetchOne(db, sql: "SELECT module_id FROM commentary_books")
            let verseCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM commentary_units WHERE unit_type = 'verse'")
            let childCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM commentary_units WHERE parent_id IS NOT NULL")
            #expect(moduleID == "test_commentary")
            #expect(verseCount == 1)
            #expect(childCount == 2)
        }
    }

    @Test func compilesReadingPlan() throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        let outputURL = fixture.url.appendingPathComponent("test_plan.lamp")

        let result = try LampModuleCompiler().compile(
            data: Data(#"""
            {
              "meta": {
                "schemaVersion": "1.0",
                "id": "test_plan",
                "type": "plan",
                "name": "Test Plan",
                "description": "A small fixture",
                "author": "Lamp Bible",
                "duration": 2,
                "readingsPerDay": 1
              },
              "days": [
                {"day": 1, "readings": [{"sv": 1001001, "ev": 1001999}]},
                {"day": 2, "readings": [{"sv": 40001001, "ev": 40001999}]}
              ]
            }
            """#.utf8),
            sourceFilename: "test_plan.json",
            destinationURL: outputURL
        )

        #expect(result.kind == .plan)
        #expect(result.tableCounts["plans"] == 1)
        #expect(result.tableCounts["plan_days"] == 2)
        let queue = try fixture.openLamp(outputURL)
        try queue.read { db in
            let planName = try String.fetchOne(db, sql: "SELECT name FROM plans")
            let days = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM plan_days")
            let readingsJSON = try String.fetchOne(db, sql: "SELECT readings_json FROM plan_days WHERE day = 1")
            #expect(planName == "Test Plan")
            #expect(days == 2)
            #expect(readingsJSON?.contains("\"sv\":1001001") == true)
        }
    }

    @Test func compilesCanonicalNotesForIOSImport() throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        let outputURL = fixture.url.appendingPathComponent("test_notes.lamp")

        let result = try LampModuleCompiler().compile(
            data: Data(#"""
            {
              "meta": {
                "schemaVersion": "1.1", "id": "test_notes",
                "type": "notes", "name": "Study Notes", "author": "A Reader"
              },
              "book": "Gen", "bookNumber": 1,
              "chapters": [{
                "chapter": 1,
                "introduction": {"text": "Notes on creation"},
                "footnotes": [{"id": "i", "content": "An introduction note"}],
                "verses": [{
                  "sv": 1001001, "ev": 1001002,
                  "commentary": {
                    "text": "The opening words matter.",
                    "annotations": [{
                      "type": "scripture", "start": 4, "end": 11,
                      "data": {"sv": 43001001}
                    }]
                  },
                  "footnotes": [{
                    "id": "1", "content": {"text": "Compare John 1:1"}
                  }],
                  "lastModified": 1700000000
                }]
              }]
            }
            """#.utf8),
            sourceFilename: "test_notes.json",
            destinationURL: outputURL
        )

        #expect(result.kind == .notes)
        #expect(result.tableCounts["note_entries"] == 2)
        let queue = try fixture.openLamp(outputURL)
        try queue.read { db in
            let metaName = try String.fetchOne(db, sql: "SELECT name FROM module_meta")
            let entries = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_entries")
            let row = try #require(try Row.fetchOne(
                db,
                sql: "SELECT * FROM note_entries WHERE verse_id = 1001001"
            ))
            let rangeJSON: String? = row["verse_refs_json"]
            let footnotesJSON: String? = row["footnotes_json"]
            let searchText: String? = row["search_text"]
            #expect(metaName == "Study Notes")
            #expect(entries == 2)
            #expect(row["content"] as String == "The opening words matter.")
            #expect(rangeJSON == "[1001002]")
            #expect(footnotesJSON?.contains("Compare John 1:1") == true)
            #expect(searchText == "The opening words matter. Compare John 1:1")
        }
    }

    @Test func compilesCanonicalHighlightsForIOSImport() throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        let outputURL = fixture.url.appendingPathComponent("test_highlights.lamp")

        let result = try LampModuleCompiler().compile(
            data: Data(#"""
            {
              "meta": {
                "schemaVersion": "1.0", "id": "test_highlights",
                "type": "highlights", "name": "Study Highlights",
                "translationId": "ESV", "created": 1700000000,
                "lastModified": 1700000100,
                "themes": [{
                  "color": "#ffcc00", "style": 0,
                  "name": "Promises", "description": "Promises of God"
                }]
              },
              "verses": [{
                "ref": 43003016,
                "highlights": [
                  {"sc": 0, "ec": 3, "style": 0, "color": "#ffcc00"},
                  {"sc": 4, "ec": 9, "style": 1, "color": "blue"}
                ]
              }]
            }
            """#.utf8),
            sourceFilename: "test_highlights.json",
            destinationURL: outputURL
        )

        #expect(result.kind == .highlights)
        #expect(result.tableCounts["highlights"] == 2)
        #expect(result.tableCounts["highlight_themes"] == 1)
        let queue = try fixture.openLamp(outputURL)
        try queue.read { db in
            let translationID = try String.fetchOne(db, sql: "SELECT translation_id FROM highlight_meta")
            let colors = try String.fetchAll(db, sql: "SELECT color FROM highlights ORDER BY id")
            let themeColor = try String.fetchOne(db, sql: "SELECT color FROM highlight_themes")
            #expect(translationID == "ESV")
            #expect(colors == ["FFCC00", "blue"])
            #expect(themeColor == "FFCC00")
        }
    }

    @Test func compilesCanonicalDevotionalForIOSImport() throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        let outputURL = fixture.url.appendingPathComponent("test_devotional.lamp")

        let result = try LampModuleCompiler().compile(
            data: Data(#"""
            {
              "meta": {
                "schemaVersion": "1.1", "id": "test_devotional",
                "type": "devotional", "title": "Hope in Christ",
                "subtitle": "A short reflection", "author": "Lamp Bible",
                "date": "2026-08-02", "tags": ["hope", "faith"],
                "category": "reflection",
                "series": {"id": "foundations", "name": "Foundations", "order": 1},
                "keyScriptures": [{"sv": 43003016, "ev": 43003017, "label": "John 3:16–17"}],
                "created": 1700000000, "lastModified": 1700000100
              },
              "summary": "God's promise gives hope.",
              "content": [{
                "type": "paragraph",
                "content": {"text": "God loved the world and gave his Son."}
              }],
              "footnotes": [{"id": "a", "content": "Compare Romans 5."}],
              "relatedDevotionals": ["grace"],
              "media": []
            }
            """#.utf8),
            sourceFilename: "test_devotional.json",
            destinationURL: outputURL
        )

        #expect(result.kind == .devotional)
        #expect(result.tableCounts["devotional_entries"] == 1)
        let queue = try fixture.openLamp(outputURL)
        try queue.read { db in
            let row = try #require(try Row.fetchOne(db, sql: "SELECT * FROM devotional_entries"))
            #expect(row["module_id"] as String == "test_devotional")
            #expect(row["title"] as String == "Hope in Christ")
            #expect(row["tags"] as String == "hope,faith")
            #expect((row["summary_json"] as String?)?.contains("God's promise") == true)
            #expect((row["content_json"] as String).contains("gave his Son") == true)
            #expect((row["search_text"] as String?)?.contains("Compare Romans 5") == true)
        }
    }

    @Test func compilesCanonicalQuizForIOSImport() throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        let outputURL = fixture.url.appendingPathComponent("test_quiz.lamp")

        let result = try LampModuleCompiler().compile(
            data: Data(#"""
            {
              "meta": {
                "schemaVersion": "1.0", "id": "test_quiz", "type": "quiz",
                "planId": "test_plan", "name": "Test Quiz",
                "questionsPerReading": 1,
                "ageGroups": [{"id": "adult", "label": "Adult", "ageRange": "18+"}]
              },
              "days": [{
                "day": 1,
                "readings": [{
                  "sv": 1001001, "ev": 1001999,
                  "quizzes": {"adult": [{
                    "question": {"text": "Who created the heavens?"},
                    "answer": "God created the heavens and the earth.",
                    "theme": "doctrine", "christFocused": false,
                    "references": [1001001], "crossReferences": [58001002]
                  }]}
                }]
              }]
            }
            """#.utf8),
            sourceFilename: "test_quiz.json",
            destinationURL: outputURL
        )

        #expect(result.kind == .quiz)
        #expect(result.tableCounts["quiz_questions"] == 1)
        let queue = try fixture.openLamp(outputURL)
        try queue.read { db in
            let module = try #require(try Row.fetchOne(db, sql: "SELECT * FROM quiz_modules"))
            let question = try #require(try Row.fetchOne(db, sql: "SELECT * FROM quiz_questions"))
            #expect(module["plan_id"] as String == "test_plan")
            #expect((module["age_groups_json"] as String).contains("adult") == true)
            #expect(question["day"] as Int == 1)
            #expect((question["question_json"] as String).contains("Who created") == true)
            #expect((question["answer_json"] as String).contains("God created") == true)
            #expect(question["theme"] as String == "doctrine")
        }
    }

    @Test func compilesHierarchicalBookForLibraryImport() throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }
        let outputURL = fixture.url.appendingPathComponent("test_book.lamp")

        let result = try LampModuleCompiler().compile(
            data: Data(#"""
            {
              "meta": {
                "schemaVersion": "1.0", "id": "test_book", "type": "book",
                "title": "The Test Book", "subtitle": "A useful volume",
                "author": "Lamp Bible", "language": "en",
                "tags": ["study", "test"]
              },
              "sections": [{
                "id": "part-one", "type": "part", "title": "Part One",
                "sections": [{
                  "id": "chapter-one", "type": "chapter", "number": 1,
                  "title": "The Beginning",
                  "keyScriptures": [{"sv": 1001001, "ev": 1001003}],
                  "content": [
                    {"type": "paragraph", "content": {"text": "Grace in the beginning."}},
                    {"type": "list", "listType": "bullet", "items": [
                      {"content": {"text": "A nested thought"}}
                    ]}
                  ]
                }]
              }],
              "footnotes": [{"id": "1", "content": "A note."}]
            }
            """#.utf8),
            sourceFilename: "test_book.json",
            destinationURL: outputURL
        )

        #expect(result.kind == .book)
        #expect(result.tableCounts["book_sections"] == 2)
        let queue = try fixture.openLamp(outputURL)
        try queue.read { db in
            let module = try #require(try Row.fetchOne(db, sql: "SELECT * FROM book_modules"))
            #expect(module["title"] as String == "The Test Book")
            #expect(module["language"] as String == "en")
            #expect((module["tags_json"] as String?)?.contains("study") == true)

            let sections = try Row.fetchAll(db, sql: "SELECT * FROM book_sections ORDER BY rowid")
            #expect(sections.count == 2)
            #expect(sections[1]["parent_id"] as String? == "test_book:part-one")
            #expect(sections[1]["depth"] as Int == 1)
            #expect((sections[1]["search_text"] as String).contains("nested thought"))

            let matches = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM book_sections_fts WHERE book_sections_fts MATCH 'grace'"
            )
            #expect(matches == 1)
        }
    }

    @Test func enforcesModuleIdentityFilename() throws {
        let fixture = try FixtureDirectory()
        defer { fixture.remove() }

        do {
            _ = try LampModuleCompiler().compile(
                data: Data(#"""
                {
                  "meta": {
                    "schemaVersion": "2.1",
                    "id": "right_name",
                    "type": "dictionary",
                    "name": "Test"
                  },
                  "entries": []
                }
                """#.utf8),
                sourceFilename: "right_name.json",
                destinationURL: fixture.url.appendingPathComponent("wrong_name.lamp")
            )
            Issue.record("Expected output filename validation to fail")
        } catch let error as ModuleCompilationError {
            guard case .outputNameMismatch(let expected, let actual) = error else {
                Issue.record("Unexpected compilation error: \(error)")
                return
            }
            #expect(expected == "right_name")
            #expect(actual == "wrong_name")
        }
    }
}

private struct FixtureDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-module-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func openLamp(_ lampURL: URL) throws -> DatabaseQueue {
        let compressed = try Data(contentsOf: lampURL)
        let database = try (compressed as NSData).decompressed(using: .zlib) as Data
        let databaseURL = url.appendingPathComponent("\(UUID().uuidString).sqlite")
        try database.write(to: databaseURL)
        var configuration = Configuration()
        configuration.readonly = true
        return try DatabaseQueue(path: databaseURL.path, configuration: configuration)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
