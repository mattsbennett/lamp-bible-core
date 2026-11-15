import Foundation
import SQLite3

/// Moves a library from bundle format 3 to format 4, where writing is renamed
/// in the per-file layout: `Devotionals/` to `Writing/`, `DevotionalMedia/`
/// to `WritingMedia/`, and the writing collection from
/// `Devotionals/devotionals.lamp` to `Writing/writing.lamp`
/// (`LampSyncFolderLayout.formatFourPath(ofFormatThree:)`).
///
/// Any format-4 client does it, the first time it reads a format-3 bundle;
/// `LampSyncSettingsStore.read` calls it, so nothing else has to know. It
/// copies every member it renames to its new path, the collection with its
/// module ID rewritten inside, then writes the bundle as format 4 with its
/// manifest at the new paths, under the revision it read. The copies are
/// written only where absent, so a second device moving at the same time,
/// or this one after a pass that died, finds them there and goes on; only
/// one bundle write can win.
///
/// Nothing old is deleted. A format-3 client finds format 4 newer and stops
/// rather than writing to paths nobody reads, so its edits wait on the device
/// until it is updated, and its next pass publishes them by value.
///
/// A file only another format-3 device had, uploaded after the copy and
/// before the bundle write, is left at its old path: the device that wrote it
/// still holds it, and publishes it once updated. So does media a member names
/// that no device ever copied, which the move never lists.
public enum LampSyncFormatFourMove {
    public enum MoveError: Error, Equatable, LocalizedError {
        /// An installed writing module whose ID is `writing` and the writing
        /// collection would both be `Writing/writing.lamp`.
        case collision([String])
        /// The collection's module ID could not be rewritten.
        case unreadableCollection(String)

        public var errorDescription: String? {
            switch self {
            case .collision(let paths):
                "This library holds a writing module whose ID is “writing”, which the writing collection is now called, so the library could not be moved to the new layout. Remove that module on a device still on the older version of Lamp Bible, then sync. Nothing was changed. (\(paths.joined(separator: ", ")))"
            case .unreadableCollection(let path):
                "The writing collection at \(path) could not be read to move it to the new layout. Nothing was changed."
            }
        }
    }

    /// The format-4 bundle for `formatThree`, whose files have been copied:
    /// its manifest at the new paths, recording each copy at the revision
    /// the copy was written at.
    static func bundle(
        _ formatThree: LampSyncSettingsBundle, copied: [String: String]
    ) -> LampSyncSettingsBundle {
        var moved = formatThree
        moved.manifest = formatThree.manifest.formatFour(copied: copied)
        return moved
    }

    /// Copies what `manifest` holds that the move renames, and any module the
    /// format-3 writing folder holds that no manifest names yet, which a pass
    /// adopts from a listing. Returns each member copied, by its old path,
    /// with the revision of its copy where the server gave one.
    ///
    /// Throws `collision` before copying anything if two paths would land on
    /// one.
    static func copy(
        _ manifest: LampSyncLibraryManifest,
        in store: any LampSyncRemoteStore,
        patience: LampSyncConditionalWrite.Patience
    ) async throws -> [String: String] {
        try await copy(
            members: manifest.members.map(\.path), known: manifest.paths, in: store, patience: patience
        )
    }

    /// Copies `members`, format-3 paths, to their format-4 paths, with any
    /// module the format-3 writing folder holds that `known` doesn't name.
    /// Throws `collision`, copying nothing, if two of them, or of `known`,
    /// would land on one path. The Mac's move from an archive calls this
    /// with the per-file files it found in place, which it leaves to the
    /// next pass to adopt: that pass lists format 4's folders, not 3's.
    public static func copy(
        members: some Sequence<String>,
        known: Set<String> = [],
        in store: any LampSyncRemoteStore,
        patience: LampSyncConditionalWrite.Patience = .standard
    ) async throws -> [String: String] {
        let members = Set(members)
        let folder = LampSyncFolderLayout.FormatThree.writingFolder
        let listed = (try await store.list(directory: folder + "/") ?? [])
            .filter { !$0.isDirectory && !$0.name.hasPrefix(".") }
            .map { "\(folder)/\($0.name)" }
        let collision = LampSyncFolderLayout.formatFourCollision(in: known.union(members).union(listed))
        guard collision.isEmpty else { throw MoveError.collision(collision) }

        var toCopy = members
        toCopy.formUnion(listed.filter { !known.contains($0) })
        var copied: [String: String] = [:]
        for path in toCopy.sorted() {
            guard let target = LampSyncFolderLayout.formatFourPath(ofFormatThree: path), target != path
            else { continue }
            if let revision = try await copy(path, to: target, in: store, patience: patience) {
                copied[path] = revision
            }
        }
        return copied
    }

    /// One file, to its new path where nothing is there yet. Returns the
    /// revision of what is at the new path afterwards, the copy or the one
    /// already there; nil when the old path holds nothing, or when the server
    /// took the copy without showing it back yet.
    private static func copy(
        _ path: String, to target: String,
        in store: any LampSyncRemoteStore,
        patience: LampSyncConditionalWrite.Patience
    ) async throws -> String? {
        // Already there: an earlier attempt, or another device moving too.
        if let existing = try await store.revision(path: target) { return existing }
        return try await LampSyncScratchFile.with { scratch -> String? in
            guard try await store.read(path: path, into: scratch) != nil else { return nil }
            let isMedia = LampSyncFolderLayout.kind(of: target)?.isMedia ?? false
            if path == formatThreeCollectionPath {
                try renameCollection(at: scratch, path: path)
            }
            switch try await LampSyncConditionalWrite.write(
                fileAt: scratch, to: target, in: store, condition: .ifAbsent,
                patience: patience, confirm: isMedia ? .revision : .reading
            ) {
            case .written(let revision): return revision
            case .writtenUnconfirmed: return nil
            case .refused: return try await store.revision(path: target)
            }
        }
    }

    static let formatThreeCollectionPath =
        "\(LampSyncFolderLayout.FormatThree.writingFolder)/\(LampSyncFolderLayout.FormatThree.writingCollectionID).\(LampSyncFolderLayout.moduleExtension)"

    /// Rewrites the collection at `url` in place to say it is
    /// `LampSyncLocalDeletion.writingCollectionID`, wherever a writing
    /// collection names its module: `module_format`, `module_meta` and each
    /// entry. Nothing else in it changes. A client checks that a module's
    /// file name and the ID inside agree, so the copy must say what its new
    /// name says.
    static func renameCollection(at url: URL, path: String) throws {
        guard let compressed = try? Data(contentsOf: url),
              let database = try? (compressed as NSData).decompressed(using: .zlib) as Data
        else { throw MoveError.unreadableCollection(path) }
        let sqliteURL = url.appendingPathExtension("sqlite")
        try database.write(to: sqliteURL, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: sqliteURL)
            try? FileManager.default.removeItem(atPath: sqliteURL.path + "-journal")
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(sqliteURL.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let handle else {
            if handle != nil { sqlite3_close(handle) }
            throw MoveError.unreadableCollection(path)
        }
        let id = LampSyncLocalDeletion.writingCollectionID
        let statements = [
            "UPDATE module_format SET module_id = ?1",
            "UPDATE module_meta SET id = ?1",
            "UPDATE devotional_entries SET module_id = ?1",
        ]
        var ok = sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK
        for sql in statements where ok {
            var statement: OpaquePointer?
            ok = sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK
                && sqlite3_bind_text(statement, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK
                && sqlite3_step(statement) == SQLITE_DONE
            sqlite3_finalize(statement)
        }
        ok = ok && sqlite3_exec(handle, "COMMIT", nil, nil, nil) == SQLITE_OK
        if !ok { sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) }
        sqlite3_close(handle)
        guard ok,
              let rewritten = try? Data(contentsOf: sqliteURL),
              let recompressed = try? (rewritten as NSData).compressed(using: .zlib) as Data
        else { throw MoveError.unreadableCollection(path) }
        try recompressed.write(to: url, options: .atomic)
    }
}
