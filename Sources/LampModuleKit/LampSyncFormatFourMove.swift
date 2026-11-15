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
/// manifest at the new paths, under the revision it read.
///
/// It writes over a file at a new path only when it can tell the file is a
/// copy of what the old path no longer holds: one this same move made before
/// a format-3 device wrote the old path again, or one a move cut short left,
/// while the format-3 bundle this move read still stands, so no device can
/// have published there yet (`formatFourCopy`). Anything else is kept: once
/// the bundle has moved, or beside iCloud versions of it, a file at a new path
/// may be a format-4 device's, newer than any copy.
///
/// Nothing old is deleted. A format-3 client finds format 4 newer and stops
/// rather than writing to paths nobody reads, so its edits wait on the device
/// until it is updated, and its next pass publishes them by value. A member
/// whose file was not there yet is copied when it arrives
/// (`lateArrivals(in:in:patience:)`).
public enum LampSyncFormatFourMove {
    public enum MoveError: Error, Equatable, LocalizedError {
        /// The collection's module ID could not be rewritten.
        case unreadableCollection(String)

        public var errorDescription: String? {
            switch self {
            case .unreadableCollection(let path):
                "The writing collection at \(path) could not be read to move it to the new layout. Nothing was changed."
            }
        }
    }

    /// What one move has written, by new path, at the revision it wrote,
    /// which it may write over. Kept across the attempts of one
    /// `LampSyncSettingsStore.read`, and no longer.
    ///
    /// `asRead` is the revision of the format-3 bundle this attempt read, on
    /// a server with one view of all its files, WebDAV's. While the bundle is
    /// still there at that revision, no device has moved the library, and
    /// none has published to format 4's paths, so anything at one is a copy
    /// a move left, one cut short before it wrote the bundle, and it may be
    /// written over with what the old path holds now. Nil where that cannot
    /// be known: beside iCloud versions of the bundle, and in any folder iCloud
    /// fills file by file, which can hold another device's newer copy at a
    /// new path before the bundle that moved the library reaches it.
    final class Copies: @unchecked Sendable {
        var written: [String: String] = [:]
        var asRead: String?
        init() {}
    }

    /// What the move found to carry: each file's old path, with the revision
    /// of its copy where the server gave one, and the files put back after a
    /// deletion, which the manifest adopts.
    struct Carried: Equatable {
        var copied: [String: String] = [:]
        var putBack: Set<String> = []
    }

    /// The format-4 bundle for `formatThree`, whose files have been copied:
    /// its manifest at the new paths, recording each copy at the revision the
    /// copy was written at, and adopting each copy put back after a deletion.
    static func bundle(
        _ formatThree: LampSyncSettingsBundle, carried: Carried = .init(), at now: Int64 = currentTime()
    ) -> LampSyncSettingsBundle {
        var moved = formatThree
        moved.manifest = formatThree.manifest.formatFour(copied: carried.copied, putBack: carried.putBack, at: now)
        return moved
    }

    static func currentTime() -> Int64 { Int64((Date().timeIntervalSince1970 * 1_000).rounded()) }

    /// Copies what `manifest` holds that the move renames, with every file at
    /// format 3's writing paths it does not account for (`files(in:beside:)`).
    static func copy(
        _ manifest: LampSyncLibraryManifest,
        in store: any LampSyncRemoteStore,
        copies: Copies,
        patience: LampSyncConditionalWrite.Patience
    ) async throws -> Carried {
        try await copy(
            members: manifest.members.map(\.path), manifest: manifest, in: store, copies: copies, patience: patience
        )
    }

    /// Copies `members`, format-3 paths, to their format-4 paths, with the
    /// files at format 3's writing paths that `manifest` does not account for.
    /// The Mac's move from an archive calls this with the per-file files it
    /// found in place, and the phone's move from its own layout with none, so
    /// both carry the old folders' files to where the next pass lists.
    public static func copy(
        members: some Sequence<String>,
        manifest: LampSyncLibraryManifest = .init(),
        in store: any LampSyncRemoteStore,
        patience: LampSyncConditionalWrite.Patience = .standard
    ) async throws -> [String: String] {
        try await copy(members: members, manifest: manifest, in: store, copies: Copies(), patience: patience).copied
    }

    static func copy(
        members: some Sequence<String>,
        manifest: LampSyncLibraryManifest,
        in store: any LampSyncRemoteStore,
        copies: Copies,
        patience: LampSyncConditionalWrite.Patience
    ) async throws -> Carried {
        let found = try await files(in: store, beside: manifest)
        var carried = Carried(putBack: found.putBack)
        for path in Set(members).union(found.unaccounted).union(found.putBack).sorted() {
            guard let target = LampSyncFolderLayout.formatFourPath(ofFormatThree: path), target != path
            else { continue }
            if let revision = try await copy(path, to: target, in: store, copies: copies, patience: patience) {
                carried.copied[path] = revision
            }
        }
        // A copy put back that could not be copied stays deleted.
        carried.putBack = carried.putBack.filter { carried.copied[$0] != nil }
        return carried
    }

    /// The files at format 3's writing paths that `manifest` does not account
    /// for: a module or a writing's media no entry names, which a pass would
    /// have adopted, and a copy put back after a deletion, which it would have
    /// adopted too (`adoptFile`). Media is never listed by a pass, so its
    /// folder is walked here, its three levels: module, writing, file. A file
    /// the move does not carry, such as a module called `writing`, is left out.
    static func files(
        in store: any LampSyncRemoteStore, beside manifest: LampSyncLibraryManifest
    ) async throws -> (unaccounted: [String], putBack: Set<String>) {
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
        var unaccounted: [String] = []
        var putBack: Set<String> = []
        for (path, listed) in found where LampSyncFolderLayout.formatFourPath(ofFormatThree: path) != nil {
            guard let entry = manifest.entry(at: path) else { unaccounted.append(path); continue }
            guard !entry.isMember else { continue }
            // A tombstone: the copy it deleted is waiting to be reaped, and
            // any other was put back after it. A folder lists no revisions,
            // so one is asked for.
            let revision: String? = if let listed { listed } else { try await store.revision(path: path) }
            if let revision, !entry.deletes(revision: revision) { putBack.insert(path) }
        }
        return (unaccounted, putBack)
    }

    /// One file, to its new path: the old file, or the collection with its
    /// ID rewritten. Where nothing is, it is written. What is there is kept
    /// when it holds the same, and when another device may have published
    /// it; a copy this move wrote, from what the old path held before, is
    /// replaced, and so is one a move left while the bundle is still the
    /// format-3 one this move read (`Copies.asRead`).
    /// Returns the revision at the new path afterwards: nil when the old path
    /// holds nothing, or the server took the copy without showing it back.
    /// (`Verification/SyncMerge.lean`: `formatFourCopy`.)
    private static func copy(
        _ path: String, to target: String,
        in store: any LampSyncRemoteStore,
        copies: Copies,
        patience: LampSyncConditionalWrite.Patience
    ) async throws -> String? {
        try await LampSyncScratchFile.with { scratch -> String? in
            guard try await store.read(path: path, into: scratch) != nil else { return nil }
            if target == formatFourCollectionPath {
                try renameCollection(at: scratch, path: path)
            }
            let expected = try LampSyncContentRevision.digest(forFileAt: scratch)
            let isMedia = LampSyncFolderLayout.kind(of: target)?.isMedia ?? false
            // A refusal means another device wrote first, which the next
            // look finds and keeps; a server that refuses and still shows
            // nothing is given up on after a few, the copy left unrecorded.
            for _ in 0..<3 {
                let existing = try await LampSyncScratchFile.with { other -> (revision: String?, digest: String)? in
                    guard let there = try await store.read(path: target, into: other) else { return nil }
                    return (there.revision, try LampSyncContentRevision.digest(forFileAt: other))
                }
                let ours = existing.flatMap(\.revision).map {
                    LampSyncConditionalWrite.namesSameRevision(copies.written[target], $0)
                } ?? false
                let same = existing?.digest == expected
                // Asked only where it decides anything.
                var stillAsRead = false
                if existing != nil, !same, !ours, let asRead = copies.asRead {
                    stillAsRead = LampSyncConditionalWrite.namesSameRevision(
                        try await store.revision(path: LampSyncSettingsStore.path), asRead
                    )
                }
                switch formatFourCopy(present: existing != nil, same: same, ours: ours, stillAsRead: stillAsRead) {
                case .keep:
                    return existing?.revision
                case .write, .replace:
                    let condition: LampSyncWriteCondition = existing?.revision.map { .ifRevision($0) } ?? .ifAbsent
                    switch try await LampSyncConditionalWrite.write(
                        fileAt: scratch, to: target, in: store, condition: condition,
                        patience: patience, confirm: isMedia ? .revision : .reading
                    ) {
                    case .written(let revision):
                        copies.written[target] = revision
                        return revision
                    case .writtenUnconfirmed:
                        return nil
                    case .refused:
                        copies.written[target] = nil
                        continue
                    }
                }
            }
            return nil
        }
    }

    enum FormatFourCopy: Equatable {
        case write, keep, replace
    }

    /// What the move does at a file's new path: write where nothing is; keep
    /// what is there when it holds the same; replace it when this move wrote
    /// it, or while the format-3 bundle this move read still stands; keep it
    /// otherwise, since another device may have published it.
    /// (`Verification/SyncMerge.lean`: `formatFourCopy`.)
    static func formatFourCopy(present: Bool, same: Bool, ours: Bool, stillAsRead: Bool) -> FormatFourCopy {
        guard present else { return .write }
        return same || !(ours || stillAsRead) ? .keep : .replace
    }

    /// Members at format 4's writing paths with no revision: a member the move
    /// found no file for, as iCloud can deliver a bundle before the files it
    /// names. Each is copied once its file reaches the old path, and one whose
    /// file is at the new path, copied by an earlier read or published since,
    /// is recorded at the revision there. Returns those revisions by new
    /// path, for the bundle to record, after which no read asks again. One
    /// listing of each folder such a member is in.
    static func lateArrivals(
        in manifest: LampSyncLibraryManifest,
        in store: any LampSyncRemoteStore,
        patience: LampSyncConditionalWrite.Patience
    ) async throws -> [String: String] {
        let waiting = manifest.members.filter { entry in
            guard entry.revision == nil,
                  let old = LampSyncFolderLayout.formatThreePath(ofFormatFour: entry.path)
            else { return false }
            return old != entry.path
        }
        guard !waiting.isEmpty else { return [:] }
        var listings: [String: [String: String?]] = [:]
        func files(in folder: String) async throws -> [String: String?] {
            if let known = listings[folder] { return known }
            var files: [String: String?] = [:]
            for entry in try await store.list(directory: folder + "/") ?? [] where !entry.isDirectory {
                files[entry.name] = entry.revision
            }
            listings[folder] = files
            return files
        }
        func split(_ path: String) -> (folder: String, name: String) {
            let slash = path.lastIndex(of: "/")!
            return (String(path[..<slash]), String(path[path.index(after: slash)...]))
        }
        var recovered: [String: String] = [:]
        for entry in waiting {
            let (folder, name) = split(entry.path)
            if let listed = try await files(in: folder)[name] {
                // There already. A folder lists no revisions, so one is asked
                // for, once: recorded, it is not asked again.
                let revision: String? = if let listed { listed } else { try await store.revision(path: entry.path) }
                if let revision { recovered[entry.path] = revision }
                continue
            }
            guard let expected = LampSyncFolderLayout.formatThreePath(ofFormatFour: entry.path) else { continue }
            // The old file by what it moves to, so `devotionals.LAMP` is
            // found as surely as `devotionals.lamp`.
            let (oldFolder, _) = split(expected)
            guard let source = try await files(in: oldFolder).keys
                .map({ "\(oldFolder)/\($0)" })
                .first(where: { LampSyncFolderLayout.formatFourPath(ofFormatThree: $0) == entry.path })
            else { continue }
            if let revision = try await copy(source, to: entry.path, in: store, copies: Copies(), patience: patience) {
                recovered[entry.path] = revision
            }
        }
        return recovered
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
