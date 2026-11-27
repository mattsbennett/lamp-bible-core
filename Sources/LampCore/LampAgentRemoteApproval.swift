import CryptoKit
import Foundation

/// A request a running turn is waiting on the person for, as a paired device
/// shows it: a command an agent asks to run, or another tool call, on the
/// host's approval card (`decisions/0037`).
///
/// A device may answer Allow Once or Deny, never a remembered rule. It may
/// allow only what it can show whole (`canAllow`): a command the host could
/// send and a phone draw, in full. Anything else is offered for Deny alone,
/// and is answered on the Mac.
public struct LampAgentRemoteApproval: Codable, Equatable, Identifiable, Sendable {
    /// The host's id for the request, unique only within its turn: Codex
    /// numbers its requests afresh in each turn, so an answer names the turn
    /// too (`LampAgentRemoteApprovalAnswer`).
    public var id: String
    /// Who asks: a provider's id, as the chat's summary names it.
    public var provider: String
    /// A command to run (`LampAgentRemoteApproval.command`), or any other
    /// tool call (`LampAgentRemoteApproval.tool`).
    public var kind: String
    /// What the card is headed with, as the Mac heads it.
    public var title: String
    /// The command, whole.
    public var command: String?
    /// Where it runs.
    public var folder: String?
    /// Why the agent says it asks, in the agent's words: shown as the
    /// agent's, never as Lamp's.
    public var agentReason: String?
    /// What Lamp says about it.
    public var note: String?
    /// Whether a device may allow it: false where it can't be shown whole.
    public var canAllow: Bool

    public static let command = "command"
    public static let tool = "tool"

    public init(
        id: String, provider: String, kind: String, title: String, command: String? = nil,
        folder: String? = nil, agentReason: String? = nil, note: String? = nil, canAllow: Bool
    ) {
        self.id = id
        self.provider = provider
        self.kind = kind
        self.title = title
        self.command = command
        self.folder = folder
        self.agentReason = agentReason
        self.note = note
        self.canAllow = canAllow
    }

    /// The longest command a device may allow: one a phone can show whole,
    /// well within the largest frame a connection seals.
    public static let largestAllowedCommand = 8_000

    /// Whether `command` can be shown whole, so a device may allow it: within
    /// `largestAllowedCommand` characters, and holding nothing that doesn't
    /// draw — a control character but a line break or tab, a format
    /// character (a bidirectional override, a zero-width space or joiner), a
    /// line or paragraph separator — which could make what runs differ from
    /// what is read.
    public static func canShowWhole(_ command: String) -> Bool {
        guard !command.isEmpty, command.count <= largestAllowedCommand else { return false }
        return command.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .control: scalar == "\n" || scalar == "\t"
            case .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned, .privateUse: false
            default: true
            }
        }
    }

    /// What a device answers with, and the host checks an answer against:
    /// the request as it was shown, in this chat and turn. Every field the
    /// device draws is in it, so an answer to one request can't be taken for
    /// another, nor for the same id in a later turn.
    public static func digest(chatID: String, turnID: UUID?, approval: Self) -> String {
        var hasher = SHA256()
        func add(_ field: String?) {
            // Length first, so no two lists of fields run together alike.
            let bytes = Array((field ?? "").utf8)
            hasher.update(data: Data("\(field == nil ? -1 : bytes.count):".utf8))
            hasher.update(data: bytes)
        }
        add("lamp-agent-approval-1")
        add(chatID)
        add(turnID?.uuidString)
        add(approval.id)
        add(approval.provider)
        add(approval.kind)
        add(approval.title)
        add(approval.command)
        add(approval.folder)
        add(approval.agentReason)
        add(approval.note)
        add(approval.canAllow ? "allow" : "deny-only")
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// A device's answer to a request, and what the host makes of it.
public enum LampAgentRemoteApprovalAnswer {
    /// The answers a device may give.
    public static let allowOnce = "allow-once"
    public static let deny = "deny"

    public enum Outcome: String, Equatable, Sendable {
        /// Allowed this once.
        case allowOnce
        case deny
        /// Not waiting as it was shown: answered elsewhere, timed out, its
        /// turn over, or changed.
        case gone
        /// Not an answer a device may give to it: a decision it doesn't know,
        /// or Allow for a request it may only deny.
        case notAllowed
    }

    /// What the host does with a device's answer: `decision` to the request
    /// `approvalID`, shown with `digest`, in the turn `shownTurn`; against the
    /// turn now running and the requests waiting in it, as the host has them.
    /// Only the request shown, still waiting in the same turn, unchanged, and
    /// one a device may allow, is allowed.
    public static func decide(
        decision: String?, approvalID: String?, digest: String?, shownTurn: UUID?,
        chatID: String, currentTurn: UUID?, waiting: [LampAgentRemoteApproval]
    ) -> Outcome {
        let allowing: Bool
        switch decision {
        case allowOnce: allowing = true
        case deny: allowing = false
        default: return .notAllowed
        }
        guard let currentTurn, shownTurn == currentTurn,
              let request = waiting.first(where: { $0.id == approvalID }),
              digest == LampAgentRemoteApproval.digest(chatID: chatID, turnID: currentTurn, approval: request)
        else { return .gone }
        if allowing {
            return request.canAllow ? .allowOnce : .notAllowed
        }
        return .deny
    }
}
