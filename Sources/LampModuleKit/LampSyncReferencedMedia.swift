import Foundation

/// Transfers referenced files as one sync phase. A failed file does not hide
/// later files, but any failure prevents the phase from reporting completion.
public enum LampSyncReferencedMedia {
    public struct Item: Equatable, Sendable {
        public let remotePath: String
        public let localURL: URL

        public init(remotePath: String, localURL: URL) {
            self.remotePath = remotePath
            self.localURL = localURL
        }
    }

    public static func downloadMissing(
        _ items: [Item],
        fileManager: FileManager = .default,
        readRemote: (String) async throws -> Data
    ) async throws {
        var firstFailure: Error?
        for item in items {
            try Task.checkCancellation()
            if fileManager.fileExists(atPath: item.localURL.path) { continue }
            do {
                let data = try await readRemote(item.remotePath)
                try fileManager.createDirectory(
                    at: item.localURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: item.localURL, options: .atomic)
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure { throw firstFailure }
    }

    public static func uploadAll(
        _ items: [Item],
        readLocal: (URL) throws -> Data,
        publish: (String, Data) async throws -> Void
    ) async throws {
        var firstFailure: Error?
        for item in items {
            try Task.checkCancellation()
            do {
                let data = try readLocal(item.localURL)
                try await publish(item.remotePath, data)
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure { throw firstFailure }
    }
}
