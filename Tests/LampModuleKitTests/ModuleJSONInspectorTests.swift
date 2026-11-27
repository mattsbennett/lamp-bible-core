import Foundation
import Testing
@testable import LampModuleKit

struct ModuleJSONInspectorTests {
    private let inspector = ModuleJSONInspector()

    @Test func detectsAndValidatesTranslation() throws {
        let result = try inspector.inspect(Data(#"""
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
              "verses": [{"v": 1, "ref": 1001001, "content": {"text": "In the beginning"}}]
            }]
          }]
        }
        """#.utf8))

        #expect(result.kind == .translation)
        #expect(result.metadata.id == "TEST")
        #expect(result.canCompile)
        #expect(result.statistics == ["books": 1, "chapters": 1, "verses": 1])
    }

    @Test func reportsMismatchedTranslationReference() throws {
        let result = try inspector.inspect(Data(#"""
        {
          "meta": {
            "schemaVersion": "1.0",
            "id": "TEST",
            "type": "translation",
            "name": "Test",
            "abbreviation": "TST",
            "language": "en"
          },
          "books": [{"number": 40, "chapters": [{"chapter": 1, "verses": [{"v": 1, "ref": 1001001}]}]}]
        }
        """#.utf8))

        #expect(!result.canCompile)
        #expect(result.issues.contains { $0.path == "/books/0/chapters/0/verses/0/ref" })
    }

    @Test func infersCommentaryWithoutDeclaredType() throws {
        let result = try inspector.inspect(Data(#"""
        {
          "meta": {
            "schemaVersion": "2.1",
            "seriesAbbrev": "TEST",
            "seriesFull": "Test Commentary",
            "title": "Genesis"
          },
          "book": "Gen",
          "bookNumber": 1,
          "chapters": []
        }
        """#.utf8))

        #expect(result.kind == .commentary)
        #expect(result.canCompile)
        #expect(result.metadata.name == "Genesis")
    }

    @Test func acceptsNamedCrossReferenceCommentary() throws {
        let result = try inspector.inspect(Data(#"""
        {
          "meta": {
            "schemaVersion": "2.0", "id": "crossrefs_Gen",
            "type": "commentary", "name": "Cross-References",
            "seriesAbbrev": "XRef", "seriesFull": "Cross-References"
          },
          "book": "Gen", "bookNumber": 1,
          "chapters": [{"chapter": 1, "verses": []}]
        }
        """#.utf8))

        #expect(result.kind == .commentary)
        #expect(result.canCompile)
        #expect(result.metadata.id == "crossrefs_Gen")
    }

    @Test func reportsDuplicateDictionaryKeys() throws {
        let result = try inspector.inspect(Data(#"""
        {
          "meta": {
            "schemaVersion": "2.1",
            "id": "test_dict",
            "type": "dictionary",
            "name": "Test Dictionary"
          },
          "entries": [
            {"key": "G1", "lemma": "alpha"},
            {"key": "G1", "lemma": "alpha again"}
          ]
        }
        """#.utf8))

        #expect(!result.canCompile)
        #expect(result.issues.contains { $0.message.contains("Duplicate entry key") })
    }

    @Test func rejectsInvalidPlanDaysAndRanges() throws {
        let result = try inspector.inspect(Data(#"""
        {
          "meta": {
            "schemaVersion": "1.0", "id": "test_plan",
            "type": "plan", "name": "Test Plan"
          },
          "days": [
            {"day": 1, "readings": [{"sv": 1002001, "ev": 1001001}]},
            {"day": 1, "readings": []},
            {"day": 367, "readings": []}
          ]
        }
        """#.utf8))

        #expect(!result.canCompile)
        #expect(result.issues.contains { $0.message.contains("precedes start") })
        #expect(result.issues.contains { $0.message.contains("Duplicate day") })
        #expect(result.issues.contains { $0.message.contains("1 through 366") })
    }

    @Test func validatesNotesReferencesAndHighlightSpans() throws {
        let notes = try inspector.inspect(Data(#"""
        {
          "meta": {"id": "notes", "type": "notes"},
          "book": "Gen", "bookNumber": 1,
          "chapters": [{
            "chapter": 1,
            "verses": [
              {"sv": 2001001, "commentary": "Wrong book"},
              {"sv": 2001001, "ev": 1001000, "commentary": "Duplicate"}
            ]
          }]
        }
        """#.utf8))
        #expect(!notes.canCompile)
        #expect(notes.issues.contains { $0.message.contains("does not belong") })
        #expect(notes.issues.contains { $0.message.contains("Duplicate note reference") })
        #expect(notes.issues.contains { $0.message.contains("precedes start") })

        let highlights = try inspector.inspect(Data(#"""
        {
          "meta": {
            "schemaVersion": "1.0", "id": "highlights", "type": "highlights",
            "translationId": "ESV"
          },
          "verses": [{
            "ref": 43003016,
            "highlights": [
              {"sc": 8, "ec": 4, "style": 0},
              {"sc": 0, "ec": 4, "style": 9}
            ]
          }]
        }
        """#.utf8))
        #expect(!highlights.canCompile)
        #expect(highlights.issues.contains { $0.path.hasSuffix("/ec") })
        #expect(highlights.issues.contains { $0.path.hasSuffix("/style") })
    }

    @Test func validatesQuizAgeGroupsAndQuestions() throws {
        let quiz = try inspector.inspect(Data(#"""
        {
          "meta": {
            "schemaVersion": "1.0", "id": "quiz", "type": "quiz",
            "planId": "plan", "name": "Quiz",
            "ageGroups": [{"id": "adult", "label": "Adult", "ageRange": "18+"}]
          },
          "days": [{
            "day": 1,
            "readings": [{
              "sv": 1001001, "ev": 1001999,
              "quizzes": {
                "unknown": [{
                  "question": "Question", "answer": "Answer",
                  "theme": "narrative", "christFocused": false,
                  "references": [1001001]
                }]
              }
            }]
          }]
        }
        """#.utf8))

        #expect(quiz.kind == .quiz)
        #expect(!quiz.canCompile)
        #expect(quiz.issues.contains { $0.message.contains("undefined age group") })
    }

    @Test func rejectsEmptyDevotionalContent() throws {
        let devotional = try inspector.inspect(Data(#"""
        {
          "meta": {
            "schemaVersion": "1.1", "id": "devotional", "type": "devotional",
            "title": "Devotional"
          },
          "content": []
        }
        """#.utf8))

        #expect(devotional.kind == .devotional)
        #expect(!devotional.canCompile)
        #expect(devotional.issues.contains { $0.path == "/content" })
    }

    /// A table wider than readers lay out is warned about, and still builds:
    /// readers show it clipped, so refusing it would only stop it opening
    /// anywhere.
    @Test func atableWiderThanReadersShowIsAWarningNotAnError() throws {
        let book = try inspector.inspect(Data(#"""
        {
          "meta": {"schemaVersion": "1.0", "id": "wide-book", "type": "book", "title": "Wide", "language": "en"},
          "sections": [{
            "id": "charts", "type": "chapter", "title": "Charts",
            "content": [
              {"type": "table", "columnCount": 2, "rows": [{"cells": [
                {"column": 0, "content": {"text": "fits"}}, {"column": 1, "content": {"text": "too"}}
              ]}]},
              {"type": "table", "columnCount": 2, "rows": [{"cells": [
                {"column": 0, "content": {"text": "a"}},
                {"column": 1, "colSpan": 9223372036854775807, "content": {"text": "past every column"}},
                {"column": -1, "content": {"text": "before the first"}}
              ]}]}
            ]
          }]
        }
        """#.utf8))
        #expect(book.canCompile)
        let warnings = book.issues.filter { $0.severity == .warning }
        #expect(warnings.map(\.path) == ["/sections/0/content/1", "/sections/0/content/1"], "\(warnings)")

        // A figure's tables are laid out within the same bound.
        let inFigure = try inspector.inspect(Data(#"""
        {"meta": {"schemaVersion": "1.0", "id": "figure-book", "type": "book", "title": "F", "language": "en"},
         "sections": [{"id": "c", "type": "chapter", "title": "C", "content": [
           {"type": "figure", "children": [
             {"type": "table", "columnCount": 70, "rows": [{"cells": [{"column": 0, "content": {"text": "wide"}}]}]}
           ]}
         ]}]}
        """#.utf8))
        // Warned for its table, and for having no content to be drawn as.
        #expect(Set(inFigure.issues.filter { $0.severity == .warning }.map(\.path))
            == ["/sections/0/content/0/children/0", "/sections/0/content/0"])

        // Another block's `children` is never drawn, so never warned about.
        let notFigure = try inspector.inspect(Data(#"""
        {"meta": {"schemaVersion": "1.0", "id": "plain-book", "type": "book", "title": "P", "language": "en"},
         "sections": [{"id": "c", "type": "chapter", "title": "C", "content": [
           {"type": "paragraph", "content": {"text": "Shown"}, "children": [
             {"type": "table", "columnCount": 70, "rows": [{"cells": [{"column": 0, "content": {"text": "wide"}}]}]}
           ]}
         ]}]}
        """#.utf8))
        #expect(notFigure.issues.filter { $0.severity == .warning }.isEmpty, "\(notFigure.issues)")

        // A link that names no place a reader of the book can open is said.
        let dead = try inspector.inspect(Data(#"""
        {"meta": {"schemaVersion": "1.0", "id": "dead-book", "type": "book", "title": "D", "language": "en"},
         "sections": [{"id": "c", "type": "chapter", "title": "C", "content": [
           {"type": "paragraph", "content": {"text": "see the note", "annotations": [
             {"type": "link", "start": 4, "end": 12, "data": {"target": {"kind": "commentary", "module": "N", "sv": 1002001, "ev": 1001001}}}
           ]}},
           {"type": "paragraph", "content": {"text": "see the preface", "annotations": [
             {"type": "link", "start": 8, "end": 15, "data": {"target": {"section": "preface"}}}
           ]}},
           {"type": "paragraph", "content": {"text": "see the other", "annotations": [
             {"type": "link", "start": 4, "end": 13, "data": {"target": {"kind": "book", "module": 42, "section": "preface"}}}
           ]}},
           {"type": "paragraph", "content": {"text": "John 3:16", "annotations": [
             {"type": "scripture", "start": 0, "end": 9, "data": {"sv": 43003016, "target": {"section": "preface"}}}
           ]}},
           {"type": "paragraph", "content": {"text": "unrelated", "metadata": {"type": "link", "data": {"target": "source.pdf"}}}},
           {"type": "paragraph", "content": {"text": "nowhere", "annotations": [
             {"type": "link", "start": 3, "end": 3, "data": {"target": {"section": "preface"}}}
           ]}},
           {"type": "table", "columnCount": 1, "rows": [{"cells": [
             {"column": 0, "content": {"text": "shown"}},
             {"column": 0, "content": {"text": "hidden", "annotations": [
               {"type": "link", "start": 0, "end": 6, "data": {"target": {"sv": 1001001}}}
             ]}}
           ]}]}
         ]}],
         "footnotes": [{"id": "1", "content": {"text": "see it", "annotations": [
           {"type": "link", "start": 4, "end": 6, "data": {"target": {"kind": "commentary", "module": "N", "sv": 1002001, "ev": 1001001}}}
         ]}}]}
        """#.utf8))
        // The dead link, the one written wrong, a scripture note that is no
        // passage, one on no words, and a footnote's — not the live link,
        // metadata that is no annotation, nor a cell the layout hides.
        #expect(Set(dead.issues.filter { $0.severity == .warning }.map(\.path))
            == ["/sections/0/content/0", "/sections/0/content/2", "/sections/0/content/3",
                "/sections/0/content/5", "/footnotes/0/content"],
                "\(dead.issues)")

        // A fractional span is no clipping: readers cannot decode the table
        // at all, and the warning says so.
        let unreadable = try inspector.inspect(Data(#"""
        {
          "meta": {"schemaVersion": "1.0", "id": "odd-book", "type": "book", "title": "Odd", "language": "en"},
          "sections": [{"id": "c", "type": "chapter", "title": "C", "content": [
            {"type": "table", "columnCount": 2, "rows": [{"cells": [
              {"column": 0, "colSpan": 65.5, "content": {"text": "half a column"}}
            ]}]}
          ]}]
        }
        """#.utf8))
        #expect(unreadable.issues.map(\.message) == ["Readers cannot read this table, and leave it out."])
        #expect(book.issues.allSatisfy { $0.severity != .error })
    }

    /// A commentary in a version this build does not read is an error, not
    /// read as the nearest it does: a note given only as 2.3 `blocks`
    /// compiled to an empty unit that looked valid.
    @Test func acommentaryInAnUnreadVersionIsRefused() throws {
        func inspect(_ version: String) throws -> ModuleInspection {
            try inspector.inspect(Data(#"""
            {"meta":{"schemaVersion":"\#(version)","seriesAbbrev":"V","seriesFull":"V","title":"Genesis"},
             "book":"Gen","bookNumber":1,"chapters":[{"chapter":1,"verses":[{"sv":1001001,"commentary":{"text":"A note."}}]}]}
            """#.utf8))
        }
        for version in ["1.0", "2.0", "2.1", "2.2"] {
            #expect(try inspect(version).canCompile, "\(version)")
        }
        let unread = try inspect("2.3")
        #expect(!unread.canCompile)
        #expect(unread.issues.contains { $0.path == "/meta/schemaVersion" && $0.severity == .error })
    }

    /// A source-tracked commentary whose pericopae give a sourceOrder only
    /// some of the time is warned about: the two writers ordered it apart.
    @Test func amixedSourceOrderIsAWarning() throws {
        let mixed = try inspector.inspect(Data(#"""
        {"meta":{"schemaVersion":"2.2","seriesAbbrev":"M","seriesFull":"M","title":"Genesis"},
         "book":"Gen","bookNumber":1,"extraction":{"sourceTracked":true},"chapters":[
           {"chapter":1,"pericopae":[{"id":"a","sourceOrder":1,"sv":1001001,"content":[]},{"id":"b","sv":1001002,"content":[]}]}]}
        """#.utf8))
        #expect(mixed.canCompile)
        #expect(mixed.issues.contains { $0.severity == .warning && $0.path == "/chapters" }, "\(mixed.issues)")
    }

    @Test func validatesHierarchicalBookSections() throws {
        let book = try inspector.inspect(Data(#"""
        {
          "meta": {
            "schemaVersion": "1.0", "id": "test-book", "type": "book",
            "title": "Test Book", "language": "en"
          },
          "sections": [{
            "id": "part-one", "type": "part", "title": "Part One",
            "sections": [{
              "id": "chapter-one", "type": "chapter", "title": "Chapter One",
              "content": [{"type": "paragraph", "content": {"text": "Opening words."}}]
            }]
          }]
        }
        """#.utf8))

        #expect(book.kind == .book)
        #expect(book.canCompile)
        #expect(book.statistics == ["sections": 2, "contentBlocks": 1])

        let duplicate = try inspector.inspect(Data(#"""
        {
          "meta": {
            "schemaVersion": "1.0", "id": "invalid-book", "type": "book",
            "title": "Invalid Book", "language": "en"
          },
          "sections": [
            {"id": "same", "type": "chapter", "title": "One", "content": []},
            {"id": "same", "type": "chapter", "title": "Two", "content": [
              {"type": "paragraph", "content": {"text": "Two"}}
            ]}
          ]
        }
        """#.utf8))

        #expect(!duplicate.canCompile)
        #expect(duplicate.issues.contains { $0.message.contains("Duplicate section ID") })
        #expect(duplicate.issues.contains { $0.message.contains("needs content or child sections") })
    }

    @Test func rejectsArrayRoot() {
        #expect(throws: ModuleInspectionError.rootMustBeObject) {
            try inspector.inspect(Data("[]".utf8))
        }
    }
}
