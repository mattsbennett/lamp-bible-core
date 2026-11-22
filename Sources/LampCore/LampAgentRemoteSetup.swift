import Foundation

/// What a host's chats can run with, as a device's setup offers it: the
/// providers, what each is set to by default, whether it is signed in on the
/// Mac, and what a chat may read.
///
/// The host names everything here from what its providers publish, as its
/// own menus do. An empty list of models or efforts means the provider takes
/// a typed name, not that there is nothing to choose: `modelHint` and
/// `effortHint` say what to type.
public struct LampAgentRemoteSetup: Codable, Equatable, Sendable {
    public var providers: [Provider]
    /// The provider a new chat of each kind opens on: what a window on the
    /// Mac would open it on.
    public var readerProvider: String
    public var writingProvider: String
    /// What a reader chat may read, as the Mac's settings set it.
    public var access: Access?

    public init(providers: [Provider], readerProvider: String, writingProvider: String, access: Access? = nil) {
        self.providers = providers
        self.readerProvider = readerProvider
        self.writingProvider = writingProvider
        self.access = access
    }

    public func provider(_ id: String?) -> Provider? {
        guard let id else { return nil }
        return providers.first { $0.id == id }
    }

    /// The provider a new chat of this kind opens on.
    public func defaultProvider(forKind kind: String) -> String {
        kind == LampAgentRemoteChatSummary.writing ? writingProvider : readerProvider
    }

    public struct Provider: Codable, Equatable, Identifiable, Sendable {
        /// As in a chat summary: "claude", "codex".
        public var id: String
        public var name: String
        /// The name a menu shows: "Claude", "Codex".
        public var shortName: String
        /// An SF Symbol, shared by the Mac and the phone.
        public var systemImage: String?
        public var connection: Connection
        /// The model names the provider stands behind; empty where it takes
        /// a typed one.
        public var models: [String]
        public var modelHint: String
        /// The effort levels it takes; empty where it takes a typed one, or
        /// where the effort is carried on the model.
        public var efforts: [String]
        public var effortHint: String
        /// The effort is a variant of the model, written on its name
        /// (OpenCode's): there is no effort until a model is named.
        public var effortIsOnTheModel: Bool
        /// What a new chat opens on, as the Mac remembers it: "" for the
        /// provider's own default.
        public var defaultModel: String
        public var defaultEffort: String

        public init(
            id: String,
            name: String,
            shortName: String,
            systemImage: String? = nil,
            connection: Connection,
            models: [String] = [],
            modelHint: String = "",
            efforts: [String] = [],
            effortHint: String = "",
            effortIsOnTheModel: Bool = false,
            defaultModel: String = "",
            defaultEffort: String = ""
        ) {
            self.id = id
            self.name = name
            self.shortName = shortName
            self.systemImage = systemImage
            self.connection = connection
            self.models = models
            self.modelHint = modelHint
            self.efforts = efforts
            self.effortHint = effortHint
            self.effortIsOnTheModel = effortIsOnTheModel
            self.defaultModel = defaultModel
            self.defaultEffort = defaultEffort
        }

        /// Whether an effort can be set with this model: always, except
        /// where it is a variant of a model and none is named.
        public func takesEffort(withModel model: String?) -> Bool {
            !effortIsOnTheModel || !(model ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        /// Why the effort can't be set, when it can't.
        public var effortNeedsModel: String {
            "Name a model first: \(shortName) sets effort as a variant of the model."
        }
    }

    /// Whether a provider can answer on the Mac, as its settings check it.
    public struct Connection: Codable, Equatable, Sendable {
        /// One of the states below, or one a later Lamp knows, which a device
        /// shows as `detail`.
        public var state: String
        /// What to say for it: the reason, for `unavailable`.
        public var detail: String?
        /// When the Mac last checked.
        public var checkedAt: Date?

        public static let checking = "checking"
        public static let connected = "connected"
        public static let notInstalled = "not-installed"
        public static let notConnected = "not-connected"
        public static let unavailable = "unavailable"

        public init(state: String, detail: String? = nil, checkedAt: Date? = nil) {
            self.state = state
            self.detail = detail
            self.checkedAt = checkedAt
        }

        public var isConnected: Bool { state == Self.connected }
        /// Known not to answer: not installed, signed out, or failing.
        public var needsAttention: Bool { !isConnected && state != Self.checking }

        /// As the Mac's settings word it.
        public var label: String {
            switch state {
            case Self.checking: "Checking…"
            case Self.connected: "Connected"
            case Self.notInstalled: "Not installed on your Mac"
            case Self.notConnected: "Not signed in on your Mac"
            default: detail ?? "Unavailable"
            }
        }

        /// What to do about it, which only the Mac can.
        public var remedy: String? {
            switch state {
            case Self.notInstalled, Self.notConnected, Self.unavailable:
                "Set it up in Lamp Bible on your Mac, in Settings › AI & Agents, or choose another provider."
            default: nil
            }
        }
    }

    /// What a reader chat may read on the Mac, as its settings set it.
    public struct Access: Codable, Equatable, Sendable {
        /// Chats may read and search, but not change, the library.
        public var readOnly: Bool
        /// Module access is on.
        public var modulesEnabled: Bool
        /// Every installed module, not only the enabled ones.
        public var allModules: Bool
        /// Notes and highlights on the passage go with each message.
        public var personalStudy: Bool

        public init(readOnly: Bool = true, modulesEnabled: Bool, allModules: Bool, personalStudy: Bool) {
            self.readOnly = readOnly
            self.modulesEnabled = modulesEnabled
            self.allModules = allModules
            self.personalStudy = personalStudy
        }

        /// In the words the Mac's setting uses.
        public var modules: String {
            guard modulesEnabled else { return "Module access is off in AI & Agents settings" }
            let modules = allModules ? "All installed modules" : "Enabled modules"
            return personalStudy ? "\(modules) and personal study content" : modules
        }
    }
}

/// What to change in a chat, or begin one with: each nil is left as it is.
/// "" is a choice, the provider's own default.
public struct LampAgentRemoteChoices: Codable, Equatable, Sendable {
    public var provider: String?
    public var model: String?
    public var effort: String?

    public init(provider: String? = nil, model: String? = nil, effort: String? = nil) {
        self.provider = provider
        self.model = model
        self.effort = effort
    }

    public var isEmpty: Bool { provider == nil && model == nil && effort == nil }
}

/// How a chat's setup is shown in one line, folded: who answers, with what
/// model, about what. The same on every device.
public enum LampAgentRemoteSetupLine {
    /// "Claude · opus · John 3". A provider's own default model goes unnamed,
    /// as its menu calls it only "Default".
    public static func line(provider: String, model: String?, about: String?) -> String {
        let model = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        return [provider, model?.isEmpty == false ? model : nil, about?.isEmpty == false ? about : nil]
            .compactMap { $0 }
            .joined(separator: " \u{00B7} ")
    }

    /// What a model or effort menu says for a choice: the name, or the
    /// provider's default.
    public static func choice(_ value: String?, defaultLabel: String) -> String {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? defaultLabel : value
    }
}
