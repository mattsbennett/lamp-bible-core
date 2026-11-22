import XCTest
@testable import LampCore

final class LampAgentRemoteSetupTests: XCTestCase {
    private func roundTrip(_ message: LampAgentRemoteMessage) throws -> LampAgentRemoteMessage {
        try JSONDecoder().decode(LampAgentRemoteMessage.self, from: JSONEncoder().encode(message))
    }

    private let claude = LampAgentRemoteSetup.Provider(
        id: "claude", name: "Claude Code", shortName: "Claude", systemImage: "sparkles",
        connection: .init(state: LampAgentRemoteSetup.Connection.connected),
        models: ["opus", "sonnet", "haiku"], modelHint: "Or a full model name",
        efforts: ["low", "medium", "high"], effortHint: "",
        defaultModel: "opus", defaultEffort: ""
    )

    func testSetupAndChoicesCrossTheWireWhole() throws {
        let setup = LampAgentRemoteSetup(
            providers: [claude],
            readerProvider: "claude",
            writingProvider: "codex",
            access: .init(modulesEnabled: true, allModules: false, personalStudy: true)
        )
        let sent = try roundTrip(.setup(setup, requestID: UUID()))
        XCTAssertEqual(sent.kind, .setup)
        XCTAssertEqual(sent.setup, setup)

        let choices = LampAgentRemoteChoices(provider: "claude", model: "", effort: "high")
        let set = try roundTrip(.setChoices(choices, for: "chat-1"))
        XCTAssertEqual(set.kind, .setChoices)
        XCTAssertEqual(set.chatID, "chat-1")
        XCTAssertEqual(set.choices, choices)
        // "" is the provider's default, and stays a choice, not nothing.
        XCTAssertEqual(set.choices?.model, "")

        XCTAssertEqual(try roundTrip(.getSetup()).kind, .getSetup)
    }

    /// A phone and a Mac a version apart still understand each other: what
    /// an older one sends decodes, with the new fields empty.
    func testAnOlderPeersMessagesStillDecode() throws {
        let olderSummary = """
        {"kind":"chats","chats":[{"id":"c","title":"T","kind":"reader","provider":"codex",
        "providerName":"OpenAI Codex","isRunning":false,"acceptsMessages":true}]}
        """
        let message = try JSONDecoder().decode(LampAgentRemoteMessage.self, from: Data(olderSummary.utf8))
        XCTAssertNil(message.chats?.first?.model)
        XCTAssertNil(message.chats?.first?.effort)
        XCTAssertNil(message.setup)

        let olderStart = """
        {"kind":"start-chat","newChat":{"kind":"reader","firstMessage":"Hi"}}
        """
        let start = try JSONDecoder().decode(LampAgentRemoteMessage.self, from: Data(olderStart.utf8))
        XCTAssertNil(start.newChat?.model)
        XCTAssertNil(start.newChat?.effort)
    }

    func testANewChatCarriesItsModelAndEffort() throws {
        let reader = LampAgentRemoteNewChat(provider: "claude", model: "sonnet", effort: "", firstMessage: "Why here?")
        let writing = LampAgentRemoteNewChat.writing("w1", firstMessage: "Tighten this", provider: "codex", model: "gpt-5", effort: "high")
        let sent = try roundTrip(.startChat(reader))
        XCTAssertEqual(sent.newChat?.model, "sonnet")
        XCTAssertEqual(sent.newChat?.effort, "")
        XCTAssertEqual(try roundTrip(.startChat(writing)).newChat, writing)
    }

    func testTheFoldedLineNamesOnlyAChosenModel() {
        XCTAssertEqual(LampAgentRemoteSetupLine.line(provider: "Claude", model: "opus", about: "John 3"), "Claude · opus · John 3")
        XCTAssertEqual(LampAgentRemoteSetupLine.line(provider: "Codex", model: "", about: "John 3"), "Codex · John 3")
        XCTAssertEqual(LampAgentRemoteSetupLine.line(provider: "Codex", model: nil, about: nil), "Codex")
        XCTAssertEqual(LampAgentRemoteSetupLine.choice(" ", defaultLabel: "Default"), "Default")
        XCTAssertEqual(LampAgentRemoteSetupLine.choice("high", defaultLabel: "Default"), "high")
    }

    func testAnEffortOnTheModelWaitsForAModel() {
        var openCode = claude
        openCode.effortIsOnTheModel = true
        XCTAssertFalse(openCode.takesEffort(withModel: ""))
        XCTAssertFalse(openCode.takesEffort(withModel: nil))
        XCTAssertTrue(openCode.takesEffort(withModel: "anthropic/claude-sonnet"))
        XCTAssertTrue(claude.takesEffort(withModel: ""))
    }

    func testConnectionWordsAndWhatNeedsAttention() {
        typealias C = LampAgentRemoteSetup.Connection
        XCTAssertFalse(C(state: C.checking).needsAttention)
        XCTAssertFalse(C(state: C.connected).needsAttention)
        XCTAssertTrue(C(state: C.notConnected).needsAttention)
        XCTAssertEqual(C(state: C.unavailable, detail: "Could not check").label, "Could not check")
        // A state a later Mac knows reads as what it says about itself.
        XCTAssertEqual(C(state: "rate-limited", detail: "Limit reached").label, "Limit reached")
        XCTAssertTrue(C(state: "rate-limited").needsAttention)
        XCTAssertNil(C(state: C.connected).remedy)
    }

    func testAccessIsWordedAsTheMacsSettingIs() {
        typealias A = LampAgentRemoteSetup.Access
        XCTAssertEqual(A(modulesEnabled: true, allModules: false, personalStudy: false).modules, "Enabled modules")
        XCTAssertEqual(
            A(modulesEnabled: true, allModules: true, personalStudy: true).modules,
            "All installed modules and personal study content"
        )
        XCTAssertEqual(A(modulesEnabled: false, allModules: true, personalStudy: true).modules, "Module access is off in AI & Agents settings")
    }
}
