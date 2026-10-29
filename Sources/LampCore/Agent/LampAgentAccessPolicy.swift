import Foundation

public struct LampAgentAccessPolicy: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    /// `nil` means every installed module; an empty set means none.
    public var allowedModuleIDs: Set<String>?
    public var includesPersonalContent: Bool
    public var maximumSearchResults: Int
    public var maximumPassageVerses: Int
    public var maximumItemCharacters: Int

    public init(
        isEnabled: Bool = true,
        allowedModuleIDs: Set<String>? = nil,
        includesPersonalContent: Bool = false,
        maximumSearchResults: Int = 50,
        maximumPassageVerses: Int = 100,
        maximumItemCharacters: Int = 40_000
    ) {
        self.isEnabled = isEnabled
        self.allowedModuleIDs = allowedModuleIDs
        self.includesPersonalContent = includesPersonalContent
        self.maximumSearchResults = min(max(maximumSearchResults, 1), 200)
        self.maximumPassageVerses = min(max(maximumPassageVerses, 1), 500)
        self.maximumItemCharacters = min(max(maximumItemCharacters, 1_000), 200_000)
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, allowedModuleIDs, includesPersonalContent
        case maximumSearchResults, maximumPassageVerses, maximumItemCharacters
    }

    /// Each key read when present, so a field added later doesn't make every
    /// policy already on disk unreadable, and through `init`, so a limit edited
    /// by hand is held to the same bounds as one set in the app.
    ///
    /// A missing `isEnabled` reads as off, the one default that differs from
    /// `init`'s: a file that doesn't say access is on gives none. A missing
    /// `allowedModuleIDs` is every module, as it always was: that is how the
    /// encoder writes `nil`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LampAgentAccessPolicy()
        self.init(
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
            allowedModuleIDs: try container.decodeIfPresent(Set<String>.self, forKey: .allowedModuleIDs),
            includesPersonalContent: try container.decodeIfPresent(Bool.self, forKey: .includesPersonalContent)
                ?? defaults.includesPersonalContent,
            maximumSearchResults: try container.decodeIfPresent(Int.self, forKey: .maximumSearchResults)
                ?? defaults.maximumSearchResults,
            maximumPassageVerses: try container.decodeIfPresent(Int.self, forKey: .maximumPassageVerses)
                ?? defaults.maximumPassageVerses,
            maximumItemCharacters: try container.decodeIfPresent(Int.self, forKey: .maximumItemCharacters)
                ?? defaults.maximumItemCharacters
        )
    }

    public static let disabled = LampAgentAccessPolicy(isEnabled: false)

    public func allows(moduleID: String) -> Bool {
        allowedModuleIDs?.contains(moduleID) ?? true
    }
}
