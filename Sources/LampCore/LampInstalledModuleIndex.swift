import Foundation
import LampModuleKit

/// What a library learned about each installed module's file, kept so that the
/// next launch inspects only what has changed.
///
/// Inspecting a module means opening its database and reading its metadata —
/// roughly 200 ms for one of a few hundred megabytes, by the measurement in
/// `openReadOnlyDatabase` — and a library of several hundred modules paid that
/// for every one of them on every launch, because the answer was kept in
/// memory only. See `Documentation/decisions/0005`.
///
/// A cache of an answer about a file, never a record of what the library
/// holds: the files are that record. So an entry is used only while the file's
/// `LampDatabaseFileRevision` and `.lamp` byte count both match what was
/// recorded, an entry for a file that is gone is dropped, and the whole thing
/// is safe to delete — deleting it costs one launch's inspections.
struct InstalledModuleIndex: Codable {
    struct Entry: Codable {
        let revision: LampDatabaseFileRevision
        let byteCount: Int
        let module: Module
    }

    /// `LampInstalledModule`'s fields, written down.
    ///
    /// Not `Codable` on the model itself: that type is the library's answer to
    /// its callers, and giving it a wire format invites it to be stored and
    /// sent, at which point adding a field becomes a compatibility question.
    /// Here the shape is private to this cache, and an index that cannot be
    /// decoded is simply absent.
    struct Module: Codable {
        let id: String
        let kind: LampModuleKind
        let name: String
        let abbreviation: String?
        let language: String?
        let compressedByteCount: Int
        let isBundled: Bool
        let tagsStrongs: Bool
        let coveredBooks: [Int: Int]

        init(_ module: LampInstalledModule) {
            id = module.id
            kind = module.kind
            name = module.name
            abbreviation = module.abbreviation
            language = module.language
            compressedByteCount = module.compressedByteCount
            isBundled = module.isBundled
            tagsStrongs = module.tagsStrongs
            coveredBooks = module.coveredBooks
        }

        var module: LampInstalledModule {
            LampInstalledModule(
                id: id,
                kind: kind,
                name: name,
                abbreviation: abbreviation,
                language: language,
                compressedByteCount: compressedByteCount,
                isBundled: isBundled,
                tagsStrongs: tagsStrongs,
                coveredBooks: coveredBooks
            )
        }
    }

    /// Keyed by the database file's path.
    var entries: [String: Entry] = [:]

    init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    init(_ metadata: [String: (revision: LampDatabaseFileRevision, byteCount: Int, module: LampInstalledModule)]) {
        entries = metadata.mapValues {
            Entry(revision: $0.revision, byteCount: $0.byteCount, module: Module($0.module))
        }
    }

    /// The index at this path, or an empty one. An index that cannot be read
    /// or decoded is absent, not an error: the library inspects the modules
    /// instead, which is what it did before this existed.
    static func read(at url: URL) -> InstalledModuleIndex {
        guard let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode(InstalledModuleIndex.self, from: data)
        else { return InstalledModuleIndex() }
        return index
    }

    /// Writes the index, and says nothing if it cannot.
    ///
    /// Atomically, and failure is ignored on purpose: two processes open the
    /// same library — the app and each `lamp-mcp` — and the loser of a race
    /// has written a cache nobody needed. A library on a read-only volume
    /// simply has no index.
    func write(to url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
