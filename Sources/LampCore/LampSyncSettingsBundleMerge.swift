import Foundation
import LampModuleKit

extension LampSyncSettingsBundle {
    /// Folds in a copy of the bundle another device wrote at the same time,
    /// which the store kept beside this one (`LampSyncSettingsStore.Version`).
    ///
    /// Every part that is a join is joined: membership, the shared
    /// preferences, both deletion ledgers, plan progress and book reading, so the result is the same
    /// whichever copy the store kept as current, and nothing either device
    /// recorded is lost. The apps' own settings stay as this copy has them:
    /// they are opaque here, and each app merges them from
    /// `Snapshot.versions` itself, before the write.
    ///
    /// A ledger this client can't read never stops the merge, as it never
    /// stops a pass: of two personal ledgers the readable one stands, and of
    /// two deck ledgers an unreadable one leaves this copy's as it is, so a
    /// newer client's is never rewritten in an older format.
    /// (`Verification/SyncMerge.lean`: `versionMerge`, `mergeReadingPart`.)
    public mutating func merge(version other: LampSyncSettingsBundle) throws {
        manifest = manifest.merged(with: other.manifest)
        preferences = preferences.joined(with: other.preferences)
        personalDeletions = Self.joined(personalDeletions, other.personalDeletions) { ours, theirs in
            switch (try? LampPersonalDeletionLedger.decode(ours), try? LampPersonalDeletionLedger.decode(theirs)) {
            case (var ledger?, let incoming?):
                ledger.merge(incoming)
                return (try? ledger.encoded()) ?? ours
            case (nil, .some): return theirs
            default: return ours
            }
        }
        deckDeletions = Self.joined(deckDeletions, other.deckDeletions) { ours, theirs in
            func decoded(_ data: Data) throws -> LampPresentationDeckDeletionLedger {
                let ledger = try JSONDecoder().decode(LampPresentationDeckDeletionLedger.self, from: data)
                guard ledger.formatVersion == LampPresentationDeckDeletionLedger.currentFormatVersion else {
                    throw CocoaError(.coderReadCorrupt)
                }
                return ledger
            }
            guard var ledger = try? decoded(ours), let incoming = try? decoded(theirs) else { return ours }
            ledger.merge(incoming)
            return (try? ledger.encoded()) ?? ours
        }
        // As the personal ledger: of two, the readable one stands.
        planProgress = Self.joined(planProgress, other.planProgress) { ours, theirs in
            switch (try? LampSyncPlanProgress.decode(ours), try? LampSyncPlanProgress.decode(theirs)) {
            case (var progress?, let incoming?):
                progress.merge(incoming)
                return (try? progress.encoded()) ?? ours
            case (nil, .some): return theirs
            default: return ours
            }
        }
        // And as plan progress.
        bookReading = Self.joined(bookReading, other.bookReading) { ours, theirs in
            switch (try? LampSyncBookReading.decode(ours), try? LampSyncBookReading.decode(theirs)) {
            case (var reading?, let incoming?):
                reading.merge(incoming)
                return (try? reading.encoded()) ?? ours
            case (nil, .some): return theirs
            default: return ours
            }
        }
    }

    /// One copy's ledger where only one has it, and both joined where both do.
    private static func joined(
        _ ours: Data?, _ theirs: Data?, _ join: (Data, Data) throws -> Data
    ) rethrows -> Data? {
        guard let ours else { return theirs }
        guard let theirs, ours != theirs else { return ours }
        return try join(ours, theirs)
    }
}
