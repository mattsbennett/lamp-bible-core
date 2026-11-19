import Foundation
import LampModuleKit

/// Where a device keeps its writings' documents, the outline, notes and
/// sources beside each writing's prose: `<root>/<folder>/<name>`, one folder
/// per writing named by `LampWritingWorkspaceLayout.directoryName(for:)`.
/// The Mac's root is its writing workspaces, so these are the files its
/// editor shows as tabs; the phone's is a folder of its own.
///
/// Both apps use this, so a document arriving from a pass is taken in the
/// same way wherever it lands (`LampWritingDocumentMerge`), and names are
/// read and written in NFC on both.
public struct LampWritingDocumentStore: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public struct Document: Equatable, Sendable, Identifiable {
        /// In NFC.
        public let name: String
        public let data: Data
        /// Read from the file system, never from a URL's cached values.
        public let modified: Date?

        public var id: String { name }
        public var text: String { String(decoding: data, as: UTF8.self) }
        public var isKeptCopy: Bool { LampWritingWorkspaceLayout.isKeptCopy(name) }
    }

    public func folderURL(writingID: String) -> URL {
        rootURL.appendingPathComponent(LampWritingWorkspaceLayout.directoryName(for: writingID), isDirectory: true)
    }

    /// Throws for a name that is not a document's.
    public func url(writingID: String, name: String) throws -> URL {
        try url(folder: LampWritingWorkspaceLayout.directoryName(for: writingID), name: name)
    }

    func url(folder: String, name: String) throws -> URL {
        // Checked by building its server path, which refuses what the
        // layout does not hold.
        let path = try LampWritingWorkspaceLayout.documentPath(folder: folder, name: name)
        guard let document = LampWritingWorkspaceLayout.document(ofPath: path) else {
            throw LampSyncFolderLayout.PathError.unsafe(path)
        }
        return rootURL
            .appendingPathComponent(document.folder, isDirectory: true)
            .appendingPathComponent(document.name)
    }

    /// The writing's documents, by name. A file that cannot be read is left
    /// out rather than shown empty: shown empty, a save would replace it.
    public func documents(writingID: String) throws -> [Document] {
        try documents(inFolder: folderURL(writingID: writingID))
    }

    private func documents(inFolder folder: URL) throws -> [Document] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).compactMap { url -> Document? in
            let name = url.lastPathComponent.precomposedStringWithCanonicalMapping
            guard LampWritingWorkspaceLayout.isDocumentName(name) else { return nil }
            return Self.locks.holding(url) {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      let data = try? Data(contentsOf: url) else { return nil }
                return Document(name: name, data: data, modified: Self.modified(url))
            }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Every document held here, by its server path, for a pass to gather.
    public func held() throws -> [String: URL] {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return [:] }
        var held: [String: URL] = [:]
        for folder in try FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) {
            let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            for document in try documents(inFolder: folder) {
                guard let path = try? LampWritingWorkspaceLayout.documentPath(
                    folder: folder.lastPathComponent, name: document.name
                ) else { continue }
                held[path] = folder.appendingPathComponent(document.name)
            }
        }
        return held
    }

    /// Writes a document, only if the file still holds `expected`: the bytes
    /// the writer's editor opened, or nil for a document that must not exist
    /// yet. Returns false, writing nothing, where it changed meanwhile, as a
    /// pass taking a download in would change it; the caller keeps the
    /// writer's text and asks again rather than writing over the other.
    ///
    /// A new document whose name differs from one already there only in
    /// case is refused too: the file systems Lamp runs on hold the two as
    /// one file, and the server as two.
    @discardableResult
    public func write(_ data: Data, writingID: String, name: String, replacing expected: Data?) throws -> Bool {
        let url = try url(writingID: writingID, name: name)
        let folded = name.precomposedStringWithCanonicalMapping.lowercased()
        let exact = name.precomposedStringWithCanonicalMapping
        return try Self.locks.holding(url) {
            if expected == nil, try documents(writingID: writingID)
                .contains(where: { $0.name.lowercased() == folded && $0.name != exact }) {
                return false
            }
            guard try Self.contents(of: url) == expected else { return false }
            if expected == data { return true }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return true
        }
    }

    /// Removes a document the writer deleted. The caller records the removal
    /// as a deletion (`deletionTime`), so other devices remove theirs.
    public func remove(writingID: String, name: String) throws {
        try remove(at: url(writingID: writingID, name: name))
    }

    /// Carries out a deletion made on another device: the document at a
    /// server path is removed, unless this device edited it since it last
    /// agreed with the server (`agreedDigest`, the pass's record of what it
    /// last sent or took). Then it is kept under a copy's name instead, as
    /// both sides' edits are when both change it, and returns that name; the
    /// next pass sends it as a document of its own.
    @discardableResult
    public func remove(
        path: String, agreedDigest: String?, localDevice: String, at date: Date = Date()
    ) throws -> String? {
        guard let document = LampWritingWorkspaceLayout.document(ofPath: path) else {
            throw LampSyncFolderLayout.PathError.unsafe(path)
        }
        let url = try url(folder: document.folder, name: document.name)
        let folder = url.deletingLastPathComponent()
        return try Self.locks.holding(url) {
            let held = try Self.contents(of: url)
            guard LampWritingDocumentMerge.keepsOnDeletion(held: held, agreedDigest: agreedDigest) else {
                try remove(at: url)
                return nil
            }
            // Under a new name even where it is a kept copy already: the
            // deleted path is gone everywhere, and a file left at it would
            // be deleted again or argue with the deletion.
            let copyName = LampWritingWorkspaceLayout.keptCopyName(
                of: document.name, device: localDevice, at: date,
                taken: { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
            )
            let copy = try self.url(folder: document.folder, name: copyName)
            try Self.locks.holding(copy) {
                try FileManager.default.moveItem(at: url, to: copy)
            }
            return copyName
        }
    }

    private func remove(at url: URL) throws {
        try Self.locks.holding(url) {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Takes in a copy a pass downloaded, as `LampWritingDocumentMerge`
    /// decides, and says what it did. `agreedDigest` is the pass's record
    /// of what this device last sent or took at the path, nil for none: a
    /// copy held otherwise than that was edited here, and is kept. Judged
    /// under the file's lock, so a save that lands after the pass planned
    /// is kept too. A kept copy is written before the document is replaced,
    /// so a stop between the two leaves both bodies.
    @discardableResult
    public func takeIn(
        downloaded data: Data, path: String, agreedDigest: String?, localDevice: String, at date: Date = Date()
    ) throws -> LampWritingDocumentMerge.Decision {
        guard let document = LampWritingWorkspaceLayout.document(ofPath: path) else {
            throw LampSyncFolderLayout.PathError.unsafe(path)
        }
        let url = try url(folder: document.folder, name: document.name)
        let folder = url.deletingLastPathComponent()
        return try Self.locks.holding(url) {
            let held = try Self.contents(of: url)
            let decision = LampWritingDocumentMerge.decide(
                name: document.name, held: held, incoming: data,
                agreedDigest: agreedDigest, localDevice: localDevice, at: date,
                taken: { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
            )
            switch decision {
            case .keep:
                break
            case .take:
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            case .takeKeepingHeldAs(let copyName):
                let copy = try self.url(folder: document.folder, name: copyName)
                try Self.locks.holding(copy) {
                    // Never over a file already there: the name was free
                    // when it was chosen, and a file that took it since is
                    // someone else's. (Not atomic: the two cannot be asked
                    // for together.)
                    try (held ?? Data()).write(to: copy, options: .withoutOverwriting)
                }
                try data.write(to: url, options: .atomic)
            }
            return decision
        }
    }

    /// The deletions a pass records for the documents of writings deleted,
    /// by path; the files here are removed as they are found. A writing's
    /// documents go with it everywhere, as its review marks do
    /// (`LampWritingReviewStore.deletions`), and only where there is a file
    /// to delete, here or on the server.
    ///
    /// `deleted` is the writings whose deletion stands
    /// (`LampWritingReviewStore.deletedWritings(in:)`), `held` the writings
    /// this device still has, which win over a deletion of the same id,
    /// compared folded; `members` the paths the manifest names, each with
    /// the latest time a device wrote it; `now` the time to record, in
    /// milliseconds. Each folder is named from the deleted id as it is
    /// spelled, as every app names it.
    public func deletions(
        deleted: Set<String>, held: Set<String>, members: [String: Int64], now: Int64
    ) throws -> [String: Int64] {
        let heldFolded = Set(held.map { $0.lowercased() })
        var result: [String: Int64] = [:]
        for id in deleted where Self.swept(deleted: true, held: heldFolded.contains(id.lowercased())) {
            let folder = LampWritingWorkspaceLayout.directoryName(for: id)
            for document in try documents(writingID: id) {
                let path = try LampWritingWorkspaceLayout.documentPath(folder: folder, name: document.name)
                try remove(at: url(folder: folder, name: document.name))
                result[path] = Self.deletionTime(of: path, members: members, now: now)
            }
            for path in members.keys where LampWritingWorkspaceLayout.document(ofPath: path)?.folder == folder {
                result[path] = Self.deletionTime(of: path, members: members, now: now)
            }
        }
        return result
    }

    /// Whether a writing's documents are swept: deleted, and held by no
    /// writing here. (`Verification/SyncMerge.lean`: `documentSwept`.)
    static func swept(deleted: Bool, held: Bool) -> Bool {
        deleted && !held
    }

    /// When to record a document's deletion, in milliseconds: now, but never
    /// before the write the manifest holds for it (`members`, the latest
    /// time a device wrote each path). A device whose clock runs behind
    /// would otherwise date its deletion before the save it removes, and
    /// the save would win and bring the document back.
    /// (`Verification/SyncMerge.lean`: `documentDeletionStamp`.)
    public static func deletionTime(of path: String, members: [String: Int64], now: Int64) -> Int64 {
        members[path].map { max(now, $0 + 1) } ?? now
    }

    /// The file's bytes, nil where there is no file. A file that is there
    /// and cannot be read is an error, never nil: read as absent, a write
    /// would replace a document the writer still has.
    private static func contents(of url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private static let locks = FileLocks()
}
