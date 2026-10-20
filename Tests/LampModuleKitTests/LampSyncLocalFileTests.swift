import Foundation
import Testing
@testable import LampModuleKit

/// The shared half of gathering what a client holds: digesting each file,
/// and the plan's view of it. Each app's own enumeration is tested there.
struct LampSyncLocalFileTests {
    private let webDAV = LampSyncFileRecords.webDAVSource(
        URL(string: "https://dav.example.com/sync/")!
    )

    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-local-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func eachCandidateIsDigestedAndAnUnreadableOneIsReported() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let present = directory.appendingPathComponent("present.lamp")
        try Data("bytes".utf8).write(to: present)
        let absent = directory.appendingPathComponent("absent.lamp")

        let described = LampSyncLocalFiles.describe([
            .init(path: "Translations/present.lamp", kind: .module(.translations), url: present),
            .init(path: "Translations/absent.lamp", kind: .module(.translations), url: absent),
        ])

        #expect(described.files.map(\.path) == ["Translations/present.lamp"])
        #expect(
            described.files.first?.digest == LampSyncContentRevision.digest(for: Data("bytes".utf8))
        )
        // Reported rather than dropped: a pass that publishes a shorter
        // library without saying so is how a file goes missing quietly.
        #expect(described.unreadable.map(\.path) == ["Translations/absent.lamp"])
    }

    /// A file is digested every pass. An earlier version of this skipped the
    /// read when size and modification date matched what was recorded, which
    /// would have silently never uploaded a file replaced at the same size
    /// with its date preserved — a restore, `cp -p`, `rsync -t`.
    @Test func aReplacedFileIsSeenEvenWithItsSizeAndDatePreserved() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("module.lamp")
        try Data("aaaaa".utf8).write(to: url)
        let date = try #require(
            try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        )

        let candidate = LampSyncLocalFiles.Candidate(
            path: "Translations/module.lamp", kind: .module(.translations), url: url
        )
        let before = LampSyncLocalFiles.describe([candidate]).files.first?.digest

        try Data("bbbbb".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: url.path
        )
        let after = LampSyncLocalFiles.describe([candidate]).files.first?.digest

        #expect(before != nil)
        #expect(before != after, "the same size and date must not hide different bytes")
    }

    @Test func localsCarryWhatThisClientLastUploaded() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let unchanged = directory.appendingPathComponent("unchanged.lamp")
        let edited = directory.appendingPathComponent("edited.lamp")
        try Data("same".utf8).write(to: unchanged)
        try Data("new".utf8).write(to: edited)

        var records = LampSyncFileRecords()
        records.recordUpload(
            "Translations/unchanged.lamp", in: webDAV,
            digest: LampSyncContentRevision.digest(for: Data("same".utf8)),
            revision: "\"v1\""
        )
        records.recordUpload(
            "Translations/edited.lamp", in: webDAV,
            digest: LampSyncContentRevision.digest(for: Data("old".utf8)),
            revision: "\"v2\""
        )

        let described = LampSyncLocalFiles.describe([
            .init(path: "Translations/unchanged.lamp", kind: .module(.translations), url: unchanged),
            .init(path: "Translations/edited.lamp", kind: .module(.translations), url: edited),
        ])
        let locals = LampSyncLocalFiles.locals(described.files, records: records, source: webDAV)

        #expect(locals.count == 2)
        #expect(locals.first?.changedSinceUpload == false)
        #expect(locals.first?.lastRevision == "\"v1\"")
        #expect(locals.last?.changedSinceUpload == true)
    }
}
