import Foundation
import Testing
@testable import LampCore

/// The update contract between a host and a device, both halves at once.
struct LampAgentRemoteChatTests {
    private let summary = LampAgentRemoteChatSummary(
        id: "chat", title: "t", kind: LampAgentRemoteChatSummary.reader,
        provider: "claude", providerName: "Claude Code", acceptsMessages: true
    )
    private func said(_ text: String, _ role: String, _ minutes: Double) -> LampAgentRemoteChatMessage {
        LampAgentRemoteChatMessage(role: role, text: text, date: Date(timeIntervalSince1970: 1_800_000_000 + minutes * 60))
    }

    /// A small, repeatable generator, so a failure names the seed to replay.
    private struct Generator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
        mutating func pick<T>(_ options: [T]) -> T { options[Int(next() % UInt64(options.count))] }
        mutating func chance(_ percent: UInt64) -> Bool { next() % 100 < percent }
    }

    private static let activities: [LampAgentRemoteActivity?] = [
        nil,
        LampAgentRemoteActivity(kind: LampAgentRemoteActivity.thinking, estimatedTokens: 40),
        LampAgentRemoteActivity(kind: LampAgentRemoteActivity.tool, name: "read_passage"),
        LampAgentRemoteActivity(kind: LampAgentRemoteActivity.writing),
    ]

    /// The contract, over thousands of steps: a device holding one state's
    /// snapshot and applying the events to the next holds the next one's
    /// snapshot — or, where events cannot say the change, is sent it.
    @Test func applyingTheEventsAlwaysArrivesAtTheNextSnapshot() {
        for seed in 1...400 as ClosedRange<UInt64> {
            var g = Generator(state: seed)
            var state = LampAgentRemoteChatState()
            var view = LampAgentRemoteChatView(LampAgentRemoteChatUpdates.snapshot(summary: summary, state: state))
            var minute = 0.0
            for step in 0..<30 {
                var next = state
                // Messages: mostly appended, now and then taken away or
                // rewritten, which only a snapshot can say.
                if g.chance(8), !next.messages.isEmpty {
                    next.messages.removeLast()
                } else if g.chance(4), let last = next.messages.last {
                    next.messages[next.messages.count - 1] = LampAgentRemoteChatMessage(
                        id: last.id, role: last.role, text: last.text + "!", date: last.date
                    )
                } else {
                    for _ in 0..<g.pick([0, 0, 1, 1, 2, 3]) {
                        minute += 1
                        next.messages.append(said("m\(minute)", g.pick([LampAgentRemoteChatMessage.user, LampAgentRemoteChatMessage.assistant]), minute))
                    }
                }
                next.isRunning = g.chance(50)
                next.arriving = g.pick(["", "", "So", "So far", "Something else"])
                next.activity = g.pick(Self.activities)
                next.failure = g.pick([nil, nil, nil, "Not signed in", "Stopped"])

                let snapshot = LampAgentRemoteChatUpdates.snapshot(summary: summary, state: next)
                if LampAgentRemoteChatUpdates.needsSnapshot(from: state, to: next) {
                    view.apply(snapshot)
                } else {
                    for event in LampAgentRemoteChatUpdates.events(chatID: summary.id, from: state, to: next) {
                        view.apply(event)
                    }
                }
                #expect(view.matches(snapshot), "seed \(seed) step \(step)")
                if !view.matches(snapshot) { return }
                state = next
            }
        }
    }

    @Test func areplyArrivesAsItsTurnTheReplySoFarWholeAndTheAnswer() {
        let question = said("Who wrote Hebrews?", LampAgentRemoteChatMessage.user, 0)
        let answer = said("Nobody knows for certain.", LampAgentRemoteChatMessage.assistant, 1)
        let thinking = LampAgentRemoteActivity(kind: LampAgentRemoteActivity.thinking, estimatedTokens: 40)
        let writing = LampAgentRemoteActivity(kind: LampAgentRemoteActivity.writing)
        let states = [
            LampAgentRemoteChatState(),
            LampAgentRemoteChatState(messages: [question], isRunning: true),
            LampAgentRemoteChatState(messages: [question], activity: thinking, isRunning: true),
            LampAgentRemoteChatState(messages: [question], arriving: "Nobody", activity: writing, isRunning: true),
            LampAgentRemoteChatState(messages: [question], arriving: "Nobody knows", activity: writing, isRunning: true),
            LampAgentRemoteChatState(messages: [question, answer]),
        ]
        let events = states.indices.dropFirst().flatMap {
            LampAgentRemoteChatUpdates.events(chatID: "c", from: states[$0 - 1], to: states[$0])
        }
        #expect(events.map(\.kind) == ["turn-started", "activity", "fragment", "activity", "fragment", "reply", "turn-ended"])
        #expect(events[0].message?.id == question.id)
        #expect(events[4].text == "Nobody knows")
        #expect(events.allSatisfy { $0.turnID == question.id })
    }

    @Test func turnsThatRunTogetherAreToldApart() {
        let first = said("First?", LampAgentRemoteChatMessage.user, 0)
        let firstAnswer = said("One.", LampAgentRemoteChatMessage.assistant, 1)
        let second = said("Second?", LampAgentRemoteChatMessage.user, 2)
        let events = LampAgentRemoteChatUpdates.events(
            chatID: "c",
            from: .init(messages: [first], isRunning: true),
            to: .init(messages: [first, firstAnswer, second], isRunning: true)
        )
        #expect(events.map(\.kind) == ["reply", "turn-ended", "turn-started"])
        #expect(events[0].turnID == first.id && events[1].turnID == first.id && events[2].turnID == second.id)

        let quick = LampAgentRemoteChatUpdates.events(chatID: "c", from: .init(), to: .init(messages: [first, firstAnswer]))
        #expect(quick.map(\.kind) == ["turn-started", "reply", "turn-ended"])
    }

    @Test func afailureIsToldBeforeItsTurnEnds() {
        let question = said("Hello", LampAgentRemoteChatMessage.user, 0)
        let events = LampAgentRemoteChatUpdates.events(
            chatID: "c", from: .init(messages: [question], isRunning: true), to: .init(messages: [question], failure: "Not signed in")
        )
        #expect(events.map(\.kind) == ["failed", "turn-ended"])
    }

    /// The same words from the Mac and from the device are told apart by the
    /// request each came with, wherever the question is carried: begun as a
    /// turn, stopped before its first update, or whole in one step.
    @Test func aquestionCarriesTheRequestItWasSentBy() {
        let user = LampAgentRemoteChatMessage.user
        let request = UUID()
        let fromMac = said("Why?", user, 0)
        let fromDevice = said("Why?", user, 1)
        let answer = said("Because.", LampAgentRemoteChatMessage.assistant, 2)
        let asked = [fromDevice.id: request]

        let elsewhere = LampAgentRemoteChatUpdates.events(chatID: "c", from: .init(), to: .init(messages: [fromMac]))
        #expect(elsewhere.map(\.requestID) == [nil])

        let begun = LampAgentRemoteChatUpdates.events(
            chatID: "c", from: .init(messages: [fromMac]),
            to: .init(messages: [fromMac, fromDevice], isRunning: true, askedBy: asked)
        )
        #expect(begun.map(\.kind) == ["turn-started"])
        #expect(begun[0].requestID == request)

        let stopped = LampAgentRemoteChatUpdates.events(
            chatID: "c", from: .init(messages: [fromMac]), to: .init(messages: [fromMac, fromDevice], askedBy: asked)
        )
        #expect(stopped.map(\.kind) == ["reply"])
        #expect(stopped[0].requestID == request)

        let whole = LampAgentRemoteChatUpdates.events(
            chatID: "c", from: .init(messages: [fromMac]), to: .init(messages: [fromMac, fromDevice, answer], askedBy: asked)
        )
        #expect(whole.map(\.kind) == ["turn-started", "reply", "turn-ended"])
        #expect(whole.map(\.requestID) == [request, nil, nil])
    }

    /// A snapshot names the request each question it holds came with, so a
    /// device that lost the connection before hearing back can find its own.
    @Test func asnapshotNamesTheRequestsItsQuestionsCameWith() throws {
        let request = UUID()
        let mine = said("Why?", LampAgentRemoteChatMessage.user, 0)
        let theirs = said("Why?", LampAgentRemoteChatMessage.user, 1)
        let snapshot = LampAgentRemoteChatUpdates.snapshot(
            summary: summary, state: .init(messages: [mine, theirs], askedBy: [mine.id: request, UUID(): UUID()])
        )
        #expect(snapshot.askedBy == [.init(messageID: mine.id, requestID: request)])
        let old = #"{"summary":{"id":"c","title":"t","kind":"reader","provider":"p","providerName":"P","isRunning":false,"acceptsMessages":true},"messages":[]}"#
        #expect(try JSONDecoder().decode(LampAgentRemoteChatSnapshot.self, from: Data(old.utf8)).askedBy == nil)
    }

    /// An event from a host older than the field still reads, with no request.
    @Test func anEventWithNoRequestStillDecodes() throws {
        let old = #"{"chatID":"c","kind":"turn-started"}"#
        let event = try JSONDecoder().decode(LampAgentRemoteChatEvent.self, from: Data(old.utf8))
        #expect(event.kind == LampAgentRemoteChatEvent.turnStarted && event.requestID == nil)
    }

    @Test func aquestionFromElsewhereIsAMessageAndAClearedChatIsSnapshotted() {
        let question = said("Asked on the Mac", LampAgentRemoteChatMessage.user, 0)
        let arrived = LampAgentRemoteChatUpdates.events(chatID: "c", from: .init(), to: .init(messages: [question]))
        #expect(arrived.map(\.kind) == ["reply"])
        #expect(LampAgentRemoteChatUpdates.needsSnapshot(from: .init(messages: [question]), to: .init()))
        #expect(LampAgentRemoteChatUpdates.needsSnapshot(
            from: .init(messages: [question], failure: "x"), to: .init(messages: [question])
        ))
    }
}
