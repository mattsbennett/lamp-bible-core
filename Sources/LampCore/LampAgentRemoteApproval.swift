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
    /// The command, whole where a device may allow it; for any other tool
    /// call, what the Mac's card shows of it.
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
    /// `largestAllowedCommand` characters, every one printable ASCII, a line
    /// break or a tab. Anything else can look like something it isn't — a
    /// no-break space like a space, though the shell reads it as part of a
    /// word; a letter from another script like a Latin one; a mark or
    /// override that draws as nothing — and listing those kept missing one
    /// (Codex's reviews, 0040), so only what reads as itself is let through.
    /// A command with anything more is Deny-only on a device, and may still be
    /// allowed on the Mac.
    public static func canShowWhole(_ command: String) -> Bool {
        guard !command.isEmpty, command.utf8.count <= largestAllowedCommand else { return false }
        return command.unicodeScalars.allSatisfy { scalar in
            (0x20...0x7E).contains(scalar.value) || scalar == "\n" || scalar == "\t"
        }
    }

    /// Whether a device may allow a command run in `folder`: the command
    /// shown whole, and the folder too, by the same rule, since a relative
    /// path in the command is read from it. A command with no folder named,
    /// or one too long to send whole, is Deny-only on a device.
    public static func mayAllow(command: String?, folder: String?) -> Bool {
        guard let command, canShowWhole(command), let folder, canShowWhole(folder),
              folder.utf8.count <= largestField, !folder.contains("\n"), !folder.contains("\t")
        else { return false }
        return true
    }

    /// The most requests a device is sent at once, and the longest any of
    /// their other fields may be: with `largestAllowedCommand`, what keeps a
    /// snapshot or an `approvals` event far inside the largest frame a
    /// connection seals, which it would otherwise drop unsent.
    public static let largestListed = 16
    public static let largestField = 2_000
    /// The longest id a device is sent. A provider's own ids are short; one
    /// longer is left to the Mac, since cutting it could make two one.
    public static let largestID = 256

    /// This request cut to what a device is sent: a command it may allow is
    /// whole already; anything longer is cut, and can only be denied. Cut by
    /// bytes, not characters, since one character can hold any number of
    /// marks.
    public func bounded() -> Self {
        func cut(_ text: String?, _ limit: Int) -> String? {
            guard let text, text.utf8.count > limit else { return text }
            var kept = String.UnicodeScalarView()
            var bytes = 0
            for scalar in text.unicodeScalars {
                bytes += String(scalar).utf8.count
                if bytes > limit { break }
                kept.append(scalar)
            }
            return String(kept) + "…"
        }
        var copy = self
        copy.title = cut(title, 200) ?? ""
        // Allowed only as sent whole: a command or folder cut is Deny-only.
        if cut(command, Self.largestAllowedCommand) != command || cut(folder, Self.largestField) != folder {
            copy.canAllow = false
        }
        copy.command = cut(command, Self.largestAllowedCommand)
        copy.folder = cut(folder, Self.largestField)
        copy.agentReason = cut(agentReason, Self.largestField)
        copy.note = cut(note, Self.largestField)
        return copy
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

    /// Whether two lists are the same to the byte, as the digest reads them:
    /// Swift's `==` takes a precomposed accent and a combining one for the
    /// same, so a change between them would go untold, and an answer to the
    /// copy shown be refused.
    public static func same(_ a: [Self], _ b: [Self]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { digest(chatID: "", turnID: nil, approval: $0) == digest(chatID: "", turnID: nil, approval: $1) }
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
