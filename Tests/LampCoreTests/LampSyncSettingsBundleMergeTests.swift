import Foundation
import LampModuleKit
import Testing
@testable import LampCore

/// Folding in a copy of the bundle another device wrote at the same time.
struct LampSyncSettingsBundleMergeTests {
    @Test func bothDevicesDeletionsSurviveAndTheAppsOwnSettingsStay() throws {
        var mine = LampPersonalDeletionLedger()
        mine.recordDeletion(.note, "a", at: 5)
        var theirs = LampPersonalDeletionLedger()
        theirs.recordDeletion(.note, "b", at: 6)
        var myDecks = LampPresentationDeckDeletionLedger()
        myDecks.record("deck-1", at: Date(timeIntervalSince1970: 10))
        var theirDecks = LampPresentationDeckDeletionLedger()
        theirDecks.record("deck-2", at: Date(timeIntervalSince1970: 20))
        var current = LampSyncSettingsBundle(
            userSettings: Data("current".utf8), macSettings: Data("mac".utf8),
            personalDeletions: try mine.encoded(), deckDeletions: try myDecks.encoded()
        )
        try current.merge(version: LampSyncSettingsBundle(
            userSettings: Data("lost".utf8),
            personalDeletions: try theirs.encoded(), deckDeletions: try theirDecks.encoded()
        ))
        let deletions = try LampPersonalDeletionLedger.decode(try #require(current.personalDeletions))
        #expect(deletions.entry(.note, "a")?.deletedAt == 5)
        #expect(deletions.entry(.note, "b")?.deletedAt == 6)
        let decks = LampPresentationDeckDeletionLedger.decoded(from: try #require(current.deckDeletions))
        #expect(decks.deletedAt.keys.sorted() == ["deck-1", "deck-2"])
        #expect(current.userSettings == Data("current".utf8))
        #expect(current.macSettings == Data("mac".utf8))
    }

    @Test func aLedgerOnlyOneCopyHoldsIsKept() throws {
        var theirs = LampPersonalDeletionLedger()
        theirs.recordDeletion(.devotional, "d", at: 3)
        var current = LampSyncSettingsBundle()
        try current.merge(version: LampSyncSettingsBundle(personalDeletions: try theirs.encoded()))
        #expect(current.personalDeletions == (try theirs.encoded()))
    }

    /// An unreadable personal ledger stops a pass, so it stops the merge too,
    /// rather than resolving away another device's deletions.
    @Test func anUnreadablePersonalLedgerStopsTheMerge() throws {
        var current = LampSyncSettingsBundle(personalDeletions: try LampPersonalDeletionLedger().encoded())
        #expect(throws: (any Error).self) {
            try current.merge(version: LampSyncSettingsBundle(personalDeletions: Data("damaged".utf8)))
        }
    }

    /// The deck ledger is lenient everywhere: an unreadable one, or a newer
    /// client's, leaves this copy's as it is.
    @Test func anUnreadableDeckLedgerLeavesThisCopysAlone() throws {
        var mine = LampPresentationDeckDeletionLedger()
        mine.record("deck-1", at: Date(timeIntervalSince1970: 10))
        let newer = LampPresentationDeckDeletionLedger(formatVersion: 2, deletedAt: ["deck-2": Date()])
        var current = LampSyncSettingsBundle(deckDeletions: try newer.encoded())
        try current.merge(version: LampSyncSettingsBundle(deckDeletions: try mine.encoded()))
        #expect(current.deckDeletions == (try newer.encoded()))
    }
}
