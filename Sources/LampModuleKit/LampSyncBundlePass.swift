import Foundation

/// What a pass needs the library to do. Everything about content lives behind
/// this, so the pass itself only orders the work and keeps the records.
public protocol LampSyncPassLibrary {
    /// Installs a file taken from the server, whose body is already on disk.
    ///
    /// Returns this client's own digest of what it now holds at that path, or
    /// nil when that is simply the bytes it was given.
    ///
    /// The distinction decides whether two devices settle or argue. A
    /// read-only module is stored as it arrived, so the downloaded digest is
    /// the truth about it. An editable collection is merged into the library
    /// and re-exported, and the two clients encode identically-valued content
    /// differently — so recording the *downloaded* digest means the next pass
    /// finds its own export unlike it, calls the file changed, and publishes.
    /// The other device does the same with what it receives, and the two
    /// trade encodings of the same content for ever.
    func install(_ path: String, from url: URL) async throws -> String?

    /// Reconciles the files both sides changed, having downloaded each.
    ///
    /// One call for the whole group, because the Mac merges personal content
    /// in a single staged transaction rather than file by file. Returns the
    /// file to publish for each path — the merge rewrites local content, so
    /// what to upload is what the transaction produced, not what the pass
    /// digested before it.
    func reconcile(_ downloaded: [String: URL]) async throws -> [String: URL]

    /// Removes the local copy of a file deleted elsewhere.
    func deleteLocally(_ path: String) async throws

    /// Called once after every download and merge, before anything is
    /// published.
    ///
    /// Most files are complete on their own. A workspace is not: its
    /// documents, context, skills and conversations are a tree with one
    /// importer, so they are staged as they arrive and taken in here
    /// together. Nothing to do for a library that met none.
    func finishInstalling() async throws
}

public extension LampSyncPassLibrary {
    func finishInstalling() async throws {}
}

/// One Design B pass: read the bundle, work out what moved, move it, and
/// record what happened in a single bundle update.
///
/// The order is the whole substance of this, and each step of it is a rule
/// somewhere else:
///
/// 1. `readOrClaim` rather than `read`. A pass that found nothing and wrote
///    its files first would be told `notMigrated` by its own closing update,
///    on every pass, because its own files are what make the library look
///    like an earlier one.
/// 2. Downloads and merges before uploads, so what this client publishes
///    already contains what the other side changed.
/// 3. One bundle update, carrying every write, tombstone and adoption the
///    pass made. Not one per file: the bundle is a single small object every
///    device contends for, and its read-merge-retry is bounded.
/// 4. Reaps only after that update. A file deleted from the server before the
///    bundle tombstones it reads to every other device as a member that was
///    never uploaded.
///
/// A pass that dies between its files and its update leaves written-but-
/// unrecorded revisions in `LampSyncFileRecords`, and the next pass records
/// them. That is safe only because a file and the manifest disagreeing means
/// "changed, compare by value" and never a conflict — the invariant the
/// model holds as `anUnknownFileIsAdopted`.
///
/// Not `Sendable`: it holds a store, and a pass runs where its caller is —
/// on the Mac, the main actor.
public struct LampSyncBundlePass {
    public struct Outcome {
        public var installed: [String] = []
        public var reconciled: [String] = []
        public var uploaded: [String] = []
        public var deletedLocally: [String] = []
        public var tombstoned: [String] = []
        public var reaped: [String] = []
        /// Files the server's copy turned out to be byte-for-byte the one
        /// this client already held: fetched, compared, and left alone.
        public var alreadyInStep: [String] = []
        /// Files changed here while the pass ran, after it planned to take
        /// the other side's copy or delete this one. Left alone: the next
        /// pass sees the edit and merges it, or keeps the copy. Not a failure.
        public var changedDuringPass: [String] = []
        /// A file the server would not take, or one whose work failed. The
        /// pass carries on and reports, rather than abandoning the rest.
        public var failures: [String] = []
        /// The bundle revision this pass left behind.
        public var bundleRevision: String?
        /// The bundle this pass wrote, as written: what a caller applies
        /// afterwards, so it never reads the bundle back to learn it.
        public var written: LampSyncSettingsStore.Snapshot?
    }

    /// Thrown by `contributing` when what it prepared was against a bundle
    /// that has since moved: another device wrote between this pass's read
    /// and its update. The pass reads the bundle again, hands it to
    /// `receiving` again, and retries, so a contribution is never built from
    /// a bundle older than the one it lands on.
    public struct PrepareAgain: Error, Equatable {
        public init() {}
    }

    private let store: any LampSyncRemoteStore
    private let library: any LampSyncPassLibrary
    private let source: String
    private let now: () -> Int64

    public init(
        store: any LampSyncRemoteStore,
        library: any LampSyncPassLibrary,
        source: String,
        now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    ) {
        self.store = store
        self.library = library
        self.source = source
        self.now = now
    }

    /// Runs one pass.
    ///
    /// `local` is what this Mac holds, `deletedLocally` what it has deleted
    /// since its last pass, and `extraListing` the revisions of paths that no
    /// folder listing reaches — media and workspace files, which the manifest
    /// names and the caller checks one at a time.
    ///
    /// `records` is updated in place and saved by the caller, so a pass that
    /// throws still leaves behind what it had already written.
    /// What this client holds, as the plan reads it.
    public struct Gathered {
        /// Every local file: its remote path, its kind and its digest.
        public var local: [LampSyncLocalFile] = []
        /// What this client has deleted since its last pass, by remote path.
        public var deletedLocally: [String: Int64] = [:]
        /// Revisions for paths no folder listing reaches — writing
        /// attachments, book pictures and workspace files, which the manifest
        /// names and the caller checks one at a time.
        public var extraListing: [String: String] = [:]

        /// Paths whose content this client holds, but not as a file at that
        /// path.
        ///
        /// An editable collection is merged *into* the library, so a copy
        /// taken from the server leaves nothing behind to re-export when the
        /// collection has nothing in it — an empty highlight set exports to
        /// nothing at all. The plan downloads any member with no local copy,
        /// so without saying so this client fetches and installs the same
        /// file on every pass, for ever. Saying so is the truth about it:
        /// taken at that revision, unchanged since.
        public var heldWithoutAFile: Set<String> = []

        /// When each path's content was last saved here, where the library
        /// knows. A file saved after another device deleted it survives the
        /// deletion and goes back up, so without this a collection edited
        /// here after it was tombstoned elsewhere would be deleted instead.
        public var savedAt: [String: Int64] = [:]

        public init() {}
    }

    /// `receiving` is handed the bundle as it was read, once, before anything
    /// is published — settings and deletion records are applied there, so what
    /// this client publishes already holds what came down. `contributing`
    /// writes this client's own half into the bundle, inside the pass's single
    /// update. It must only compute: `update` re-applies its change against a
    /// newer bundle when another device writes first, so anything that needs
    /// to read local state asynchronously is read in `receiving` and kept for
    /// `contributing` to use.
    ///
    /// `mergingVersion` folds in the copies iCloud keeps when two devices
    /// wrote at once. It is the caller's because merging a bundle needs to
    /// merge the ledgers inside it, and those belong to the library rather
    /// than to a pass. Without one, a bundle with versions stops rather than
    /// guessing which to keep.
    ///
    /// `gathering` runs **after** `receiving`, and that order is load-bearing:
    /// applying the deletion records removes content from this library, so a
    /// library read before them would publish the very notes and writings it
    /// had just been told were deleted, and the next pass on the other device
    /// would resurrect them.
    ///
    /// `receiving` gets the whole snapshot, versions included: on iCloud a
    /// client prepares its contribution against the copies it will merge.
    ///
    /// `plannedKinds` says which kinds of file this client syncs. Others are
    /// neither fetched, published, deleted nor recorded, and pruning still
    /// sees the whole listing, so a tombstone waiting for its file to be
    /// reaped is kept whoever plans what.
    ///
    /// `confirmByReading` says which uploads that come back without a
    /// revision are confirmed by reading the body back; the rest are asked
    /// for their revision only, so a translation is not downloaded again to
    /// see it arrived. Either way the server is waited for within `patience`,
    /// and an upload it has not shown back is reported, never recorded with
    /// a guessed revision.
    public func run(
        gathering: () async throws -> Gathered,
        records: inout LampSyncFileRecords,
        mergingVersion: (
            (inout LampSyncSettingsBundle, LampSyncSettingsStore.Version) throws -> Void
        )? = nil,
        plannedKinds: (LampSyncFileKind) -> Bool = { _ in true },
        confirmByReading: (LampSyncFileKind) -> Bool = { _ in false },
        patience: LampSyncConditionalWrite.Patience = .standard,
        attempts: Int = 3,
        receiving: (LampSyncSettingsStore.Snapshot) async throws -> Void = { _ in },
        contributing: (inout LampSyncSettingsBundle) throws -> Void = { _ in }
    ) async throws -> Outcome {
        var outcome = Outcome()
        // Deliberately without `knownArchiveRevision`. That parameter names a
        // revision at which an *archive* is known to sit, and a read that
        // still finds it there throws `notMigrated`. Handing it a bundle's
        // revision makes a migrated library report itself unmigrated on every
        // pass — which is what it did.
        let opened = try await LampSyncSettingsStore.readOrClaim(from: store, patience: patience)
        try await receiving(opened)

        // Only now: the library has had the other devices' deletions applied
        // to it, so this is what it actually holds.
        let gathered = try await gathering()

        var listing = try await LampSyncFilePlan.listing(
            in: store, manifest: opened.bundle.manifest
        )
        listing.merge(gathered.extraListing) { _, extra in extra }

        let filesByPath = Dictionary(
            gathered.local.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a }
        )
        var locals = LampSyncLocalFiles.locals(
            gathered.local, records: records, source: source, savedAt: { gathered.savedAt[$0] }
        )
        let described = Set(gathered.local.map(\.path))
        for path in gathered.heldWithoutAFile.sorted() where !described.contains(path) {
            guard let revision = records.record(path, in: source)?.effectiveRevision else {
                continue
            }
            locals.append(LampSyncFilePlan.Local(
                path: path,
                changedSinceUpload: false,
                lastRevision: revision,
                savedAt: gathered.savedAt[path]
            ))
        }

        let plan = LampSyncFilePlan.plan(
            manifest: opened.bundle.manifest,
            local: locals,
            deletedLocally: gathered.deletedLocally,
            listing: listing
        ).only { path in LampSyncFolderLayout.kind(of: path).map(plannedKinds) ?? false }

        // A local copy is acted on — installed over or deleted — only while
        // it is still the one the plan saw, as a write to the server is
        // conditioned on the revision it read. The person may have changed it
        // since; the next pass then sees both sides changed and merges, or
        // sees a save after the deletion and keeps it. An exported
        // collection's file is a snapshot merged on install, so it reads
        // unchanged. One that cannot be read now is acted on as before, not
        // refused: a collection whose exported snapshot is gone by then would
        // otherwise never be installed.
        // (`Verification/SyncMerge.lean`: `anEditDuringAPassSurvives`.)
        func unchangedSincePlanned(_ path: String) -> Bool {
            guard let planned = filesByPath[path],
                  let now = try? LampSyncContentRevision.digest(forFileAt: planned.url)
            else { return true }
            return now == planned.digest
        }

        // 1. Take what the other side has. A file staged for a tree taken in
        //    together is recorded once the tree is in, at step 3: recorded
        //    now, a failed import would leave the record naming the new
        //    revision over the old copy, which the next pass would read as an
        //    edit here and send back over the other device's.
        //    (`Verification/SyncMerge.lean`: `aPartialTreeImportIsCompletedByTheNextPass`.)
        var staged: [(path: String, revision: String?, digest: String?)] = []
        for path in plan.downloads.sorted() {
            do {
                try await LampSyncScratchFile.with { scratch in
                    guard let downloaded = try await store.read(path: path, into: scratch) else {
                        // Nothing there. For media that is "not uploaded yet",
                        // and for anything else the next pass sees it again.
                        return
                    }
                    guard unchangedSincePlanned(path) else {
                        outcome.changedDuringPass.append(path)
                        return
                    }
                    let held = try await library.install(path, from: downloaded.url)
                    let digest = held ?? (try? LampSyncContentRevision.digest(forFileAt: downloaded.url))
                    if LampSyncFolderLayout.kind(of: path)?.isTakenInTogether == true {
                        staged.append((path, downloaded.revision, digest))
                        return
                    }
                    records.recordInstall(path, in: source, revision: downloaded.revision, digest: digest)
                    outcome.installed.append(path)
                }
            } catch {
                outcome.failures.append("\(path): \(error.localizedDescription)")
            }
        }

        // 2. Reconcile what both sides changed, as one transaction, and
        //    publish the result under the revision the plan named.
        var republish: [String: URL] = [:]
        if !plan.merge.isEmpty {
            do {
                republish = try await reconcile(
                    plan.merge, local: filesByPath, records: &records, outcome: &outcome
                )
            } catch {
                outcome.failures.append("merging: \(error.localizedDescription)")
            }
        }

        // 3. Let whatever arrived as part of a tree be taken in together,
        //    and only then record it.
        do {
            try await library.finishInstalling()
            for file in staged {
                records.recordInstall(file.path, in: source, revision: file.revision, digest: file.digest)
                outcome.installed.append(file.path)
            }
        } catch {
            outcome.failures.append("installing: \(error.localizedDescription)")
        }

        // 4. Publish, both what only changed here and what was just merged.
        //    A merged path carries its own condition — the revision that was
        //    downloaded — and publishes the file the transaction produced,
        //    never the one digested before it ran. Each success is remembered
        //    as pending until the bundle below names it.
        var toPublish = plan.uploads
        for (path, revision) in plan.merge where republish[path] != nil {
            toPublish[path] = .ifRevision(revision)
        }
        var written: [String: (revision: String?, previous: String?)] = [:]
        // Media first, then everything else, each in path order. A writing
        // must never land on another device before the picture it names, and
        // a book before its plates. Today that also happens to fall out of
        // the alphabet — `BookMedia` before `Books`, `DevotionalMedia` before
        // `Devotionals` — which is true until somebody renames a folder.
        let inOrder = toPublish.sorted { a, b in
            let aMedia = LampSyncFolderLayout.kind(of: a.key)?.isMedia ?? false
            let bMedia = LampSyncFolderLayout.kind(of: b.key)?.isMedia ?? false
            return aMedia == bMedia ? a.key < b.key : aMedia
        }
        for (path, condition) in inOrder {
            // A merged file is only ever the merge's own output: falling back
            // to the pre-merge copy would publish the other side's changes
            // straight back out of the library.
            guard let url = plan.merge[path] == nil
                ? (republish[path] ?? filesByPath[path]?.url)
                : republish[path]
            else { continue }
            let digest = url == filesByPath[path]?.url
                ? filesByPath[path]?.digest
                : (try? LampSyncContentRevision.digest(forFileAt: url))
            guard let digest else {
                outcome.failures.append("\(path): its file could not be read")
                continue
            }
            // A PUT that answers without an ETag leaves this client with no
            // revision for a file it has just written. The next pass then
            // finds a revision in the listing where it recorded none, reads
            // that as the other side having changed the file, and downloads
            // its own upload back — 601 of them, on the first pass after the
            // workspaces went up. Media is worse still: with no revision it
            // is offered `.ifAbsent` for ever against a file plainly there.
            //
            // So a write that names no revision is confirmed, waiting out a
            // server still showing what it held before, or a tag Apache marks
            // weak for the second after a change. By reading the body back
            // where the caller asks, by revision alone otherwise. One it has
            // not shown back is reported and left unrecorded, never recorded
            // under a guess; the next pass compares it.
            let kind = LampSyncFolderLayout.kind(of: path)
            do {
                switch try await LampSyncConditionalWrite.write(
                    fileAt: url, to: path, in: store, condition: condition, patience: patience,
                    confirm: kind.map(confirmByReading) == true ? .reading : .revision
                ) {
                case .written(let revision):
                    records.recordUpload(path, in: source, digest: digest, revision: revision)
                    written[path] = (revision, condition.revision)
                    outcome.uploaded.append(path)
                case .writtenUnconfirmed:
                    outcome.failures.append(
                        "\(path): sent, but the server has not shown it back yet; the next sync settles it"
                    )
                case .refused where condition == .ifAbsent && (kind?.isMedia ?? false):
                    // A refused `.ifAbsent` means the file is already there,
                    // and for media that is the whole answer: a path's bytes
                    // never change, so an existing copy is either ours or a
                    // genuine clash. Without settling it the pass offers the
                    // same write every time and is refused every time — which
                    // is what two deck images did, on every pass, for ever.
                    try await settleExistingMedia(
                        at: path, ours: digest, records: &records, outcome: &outcome
                    )
                case .refused:
                    // Another device wrote first; the next pass plans again
                    // from what won.
                    outcome.failures.append(
                        "\(path): \(LampSyncConditionalWrite.WriteError.conflict.localizedDescription)"
                    )
                }
            } catch {
                outcome.failures.append("\(path): \(error.localizedDescription)")
            }
        }

        // 5. Drop what was deleted elsewhere.
        for path in plan.deleteLocally.sorted() {
            guard unchangedSincePlanned(path) else {
                outcome.changedDuringPass.append(path)
                continue
            }
            do {
                try await library.deleteLocally(path)
                records.forget(path, in: source)
                outcome.deletedLocally.append(path)
            } catch {
                outcome.failures.append("\(path): \(error.localizedDescription)")
            }
        }

        // 6. One update, carrying everything this pass did.
        let time = now()
        let adopt = plan.adopt
        let tombstone = plan.tombstone
        var snapshot: LampSyncSettingsStore.Snapshot?
        for attempt in 0..<max(attempts, 1) {
            if attempt > 0 {
                // The contribution was prepared against a bundle that moved.
                // Hand the one there now to `receiving`, so it prepares again.
                guard let current = try await LampSyncSettingsStore.read(from: store, patience: patience) else {
                    throw LampSyncSettingsStore.StoreError.tooManyAttempts
                }
                try await receiving(current)
            }
            do {
                snapshot = try await update(
                    adopt: adopt, tombstone: tombstone, written: written, listing: listing,
                    supersede: plan.supersede,
                    time: time, mergingVersion: mergingVersion, patience: patience,
                    attempts: attempts, contributing: contributing
                )
                break
            } catch is PrepareAgain {
                continue
            }
        }
        guard let snapshot else { throw LampSyncSettingsStore.StoreError.tooManyAttempts }
        outcome.bundleRevision = snapshot.revision
        outcome.written = snapshot
        outcome.tombstoned = tombstone.keys.sorted()
        records.confirmRecorded(
            written.compactMapValues(\.revision), in: source
        )

        // 7. Only now may the bytes go. Before the bundle named the deletion,
        //    a missing file reads as one nobody has uploaded yet.
        for (path, revision) in plan.reap.sorted(by: { $0.key < $1.key }) {
            do {
                try await store.delete(path: path, condition: .ifRevision(revision))
                records.forget(path, in: source)
                outcome.reaped.append(path)
            } catch {
                outcome.failures.append("\(path): \(error.localizedDescription)")
            }
        }

        return outcome
    }

    /// The pass's one bundle update: this client's contribution, then every
    /// write, adoption and tombstone the pass made, then pruning.
    private func update(
        adopt: [String: String],
        tombstone: [String: Int64],
        written: [String: (revision: String?, previous: String?)],
        listing: [String: String],
        supersede: [String: Int64],
        time: Int64,
        mergingVersion: ((inout LampSyncSettingsBundle, LampSyncSettingsStore.Version) throws -> Void)?,
        patience: LampSyncConditionalWrite.Patience,
        attempts: Int,
        contributing: (inout LampSyncSettingsBundle) throws -> Void
    ) async throws -> LampSyncSettingsStore.Snapshot {
        try await LampSyncSettingsStore.update(
            in: store,
            attempts: attempts,
            patience: patience,
            mergingVersion: mergingVersion
        ) { bundle in
            try contributing(&bundle)
            // A copy that survived a tombstone is recorded after it, however
            // far ahead the deleting device's clock ran.
            // (`Verification/SyncMerge.lean`: `aWriteSupersedesATombstoneFromAFastClock`.)
            for (path, write) in written {
                bundle.manifest = try bundle.manifest.recordingWrite(
                    path, revision: write.revision, replacing: write.previous,
                    at: supersede[path].map { max(time, $0 + 1) } ?? time
                )
            }
            for (path, revision) in adopt where written[path] == nil {
                bundle.manifest = try bundle.manifest.adopting(path, revision: revision, at: time)
            }
            for (path, deletedAt) in tombstone {
                bundle.manifest = try bundle.manifest.removing(
                    path, at: deletedAt, revision: listing[path]
                )
            }
            // Old enough to forget, and gone from the server. `present` is
            // the **whole** listing, never a filtered one: a tombstone whose
            // file is still waiting to be reaped must be kept, or the next
            // pass finds a file no manifest knows and adopts the deletion
            // back into the library. ios-92 hit exactly that on the phone by
            // pruning against a listing it had filtered for planning.
            bundle.manifest = bundle.manifest.pruned(
                now: time, present: Set(listing.keys)
            )
        }
    }

    /// Downloads everything the plan says both sides changed, and merges what
    /// is genuinely different.
    ///
    /// A file whose downloaded bytes are the ones this client already holds
    /// needs neither merging nor installing — it is only *recorded*, as
    /// having been uploaded from here at the server's revision, which is the
    /// plain truth about it: these bytes, that revision. Without that, a pass
    /// with no records to go on treats every file as changed on both sides
    /// and reinstalls the whole library, module by module, having just
    /// proved each one identical. It also leaves nothing recorded, so the
    /// next pass does it again.
    ///
    /// The comparison is of real downloaded bytes, not an assumption that
    /// two clients encode alike. That distinction is the whole reason this
    /// is safe where seeding records from a guess would not be.
    /// What to do about a file that would not go up because one is already
    /// there, at a path whose bytes never change.
    ///
    /// Reading it is the only way to tell the two cases apart. If it is the
    /// same file, this client simply had no record of having sent it — so it
    /// records one, and the path is finished with. If it is a different file,
    /// that is a real clash at an immutable path: reported, never
    /// overwritten, because the other copy is as much somebody's as this one.
    private func settleExistingMedia(
        at path: String,
        ours digest: String,
        records: inout LampSyncFileRecords,
        outcome: inout Outcome
    ) async throws {
        try await LampSyncScratchFile.with { scratch in
            guard let theirs = try await store.read(path: path, into: scratch) else {
                // Gone between the refusal and now. The next pass sends it.
                return
            }
            guard try LampSyncContentRevision.digest(forFileAt: theirs.url) == digest else {
                outcome.failures.append(
                    "\(path): a different file is already there, so this one was not sent"
                )
                return
            }
            records.recordUpload(
                path, in: source, digest: digest, revision: theirs.revision
            )
            records.confirmRecorded(
                theirs.revision.map { [path: $0] } ?? [:], in: source
            )
            outcome.alreadyInStep.append(path)
        }
    }

    private func reconcile(
        _ merge: [String: String],
        local: [String: LampSyncLocalFile],
        records: inout LampSyncFileRecords,
        outcome: inout Outcome
    ) async throws -> [String: URL] {
        var downloaded: [String: URL] = [:]
        var scratch: [URL] = []
        defer { for url in scratch { try? FileManager.default.removeItem(at: url) } }
        var unchanged: [String] = []
        for path in merge.keys.sorted() {
            let url = LampSyncScratchFile.url()
            scratch.append(url)
            guard let file = try await store.read(path: path, into: url) else { continue }
            if let held = local[path],
               let fetched = try? LampSyncContentRevision.digest(forFileAt: file.url),
               fetched == held.digest {
                records.recordUpload(
                    path, in: source, digest: held.digest, revision: file.revision
                )
                records.confirmRecorded(
                    file.revision.map { [path: $0] } ?? [:], in: source
                )
                unchanged.append(path)
                continue
            }
            downloaded[path] = file.url
            records.recordInstall(
                path, in: source, revision: file.revision,
                digest: try? LampSyncContentRevision.digest(forFileAt: file.url)
            )
        }
        outcome.alreadyInStep.append(contentsOf: unchanged)
        guard !downloaded.isEmpty else { return [:] }
        let republish = try await library.reconcile(downloaded)
        outcome.reconciled = downloaded.keys.sorted()
        return republish
    }
}

private extension LampSyncFilePlan.Plan {
    /// The plan for the paths `keep` admits, and nothing else.
    func only(_ keep: (String) -> Bool) -> Self {
        var plan = LampSyncFilePlan.Plan()
        plan.downloads = downloads.filter(keep)
        plan.merge = merge.filter { keep($0.key) }
        plan.uploads = uploads.filter { keep($0.key) }
        plan.deleteLocally = deleteLocally.filter(keep)
        plan.adopt = adopt.filter { keep($0.key) }
        plan.tombstone = tombstone.filter { keep($0.key) }
        plan.reap = reap.filter { keep($0.key) }
        plan.supersede = supersede.filter { keep($0.key) }
        return plan
    }
}

private extension LampSyncWriteCondition {
    /// The revision a conditional write replaces, for the manifest to record
    /// the new one as its successor.
    var revision: String? {
        switch self {
        case .ifRevision(let revision): revision
        case .unconditional, .ifAbsent: nil
        }
    }
}
