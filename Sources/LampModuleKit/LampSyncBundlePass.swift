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

    /// `install`, told the digest of the bytes this client last agreed with
    /// the server on at the path, sent or taken (nil where it has none). A
    /// library whose files the writer edits keeps what was edited since, as
    /// a writing's documents do (`LampWritingDocumentMerge`), whatever the
    /// plan saw: a save can land between the plan and the install. The rest
    /// ignore it.
    func install(_ path: String, from url: URL, agreedDigest: String?) async throws -> String?

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

    /// Removes the local copy of a file deleted elsewhere, told the digest
    /// of the bytes this client last agreed with the server on, sent or
    /// taken (nil where it has none). A library whose files the writer edits
    /// keeps what was edited since, as a writing's documents do
    /// (`LampWritingDocumentMerge.keepsOnDeletion`); the rest ignore it.
    func deleteLocally(_ path: String, agreedDigest: String?) async throws

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

    func deleteLocally(_ path: String, agreedDigest: String?) async throws {
        try await deleteLocally(path)
    }

    func install(_ path: String, from url: URL, agreedDigest: String?) async throws -> String? {
        try await install(path, from: url)
    }
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
        /// Deletions queued here the manifest needs nothing more of: one it
        /// carries already, at that time or later, from a pass that stopped
        /// before the queue was cleared or another device's later deletion;
        /// or one a write recorded after it wins. Drop them as the
        /// tombstoned are dropped, or each is asked for on every pass.
        /// (`LampSyncFilePlan.Plan.settled`.)
        public var settled: [String] = []
        /// Deletions queued here this pass left out, its ask about their
        /// file unanswered (`defersDeletion`): keep them queued for the next
        /// pass, whatever else is cleared.
        public var deferred: [String] = []
        public var reaped: [String] = []
        /// Files the server's copy turned out to be byte-for-byte the one
        /// this client already held: fetched, compared, and left alone.
        public var alreadyInStep: [String] = []
        /// Files changed here while the pass ran, after it planned to take
        /// the other side's copy, delete this one, or publish it. Left
        /// alone: the next pass sees the edit and merges it, keeps the copy,
        /// or publishes what replaced it. Not a failure.
        public var changedDuringPass: [String] = []
        /// A file the server would not take, or one whose work failed. The
        /// pass carries on and reports, rather than abandoning the rest.
        public var failures: [String] = []
        /// Files fetched although this client's own records say it installed
        /// those very bytes and has not deleted them since
        /// (`LampSyncUnclaimedInstalls`). Not a failure of this pass — it
        /// does exactly what the plan says — but the fingerprint of a client
        /// holding content without saying so, which costs it this download on
        /// every pass and a deletion from another device never carried out.
        /// Show it: nothing else about either consequence is visible.
        public var fetchedAgain: [String] = []
        /// Files another device deleted that this pass will not delete here,
        /// although this client's own records say it installed them and has
        /// recorded no deletion of its own (`LampSyncUnclaimedInstalls`). The
        /// same fault as `fetchedAgain`, caught where somebody notices it:
        /// nothing else says why a thing deleted on one device is still on
        /// this one after pass upon pass.
        public var deletionsNotCarriedOut: [String] = []
        /// Modules and decks this client holds, as the server last had them,
        /// that the server's listing did not find, and why
        /// (`LampSyncFilePlan.missing`). Nothing is done about them: show
        /// them, and let the person delete one if it is gone for good. A
        /// path leaves the set when a pass finds its file again.
        public var missing: [String: LampSyncFilePlan.Missing] = [:]
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

        /// Paths this client holds something at and will not sync, by the
        /// reason to tell the person, which is reported once per pass.
        ///
        /// A gather that cannot read a file leaves it out of `local` — and
        /// without saying so, "no local copy" is what the plan reads, so it
        /// **downloads the server's copy and installs it over the file**. A
        /// module whose permissions are wrong, or one symlinked to a disk
        /// that is not mounted, was replaced by whatever the server had and
        /// nothing said a word. No hostile process and no race: a person who
        /// had done an ordinary thing to their own library lost a file.
        ///
        /// So a refused path is excluded from the plan exactly as an
        /// unplanned kind is: neither fetched, published, deleted nor
        /// recorded, and pruning still sees the whole listing. Nothing is
        /// lost on the server; the person is told, and the next pass takes
        /// the file once it can be read.
        public var refused: [String: String] = [:]

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

        func folded(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
        // A refusal has to be known before the listing, which asks the
        // server for a revision it was not given — on a folder store that is
        // a read of the body, and a read that fails takes the pass with it,
        // before the refusal it would have reported.
        let refusedSpellings = Set(gathered.refused.keys.map(folded))
        let listed = try await LampSyncFilePlan.listingAndFolders(
            in: store, manifest: opened.bundle.manifest,
            skippingRevisionFor: { refusedSpellings.contains(folded($0)) }
        )
        var listing = listed.listing
        listing.merge(gathered.extraListing) { _, extra in extra }
        // Revisions no listing reaches and the caller did not ask for
        // (`asksForRevision`): an upload the server had not shown back, which
        // the pass records nothing of and no bundle names, and which the plan,
        // unasked, sends "if absent" on every pass, refused for good; and a
        // deletion's file this client was to reap and could not. One request
        // for each, until a bundle names the one or a reap forgets the other.
        let manifest = opened.bundle.manifest
        let held = Set(gathered.local.map(\.path)).union(gathered.heldWithoutAFile)
        let known = held.union(manifest.paths)
        let spellings = Dictionary(grouping: known, by: folded)
        let started = now()
        var asked = Set<String>()
        var unanswered = Set<String>()
        for path in known.sorted() {
            guard let kind = LampSyncFolderLayout.kind(of: path) else { continue }
            let entry: ProbeEntry = manifest.entry(at: path).map { $0.isMember ? .member : .deletion } ?? .none
            // Any other spelling, live or deleted, held or named: on a server
            // that folds case its file answers for this one, and the plan
            // would adopt a deleted file or reap a live one. Two deleted
            // spellings then leave their file for the tombstones' pruning, a
            // file left over and nothing brought back.
            let otherSpelling = (spellings[folded(path)] ?? []).contains { $0 != path }
            // Only a deletion's age is asked; no deletion, no age.
            let young = manifest.entry(at: path)?.deletedAt.map { started - $0 < Self.reapRetryWindow } ?? false
            guard Self.asksForRevision(
                listedKind: kind.isListed, media: kind.isMedia, inListing: listing[path] != nil, entry: entry,
                held: held.contains(path), otherSpelling: otherSpelling, young: young
            ) else { continue }
            asked.insert(path)
            do {
                if let revision = try await store.revision(path: path) { listing[path] = revision }
            } catch {
                unanswered.insert(path)
            }
        }

        // A document deleted here while a pass sent it: that pass recorded
        // its write after the deletion, which then reads as a save made
        // elsewhere since, and the document comes back. Where the write is
        // the copy this client last had, the deletion saw it, and is dated
        // past it (`queuedDeletionTime`).
        var deletedLocally = gathered.deletedLocally
        // A deletion whose file the server was asked about and gave no
        // answer for is left queued for the next pass, and nothing is
        // planned of it in this one: planned blind, it would be settled on
        // the manifest's word while the copy this client deleted stood, and
        // the next answer would put that copy back. An answer with no
        // revision is no answer either where the copy this client deleted is
        // one the manifest's deletion does not cover: a server can answer
        // with no ETag for a file it holds (`defersDeletion`).
        for path in deletedLocally.keys.sorted() {
            let recordCovered = records.record(path, in: source)?.effectiveRevision.map { record in
                manifest.entry(at: path)?.deletes(revision: record) ?? false
            } ?? true
            guard Self.defersDeletion(
                asked: asked.contains(path), threw: unanswered.contains(path),
                hasRevision: listing[path] != nil, recordCovered: recordCovered
            ) else { continue }
            deletedLocally[path] = nil
            outcome.deferred.append(path)
        }
        for (path, deletedAt) in deletedLocally {
            deletedLocally[path] = Self.queuedDeletionTime(
                kind: LampSyncFolderLayout.kind(of: path), deletedAt: deletedAt, held: held.contains(path),
                entry: manifest.entry(at: path), recorded: records.record(path, in: source)?.effectiveRevision,
                listed: listing[path]
            )
        }

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

        // What this pass will act on at all: a kind this client syncs, and not
        // a path the gather refused.
        //
        // Matched folded as well as exactly. A library on a case-insensitive
        // volume has one file for `easter.lampdeck` and `Easter.lampdeck`, so
        // refusing the spelling the gather saw while fetching the other
        // spelling installs over the very file that was refused — the
        // install removes the destination before it copies. Folding may
        // refuse a genuinely different file on a case-sensitive volume, and
        // that is the conservative way round: nothing is lost on the server,
        // and a pair of paths differing only in case is a thing to tell the
        // person about rather than to act on (see `0010`).
        func isPlanned(_ path: String) -> Bool {
            guard !refusedSpellings.contains(folded(path)) else { return false }
            return LampSyncFolderLayout.kind(of: path).map(plannedKinds) ?? false
        }
        for (path, reason) in gathered.refused.sorted(by: { $0.key < $1.key }) {
            outcome.failures.append("\(path): \(reason)")
        }

        let plan = LampSyncFilePlan.plan(
            manifest: opened.bundle.manifest,
            local: locals,
            deletedLocally: deletedLocally,
            listing: listing,
            // The copy this client last had of each, which its deletion saw.
            deletedRecords: deletedLocally.keys.reduce(into: [:]) { revisions, path in
                revisions[path] = records.record(path, in: source)?.effectiveRevision
            }
        ).only(isPlanned)
        outcome.missing = LampSyncFilePlan.missing(
            manifest: opened.bundle.manifest,
            local: locals,
            deletedLocally: deletedLocally,
            found: listed.found.union(gathered.extraListing.keys),
            listedFolders: listed.folders
        ).filter { isPlanned($0.key) }

        // Read before anything is fetched, since fetching is what records the
        // revision that would hide it — and before anything is reaped, which
        // is what forgets the record a deletion left behind.
        outcome.fetchedAgain = LampSyncUnclaimedInstalls.paths(
            downloads: plan.downloads, records: records, source: source, listing: listing
        )
        outcome.deletionsNotCarriedOut = LampSyncUnclaimedInstalls.deletionsNotCarriedOut(
            manifest: opened.bundle.manifest,
            claimed: Set(locals.map(\.path)),
            deletedHere: Set(gathered.deletedLocally.keys),
            records: records,
            source: source,
            planned: plannedKinds,
            refused: Set(gathered.refused.keys)
        )

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
                    let held = try await library.install(
                        path, from: downloaded.url, agreedDigest: records.record(path, in: source)?.uploadedDigest
                    )
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
        var fetchedRevisions: [String: String] = [:]
        if !plan.merge.isEmpty {
            do {
                (republish, fetchedRevisions) = try await reconcile(
                    plan.merge, local: filesByPath, records: &records, staged: &staged, outcome: &outcome
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
                // A merged one is reported as merged, not twice.
                if !outcome.reconciled.contains(file.path) { outcome.installed.append(file.path) }
            }
        } catch {
            outcome.failures.append("installing: \(error.localizedDescription)")
        }

        // 4. Publish, both what only changed here and what was just merged.
        //    A merged path carries its own condition — the revision of the
        //    copy that was downloaded, not the one the listing showed, which
        //    the server may have moved from and back to since — and publishes
        //    the file the transaction produced, never the one digested before
        //    it ran. Each success is remembered as pending until the bundle
        //    below names it.
        var toPublish = plan.uploads
        for (path, revision) in plan.merge where republish[path] != nil {
            toPublish[path] = .ifRevision(fetchedRevisions[path] ?? revision)
        }
        var written: [String: (revision: String?, previous: String?)] = [:]
        // Media first, then everything else, each in path order. A writing
        // must never land on another device before the picture it names, and
        // a book before its plates. The alphabet doesn't promise it: since
        // writing was renamed, `Writing` sorts before `WritingMedia`.
        let inOrder = toPublish.sorted { a, b in
            let aMedia = LampSyncFolderLayout.kind(of: a.key)?.isMedia ?? false
            let bMedia = LampSyncFolderLayout.kind(of: b.key)?.isMedia ?? false
            return aMedia == bMedia ? a.key < b.key : aMedia
        }
        for (path, condition) in inOrder {
            // A merged file is only ever the merge's own output: falling back
            // to the pre-merge copy would publish the other side's changes
            // straight back out of the library.
            let transacted = republish[path]
            guard let url = transacted
                ?? (plan.merge[path] == nil ? filesByPath[path]?.url : nil)
            else { continue }
            // Whether these bytes are the ones the gather described, or the
            // transaction's own output. `reconcile` may replace a file
            // atomically and hand back the same URL, which is within what a
            // fixed candidate promises — so the URL cannot be read as
            // standing for the gathered file.
            let cameFromTheGather = transacted == nil
            // One copy of the file, taken here, hashed here and sent from
            // here — because a candidate may name a **live** file rather
            // than a copy of it (`LampWorkspaceSync.WorkspaceExportRecord`,
            // `Documentation/decisions/0008`), and a live file can be
            // rewritten or deleted between the plan and this line: the Mac's
            // own import compacts revision history, and opening a workspace
            // compacts it on a background queue.
            //
            // The digest has to be of the bytes that went up. Taking it from
            // the plan sends one thing and records another, and a later
            // revert to the recorded bytes then reads as already synced and
            // is never published. Taking it from the live file instead is not
            // enough either: the PUT opens the path again, and so does the
            // read-back confirmation, so a file that went A, B, A across
            // those reads would send A and record B. Found by a Codex
            // review of the first version of this, which did exactly that.
            //
            // A copy is affordable here where it was not in the gather,
            // which is the whole of `0008`: this runs for the handful of
            // files a pass actually uploads, not for every candidate it
            // considered, and `copyItem` on APFS clones.
            //
            // Sending what is held now is what the model says: `act`'s
            // upload arm sends `(w.device who).copy` — the copy at act time
            // — and `send` records `encode who content` of what it sent.
            // `planned` gates `download` and `deleteLocally` there, never
            // `upload` (`Verification/SyncMerge.lean`).
            let sending = LampSyncScratchFile.url()
            defer { try? FileManager.default.removeItem(at: sending) }
            // One copy of the file, taken through one open of it, hashed
            // from that copy and sent from it.
            //
            // `0009`: the digest has to be of the bytes that went up, or a
            // pass sends one thing and records another and a later revert to
            // the recorded bytes reads as already synced. `0010`: only an
            // ordinary file is published, a symbolic link's target being any
            // file this app can read. `0012`: both answered from a single
            // descriptor, because a path asked twice can answer differently
            // — and a clone of an open regular file cannot come out as
            // anything but a regular file, where `copyItem` on a link
            // copied the link.
            //
            // A copy is affordable here where it was not in the gather,
            // which is the whole of `0008`: this runs for the handful of
            // files a pass actually uploads, and on APFS the clone moves no
            // bytes.
            // The source, and the copy of it, in two steps — because what a
            // failure means depends on which one failed. A source that has
            // gone is a file that changed under the pass; a *copy* that has
            // gone is something wrong with the scratch directory, and
            // reporting it as a changed library file would be a lie about
            // the library.
            do {
                try LampSyncOpenFile.with(url) { file in
                    guard file.isOrdinaryFile else { throw LampSyncOpenFile.Failure.notAnOrdinaryFile }
                    try file.copy(into: sending)
                }
            } catch let failure as LampSyncOpenFile.Failure {
                // Gone since the plan: the model holds no copy to send and
                // records nothing, and the next pass publishes whatever
                // replaced it. Something that is not an ordinary file is a
                // failure, reported with its path. Anything else — a file
                // there but unreadable, a scratch directory that went away
                // under the pass — is a failure too, as it always was.
                if failure.namesAMissingFile {
                    outcome.changedDuringPass.append(path)
                } else if failure.namesSomethingUnpublishable {
                    outcome.failures.append("\(path): it is not an ordinary file")
                } else {
                    outcome.failures.append("\(path): its file could not be read")
                }
                continue
            }
            let digest: String
            do {
                digest = try LampSyncOpenFile.with(sending) { try $0.digest() }
            } catch {
                outcome.failures.append("\(path): the copy of it to send could not be read")
                continue
            }
            // A file the app said was fixed at its path must hash to what the
            // gather hashed. Nothing rewrites such a file where it sits, so
            // bytes that are not the bytes that were read mean this is not
            // that file — which is what catches a *directory* on the way to
            // it having been replaced by a link after the gather.
            //
            // Compared by the bytes and not by the file's identity, which
            // was the first version and refused good uploads: consolidating
            // the context store links the shared object over the path and
            // sets its permissions, so the inode moves and `st_ctime` with
            // it while the file is byte-for-byte what it was — on an
            // ordinary pass, caused by the pass's own import.
            //
            // Only where the bytes came from the gather: `reconcile` may
            // replace a file atomically and hand back the same URL, which is
            // within what a fixed candidate promises.
            if cameFromTheGather, let local = filesByPath[path], local.isFixedAtItsPath,
               digest != local.digest {
                outcome.failures.append("\(path): its file is not the one that was read")
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
                    fileAt: sending, to: path, in: store, condition: condition, patience: patience,
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
                try await library.deleteLocally(
                    path, agreedDigest: records.record(path, in: source)?.uploadedDigest
                )
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
        // Still members once the update took in what other devices did: one
        // deleted elsewhere meanwhile is not missing but gone, and the next
        // pass deletes it here.
        outcome.missing = outcome.missing.filter {
            snapshot.bundle.manifest.entry(at: $0.key)?.isMember == true
        }
        outcome.written = snapshot
        // What the manifest took, not what the plan asked for
        // (`recordsAdeletion`). A client whose deletions come from a ledger
        // rather than a queue asks for the same ones on every pass, and a
        // caller that forgets a local record, writes a file or tells somebody
        // on the strength of the ask does it on every pass too.
        //
        // Measured against the bundle this pass read. Another device
        // tombstoning the same path in between makes that a deletion this
        // pass only shares the credit for, which is the safe way to be wrong:
        // a caller may act once too often, never once too few.
        outcome.tombstoned = tombstone.keys.filter {
            snapshot.bundle.manifest.recordsAdeletion(of: $0, notIn: opened.bundle.manifest)
        }.sorted()
        outcome.settled = plan.settled.sorted()
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
                // A deletion queued here whose file is now gone has nothing
                // left to do; the model's pass drops it the same way.
                if deletedLocally[path] != nil, !outcome.settled.contains(path) {
                    outcome.settled.append(path)
                }
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
        staged: inout [(path: String, revision: String?, digest: String?)],
        outcome: inout Outcome
    ) async throws -> (republish: [String: URL], fetchedRevisions: [String: String]) {
        var downloaded: [String: URL] = [:]
        var fetchedRevisions: [String: String] = [:]
        var scratch: [URL] = []
        defer { for url in scratch { try? FileManager.default.removeItem(at: url) } }
        var unchanged: [String] = []
        var ahead: [String: URL] = [:]
        for path in merge.keys.sorted() {
            let url = LampSyncScratchFile.url()
            scratch.append(url)
            guard let file = try await store.read(path: path, into: url) else { continue }
            if let revision = file.revision { fetchedRevisions[path] = revision }
            let fetched = try? LampSyncContentRevision.digest(forFileAt: file.url)
            switch Self.fetchedForMerge(
                fetched: fetched, held: local[path]?.digest,
                lastUpload: records.record(path, in: source)?.uploadedDigest
            ) {
            case .inStep:
                guard let held = local[path] else { continue }
                records.recordUpload(
                    path, in: source, digest: held.digest, revision: file.revision
                )
                records.confirmRecorded(
                    file.revision.map { [path: $0] } ?? [:], in: source
                )
                unchanged.append(path)
                continue
            case .ours:
                // The server holds what this client last uploaded, so only
                // this side changed: its copy goes up as it is, under the
                // revision the plan named, and nothing is merged.
                if let held = local[path] { ahead[path] = held.url }
                continue
            case .merge:
                break
            }
            downloaded[path] = file.url
        }
        outcome.alreadyInStep.append(contentsOf: unchanged)
        guard !downloaded.isEmpty else { return (ahead, fetchedRevisions) }
        let digests = downloaded.mapValues { try? LampSyncContentRevision.digest(forFileAt: $0) }
        let republish = try await library.reconcile(downloaded)
        // Recorded only once the merge is in. Recorded before it, a merge
        // that failed left the records naming the server's copy as taken
        // over a copy here that never took it, and the next pass sent this
        // client's copy over the other device's edit as a change of its own.
        // A file of a tree taken in together is only staged by the merge, and
        // is recorded with the rest of the tree once that is in (step 3).
        for path in downloaded.keys {
            let takenTogether = LampSyncFolderLayout.kind(of: path)?.isTakenInTogether == true
            if Self.recordsMergedInstall(takenTogether: takenTogether, reconciled: true, treeIn: false) {
                records.recordInstall(path, in: source, revision: fetchedRevisions[path], digest: digests[path] ?? nil)
            } else {
                staged.append((path, fetchedRevisions[path], digests[path] ?? nil))
            }
        }
        outcome.reconciled = downloaded.keys.sorted()
        return (republish.merging(ahead) { merged, _ in merged }, fetchedRevisions)
    }

    /// Whether a merged path's install is recorded: only once the library
    /// has merged it, and for a file of a tree taken in together, once the
    /// tree is in. (`Verification/SyncMerge.lean`: `mergedRecord`.)
    static func recordsMergedInstall(takenTogether: Bool, reconciled: Bool, treeIn: Bool) -> Bool {
        reconciled && (!takenTogether || treeIn)
    }

    /// When a deletion queued here is recorded: when it was made, or, for a
    /// document this client no longer holds whose manifest write is the copy
    /// this client last had (`recorded`, its record's revision), just past
    /// that write. Such a write is this client's own upload, sent while the
    /// document was being deleted, or the copy it took and then deleted:
    /// either way the deletion saw it. A write it has no record of is a save
    /// made elsewhere that the deletion never saw, and it outlives the
    /// deletion; so does a copy the server holds (`listed`) other than the
    /// recorded one, uploaded since and not yet recorded, which dated past
    /// the write would be reaped. Documents only, whose deletions both apps forget once the
    /// document is held again: a module's or deck's ledger can outlive its
    /// re-creation here, and dated past this client's own new write it would
    /// delete it everywhere. (`Verification/SyncMerge.lean`: `queuedDeletionStamp`.)
    static func queuedDeletionTime(
        kind: LampSyncFileKind?, deletedAt: Int64, held: Bool,
        entry: LampSyncLibraryManifest.Entry?, recorded: String?, listed: String?
    ) -> Int64 {
        guard kind == .writingDocument, !held, let entry, entry.isMember,
              let written = entry.presentSince, let revision = entry.revision, let recorded,
              LampSyncConditionalWrite.namesSameRevision(revision, recorded),
              listed.map({ LampSyncConditionalWrite.namesSameRevision($0, revision) }) ?? true
        else { return deletedAt }
        return max(deletedAt, written + 1)
    }

    /// Whether a queued deletion is left out of this pass: where the pass
    /// asked the server for its file's revision and the ask failed, or came
    /// back with no revision while the copy this client deleted is one the
    /// manifest's deletion does not cover (`recordCovered` false), so that
    /// whether it still stands is what was asked. Unasked, the deletion is
    /// planned on what the manifest says; answered, on the answer.
    /// (`Verification/SyncMerge.lean`: `defersDeletion`.)
    static func defersDeletion(asked: Bool, threw: Bool, hasRevision: Bool, recordCovered: Bool) -> Bool {
        asked && (threw || (!hasRevision && !recordCovered))
    }

    /// What the manifest says of a path, as `asksForRevision` reads it.
    enum ProbeEntry: Equatable { case none, member, deletion }

    /// Whether the pass asks the server for a path's revision itself.
    /// Listings reach the listed kinds, the caller asks for the manifest's
    /// unlisted members, and media never changes at a path. Besides those, an
    /// unlisted file held here that the manifest does not name; and a
    /// deletion's file while the deletion is `young`, which a reap that
    /// failed leaves, whichever client asks: the one that deleted it may
    /// keep no record once the deletion is queued. Neither where another
    /// spelling could answer for it on a server that folds case.
    /// (`Verification/SyncMerge.lean`: `asksRevision`.)
    static func asksForRevision(
        listedKind: Bool, media: Bool, inListing: Bool, entry: ProbeEntry,
        held: Bool, otherSpelling: Bool, young: Bool
    ) -> Bool {
        if listedKind || media || inListing { return false }
        switch entry {
        case .none: return held && !otherSpelling
        case .member: return false
        case .deletion: return young && !otherSpelling
        }
    }

    /// How long a deletion's file is asked about again for, so a reap that
    /// failed is retried: a fortnight, in milliseconds.
    public static let reapRetryWindow: Int64 = 14 * 24 * 60 * 60 * 1_000

    enum FetchedForMerge: Equatable {
        /// The server's copy is the one held here.
        case inStep
        /// The server's copy is what this client last uploaded: it has not
        /// changed since, and the copy here is ahead of it.
        case ours
        case merge
    }

    /// What a file both sides were planned to have changed turns out to be,
    /// once the server's copy is fetched. A copy that is what this client
    /// last uploaded was not changed elsewhere, whatever its revision says:
    /// a revision this client recorded can be lost, as when a path is
    /// renamed, and then a change here would otherwise be merged with its
    /// own past, which for a file kept by its date can lose it.
    /// (`Verification/SyncMerge.lean`: `fetchedForMerge`.)
    static func fetchedForMerge(fetched: String?, held: String?, lastUpload: String?) -> FetchedForMerge {
        guard let fetched else { return .merge }
        if fetched == held { return .inStep }
        if fetched == lastUpload { return .ours }
        return .merge
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
        plan.settled = settled.filter(keep)
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
