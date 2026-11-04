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

    /// A module holding part of the Bible is the normal case — `TAHOT` is the
    /// Hebrew, `TAGNT` the Greek, the Septuagint modules have no Nehemiah — and
    /// asking one for a book it does not carry used to be reported as the
    /// reference being invalid, which sent the caller to correct `John 1:1`.
    @Test func amoduleWithoutTheBookSaysSoRatherThanBlamingTheReference() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-agent-books-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let moduleURL = fixture.appendingPathComponent("AGENT_JOHN.lamp")
        _ = try LampModuleCompiler().compile(
            data: Data(#"""
            {
              "meta": {
                "schemaVersion": "1.0", "id": "AGENT_JOHN", "type": "translation",
                "name": "John Only", "abbreviation": "JO", "language": "en"
              },
              "books": [{
                "id": "John", "name": "John", "number": 43, "testament": "NT",
                "chapters": [
                  {"chapter": 1, "verses": [
                    {"v": 1, "ref": 43001001, "content": {"text": "The Word was in the beginning"}}
                  ]}
                ]
              }]
            }
            """#.utf8),
            sourceFilename: "AGENT_JOHN.json",
            destinationURL: moduleURL
        )
        let library = LampLibrary(rootURL: fixture.appendingPathComponent("Library"))
        _ = try await library.install(from: moduleURL)
        let agent = LampAgentLibrary(library: library)

        await #expect(throws: LampAgentError.bookNotInModule(
            book: "Nehemiah", moduleID: "AGENT_JOHN"
        )) {
            try await agent.readPassage(reference: "Nehemiah 1:1", translationIDs: ["AGENT_JOHN"])
        }
        let said = LampAgentError.bookNotInModule(book: "Nehemiah", moduleID: "AGENT_JOHN")
            .errorDescription ?? ""
        #expect(said.contains("‘AGENT_JOHN’ has no Nehemiah"))
        #expect(!said.contains("not a valid Bible reference"))
        #expect(said.contains("inside another"))

        // A chapter the module's own book does not reach is still the
        // reference's problem, and a reference that cannot be read still is.
        await #expect(throws: LampAgentError.invalidReference("John 99:1")) {
            try await agent.readPassage(reference: "John 99:1", translationIDs: ["AGENT_JOHN"])
        }
        await #expect(throws: LampAgentError.self) {
            try await agent.readPassage(reference: "not a reference", translationIDs: ["AGENT_JOHN"])
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

    /// Laid out as NIC is: a pericope with no text of its own, holding every
    /// note in its source scope, over blocks that each carry the notes they
    /// cite, with a sub-heading among them.
    ///
    /// Served as stored, the container came first and was all a reader chat
    /// got of John 1:1–2 — its notes, and none of the exposition.
    @Test func commentaryIsServedAsItsTextUnderItsHeadings() async throws {
        let fixture = try temporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let library = try await commentaryLibrary(in: fixture, [
            "OUTLINED": #"""
            {"meta":{"schemaVersion":"2.2","id":"OUTLINED","seriesAbbrev":"OC","seriesFull":"Outlined Commentary","title":"John"},
             "book":"John","bookNumber":43,
             "footnotes":[
               {"id":"1","label":"1","content":{"text":"A note the exposition cites."}},
               {"id":"2","label":"2","content":{"text":"A note gathered from elsewhere in the volume."}}
             ],
             "chapters":[{"chapter":1,"pericopae":[
               {"title":"Preamble (1:1–5)","sv":43001001,"ev":43001005,"footnoteIds":["1","2"],"content":[
                 {"type":"commentary","content":{"text":"The Word was there before anything.","footnote_refs":[{"id":"1","offset":10}]}},
                 {"type":"heading","content":{"text":"The light"}},
                 {"type":"commentary","sv":43001004,"ev":43001005,"content":{"text":"Life is the light."}}
               ]}
             ]}]}
            """#,
        ])
        let units = try await LampAgentLibrary(library: library)
            .readCommentary(reference: "John 1:4").units

        #expect(units.map(\.commentary) == ["The Word was there before anything.", "Life is the light."])
        #expect(units.allSatisfy { !($0.footnotes ?? "").contains("gathered") },
                "a container's notes were served, which are its whole source scope")
        #expect(units.first?.footnotes?.contains("A note the exposition cites.") == true)
        #expect(units.first?.sections == ["Preamble (1:1–5)"],
                "a heading reached the text before it")
        #expect(units.last?.sections == ["Preamble (1:1–5)", "The light"])
    }

    /// A commentary keeps its source's font-encoded Greek and Hebrew as written
    /// and gives each span its Unicode reading in an annotation.
    @Test func commentaryEncodedGreekAndHebrewReadAsUnicode() async throws {
        let fixture = try temporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let library = try await commentaryLibrary(in: fixture, [
            "ENCODED": #"""
            {"meta":{"schemaVersion":"2.2","id":"ENCODED","seriesAbbrev":"EC","seriesFull":"Encoded Commentary","title":"John"},
             "book":"John","bookNumber":43,
             "footnotes":[
               {"id":"1","label":"1","content":{"text":"Hebrew vDlUwM here.","annotations":[
                 {"type":"hebrew","start":7,"end":13,"text":"vDlUwM","data":{"unicode":"שָׁלוֹם","sourceEncoding":"accordance-hebrew"}}
               ]}}
             ],
             "chapters":[{"chapter":1,"pericopae":[
               {"title":"The Word (1:1)","sv":43001001,"ev":43001001,"footnoteIds":["1"],"content":[
                 {"type":"commentary","content":{"text":"The phrase oJ lo/gos is masculine; qeo/v is not.","annotations":[
                   {"type":"greek","start":11,"end":20,"text":"oJ lo/gos","data":{"unicode":"ὁ λόγος","sourceEncoding":"accordance-greek"}},
                   {"type":"greek","start":0,"end":5,"text":"qeo/v","data":{"unicode":"θεός","sourceEncoding":"accordance-greek"}}
                 ],"footnote_refs":[{"id":"1","offset":20}]}}
               ]}
             ]}]}
            """#,
        ])
        let unit = try await LampAgentLibrary(library: library)
            .readCommentary(reference: "John 1:1").units.first

        #expect(unit?.commentary == "The phrase ὁ λόγος is masculine; qeo/v is not.",
                "a span whose offsets miss its own text was rewritten, or a matching one was not")
        #expect(unit?.footnotes?.contains("Hebrew שָׁלוֹם here.") == true)
    }

    /// A passage is stored under the chapter it starts in, so a verse in a
    /// later chapter is reached only by its range.
    @Test func commentaryOnAPassageFromAnEarlierChapterIsServed() async throws {
        let fixture = try temporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let library = try await commentaryLibrary(in: fixture, [
            "CROSSING": #"""
            {"meta":{"schemaVersion":"2.2","id":"CROSSING","seriesAbbrev":"CC","seriesFull":"Crossing Commentary","title":"Mark"},
             "book":"Mark","bookNumber":41,
             "chapters":[
               {"chapter":8,"pericopae":[
                 {"title":"Peter's Confession (8:27–33)","sv":41008027,"ev":41008033,"content":[
                   {"type":"commentary","content":{"text":"Who do you say I am?"}}
                 ]},
                 {"title":"Following Jesus (8:34–9:1)","sv":41008034,"ev":41009001,"content":[
                   {"type":"commentary","content":{"text":"Take up the cross."}}
                 ]}
               ]},
               {"chapter":9,"pericopae":[
                 {"title":"The Transfiguration (9:2–8)","sv":41009002,"ev":41009008,"content":[
                   {"type":"commentary","content":{"text":"On the mountain."}}
                 ]}
               ]}
             ]}
            """#,
        ])
        let agent = LampAgentLibrary(library: library)

        let verse = try await agent.readCommentary(reference: "Mark 9:1").units
        #expect(verse.map(\.commentary) == ["Take up the cross."])
        #expect(verse.first?.sections == ["Following Jesus (8:34–9:1)"])

        let range = try await agent.readCommentary(reference: "Mark 9:1-2").units
        #expect(range.map(\.commentary) == ["Take up the cross.", "On the mountain."])
    }

    /// A client sets aside a result over its cap rather than shortening it, so
    /// a call stops short of its limit and says where to go on.
    @Test func commentaryLongerThanOneResultIsReadInTurns() async throws {
        let paragraph = String(repeating: "Exposition. ", count: 400)
        func module(_ id: String, name: String, blocks: Int) -> String {
            let content = (0..<blocks).map { index in
                #"{"type":"commentary","content":{"text":"\#(index) \#(paragraph)"}}"#
            }.joined(separator: ",")
            return #"""
            {"meta":{"schemaVersion":"2.2","id":"\#(id)","seriesAbbrev":"\#(id)","seriesFull":"\#(name)","title":"John"},
             "book":"John","bookNumber":43,
             "chapters":[{"chapter":1,"pericopae":[{"title":"All of it","sv":43001001,"ev":43001005,"content":[\#(content)]}]}]}
            """#
        }
        // Named so the long one is listed first: read a module at a time, it
        // would fill every call before the short one was reached.
        let fixture = try temporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let library = try await commentaryLibrary(in: fixture, [
            "LONG": module("LONG", name: "A Long Commentary", blocks: 12),
            "SHORT": module("SHORT", name: "B Short Commentary", blocks: 1),
        ])
        let agent = LampAgentLibrary(library: library)

        var offset: Int? = 0
        var calls: [LampAgentCommentaryReading] = []
        while let next = offset, calls.count < 20 {
            let reading = try await agent.readCommentary(reference: "John 1:1", offset: next)
            calls.append(reading)
            offset = reading.nextOffset
        }
        #expect(calls.count > 1)
        for reading in calls {
            let characters = reading.units.reduce(0) { $0 + ($1.commentary?.count ?? 0) }
            #expect(characters <= 30_000, "one call held \(characters) characters")
        }
        let served = calls.flatMap(\.units)
        #expect(served.count == 13)
        #expect(Set(served.map(\.id)).count == 13, "a unit was served twice, or one was skipped")
        #expect(calls.first?.units.contains { $0.moduleID == "SHORT" } == true,
                "the first call was all one commentary")

        let limited = try await agent.readCommentary(reference: "John 1:1", limit: 2)
        #expect(limited.units.count == 2)
        #expect(limited.nextOffset == 2)
    }

    private func temporaryFixture() throws -> URL {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-agent-commentary-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        return fixture
    }

    private func commentaryLibrary(
        in fixture: URL,
        _ modules: [String: String]
    ) async throws -> LampLibrary {
        let library = LampLibrary(rootURL: fixture.appendingPathComponent("Library"))
        for (id, json) in modules {
            let moduleURL = fixture.appendingPathComponent("\(id).lamp")
            _ = try LampModuleCompiler().compile(
                data: Data(json.utf8),
                sourceFilename: "\(id).json",
                destinationURL: moduleURL
            )
            _ = try await library.install(from: moduleURL)
        }
        return library
    }
}
