import Foundation

public struct ModuleCompilationResult: Equatable, Sendable {
    public let outputURL: URL
    public let moduleID: String
    public let kind: LampModuleKind
    public let formatVersion: String
    public let tableCounts: [String: Int]
    public let uncompressedByteCount: Int
    public let compressedByteCount: Int
    public let sha256: String
    /// What the inputs were warned about, for a build that went ahead anyway:
    /// a series' volumes', each path prefixed with its file.
    public let warnings: [ModuleValidationIssue]

    public init(
        outputURL: URL,
        moduleID: String,
        kind: LampModuleKind,
        formatVersion: String,
        tableCounts: [String: Int],
        uncompressedByteCount: Int,
        compressedByteCount: Int,
        sha256: String,
        warnings: [ModuleValidationIssue] = []
    ) {
        self.outputURL = outputURL
        self.moduleID = moduleID
        self.kind = kind
        self.formatVersion = formatVersion
        self.tableCounts = tableCounts
        self.uncompressedByteCount = uncompressedByteCount
        self.compressedByteCount = compressedByteCount
        self.sha256 = sha256
        self.warnings = warnings
    }
}

public enum ModuleCompilationError: Error, LocalizedError, Sendable {
    case validationFailed([ModuleValidationIssue])
    case unsupportedModuleType(LampModuleKind)
    case missingValue(path: String)
    case invalidValue(path: String, expected: String)
    case invalidOutputExtension
    case outputNameMismatch(expected: String, actual: String)
    case outputDirectoryMissing(String)
    case databaseCreationFailed(String)
    case integrityCheckFailed(String)
    case compressionFailed

    public var errorDescription: String? {
        switch self {
        case .validationFailed(let issues):
            let errors = issues.filter { $0.severity == .error }
            // Each error where it is, so a build that stops says why, and of
            // a series' volumes which file. Found by Codex.
            let listed = errors.prefix(5).map { "\($0.path): \($0.message)" }.joined(separator: "; ")
            let more = errors.count > 5 ? "; and \(errors.count - 5) more" : ""
            return "Module validation failed with \(errors.count) error\(errors.count == 1 ? "" : "s"): \(listed)\(more)."
        case .unsupportedModuleType(let kind):
            return "Building \(kind.rawValue) modules is not supported yet."
        case .missingValue(let path):
            return "Missing required value at \(path)."
        case .invalidValue(let path, let expected):
            return "Invalid value at \(path); expected \(expected)."
        case .invalidOutputExtension:
            return "The output filename must use the .lamp extension."
        case .outputNameMismatch(let expected, let actual):
            return "The output must be named \(expected).lamp, not \(actual).lamp, because the filename is part of the module identity."
        case .outputDirectoryMissing(let path):
            return "The output directory does not exist: \(path)"
        case .databaseCreationFailed(let reason):
            return "Could not create the module database: \(reason)"
        case .integrityCheckFailed(let reason):
            return "The generated module failed its integrity check: \(reason)"
        case .compressionFailed:
            return "Could not compress and verify the generated module."
        }
    }
}
