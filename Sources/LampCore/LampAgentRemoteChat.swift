import Foundation

/// A chat as it stands on the host: its finished messages, the reply so far
/// while one arrives, what the run is doing, and what went wrong. Plain
/// protocol values, so the host's model is turned into this once, and the
/// rest is decided here.
public struct LampAgentRemoteChatState: Equatable, Sendable {
    public var messages: [LampAgentRemoteChatMessage]
    public var arriving: String
    public var activity: LampAgentRemoteActivity?
    public var isRunning: Bool
    public var failure: String?
    /// The request each question was sent by, by the question's id, for the
    /// questions a device sent through this host: what lets that device know
    /// its own question from the same words sent elsewhere.
    public var askedBy: [UUID: UUID]
    /// What the running turn waits on the person for, oldest first, as a
    /// device is sent it and the host judges an answer against it: the
    /// first `LampAgentRemoteApproval.largestListed`, each `bounded()`.
    public var approvals: [LampAgentRemoteApproval] {
        didSet {
            let sendable = Self.sendable(approvals)
            if !LampAgentRemoteApproval.same(approvals, sendable) { approvals = sendable }
        }
    }

    static func sendable(_ approvals: [LampAgentRemoteApproval]) -> [LampAgentRemoteApproval] {
        approvals.prefix(LampAgentRemoteApproval.largestListed).map { $0.bounded() }
    }

    public init(
        messages: [LampAgentRemoteChatMessage] = [],
        arriving: String = "",
        activity: LampAgentRemoteActivity? = nil,
        isRunning: Bool = false,
        failure: String? = nil,
        askedBy: [UUID: UUID] = [:],
        approvals: [LampAgentRemoteApproval] = []
    ) {
        self.messages = messages
        self.arriving = arriving
        self.activity = activity
        self.isRunning = isRunning
        self.failure = failure
        self.askedBy = askedBy
        self.approvals = Self.sendable(approvals)
    }

    /// The turn running, by the question it answers, as events name it and
    /// a device's copy works it out (`LampAgentRemoteChatView.turnID`).
    public var runningTurn: UUID? {
        isRunning ? messages.last { $0.role == LampAgentRemoteChatMessage.user }?.id : nil
    }
}

/// What a host sends a device as a chat changes, and how the device puts it
/// back together: the two halves of one contract, kept here so they are
/// tested together.
///
/// The contract: a device that held the snapshot of one state and applies
/// the events between it and the next holds the snapshot of the next
/// (`LampAgentRemoteChatView.matches`). Where events cannot say a change —
/// messages taken away or rewritten, a failure cleared with no turn begun —
/// the host sends a fresh snapshot instead (`needsSnapshot`).
public enum LampAgentRemoteChatUpdates {
    public static func snapshot(summary: LampAgentRemoteChatSummary, state: LampAgentRemoteChatState) -> LampAgentRemoteChatSnapshot {
        var summary = summary
        summary.isRunning = state.isRunning
        return LampAgentRemoteChatSnapshot(
            summary: summary,
            messages: state.messages,
            partialReply: state.isRunning && !state.arriving.isEmpty ? state.arriving : nil,
            activity: state.isRunning ? state.activity : nil,
            notice: state.failure,
            askedBy: state.messages.compactMap { message in
                state.askedBy[message.id].map { .init(messageID: message.id, requestID: $0) }
            },
            // Only while a turn runs: none outlives its turn.
            approvals: state.isRunning ? state.approvals : []
        )
    }

    /// Whether the device's copy can only be brought up to date by a fresh
    /// snapshot: a message it holds is gone, rewritten or moved, or the
    /// events cannot otherwise bring it to the new state — a failure it
    /// shows, cleared with no turn begun to clear it.
    public static func needsSnapshot(from old: LampAgentRemoteChatState, to new: LampAgentRemoteChatState) -> Bool {
        plan(chatID: "", from: old, to: new) == nil
    }

    /// The events that take a device from one state of a chat to the next,
    /// in the order they happened; empty where `needsSnapshot` is true.
    ///
    /// The host takes its model's changes a few at a time, so one step can
    /// hold a whole turn, or the end of one and the start of the next: each
    /// turn is still told as its own — begun with its question, its answer,
    /// ended — and every reply is filed under the question it answers. A
    /// question from elsewhere while nothing runs is just a message.
    ///
    /// The reply so far goes whole each time, replacing the last: a frame
    /// lost or a device that joins mid-reply still ends up with all of it.
    public static func events(chatID: String, from old: LampAgentRemoteChatState, to new: LampAgentRemoteChatState) -> [LampAgentRemoteChatEvent] {
        plan(chatID: chatID, from: old, to: new) ?? []
    }

    /// The events, worked out by playing them on the device's copy as they
    /// are chosen: the messages first, turn by turn, then whatever brings
    /// the copy's running state, reply so far, activity and notice to the
    /// new state's. Nil when no events can — the copy is checked against the
    /// new snapshot before anything is sent.
    static func plan(chatID: String, from old: LampAgentRemoteChatState, to new: LampAgentRemoteChatState) -> [LampAgentRemoteChatEvent]? {
        guard new.messages.count >= old.messages.count,
              Array(new.messages.prefix(old.messages.count)) == old.messages
        else { return nil }
        let summary = LampAgentRemoteChatSummary(
            id: chatID, title: "", kind: LampAgentRemoteChatSummary.reader, provider: "", providerName: "", acceptsMessages: true
        )
        var copy = LampAgentRemoteChatView(snapshot(summary: summary, state: old))
        var events: [LampAgentRemoteChatEvent] = []
        let user = LampAgentRemoteChatMessage.user
        func send(_ kind: String, _ turn: UUID?, message: LampAgentRemoteChatMessage? = nil,
                  text: String? = nil, activity: LampAgentRemoteActivity? = nil, approvals: [LampAgentRemoteApproval]? = nil) {
            let event = LampAgentRemoteChatEvent(
                chatID: chatID, kind: kind, turnID: turn, message: message, text: text, activity: activity,
                requestID: message.flatMap { $0.role == user ? new.askedBy[$0.id] : nil }, approvals: approvals
            )
            events.append(event)
            copy.apply(event)
        }
        let added = Array(new.messages.dropFirst(old.messages.count))
        let lastAddedQuestion = added.last { $0.role == user }?.id
        var open: UUID? = old.isRunning ? old.messages.last { $0.role == user }?.id : nil

        for (index, message) in added.enumerated() {
            guard message.role == user else {
                let index = new.messages.firstIndex { $0.id == message.id } ?? 0
                send(LampAgentRemoteChatEvent.reply, new.messages[..<index].last { $0.role == user }?.id, message: message)
                continue
            }
            // A new question ends the turn before it.
            if copy.isRunning {
                send(LampAgentRemoteChatEvent.turnEnded, open)
                open = nil
            }
            // A turn of its own when it is running now or was answered in the
            // same step; otherwise someone else's message.
            let answered = added[(index + 1)...].contains { $0.role != user }
            if answered || (message.id == lastAddedQuestion && new.isRunning) {
                send(LampAgentRemoteChatEvent.turnStarted, message.id, message: message)
                open = message.id
            } else {
                send(LampAgentRemoteChatEvent.reply, message.id, message: message)
            }
        }

        let target = snapshot(summary: summary, state: new)
        if target.summary.isRunning {
            if !copy.isRunning {
                // Running with no new question: a run picked up where it was.
                open = open ?? new.messages.last { $0.role == user }?.id
                send(LampAgentRemoteChatEvent.turnStarted, open)
            }
            if copy.partialReply != target.partialReply {
                send(LampAgentRemoteChatEvent.fragment, open, text: target.partialReply ?? "")
            }
            if copy.activity != target.activity {
                send(LampAgentRemoteChatEvent.activity, open, activity: target.activity)
            }
            if !LampAgentRemoteApproval.same(copy.approvals, target.approvals ?? []) {
                send(LampAgentRemoteChatEvent.approvals, open, approvals: target.approvals ?? [])
            }
        }
        // What went wrong, before the turn it went wrong in is ended.
        if let notice = target.notice, copy.notice != notice {
            send(LampAgentRemoteChatEvent.failed, open ?? new.messages.last { $0.role == user }?.id, text: notice)
        }
        if !target.summary.isRunning, copy.isRunning {
            send(LampAgentRemoteChatEvent.turnEnded, open)
        }
        return copy.matches(target) ? events : nil
    }
}

/// A chat as a device holds it, put together from the host's snapshot and
/// events, by message id: the host's transcript is the record.
public struct LampAgentRemoteChatView: Equatable, Sendable {
    public var summary: LampAgentRemoteChatSummary
    public var messages: [LampAgentRemoteChatMessage]
    /// The reply so far, whole as the host last sent it, never pieced
    /// together here.
    public var partialReply: String?
    public var activity: LampAgentRemoteActivity?
    /// What went wrong, as the host said it.
    public var notice: String?
    /// What the running turn waits on the person for, oldest first. A host
    /// older than this sends none, and takes no answer.
    public var approvals: [LampAgentRemoteApproval]
    /// The turn running, by the question it answers: what an answer to a
    /// request names (`LampAgentRemoteMessage.answerApproval`), and the host
    /// checks against its own (`LampAgentRemoteChatState.runningTurn`).
    public var turnID: UUID? {
        isRunning ? messages.last { $0.role == LampAgentRemoteChatMessage.user }?.id : nil
    }

    public var id: String { summary.id }
    public var isRunning: Bool { summary.isRunning }

    public init(_ snapshot: LampAgentRemoteChatSnapshot) {
        summary = snapshot.summary
        messages = snapshot.messages
        partialReply = snapshot.partialReply
        activity = snapshot.activity
        notice = snapshot.notice
        approvals = snapshot.approvals ?? []
    }

    /// A fresh snapshot of this chat: the host's account replaces what was
    /// here.
    public mutating func apply(_ snapshot: LampAgentRemoteChatSnapshot) {
        self = LampAgentRemoteChatView(snapshot)
    }

    public mutating func apply(_ event: LampAgentRemoteChatEvent) {
        guard event.chatID == summary.id else { return }
        switch event.kind {
        case LampAgentRemoteChatEvent.turnStarted:
            summary.isRunning = true
            partialReply = nil
            activity = nil
            notice = nil
            approvals = []
            if let message = event.message { upsert(message) }
        case LampAgentRemoteChatEvent.fragment:
            summary.isRunning = true
            partialReply = event.text.flatMap { $0.isEmpty ? nil : $0 }
        case LampAgentRemoteChatEvent.activity:
            summary.isRunning = true
            activity = event.activity
        case LampAgentRemoteChatEvent.approvals:
            summary.isRunning = true
            approvals = event.approvals ?? []
        case LampAgentRemoteChatEvent.reply:
            // A question too, when a turn was stopped before its first update,
            // or one asked elsewhere.
            if let message = event.message { upsert(message) }
        case LampAgentRemoteChatEvent.failed:
            // The reply so far stays until the turn ends, as the host still
            // shows it until then.
            notice = event.text
        case LampAgentRemoteChatEvent.turnEnded:
            summary.isRunning = false
            partialReply = nil
            activity = nil
            // None outlives its turn.
            approvals = []
        default:
            // A kind a later Lamp knows.
            break
        }
    }

    private mutating func upsert(_ message: LampAgentRemoteChatMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
        summary.updatedAt = message.date
        summary.preview = message.text
    }

    /// Whether this holds what the snapshot says, in everything a snapshot
    /// carries about the chat's contents.
    public func matches(_ snapshot: LampAgentRemoteChatSnapshot) -> Bool {
        messages == snapshot.messages
            && partialReply == snapshot.partialReply
            && activity == snapshot.activity
            && notice == snapshot.notice
            && isRunning == snapshot.summary.isRunning
            && LampAgentRemoteApproval.same(approvals, snapshot.approvals ?? [])
    }
}
