import Foundation
import LampModuleKit

extension LampSyncSettingsBundle {
    /// Folds in a copy of the bundle another device wrote at the same time,
    /// which the store kept beside this one (`LampSyncSettingsStore.Version`).
    ///
    /// Every part that is a join is joined: membership, the shared
    /// preferences and both deletion ledgers, so the result is the same
    /// whichever copy the store kept as current, and nothing either device
    /// recorded is lost. The apps' own settings stay as this copy has them:
    /// they are opaque here, and each app merges them from
    /// `Snapshot.versions` itself, before the write.
    ///
    /// A personal deletion ledger either copy holds that this client can't
    /// read stops the merge, as it stops a pass. The deck ledger is lenient
    /// everywhere, so here an unreadable one leaves this copy's as it is, and
    /// a newer client's is never rewritten in an older format.
    /// (`Verification/SyncMerge.lean`: `versionMerge`.)
    public mutating func merge(version other: LampSyncSettingsBundle) throws {
        manifest = manifest.merged(with: other.manifest)
        preferences = preferences.joined(with: other.preferences)
        personalDeletions = try Self.joined(personalDeletions, other.personalDeletions) { ours, theirs in
            var ledger = try LampPersonalDeletionLedger.decode(ours)
            ledger.merge(try LampPersonalDeletionLedger.decode(theirs))
            return try ledger.encoded()
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
