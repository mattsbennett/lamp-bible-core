import CryptoKit
import Foundation
import GRDB

public struct LampModuleCompiler: Sendable {
    public static let formatVersion = "1.0"
    public static let supportedKinds: Set<LampModuleKind> = [
        .translation,
        .dictionary,
        .commentary,
        .notes,
        .plan,
        .highlights,
    ]

    public init() {}

    public func compile(
        sourceURL: URL,
        destinationURL: URL? = nil
    ) throws -> ModuleCompilationResult {
        let hasSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        let resolvedDestinationURL: URL
        if let destinationURL {
            resolvedDestinationURL = destinationURL
        } else {
            let inspection = try ModuleJSONInspector().inspect(data)
            let moduleID = inspection.metadata.id
                ?? sourceURL.deletingPathExtension().lastPathComponent
            resolvedDestinationURL = sourceURL
                .deletingLastPathComponent()
                .appendingPathComponent(moduleID)
                .appendingPathExtension("lamp")
        }
        return try compile(
            data: data,
            sourceFilename: sourceURL.lastPathComponent,
            destinationURL: resolvedDestinationURL
        )
    }

    public func compile(
        data: Data,
        sourceFilename: String,
        destinationURL requestedDestinationURL: URL? = nil
    ) throws -> ModuleCompilationResult {
        let inspection = try ModuleJSONInspector().inspect(data)
        let errors = inspection.issues.filter { $0.severity == .error }
        guard errors.isEmpty else {
            throw ModuleCompilationError.validationFailed(inspection.issues)
        }
        guard let kind = inspection.kind else {
            throw ModuleCompilationError.validationFailed(inspection.issues)
        }
        guard Self.supportedKinds.contains(kind) else {
            throw ModuleCompilationError.unsupportedModuleType(kind)
        }

        let jsonValue: Any
        do {
            jsonValue = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ModuleInspectionError.invalidJSON(error.localizedDescription)
        }
        let root = try JSONSupport.requiredObject(jsonValue, path: "/")

        let sourceStem = URL(fileURLWithPath: sourceFilename).deletingPathExtension().lastPathComponent
        let moduleID = inspection.metadata.id ?? sourceStem
        guard !moduleID.isEmpty else {
            throw ModuleCompilationError.missingValue(path: "/meta/id")
        }

        let destinationURL = requestedDestinationURL
            ?? URL(fileURLWithPath: sourceFilename)
                .deletingLastPathComponent()
                .appendingPathComponent(moduleID)
                .appendingPathExtension("lamp")
        try validateOutputURL(destinationURL, moduleID: moduleID)

        let fileManager = FileManager.default
        let outputDirectory = destinationURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: outputDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ModuleCompilationError.outputDirectoryMissing(outputDirectory.path)
        }

        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("lamp-module-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let databaseURL = temporaryDirectory.appendingPathComponent("module.sqlite")
        let tableCounts: [String: Int]
        do {
            switch kind {
            case .translation:
                tableCounts = try compileTranslation(root: root, databaseURL: databaseURL, moduleID: moduleID)
            case .dictionary:
                tableCounts = try compileDictionary(root: root, databaseURL: databaseURL, moduleID: moduleID)
            case .commentary:
                tableCounts = try compileCommentary(root: root, databaseURL: databaseURL, moduleID: moduleID)
            case .notes:
                tableCounts = try compileNotes(root: root, databaseURL: databaseURL, moduleID: moduleID)
            case .plan:
                tableCounts = try compilePlan(root: root, databaseURL: databaseURL, moduleID: moduleID)
            case .highlights:
                tableCounts = try compileHighlights(root: root, databaseURL: databaseURL, moduleID: moduleID)
            default:
                throw ModuleCompilationError.unsupportedModuleType(kind)
            }
        } catch let error as ModuleCompilationError {
            throw error
        } catch {
            throw ModuleCompilationError.databaseCreationFailed(error.localizedDescription)
        }

        try verifyDatabase(at: databaseURL)
        let databaseData = try Data(contentsOf: databaseURL, options: [.mappedIfSafe])
        let compressedData = try compressAndVerify(databaseData)

        let hasDestinationScope = destinationURL.startAccessingSecurityScopedResource()
        defer {
            if hasDestinationScope {
                destinationURL.stopAccessingSecurityScopedResource()
            }
        }
        try compressedData.write(to: destinationURL, options: [.atomic])

        let digest = SHA256.hash(data: compressedData)
            .map { String(format: "%02x", $0) }
            .joined()

        return ModuleCompilationResult(
            outputURL: destinationURL,
            moduleID: moduleID,
            kind: kind,
            formatVersion: Self.formatVersion,
            tableCounts: tableCounts,
            uncompressedByteCount: databaseData.count,
            compressedByteCount: compressedData.count,
            sha256: digest
        )
    }

    func makeDatabaseQueue(at url: URL) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.label = "LampModuleKit.Compiler"
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode = DELETE")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        return queue
    }

    func createFormatMetadata(
        in db: Database,
        kind: LampModuleKind,
        moduleID: String
    ) throws {
        try db.execute(sql: """
            CREATE TABLE module_format (
                format_version TEXT NOT NULL,
                module_type TEXT NOT NULL,
                module_id TEXT NOT NULL
            )
            """)
        try db.execute(
            sql: "INSERT INTO module_format (format_version, module_type, module_id) VALUES (?, ?, ?)",
            arguments: [Self.formatVersion, kind.rawValue, moduleID]
        )
    }

    func optimize(_ queue: DatabaseQueue) throws {
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "ANALYZE")
            try db.execute(sql: "VACUUM")
        }
    }

    private func validateOutputURL(_ url: URL, moduleID: String) throws {
        guard url.pathExtension.lowercased() == "lamp" else {
            throw ModuleCompilationError.invalidOutputExtension
        }
        let actualName = url.deletingPathExtension().lastPathComponent
        guard actualName == moduleID else {
            throw ModuleCompilationError.outputNameMismatch(expected: moduleID, actual: actualName)
        }
    }

    private func verifyDatabase(at url: URL) throws {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        try queue.read { db in
            let quickCheck = try String.fetchAll(db, sql: "PRAGMA quick_check")
            guard quickCheck == ["ok"] else {
                throw ModuleCompilationError.integrityCheckFailed(quickCheck.joined(separator: "; "))
            }
            let foreignKeyFailures = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
            guard foreignKeyFailures.isEmpty else {
                throw ModuleCompilationError.integrityCheckFailed("Foreign-key check returned \(foreignKeyFailures.count) row(s).")
            }
        }
    }

    private func compressAndVerify(_ data: Data) throws -> Data {
        guard let compressed = try? (data as NSData).compressed(using: .zlib) as Data,
              let decompressed = try? (compressed as NSData).decompressed(using: .zlib) as Data,
              decompressed == data else {
            throw ModuleCompilationError.compressionFailed
        }
        return compressed
    }
}
