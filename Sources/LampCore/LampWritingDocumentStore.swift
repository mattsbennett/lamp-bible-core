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
    @discardableResult
    public func write(_ data: Data, writingID: String, name: String, replacing expected: Data?) throws -> Bool {
        let url = try url(writingID: writingID, name: name)
        return try Self.locks.holding(url) {
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

    /// Removes the document at a server path, as a pass carries out a
    /// deletion made on another device.
    public func remove(path: String) throws {
        guard let document = LampWritingWorkspaceLayout.document(ofPath: path) else {
            throw LampSyncFolderLayout.PathError.unsafe(path)
        }
        try remove(at: url(folder: document.folder, name: document.name))
    }

    private func remove(at url: URL) throws {
        try Self.locks.holding(url) {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Takes in a copy a pass downloaded, as `LampWritingDocumentMerge`
    /// decides, and says what it did. `bothChanged` is the plan's: this
    /// device's copy changed since it last agreed with the server, and so
    /// did the server's. A kept copy is written before the document is
    /// replaced, so a stop between the two leaves both bodies.
    @discardableResult
    public func takeIn(
        downloaded data: Data, path: String, bothChanged: Bool, localDevice: String, at date: Date = Date()
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
                bothChanged: bothChanged, localDevice: localDevice, at: date,
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

    /// When to record a document's deletion, in milliseconds: now, but never
    /// before the write the manifest holds for it (`members`, the latest
    /// time a device wrote each path). A device whose clock runs behind
    /// would otherwise date its deletion before the save it removes, and
    /// the save would win and bring the document back.
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
