import Foundation
import LampModuleKit
import Testing
@testable import LampCore

/// The rules every client follows with the bundle's deletion records.
struct LampSyncBundleLedgersTests {
    private func ledger(_ key: String, deletedAt: Int64) -> LampPersonalDeletionLedger {
        var ledger = LampPersonalDeletionLedger()
        ledger.recordDeletion(.note, key, at: deletedAt)
        return ledger
    }

    /// Joined, never replaced: another device's deletions stay, beside this
    /// one's.
    @Test func aContributionJoinsAnotherDevicesDeletions() throws {
        var bundle = LampSyncSettingsBundle(personalDeletions: try ledger("theirs", deletedAt: 5).encoded())
        var decks = LampPresentationDeckDeletionLedger()
        decks.record("easter", at: Date(timeIntervalSince1970: 10))
        bundle.deckDeletions = try decks.encoded()
        var mine = LampPresentationDeckDeletionLedger()
        mine.record("advent", at: Date(timeIntervalSince1970: 20))

        try LampSyncBundleLedgers.Contribution(personal: ledger("mine", deletedAt: 6), decks: mine)
            .apply(to: &bundle)

        let personal = try #require(LampSyncBundleLedgers.personalDeletions(in: bundle))
        #expect(personal.entry(.note, "theirs")?.deletedAt == 5)
        #expect(personal.entry(.note, "mine")?.deletedAt == 6)
        #expect(LampSyncBundleLedgers.deckDeletions(in: bundle)?.deletedAt.keys.sorted() == ["advent", "easter"])
    }

    /// A client with nothing of its own leaves the bundle's records exactly
    /// as they were, readable or not, and touches nothing else.
    @Test func anEmptyContributionLeavesTheBundleAlone() throws {
        let damaged = Data("not a ledger".utf8)
        var bundle = LampSyncSettingsBundle(
            userSettings: Data("phone".utf8), personalDeletions: damaged, deckDeletions: damaged
        )
        let before = bundle
        try LampSyncBundleLedgers.Contribution(personal: LampPersonalDeletionLedger()).apply(to: &bundle)
        #expect(bundle == before)
    }

    /// An unreadable record is skipped where it is read, never a reason to
    /// stop, and never reported as applied.
    @Test func anUnreadableRecordIsSkippedWhereItIsRead() throws {
        let bundle = LampSyncSettingsBundle(personalDeletions: Data("not a ledger".utf8))
        #expect(LampSyncBundleLedgers.personalDeletions(in: bundle) == nil)
        #expect(LampSyncBundleLedgers.personalDeletions(in: LampSyncSettingsBundle()) == nil)
        #expect(LampSyncBundleLedgers.deckDeletions(in: LampSyncSettingsBundle()) == nil)
    }

    /// The one cost, stated so nobody is surprised by it: this client's own
    /// records take the place of a ledger it cannot read. A ledger format
    /// change has to travel with a bundle format older clients refuse.
    @Test func aClientsRecordsTakeThePlaceOfALedgerItCannotRead() throws {
        var bundle = LampSyncSettingsBundle(personalDeletions: Data("from a newer client".utf8))
        try LampSyncBundleLedgers.Contribution(personal: ledger("mine", deletedAt: 6)).apply(to: &bundle)
        #expect(LampSyncBundleLedgers.personalDeletions(in: bundle)?.entry(.note, "mine")?.deletedAt == 6)
    }
}
