import Foundation
import LampModuleKit

/// The deletion records a pass carries in the settings bundle, and the rules
/// every client follows with them.
///
/// Sync merges content as a union, so on its own a deletion is undone by the
/// next device that still has a copy. These two ledgers are what let each
/// device tell a copy that predates a deletion, which is dropped, from a
/// change made after it, which is kept.
///
/// They live in the bundle rather than beside the content: a ledger published
/// as an ordinary file would be won rather than merged, so two devices
/// deleting different things would overwrite each other's record, and
/// whatever the loser deleted would come back. In the bundle they go through
/// `update`'s read-merge-retry.
///
/// What a client does with a ledger, applying it to its own library, is the
/// client's. Each app extends this with that half. Applying comes before the
/// pass gathers what the library holds, or the client republishes what it
/// was told was deleted.
public enum LampSyncBundleLedgers {
    /// The bundle's record of deleted notes, writings and highlights, or nil
    /// when it has none or none this client can read.
    ///
    /// An unreadable ledger is skipped: it is no reason to stop syncing
    /// content, but it is a reason not to claim a deletion was applied.
    public static func personalDeletions(in bundle: LampSyncSettingsBundle) -> LampPersonalDeletionLedger? {
        bundle.personalDeletions.flatMap { try? LampPersonalDeletionLedger.decode($0) }
    }

    /// The bundle's record of deleted decks, or nil when it has none. Lenient,
    /// as the deck ledger is everywhere: an unreadable one reads as empty.
    public static func deckDeletions(in bundle: LampSyncSettingsBundle) -> LampPresentationDeckDeletionLedger? {
        bundle.deckDeletions.map(LampPresentationDeckDeletionLedger.decoded(from:))
    }

    /// This client's own records, read before the pass's update and put into
    /// the bundle inside it.
    ///
    /// Read before rather than inside, because the update's change must only
    /// compute, and may run more than once against a newer bundle.
    public struct Contribution: Sendable {
        public let personal: LampPersonalDeletionLedger
        public let decks: LampPresentationDeckDeletionLedger

        public init(
            personal: LampPersonalDeletionLedger,
            decks: LampPresentationDeckDeletionLedger = LampPresentationDeckDeletionLedger()
        ) {
            self.personal = personal
            self.decks = decks
        }

        /// Joins this client's records into the bundle being written.
        ///
        /// Joined, never replaced: the bundle may be newer than the one the
        /// pass read, since `update` re-applies its change when another device
        /// writes first, and replacing would drop that device's deletions.
        /// Both ledgers join by the later of each entry's times, so the order
        /// does not matter, and a client with nothing of its own leaves the
        /// bundle's exactly as it was, unreadable or not.
        ///
        /// A ledger this client cannot read is replaced by its own records,
        /// when it has any. Leaving it alone would lose this client's
        /// deletions on every pass, so a ledger format change has to travel
        /// with a bundle format older clients refuse.
        public func apply(to bundle: inout LampSyncSettingsBundle) throws {
            var personal = personal
            if let existing = LampSyncBundleLedgers.personalDeletions(in: bundle) {
                personal.merge(existing)
            }
            if !personal.isEmpty {
                bundle.personalDeletions = try personal.encoded()
            }

            var decks = decks
            if let existing = LampSyncBundleLedgers.deckDeletions(in: bundle) {
                decks.merge(existing)
            }
            if !decks.isEmpty {
                bundle.deckDeletions = try decks.encoded()
            }
        }
    }
}
