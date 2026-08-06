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

    public static let disabled = LampAgentAccessPolicy(isEnabled: false)

    public func allows(moduleID: String) -> Bool {
        allowedModuleIDs?.contains(moduleID) ?? true
    }
}
