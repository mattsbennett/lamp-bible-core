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
        let everyModule = LampAgentAccessPolicy()
        #expect(try JSONDecoder().decode(LampAgentAccessPolicy.self, from: JSONEncoder().encode(everyModule)) == everyModule)
    }

    /// What a write checks against: the whole body, whatever the agent may
    /// read, and no text given out.
    @Test func aPersonalDevotionalsRevisionFollowsItsWholeBody() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("LampAgentRevision-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let library = LampLibrary(rootURL: fixture.appendingPathComponent("Library"))
        let opening = String(repeating: "In the beginning was the Word. ", count: 2_000)
        func save(_ ending: String) async throws {
            _ = try await library.savePersonalDevotional(LampDevotional(
                id: "w", moduleID: "personal-devotionals", moduleName: "My Writing",
                title: "Beginnings", content: opening + ending
            ))
        }
        // Reading is off, and the body is longer than any limit an agent reads to.
        let agent = LampAgentLibrary(library: library, policy: .disabled)

        #expect(try await agent.personalDevotionalRevision("w") == nil)
        try await save("And the Word was with God.")
        let first = try #require(try await agent.personalDevotionalRevision("w"))
        #expect(first.count == 64)
        #expect(try await agent.personalDevotionalRevision("w") == first)
        // An edit past where an agent's read would have been cut.
        try await save("And the Word was God.")
        #expect(try await agent.personalDevotionalRevision("w") != first)

        // The same words, accents composed or not, are the same writing. Swift's
        // == calls the two equal, so their bytes show they really differ.
        let composed = "Caf\u{E9} and gr\u{E2}ce."
        let decomposed = "Cafe\u{301} and gra\u{302}ce."
        #expect(Array(composed.utf8) != Array(decomposed.utf8))
        try await save(decomposed)
        // Stored as written, so it is the hash that composes it.
        let stored = try await library.personalDevotionals().first { $0.id == "w" }?.content
        #expect(stored.map { Array($0.utf8) } == Array((opening + decomposed).utf8))
        let fromDecomposed = try await agent.personalDevotionalRevision("w")
        try await save(composed)
        #expect(try await agent.personalDevotionalRevision("w") == fromDecomposed)
    }

    /// A policy missing keys still reads, with access off unless it says
    /// otherwise, so a field added later leaves the files on disk readable.
    @Test func anAccessPolicyMissingKeysReadsWithItsDefaults() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(LampAgentAccessPolicy.self, from: Data("{}".utf8)) == LampAgentAccessPolicy(isEnabled: false))
        #expect(try decoder.decode(LampAgentAccessPolicy.self, from: Data(#"{"isEnabled":true}"#.utf8)) == LampAgentAccessPolicy())
    }

    /// A limit edited by hand is held to the bounds the app's own are.
    @Test func anAccessPolicyLimitFromAFileIsClamped() throws {
        let file = #"{"isEnabled":true,"maximumSearchResults":10000,"maximumPassageVerses":0,"maximumItemCharacters":5}"#
        let policy = try JSONDecoder().decode(LampAgentAccessPolicy.self, from: Data(file.utf8))
        #expect(policy.maximumSearchResults == 200)
        #expect(policy.maximumPassageVerses == 1)
        #expect(policy.maximumItemCharacters == 1_000)
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
