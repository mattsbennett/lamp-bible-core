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

    @Test func rejectsArrayRoot() {
        #expect(throws: ModuleInspectionError.rootMustBeObject) {
            try inspector.inspect(Data("[]".utf8))
        }
    }
}
