import Foundation
import Testing
@testable import LampCore

/// A request a running turn waits on, as a paired device shows and answers
/// it (`decisions/0037`).
struct LampAgentRemoteApprovalTests {
    private let summary = LampAgentRemoteChatSummary(
        id: "chat", title: "t", kind: LampAgentRemoteChatSummary.writing,
        provider: "codex", providerName: "Codex", acceptsMessages: true
    )
    private let question = LampAgentRemoteChatMessage(role: LampAgentRemoteChatMessage.user, text: "Render it", date: Date(timeIntervalSince1970: 1_800_000_000))
    private let request = LampAgentRemoteApproval(
        id: "codex-0", provider: "codex", kind: LampAgentRemoteApproval.command, title: "Run a command outside the sandbox",
        command: "blender -b scene.blend -a", folder: "/w", agentReason: "It needs the GPU", note: nil, canAllow: true
    )

    /// Shown while its turn waits, taken away once answered, and gone with
    /// the turn: told by events, and so in a snapshot.
    @Test func aRequestIsShownWhileItsTurnWaitsAndGoesWithTheTurn() {
        let running = LampAgentRemoteChatState(messages: [question], isRunning: true)
        var waiting = running
        waiting.approvals = [request]
        let shown = LampAgentRemoteChatUpdates.events(chatID: "chat", from: running, to: waiting)
        #expect(shown.map(\.kind) == [LampAgentRemoteChatEvent.approvals])
        #expect(shown.first?.approvals == [request] && shown.first?.turnID == question.id)

        var view = LampAgentRemoteChatView(LampAgentRemoteChatUpdates.snapshot(summary: summary, state: running))
        shown.forEach { view.apply($0) }
        #expect(view.approvals == [request] && view.turnID == question.id)
        // A device joining now sees it in the snapshot, and names the turn.
        let joined = LampAgentRemoteChatView(LampAgentRemoteChatUpdates.snapshot(summary: summary, state: waiting))
        #expect(joined.approvals == [request] && joined.turnID == question.id)

        // The turn ends with the request still listed on the host: none
        // outlives it, on the device or in a snapshot.
        var ended = waiting
        ended.isRunning = false
        LampAgentRemoteChatUpdates.events(chatID: "chat", from: waiting, to: ended).forEach { view.apply($0) }
        #expect(view.approvals.isEmpty && view.turnID == nil)
        #expect(LampAgentRemoteChatUpdates.snapshot(summary: summary, state: ended).approvals == [])
    }

    /// A host older than approvals sends none, and a device older than them
    /// reads a new host's snapshot and ignores its events.
    @Test func olderHostsAndDevicesReadEachOther() throws {
        let old = #"{"summary":{"id":"c","title":"t","kind":"writing","provider":"codex","providerName":"Codex","isRunning":true,"acceptsMessages":true},"messages":[]}"#
        let snapshot = try JSONDecoder().decode(LampAgentRemoteChatSnapshot.self, from: Data(old.utf8))
        #expect(snapshot.approvals == nil && LampAgentRemoteChatView(snapshot).approvals.isEmpty)

        // What an older device's decoder keeps of a new snapshot: everything
        // it knows, the approvals left aside.
        struct OlderSnapshot: Decodable { var summary: LampAgentRemoteChatSummary; var messages: [LampAgentRemoteChatMessage] }
        let new = LampAgentRemoteChatUpdates.snapshot(summary: summary, state: .init(messages: [question], isRunning: true, approvals: [request]))
        let read = try JSONDecoder().decode(OlderSnapshot.self, from: JSONEncoder().encode(new))
        #expect(read.messages == [question])

        // An event of a kind a device doesn't know changes nothing.
        var view = LampAgentRemoteChatView(new)
        let before = view
        view.apply(LampAgentRemoteChatEvent(chatID: "chat", kind: "approvals-v2", approvals: []))
        #expect(view == before)
    }

    /// Every field drawn moves the digest, as do the chat and the turn: an
    /// answer can't be taken for another request, nor for the same id in a
    /// later turn.
    @Test func theDigestMovesWithEveryFieldTheChatAndTheTurn() {
        let turn = UUID()
        let base = LampAgentRemoteApproval.digest(chatID: "chat", turnID: turn, approval: request)
        var changed: [LampAgentRemoteApproval] = []
        for path in [\LampAgentRemoteApproval.id, \.provider, \.kind, \.title] as [WritableKeyPath<LampAgentRemoteApproval, String>] {
            var other = request
            other[keyPath: path] += "x"
            changed.append(other)
        }
        for path in [\LampAgentRemoteApproval.command, \.folder, \.agentReason, \.note] as [WritableKeyPath<LampAgentRemoteApproval, String?>] {
            var other = request
            other[keyPath: path] = (other[keyPath: path] ?? "") + "x"
            changed.append(other)
            // Absent is not empty.
            other[keyPath: path] = nil
            if request[keyPath: path] != nil { changed.append(other) }
        }
        var denyOnly = request
        denyOnly.canAllow = false
        changed.append(denyOnly)
        for other in changed {
            #expect(LampAgentRemoteApproval.digest(chatID: "chat", turnID: turn, approval: other) != base, "\(other)")
        }
        #expect(LampAgentRemoteApproval.digest(chatID: "chat2", turnID: turn, approval: request) != base)
        #expect(LampAgentRemoteApproval.digest(chatID: "chat", turnID: UUID(), approval: request) != base)
        // Fields that run together differently are told apart.
        var a = request, b = request
        a.title = "ab"; a.command = "c"
        b.title = "a"; b.command = "bc"
        #expect(LampAgentRemoteApproval.digest(chatID: "c", turnID: turn, approval: a) != LampAgentRemoteApproval.digest(chatID: "c", turnID: turn, approval: b))
    }

    /// Only a command shown whole may be allowed from a device.
    @Test func onlyACommandThatCanBeShownWholeMayBeAllowed() {
        #expect(LampAgentRemoteApproval.canShowWhole("blender -b scene.blend -a"))
        #expect(LampAgentRemoteApproval.canShowWhole("for f in *.png; do\n\techo \"$f\"\ndone"))
        #expect(LampAgentRemoteApproval.canShowWhole("echo 'Génesis' # ünïcödé"))
        #expect(!LampAgentRemoteApproval.canShowWhole(""))
        #expect(!LampAgentRemoteApproval.canShowWhole(String(repeating: "a", count: LampAgentRemoteApproval.largestAllowedCommand + 1)))
        #expect(LampAgentRemoteApproval.canShowWhole(String(repeating: "a", count: LampAgentRemoteApproval.largestAllowedCommand)))
        // What doesn't draw: a right-to-left override, a zero-width space and
        // joiner, a carriage return, an escape, a line separator.
        for hidden in ["\u{202E}", "\u{200B}", "\u{200D}", "\r", "\u{1B}", "\u{2028}", "\u{E000}"] {
            #expect(!LampAgentRemoteApproval.canShowWhole("rm -rf ~/safe\(hidden)"), "\(hidden.unicodeScalars.first!.value)")
        }
    }

    /// The answer message carries what was shown, and the host's decision
    /// takes it only for that.
    @Test func anAnswerIsTakenOnlyForTheRequestShownInItsTurn() {
        let turn = UUID()
        let answer = LampAgentRemoteMessage.answerApproval(request, in: "chat", turnID: turn, decision: LampAgentRemoteApprovalAnswer.allowOnce)
        func decide(_ message: LampAgentRemoteMessage, now: UUID?, waiting: [LampAgentRemoteApproval]) -> LampAgentRemoteApprovalAnswer.Outcome {
            LampAgentRemoteApprovalAnswer.decide(
                decision: message.decision, approvalID: message.approvalID, digest: message.approvalDigest,
                shownTurn: message.turnID, chatID: "chat", currentTurn: now, waiting: waiting
            )
        }
        #expect(decide(answer, now: turn, waiting: [request]) == .allowOnce)
        // The same id in the next turn, asking something else.
        var next = request
        next.command = "rm -rf ~"
        #expect(decide(answer, now: UUID(), waiting: [next]) == .gone)
        #expect(decide(answer, now: turn, waiting: [next]) == .gone)
        // Answered already, or the turn over.
        #expect(decide(answer, now: turn, waiting: []) == .gone)
        #expect(decide(answer, now: nil, waiting: [request]) == .gone)
        // Deny-only: Allow refused, Deny taken.
        var denyOnly = request
        denyOnly.canAllow = false
        let allow = LampAgentRemoteMessage.answerApproval(denyOnly, in: "chat", turnID: turn, decision: LampAgentRemoteApprovalAnswer.allowOnce)
        #expect(decide(allow, now: turn, waiting: [denyOnly]) == .notAllowed)
        let deny = LampAgentRemoteMessage.answerApproval(denyOnly, in: "chat", turnID: turn, decision: LampAgentRemoteApprovalAnswer.deny)
        #expect(decide(deny, now: turn, waiting: [denyOnly]) == .deny)
        // A remembered rule is no answer a device may give.
        var always = answer
        always.decision = "always-allow"
        #expect(decide(always, now: turn, waiting: [request]) == .notAllowed)
        // It survives the wire.
        let decoded = try? JSONDecoder().decode(LampAgentRemoteMessage.self, from: JSONEncoder().encode(answer))
        #expect(decoded == answer)
    }
}
