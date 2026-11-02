import Foundation

/// The fingerprint of a client holding content without saying so.
///
/// Every decision a pass makes reads what the client *says* it holds
/// (`LampSyncFilePlan.Local`). Core cannot check the claim: it has no way to
/// look in another app's database, and a client that holds content without
/// saying so is indistinguishable, path by path, from one that never had it.
/// Two things follow from getting it wrong, and both are silent:
/// the file is fetched and installed again on every pass, for ever, and a
/// deletion made on another device is never carried out here — the plan asks
/// a client to delete only what it says it holds
/// (`Verification/SyncMerge.lean`: `anUnclaimedMemberComesDownForEver`,
/// `anUnclaimedDeletionIsNeverCarriedOut`).
///
/// That is not hypothetical. A reading plan installed on the phone was never
/// registered among its modules, so the phone claimed nothing at
/// `Plans/<id>.lamp`: every pass fetched the plan again, and a plan the owner
/// deleted on their Mac stayed on their phone through sync after sync, with
/// nothing anywhere saying why.
///
/// What core can see is this client's own records. A record is a path this
/// client installed and has not deleted since — a deletion carried out
/// forgets it (`LampSyncFileRecords.forget`). So a record with no claim
/// behind it is the fingerprint: either the client holds those bytes and did
/// not say so, or it lost them without recording a deletion. Both are worth
/// saying out loud, because otherwise a pass quietly does the same work for
/// ever, or quietly fails to carry out a deletion.
///
/// Reported, never corrected. Core taking a client's record as a claim to
/// hold the file would be guessing on the client's behalf, and the guess
/// would be wrong exactly when the file really is gone.
public enum LampSyncUnclaimedInstalls {
    /// Whether fetching a file whose last installed revision was `recorded`,
    /// and whose revision on the server is `listed`, is fetching bytes this
    /// client has already had.
    ///
    /// No record means this client has never installed the path, which is
    /// what a first download is. A record naming another revision means the
    /// server's copy has moved since, which is an ordinary download.
    ///
    /// Media is the exception, and it has to be: a path never changes its
    /// bytes, so the recorded revision names the same content whatever the
    /// server now says, and the record alone is the whole answer. It matters
    /// because nothing lists media — the manifest names every such file and a
    /// caller asks for its revision one path at a time, or doesn't. A client
    /// that asks for none has no listing at all, and comparing revisions
    /// there could never report anything: on the phone, where no media
    /// revision is ever gathered, that silence covered every attachment and
    /// every picture a book shows.
    public static func isFetchedAgain(
        kind: LampSyncFileKind, recorded: String?, listed: String?
    ) -> Bool {
        guard let recorded else { return false }
        if kind.isMedia { return true }
        guard let listed else { return false }
        return LampSyncConditionalWrite.namesSameRevision(recorded, listed)
    }

    /// The paths among `downloads` that this client has installed before, at
    /// the revision it is about to fetch, in the order given.
    public static func paths(
        downloads: [String],
        records: LampSyncFileRecords,
        source: String,
        listing: [String: String]
    ) -> [String] {
        downloads.filter { path in
            guard let kind = LampSyncFolderLayout.kind(of: path) else { return false }
            return isFetchedAgain(
                kind: kind,
                recorded: records.record(path, in: source)?.effectiveRevision,
                listed: listing[path]
            )
        }
    }

    /// Tombstoned paths this client's own records say it installed, which it
    /// neither claims nor deleted here: deletions this pass will not carry
    /// out, and no later pass will either.
    ///
    /// This is the symptom rather than the cause, and it is the one somebody
    /// notices — the plan still on the phone after sync after sync. It was
    /// thought uncatchable, on the grounds that a client claiming nothing at
    /// a tombstoned path looks exactly like one that never had the file. It
    /// does not: one that never had it has no record. The record is the same
    /// evidence `isFetchedAgain` reads, and it is still there on the pass the
    /// deletion arrives, whether or not the file is still on the server for
    /// the plan to fetch or reap.
    ///
    /// Two exclusions, both of them ordinary business rather than a fault.
    /// A deletion made *here* is why the tombstone exists, so this client is
    /// right not to claim the path and its record goes when the file is
    /// reaped. And a path no library deletes (`LampSyncLocalDeletion`) is
    /// never carried out anywhere: under a tombstone some older client
    /// recorded it is planned as a member and its next write supersedes the
    /// tombstone.
    public static func deletionsNotCarriedOut(
        manifest: LampSyncLibraryManifest,
        claimed: Set<String>,
        deletedHere: Set<String>,
        records: LampSyncFileRecords,
        source: String,
        planned: (LampSyncFileKind) -> Bool
    ) -> [String] {
        manifest.tombstones.compactMap { entry in
            guard let kind = entry.kind, planned(kind),
                  !claimed.contains(entry.path), !deletedHere.contains(entry.path),
                  LampSyncLocalDeletion.target(of: entry.path).isAllowed,
                  records.record(entry.path, in: source) != nil
            else { return nil }
            return entry.path
        }
    }
}
