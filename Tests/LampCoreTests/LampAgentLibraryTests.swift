import Foundation
import LampCore
import LampModuleKit
import Testing

struct LampAgentLibraryTests {
    @Test func parsesHumanReferencesAndCommonAliases() throws {
        #expect(try LampReferenceParser.parse("John 1:1-3") == LampAgentReferenceRange(
            start: LampAgentReferencePoint(book: 43, chapter: 1, verse: 1),
            end: LampAgentReferencePoint(book: 43, chapter: 1, verse: 3)
        ))
        #expect(try LampReferenceParser.parse("Jn 1:1–2:3") == LampAgentReferenceRange(
            start: LampAgentReferencePoint(book: 43, chapter: 1, verse: 1),
            end: LampAgentReferencePoint(book: 43, chapter: 2, verse: 3)
        ))
        #expect(try LampReferenceParser.parse("1 John 1") == LampAgentReferenceRange(
            start: LampAgentReferencePoint(book: 62, chapter: 1),
            end: LampAgentReferencePoint(book: 62, chapter: 1)
        ))
        #expect(throws: LampAgentError.self) {
            try LampReferenceParser.parse("John 2:3-1:1")
        }
    }

    @Test func readsCleanCrossChapterPassagesAndEnforcesPolicy() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-agent-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let moduleURL = fixture.appendingPathComponent("AGENT_TEST.lamp")
        _ = try LampModuleCompiler().compile(
            data: Data(#"""
            {
              "meta": {
                "schemaVersion": "1.0", "id": "AGENT_TEST", "type": "translation",
                "name": "Agent Test Bible", "abbreviation": "ATB", "language": "en"
              },
              "books": [{
                "id": "John", "name": "John", "number": 43, "testament": "NT",
                "chapters": [
                  {"chapter": 1, "verses": [
                    {"v": 1, "ref": 43001001, "content": {"text": "The Word was in the beginning"}},
                    {"v": 2, "ref": 43001002, "content": {"text": "He was with God"}}
                  ]},
                  {"chapter": 2, "verses": [
                    {"v": 1, "ref": 43002001, "content": {"text": "On the third day"}},
                    {"v": 2, "ref": 43002002, "content": {"text": "Jesus was invited"}}
                  ]}
                ]
              }]
            }
            """#.utf8),
            sourceFilename: "AGENT_TEST.json",
            destinationURL: moduleURL
        )
        let library = LampLibrary(rootURL: fixture.appendingPathComponent("Library"))
        _ = try await library.install(from: moduleURL)
        let agent = LampAgentLibrary(library: library)

        let catalog = try await agent.listModules()
        #expect(catalog.map(\.id) == ["AGENT_TEST"])
        let passage = try #require(try await agent.readPassage(
            reference: "John 1:2-2:1",
            translationIDs: ["AGENT_TEST"]
        ).first)
        #expect(passage.reference == "John 1:2–2:1")
        #expect(passage.verses.map(\.text) == ["He was with God", "On the third day"])
        #expect(passage.verses.allSatisfy { $0.annotations.isEmpty })

        let search = try await agent.searchLibrary(query: "invited")
        #expect(search.first?.moduleID == "AGENT_TEST")
        #expect(search.first?.reference == "John 2:2")

        await agent.updatePolicy(LampAgentAccessPolicy(allowedModuleIDs: []))
        #expect(try await agent.listModules().isEmpty)
        await #expect(throws: LampAgentError.self) {
            try await agent.readPassage(
                reference: "John 1:1",
                translationIDs: ["AGENT_TEST"]
            )
        }
    }

    @Test func accessPolicyRoundTripsAsJSON() throws {
        let policy = LampAgentAccessPolicy(
            allowedModuleIDs: ["A", "B"],
            includesPersonalContent: true,
            maximumSearchResults: 25,
            maximumPassageVerses: 80,
            maximumItemCharacters: 12_000
        )
        let data = try JSONEncoder().encode(policy)
        #expect(try JSONDecoder().decode(LampAgentAccessPolicy.self, from: data) == policy)
    }

    @Test func browsesAndReadsLongFormBookSections() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-agent-book-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let moduleURL = fixture.appendingPathComponent("AGENT_BOOK.lamp")
        _ = try LampModuleCompiler().compile(
            data: Data(#"""
            {
              "meta": {
                "schemaVersion": "1.0", "id": "AGENT_BOOK", "type": "book",
                "title": "Agent Book", "author": "Lamp", "language": "en"
              },
              "sections": [{
                "id": "chapter-1", "type": "chapter", "title": "Grace",
                "keyScriptures": [{"sv": 43001014}],
                "content": [{"type": "paragraph", "content": "Grace and truth came through Jesus Christ."}]
              }]
            }
            """#.utf8),
            sourceFilename: "AGENT_BOOK.json",
            destinationURL: moduleURL
        )
        let library = LampLibrary(rootURL: fixture.appendingPathComponent("Library"))
        _ = try await library.install(from: moduleURL)
        let agent = LampAgentLibrary(library: library)

        #expect(try await agent.listBooks().map(\.id) == ["AGENT_BOOK"])
        let summary = try #require(try await agent.listBookSections(moduleID: "AGENT_BOOK").first)
        #expect(summary.sectionID == "chapter-1")
        #expect(summary.keyScriptures == ["John 1:14"])
        let section = try await agent.readBookSection(
            moduleID: "AGENT_BOOK",
            sectionID: "chapter-1"
        )
        #expect(section.content == "Grace and truth came through Jesus Christ.")
    }
}
