import Foundation

public enum ModuleValidationSeverity: String, Codable, Sendable {
    case error
    case warning
}

public struct ModuleValidationIssue: Codable, Equatable, Identifiable, Sendable {
    public let severity: ModuleValidationSeverity
    public let path: String
    public let message: String

    public var id: String {
        "\(severity.rawValue):\(path):\(message)"
    }

    public init(severity: ModuleValidationSeverity, path: String, message: String) {
        self.severity = severity
        self.path = path
        self.message = message
    }
}

public struct ModuleMetadataSummary: Codable, Equatable, Sendable {
    public let id: String?
    public let name: String?
    public let schemaVersion: String?
    public let declaredType: String?

    public init(id: String?, name: String?, schemaVersion: String?, declaredType: String?) {
        self.id = id
        self.name = name
        self.schemaVersion = schemaVersion
        self.declaredType = declaredType
    }
}

public struct ModuleInspection: Codable, Equatable, Sendable {
    public let kind: LampModuleKind?
    public let metadata: ModuleMetadataSummary
    public let statistics: [String: Int]
    public let issues: [ModuleValidationIssue]

    public var canCompile: Bool {
        kind != nil && !issues.contains { $0.severity == .error }
    }

    public init(
        kind: LampModuleKind?,
        metadata: ModuleMetadataSummary,
        statistics: [String: Int],
        issues: [ModuleValidationIssue]
    ) {
        self.kind = kind
        self.metadata = metadata
        self.statistics = statistics
        self.issues = issues
    }
}

public enum ModuleInspectionError: Error, LocalizedError, Equatable, Sendable {
    case invalidJSON(String)
    case rootMustBeObject

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let reason):
            return "The file is not valid JSON: \(reason)"
        case .rootMustBeObject:
            return "A module JSON file must contain an object at its root."
        }
    }
}
