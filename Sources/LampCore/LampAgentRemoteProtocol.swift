import Foundation

/// The contract between a Mac that runs agent chats and a phone or iPad that
/// follows and continues them.
///
/// The phone cannot sign in to the providers' command-line tools, so it never
/// runs an agent: it is a window onto the Mac's chats. Every turn runs on the
/// Mac, through the same chat a Mac window shows, and is saved there as any
/// other turn is. Nothing passes through a service of ours: the two find each
/// other with Bonjour on the local network, or peer to peer when they are
/// near, and talk directly.
///
/// A connection opens with a handshake in the clear
/// (`LampAgentRemoteHello`, then `LampAgentRemoteAuth`), which agrees keys
/// fresh for that connection; see `LampAgentRemoteHandshake`. Everything
/// after it is a `LampAgentRemoteMessage` sealed by a
/// `LampAgentRemoteSecureChannel`. Frames are four-byte, big-endian
/// length-prefixed, as the presentation remote's are.
public enum LampAgentRemoteProtocol {
    public static let currentVersion = 1
    public static let bonjourServiceType = "_lamp-agent._tcp"
    /// A chat's whole transcript travels in one snapshot, so this is larger
    /// than a slide's frame needs.
    public static let maximumFrameLength = 8 * 1_024 * 1_024
}

// MARK: - Sealed messages

/// Everything said after the handshake, in either direction.
///
/// Flat, with the fields each kind uses, like the presentation remote's
/// message. Kinds are open strings rather than an enum: a newer Lamp will
/// send kinds this one has no name for, and a message it doesn't know is one
/// to ignore, not a reason to drop the connection.
public struct LampAgentRemoteMessage: Codable, Equatable, Sendable {
    public struct Kind: RawRepresentable, Codable, Hashable, Sendable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        // Host to device
        /// The host's first sealed message: proof that it holds the same key,
        /// and on pairing, the device's own credential.
        public static let accepted = Kind(rawValue: "accepted")
        /// The chats the host can show, sent on request and whenever they change.
        public static let chats = Kind(rawValue: "chats")
        /// A chat as it stands, sent when it is opened.
        public static let snapshot = Kind(rawValue: "snapshot")
        /// Something that happened in the open chat.
        public static let event = Kind(rawValue: "event")
        /// A request that could not be done, with a `LampAgentRemoteFailure`
        /// code so the device can say the right thing without reading English.
        public static let failed = Kind(rawValue: "failed")
        public static let pong = Kind(rawValue: "pong")

        // Device to host
        /// What the device calls itself, for the host's list of paired devices.
        public static let introduce = Kind(rawValue: "introduce")
        public static let listChats = Kind(rawValue: "list-chats")
        /// Follow one chat: its snapshot, then its events, until another is
        /// opened or it is closed.
        public static let openChat = Kind(rawValue: "open-chat")
        public static let closeChat = Kind(rawValue: "close-chat")
        /// The next message in a chat, with where the device is reading.
        /// Refused as `busy` while a reply is running.
        public static let send = Kind(rawValue: "send")
        /// Stop the chat's running turn.
        public static let cancel = Kind(rawValue: "cancel")
        public static let startChat = Kind(rawValue: "start-chat")
        public static let ping = Kind(rawValue: "ping")
    }

    public var kind: Kind
    /// Set by the device on a request, and echoed by the host on what answers
    /// it, so a failure can be put beside the thing that failed.
    public var requestID: UUID?
    public var chatID: String?
    public var text: String?
    public var chats: [LampAgentRemoteChatSummary]?
    public var snapshot: LampAgentRemoteChatSnapshot?
    public var event: LampAgentRemoteChatEvent?
    public var newChat: LampAgentRemoteNewChat?
    /// On `send`: where the device is reading as the message is sent.
    public var reading: LampAgentRemoteReading?
    public var clientName: String?
    /// On pairing only: the id the host knows this device by, and the key
    /// it will use on every later connection. Kept in the device's Keychain,
    /// on that device only.
    public var deviceID: String?
    public var deviceKey: String?
    /// On pairing only: the host's secret, by which the device recognises it
    /// again. See `LampAgentRemoteHandshake.hostHint(secret:nonce:)`.
    public var hostSecret: String?
    /// On `failed`: one of `LampAgentRemoteFailure`'s codes, or one a later
    /// Lamp knows, which a device shows as `errorMessage`.
    public var errorCode: String?
    public var errorMessage: String?

    public init(
        kind: Kind,
        requestID: UUID? = nil,
        chatID: String? = nil,
        text: String? = nil,
        chats: [LampAgentRemoteChatSummary]? = nil,
        snapshot: LampAgentRemoteChatSnapshot? = nil,
        event: LampAgentRemoteChatEvent? = nil,
        newChat: LampAgentRemoteNewChat? = nil,
        reading: LampAgentRemoteReading? = nil,
        clientName: String? = nil,
        deviceID: String? = nil,
        deviceKey: String? = nil,
        hostSecret: String? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) {
        self.kind = kind
        self.requestID = requestID
        self.chatID = chatID
        self.text = text
        self.chats = chats
        self.snapshot = snapshot
        self.event = event
        self.newChat = newChat
        self.reading = reading
        self.clientName = clientName
        self.deviceID = deviceID
        self.deviceKey = deviceKey
        self.hostSecret = hostSecret
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }

    public static func accepted(pairing credential: LampAgentRemoteDeviceCredential? = nil, hostSecret: String? = nil) -> Self {
        .init(kind: .accepted, deviceID: credential?.deviceID, deviceKey: credential?.deviceKey, hostSecret: hostSecret)
    }

    public static func introduce(clientName: String) -> Self {
        .init(kind: .introduce, clientName: clientName)
    }

    public static func listChats(requestID: UUID = UUID()) -> Self {
        .init(kind: .listChats, requestID: requestID)
    }

    public static func chats(_ chats: [LampAgentRemoteChatSummary], requestID: UUID? = nil) -> Self {
        .init(kind: .chats, requestID: requestID, chats: chats)
    }

    public static func openChat(_ chatID: String, requestID: UUID = UUID()) -> Self {
        .init(kind: .openChat, requestID: requestID, chatID: chatID)
    }

    public static func closeChat(_ chatID: String) -> Self {
        .init(kind: .closeChat, chatID: chatID)
    }

    public static func snapshot(_ snapshot: LampAgentRemoteChatSnapshot, requestID: UUID? = nil) -> Self {
        .init(kind: .snapshot, requestID: requestID, chatID: snapshot.summary.id, snapshot: snapshot)
    }

    public static func send(
        _ text: String,
        to chatID: String,
        reading: LampAgentRemoteReading? = nil,
        requestID: UUID = UUID()
    ) -> Self {
        .init(kind: .send, requestID: requestID, chatID: chatID, text: text, reading: reading)
    }

    public static func cancel(_ chatID: String, requestID: UUID = UUID()) -> Self {
        .init(kind: .cancel, requestID: requestID, chatID: chatID)
    }

    public static func startChat(_ newChat: LampAgentRemoteNewChat, requestID: UUID = UUID()) -> Self {
        .init(kind: .startChat, requestID: requestID, newChat: newChat)
    }

    public static func event(_ event: LampAgentRemoteChatEvent) -> Self {
        .init(kind: .event, chatID: event.chatID, event: event)
    }

    public static func failed(
        _ code: String,
        _ message: String,
        requestID: UUID? = nil,
        chatID: String? = nil
    ) -> Self {
        .init(kind: .failed, requestID: requestID, chatID: chatID, errorCode: code, errorMessage: message)
    }

    public static let ping = Self(kind: .ping)
    public static let pong = Self(kind: .pong)
}

/// Why a request failed, as codes a device can act on.
public enum LampAgentRemoteFailure {
    /// A reply is already running in that chat; the host takes one at a time.
    public static let busy = "busy"
    public static let notFound = "not-found"
    /// The provider needs signing in or setting up, which only the Mac can do.
    public static let needsSetup = "needs-setup"
    /// The library's AI features are switched off.
    public static let aiOff = "ai-off"
    /// Something this device may not do, such as writing to a chat the host
    /// keeps to its own windows.
    public static let notAllowed = "not-allowed"
}

/// Where the device is reading, sent with a message so the host can tell the
/// agent, as a Mac window does. Ids only: the host reads the passage, and any
/// notes and highlights its own access policy shares, from its own library,
/// so no note's text crosses from the device.
public struct LampAgentRemoteReading: Codable, Equatable, Sendable {
    /// The verse in view or selected, as BBCCCVVV.
    public var verse: Int?
    /// The chapter, as BBCCC000.
    public var chapter: Int?
    public var translationID: String?

    public init(verse: Int? = nil, chapter: Int? = nil, translationID: String? = nil) {
        self.verse = verse
        self.chapter = chapter
        self.translationID = translationID
    }
}

/// A chat as the host's list shows it.
///
/// Version 1 lists reader chats only: a writing chat's transcript quotes its
/// draft, so the host leaves those out rather than showing them read-only.
public struct LampAgentRemoteChatSummary: Codable, Equatable, Identifiable, Sendable {
    /// The host's own name for the chat, opaque to the device. On the Mac, the
    /// reader chat's UUID: one conversation, whichever providers spoke in it.
    public var id: String
    public var title: String
    /// What the chat is about, under its title: a passage, or a writing's name.
    public var subtitle: String?
    /// `reader`, `writing`, or a kind a later Lamp knows. Only reader chats
    /// can be continued from a device in this version.
    public var kind: String
    /// The provider's id (`claude`, `codex`) and the name to show for it: the
    /// one that spoke last, which is the one `send` continues with.
    public var provider: String
    public var providerName: String
    /// The last thing said in it, by either side.
    public var updatedAt: Date?
    public var preview: String?
    /// A turn is running on the host now.
    public var isRunning: Bool
    /// Whether a device may send to it. False for a kind the host keeps to
    /// its own windows, so the device can show it and say why it can't reply.
    public var acceptsMessages: Bool

    public static let reader = "reader"
    public static let writing = "writing"

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        kind: String,
        provider: String,
        providerName: String,
        updatedAt: Date? = nil,
        preview: String? = nil,
        isRunning: Bool = false,
        acceptsMessages: Bool
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.provider = provider
        self.providerName = providerName
        self.updatedAt = updatedAt
        self.preview = preview
        self.isRunning = isRunning
        self.acceptsMessages = acceptsMessages
    }
}

/// One thing said in a chat, as its transcript keeps it.
public struct LampAgentRemoteChatMessage: Codable, Equatable, Identifiable, Sendable {
    /// The transcript's own id for the message, so the device's copy and the
    /// file agree, and a snapshot after reconnecting can be merged by id.
    public var id: UUID
    /// `user` or `assistant`.
    public var role: String
    /// Markdown, as the Mac draws it.
    public var text: String
    public var date: Date

    public static let user = "user"
    public static let assistant = "assistant"

    public init(id: UUID = UUID(), role: String, text: String, date: Date) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
    }
}

/// What a running turn is doing, on the way to its reply. Live only, as on
/// the Mac: none of it is kept.
public struct LampAgentRemoteActivity: Codable, Equatable, Sendable {
    /// `thinking`, `tool-started`, `tool`, `tool-finished`, `writing`, or a
    /// kind a later Lamp knows, which a device shows as working.
    public var kind: String
    /// The tool, as a person would name it.
    public var name: String?
    /// A tool call's input, in one line.
    public var summary: String?
    public var estimatedTokens: Int?

    public static let thinking = "thinking"
    public static let toolStarted = "tool-started"
    public static let tool = "tool"
    public static let toolFinished = "tool-finished"
    public static let writing = "writing"

    public init(kind: String, name: String? = nil, summary: String? = nil, estimatedTokens: Int? = nil) {
        self.kind = kind
        self.name = name
        self.summary = summary
        self.estimatedTokens = estimatedTokens
    }
}

/// A chat as it stands when it is opened: what has been said, and if a turn
/// is running, how far it has got, so a device joining mid-reply picks it up
/// where it is.
public struct LampAgentRemoteChatSnapshot: Codable, Equatable, Sendable {
    public var summary: LampAgentRemoteChatSummary
    public var messages: [LampAgentRemoteChatMessage]
    /// The running turn's reply so far.
    public var partialReply: String?
    public var activity: LampAgentRemoteActivity?
    /// Said by the host above the chat, such as that it continues from a
    /// session that can't be resumed on this Mac.
    public var notice: String?

    public init(
        summary: LampAgentRemoteChatSummary,
        messages: [LampAgentRemoteChatMessage],
        partialReply: String? = nil,
        activity: LampAgentRemoteActivity? = nil,
        notice: String? = nil
    ) {
        self.summary = summary
        self.messages = messages
        self.partialReply = partialReply
        self.activity = activity
        self.notice = notice
    }
}

/// Something that happened in the open chat, whichever window or device
/// caused it.
public struct LampAgentRemoteChatEvent: Codable, Equatable, Sendable {
    public var chatID: String
    /// One of the kinds below, or a kind a later Lamp knows, which a device
    /// ignores.
    public var kind: String
    /// The turn it belongs to: the id of the message the turn began with.
    public var turnID: UUID?
    /// `turn-started`: the message the turn began with. `reply`: the reply as
    /// saved, under the transcript's id, which replaces the last fragment.
    public var message: LampAgentRemoteChatMessage?
    /// `fragment`: **the reply so far, whole**, replacing the last fragment
    /// rather than adding to it, so a dropped frame or a device joining
    /// mid-reply is behind by one update, never wrong. The host sends these
    /// at its own pace. `failed`: what went wrong.
    public var text: String?
    /// `activity`: what the turn is doing now.
    public var activity: LampAgentRemoteActivity?

    public static let turnStarted = "turn-started"
    public static let fragment = "fragment"
    public static let activity = "activity"
    public static let reply = "reply"
    public static let failed = "failed"
    public static let turnEnded = "turn-ended"

    public init(
        chatID: String,
        kind: String,
        turnID: UUID? = nil,
        message: LampAgentRemoteChatMessage? = nil,
        text: String? = nil,
        activity: LampAgentRemoteActivity? = nil
    ) {
        self.chatID = chatID
        self.kind = kind
        self.turnID = turnID
        self.message = message
        self.text = text
        self.activity = activity
    }
}

/// A chat a device asks the host to begin, with its first message.
public struct LampAgentRemoteNewChat: Codable, Equatable, Sendable {
    /// `reader` in this version.
    public var kind: String
    /// The provider to run it with, or nil for the host's reader default.
    public var provider: String?
    /// Where the device is reading, as with `send`.
    public var reading: LampAgentRemoteReading?
    public var firstMessage: String

    public init(
        kind: String = LampAgentRemoteChatSummary.reader,
        provider: String? = nil,
        reading: LampAgentRemoteReading? = nil,
        firstMessage: String
    ) {
        self.kind = kind
        self.provider = provider
        self.reading = reading
        self.firstMessage = firstMessage
    }
}
