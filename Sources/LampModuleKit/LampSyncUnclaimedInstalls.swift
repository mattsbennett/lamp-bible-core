import Foundation

/// Files a pass is about to fetch that this client's own records say it
/// already installed — the same bytes, at the same revision, with no
/// deletion recorded since.
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
/// What is caught is the cause, which shows long before the symptom. Every
/// pass from the day that plan arrived fetched it again, so this would have
/// been saying so for weeks before anybody deleted anything. The symptom
/// cannot be caught here: once the path is tombstoned the plan is to reap the
/// server's copy and delete nothing locally, and a client that claims nothing
/// at a tombstoned path looks exactly like one that never had the file.
///
/// So the one thing core can do, it does here: notice the fingerprint. A
/// record naming the revision now being downloaded means this client had
/// those bytes and did not say so — or lost them without recording a
/// deletion, since a deletion carried out forgets the record
/// (`LampSyncFileRecords.forget`). Either way it is worth saying out loud,
/// because otherwise it is a pass that quietly does the same work for ever.
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
    /// Neither being known is not a match either, though `namesSameRevision`
    /// would call two absences equal. A writing's attachment and a book's
    /// picture are fetched whenever this client does not hold them, listed or
    /// not, so that pair comes up — and it says nothing at all.
    public static func isFetchedAgain(recorded: String?, listed: String?) -> Bool {
        guard recorded != nil, listed != nil else { return false }
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
        downloads.filter {
            isFetchedAgain(recorded: records.record($0, in: source)?.effectiveRevision, listed: listing[$0])
        }
    }
}
