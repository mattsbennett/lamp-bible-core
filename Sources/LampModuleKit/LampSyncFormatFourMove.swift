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
        /// A module whose ID is `writing` and the writing collection are both
        /// there: the collection's new name is taken.
        case collision([String])
        /// The collection's module ID could not be rewritten.
        case unreadableCollection(String)

        public var errorDescription: String? {
            switch self {
            case .collision(let paths):
                "This library holds a module whose ID is “writing”, which the writing collection is now called, so the library could not be moved to the new layout. Remove that module on a device still on the older version of Lamp Bible and let it sync, then sync here. Nothing was changed. (\(paths.joined(separator: ", ")))"
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

    /// Copies what `manifest` holds that the move renames, with any file at
    /// format 3's writing paths no manifest names yet or that was put back
    /// after a deletion (`files(in:beside:)`). Returns each file copied, by
    /// its old path, with the revision of its copy where the server gave one.
    ///
    /// Throws `collision` before copying anything if two of them would land
    /// on one path.
    static func copy(
        _ manifest: LampSyncLibraryManifest,
        in store: any LampSyncRemoteStore,
        patience: LampSyncConditionalWrite.Patience
    ) async throws -> [String: String] {
        try await copy(members: manifest.members.map(\.path), manifest: manifest, in: store, patience: patience)
    }

    /// Copies `members`, format-3 paths, to their format-4 paths, with the
    /// files at format 3's writing paths that `manifest` does not account for
    /// (`files(in:beside:)`). Throws `collision`, copying nothing, if two of
    /// them would land on one path, or if one is a module called `writing`
    /// and the collection is there too. The Mac's move from an archive calls
    /// this with the per-file files it found in place, and the phone's move
    /// from its own layout with none, so both carry the old folders' files to
    /// where the next pass lists.
    public static func copy(
        members: some Sequence<String>,
        manifest: LampSyncLibraryManifest = .init(),
        in store: any LampSyncRemoteStore,
        patience: LampSyncConditionalWrite.Patience = .standard
    ) async throws -> [String: String] {
        let found = try await files(in: store, beside: manifest)
        let toCopy = Set(members).union(found)
        let memberPaths = Set(manifest.members.map(\.path))
        let collision = LampSyncFolderLayout.formatFourCollision(in: toCopy.union(memberPaths))
        guard collision.isEmpty else { throw MoveError.collision(collision) }

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

    /// The files at format 3's writing paths that `manifest` does not account
    /// for: a module or a writing's media no entry names, which a pass would
    /// have adopted, and one put back after a deletion, which it would have
    /// adopted too (`adoptFile`). Media is never listed by a pass, so its
    /// folder is walked here, its three levels: module, writing, file.
    static func files(
        in store: any LampSyncRemoteStore, beside manifest: LampSyncLibraryManifest
    ) async throws -> [String] {
        func visible(_ entries: [LampSyncRemoteEntry]?) -> [LampSyncRemoteEntry] {
            (entries ?? []).filter { !$0.name.hasPrefix(".") }
        }
        var found: [(path: String, revision: String?)] = []
        let folder = LampSyncFolderLayout.FormatThree.writingFolder
        for entry in visible(try await store.list(directory: folder + "/")) where !entry.isDirectory {
            found.append(("\(folder)/\(entry.name)", entry.revision))
        }
        let media = LampSyncFolderLayout.FormatThree.writingMediaDirectory
        for module in visible(try await store.list(directory: media + "/")) where module.isDirectory {
            let modulePath = "\(media)/\(module.name)"
            for writing in visible(try await store.list(directory: modulePath + "/")) where writing.isDirectory {
                let writingPath = "\(modulePath)/\(writing.name)"
                for file in visible(try await store.list(directory: writingPath + "/")) where !file.isDirectory {
                    found.append(("\(writingPath)/\(file.name)", file.revision))
                }
            }
        }
        return found.compactMap { path, revision in
            guard LampSyncFolderLayout.formatFourPath(ofFormatThree: path) != nil else { return nil }
            guard let entry = manifest.entry(at: path) else { return path }
            if entry.isMember { return path }
            // A tombstone: the copy it deleted is waiting to be reaped, and
            // any other was put back after it.
            guard let revision, !entry.deletes(revision: revision) else { return nil }
            return path
        }
    }

    /// One file, to its new path. What the new path should hold is the old
    /// file, the collection with its ID rewritten; a copy already there that
    /// holds it is kept, and one that doesn't is written over. It can be an
    /// earlier attempt's, made before a format-3 device wrote the old path
    /// again, and the move must carry what the old path holds now. Returns
    /// the revision at the new path afterwards; nil when the old path holds
    /// nothing, or the server took the copy without showing it back yet.
    /// (`Verification/SyncMerge.lean`: `formatFourCopy`.)
    private static func copy(
        _ path: String, to target: String,
        in store: any LampSyncRemoteStore,
        patience: LampSyncConditionalWrite.Patience
    ) async throws -> String? {
        try await LampSyncScratchFile.with { scratch -> String? in
            guard try await store.read(path: path, into: scratch) != nil else { return nil }
            if target == formatFourCollectionPath {
                try renameCollection(at: scratch, path: path)
            }
            let expected = try LampSyncContentRevision.digest(forFileAt: scratch)
            let isMedia = LampSyncFolderLayout.kind(of: target)?.isMedia ?? false
            for _ in 0..<2 {
                let existing = try await LampSyncScratchFile.with { other -> (String, String)? in
                    guard let there = try await store.read(path: target, into: other),
                          let revision = there.revision else { return nil }
                    return (revision, try LampSyncContentRevision.digest(forFileAt: other))
                }
                let step = formatFourCopy(present: existing != nil, same: existing?.1 == expected)
                if step == .keep, let existing { return existing.0 }
                let condition: LampSyncWriteCondition = existing.map { .ifRevision($0.0) } ?? .ifAbsent
                switch try await LampSyncConditionalWrite.write(
                    fileAt: scratch, to: target, in: store, condition: condition,
                    patience: patience, confirm: isMedia ? .revision : .reading
                ) {
                case .written(let revision): return revision
                case .writtenUnconfirmed: return nil
                // Another device moving too wrote first: look again.
                case .refused: continue
                }
            }
            return try await store.revision(path: target)
        }
    }

    enum FormatFourCopy: Equatable {
        case write, keep, replace
    }

    /// What the move does at a file's new path: write where nothing is, keep
    /// what is there when it is what the move would write, and replace it
    /// otherwise. (`Verification/SyncMerge.lean`: `formatFourCopy`.)
    static func formatFourCopy(present: Bool, same: Bool) -> FormatFourCopy {
        guard present else { return .write }
        return same ? .keep : .replace
    }

    /// Members at format 4's writing paths with no revision, whose file is
    /// not at the new path and is at the old one: a member the move found no
    /// file for, which reached its old path later, as iCloud can deliver a
    /// bundle before the files it names. Copied there now, so a pass finds
    /// it. Asked of every format-4 bundle read, at one HEAD for each such
    /// member, which a library holds none of once its files have arrived.
    static func copyLateArrivals(
        _ manifest: LampSyncLibraryManifest,
        in store: any LampSyncRemoteStore,
        patience: LampSyncConditionalWrite.Patience
    ) async throws {
        for entry in manifest.members where entry.revision == nil {
            guard let old = LampSyncFolderLayout.formatThreePath(ofFormatFour: entry.path),
                  old != entry.path,
                  try await store.revision(path: entry.path) == nil,
                  try await store.revision(path: old) != nil
            else { continue }
            _ = try await copy(old, to: entry.path, in: store, patience: patience)
        }
    }

    static let formatFourCollectionPath =
        "\(LampSyncContentKind.devotionals.folder)/\(LampSyncLocalDeletion.writingCollectionID).\(LampSyncFolderLayout.moduleExtension)"

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
