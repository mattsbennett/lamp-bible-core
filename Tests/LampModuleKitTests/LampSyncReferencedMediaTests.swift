import Foundation
import LampModuleKit
import Testing

struct LampSyncReferencedMediaTests {
    private enum TransferFailure: Error, Equatable {
        case unavailable
    }

    @Test func missingDownloadFailsBatchButLaterFileCanArriveAndRetrySkipsIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-media-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = LampSyncReferencedMedia.Item(
            remotePath: "first", localURL: root.appendingPathComponent("nested/first")
        )
        let second = LampSyncReferencedMedia.Item(
            remotePath: "second", localURL: root.appendingPathComponent("nested/second")
        )
        await #expect(throws: TransferFailure.unavailable) {
            try await LampSyncReferencedMedia.downloadMissing([first, second]) { path in
                if path == "first" { throw TransferFailure.unavailable }
                return Data("second body".utf8)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: first.localURL.path))
        #expect(try Data(contentsOf: second.localURL) == Data("second body".utf8))

        try await LampSyncReferencedMedia.downloadMissing([first, second]) { path in
            if path == "second" { throw TransferFailure.unavailable }
            return Data("first body".utf8)
        }
        #expect(try Data(contentsOf: first.localURL) == Data("first body".utf8))
    }

    @Test func failedUploadKeepsBatchIncompleteAfterLaterFilePublishes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-media-upload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("first")
        let secondURL = root.appendingPathComponent("second")
        let publishedURL = root.appendingPathComponent("published")
        try Data("first body".utf8).write(to: firstURL)
        try Data("second body".utf8).write(to: secondURL)
        let items = [
            LampSyncReferencedMedia.Item(remotePath: "first", localURL: firstURL),
            LampSyncReferencedMedia.Item(remotePath: "second", localURL: secondURL),
        ]
        await #expect(throws: TransferFailure.unavailable) {
            try await LampSyncReferencedMedia.uploadAll(
                items,
                readLocal: { try Data(contentsOf: $0) },
                publish: { path, data in
                    if path == "first" { throw TransferFailure.unavailable }
                    try data.write(to: publishedURL)
                }
            )
        }
        #expect(try Data(contentsOf: publishedURL) == Data("second body".utf8))
    }
}
