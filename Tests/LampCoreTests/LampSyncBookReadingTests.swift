import Foundation
import Testing
@testable import LampCore
@testable import LampModuleKit

struct LampSyncBookReadingTests {
    private func withStore(_ body: (LampBookReadingStateStore, UserDefaults) throws -> Void) throws {
        let suiteName = "LampSyncBookReadingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(LampBookReadingStateStore(defaults: defaults), defaults)
    }

    // MARK: - The Mac's format from before sync

    /// What the Mac stored before this synced, dates as Foundation's default:
    /// seconds since 2001.
    @Test func readsTheMacsUnversionedFormat() throws {
        let stored = Data("""
        {"positions":{"elpis-israel":{"sectionID":"elpis-israel:chapter-4","blockIndex":37,"updatedAt":783000000}},\
        "bookmarks":{"elpis-israel":["elpis-israel:chapter-1"]}}
        """.utf8)
        let reading = try LampSyncBookReading.decode(stored)

        let position = try #require(reading.positions["elpis-israel"])
        #expect(position.sectionID == "elpis-israel:chapter-4")
        #expect(position.blockIndex == 37)
        #expect(position.updatedAt == Date(timeIntervalSinceReferenceDate: 783_000_000))
        #expect(reading.bookmarkedSections(in: "elpis-israel") == ["elpis-israel:chapter-1"])
        // Held since a time unknown, so any recorded change outranks it.
        #expect(reading.bookmarks["elpis-israel"]?["elpis-israel:chapter-1"] == .init(presentSince: 0))
    }

    /// A bookmark the Mac held before sync, removed on the other device, stays
    /// removed on both.
    @Test func aRemovalOutranksABookmarkFromBeforeSync() throws {
        let stored = Data(#"{"bookmarks":{"book":["chapter-2"]}}"#.utf8)
        var mac = try LampSyncBookReading.decode(stored)
        var phone = mac
        phone.recordUnbookmark("chapter-2", in: "book", at: 1_000)

        mac.merge(phone)
        phone.merge(try LampSyncBookReading.decode(stored))

        #expect(mac.bookmarkedSections(in: "book").isEmpty)
        #expect(phone.bookmarkedSections(in: "book").isEmpty)
    }

    @Test func refusesALaterFormat() {
        #expect(throws: (any Error).self) {
            try LampSyncBookReading.decode(Data(#"{"formatVersion":2,"positions":{}}"#.utf8))
        }
    }

    @Test func encodesTheSameRecordToTheSameBytes() throws {
        var reading = LampSyncBookReading()
        reading.record(LampBookReadingPosition(sectionID: "b", blockIndex: 3, at: 5), for: "two")
        reading.record(LampBookReadingPosition(sectionID: "a", blockIndex: 1, at: 7), for: "one")
        reading.recordBookmark("z", in: "one", at: 1)
        reading.recordBookmark("y", in: "one", at: 2)

        let encoded = try reading.encoded()
        #expect(try LampSyncBookReading.decode(encoded) == reading)
        #expect(try LampSyncBookReading.decode(encoded).encoded() == encoded)
    }

    // MARK: - Recording

    /// A move on a clock behind the device that recorded the position it moves
    /// from still stands.
    @Test func aMoveIsStampedAfterThePositionItReplaces() {
        var reading = LampSyncBookReading()
        reading.record(LampBookReadingPosition(sectionID: "ch-1", blockIndex: 0, at: 10_000), for: "book")
        reading.record(LampBookReadingPosition(sectionID: "ch-2", blockIndex: 4, at: 5_000), for: "book")

        #expect(reading.positions["book"] == LampBookReadingPosition(sectionID: "ch-2", blockIndex: 4, at: 10_001))
    }

    /// Opening a book where another device left it records nothing, so it
    /// doesn't make that place newer than it is.
    @Test func aPositionAlreadyHeldRecordsNothing() {
        var reading = LampSyncBookReading()
        reading.record(LampBookReadingPosition(sectionID: "ch-1", blockIndex: 2, at: 1_000), for: "book")

        let recorded = reading.record(LampBookReadingPosition(sectionID: "ch-1", blockIndex: 2, at: 9_000), for: "book")
        #expect(!recorded)
        #expect(reading.positions["book"]?.at == 1_000)
    }

    // MARK: - Joining

    @Test func twoDevicesAgreeWhicheverWayTheyExchange() {
        var mac = LampSyncBookReading()
        mac.record(LampBookReadingPosition(sectionID: "ch-3", blockIndex: 1, at: 2_000), for: "book")
        mac.recordBookmark("ch-1", in: "book", at: 1_000)
        var phone = LampSyncBookReading()
        phone.record(LampBookReadingPosition(sectionID: "ch-5", blockIndex: 0, at: 3_000), for: "book")
        phone.record(LampBookReadingPosition(sectionID: "intro", blockIndex: -1, at: 500), for: "other")
        phone.recordUnbookmark("ch-1", in: "book", at: 1_500)

        var macThenPhone = mac
        macThenPhone.merge(phone)
        var phoneThenMac = phone
        phoneThenMac.merge(mac)

        #expect(macThenPhone == phoneThenMac)
        #expect(macThenPhone.positions["book"]?.sectionID == "ch-5")
        #expect(macThenPhone.positions["other"]?.sectionID == "intro")
        #expect(macThenPhone.bookmarkedSections(in: "book").isEmpty)
    }

    // MARK: - The store

    @Test func theStoreKeepsPositionsAndBookmarksPerBook() throws {
        try withStore { store, _ in
            let position = LampBookReadingPosition(
                sectionID: "book-a:chapter-2",
                blockIndex: 9,
                updatedAt: Date(timeIntervalSince1970: 100)
            )

            store.save(position: position, for: "book-a")
            #expect(store.position(for: "book-a") == position)
            #expect(store.position(for: "book-b") == nil)
            #expect(store.positions() == ["book-a": position])
            #expect(store.toggleBookmark(sectionID: "chapter-2", for: "book-a"))
            #expect(store.bookmarkIDs(for: "book-a") == ["chapter-2"])
            #expect(!store.toggleBookmark(sectionID: "chapter-2", for: "book-a"))
            #expect(store.bookmarkIDs(for: "book-a").isEmpty)
        }
    }

    /// The Mac's stored state from before sync is read in place, under the
    /// same key, so updating doesn't lose anyone's place.
    @Test func theStoreReadsWhatTheMacStoredBeforeSync() throws {
        try withStore { store, defaults in
            defaults.set(
                Data(#"{"positions":{"book":{"sectionID":"ch-4","blockIndex":2,"updatedAt":783000000}},"bookmarks":{"book":["ch-1"]}}"#.utf8),
                forKey: LampBookReadingStateStore.defaultsKey
            )

            #expect(store.position(for: "book")?.sectionID == "ch-4")
            #expect(store.bookmarkIDs(for: "book") == ["ch-1"])
        }
    }

    @Test func theStoreSaysWhetherAPassChangedAnything() throws {
        try withStore { store, _ in
            store.save(position: LampBookReadingPosition(sectionID: "ch-1", blockIndex: 0, at: 1_000), for: "book")
            var incoming = store.ledger()

            #expect(!store.merge(incoming))
            incoming.record(LampBookReadingPosition(sectionID: "ch-2", blockIndex: 0, at: 2_000), for: "book")
            #expect(store.merge(incoming))
            #expect(store.position(for: "book")?.sectionID == "ch-2")
        }
    }

    // MARK: - The bundle

    @Test func theBundleCarriesItsBookReading() throws {
        var reading = LampSyncBookReading()
        reading.record(LampBookReadingPosition(sectionID: "ch-1", blockIndex: 0, at: 1_000), for: "book")
        let bundle = LampSyncSettingsBundle(bookReading: try reading.encoded())

        let decoded = try LampSyncSettingsBundle.decode(try bundle.encoded())
        #expect(decoded == bundle)
        #expect(LampSyncBundleLedgers.bookReading(in: decoded) == reading)
    }

    // MARK: - The scroll buffer

    @Test func theScrollBufferDefersAndCoalescesPersistence() {
        var buffer = LampBookReadingPositionBuffer(blockIndex: 2)

        buffer.observe(visibleBlockIndices: [4, 3, 5])
        buffer.observe(visibleBlockIndices: [7, 6])

        #expect(buffer.blockIndex == 6)
        #expect(buffer.takeChangedBlockIndex() == 6)
        #expect(buffer.takeChangedBlockIndex() == nil)

        buffer.observe(visibleBlockIndices: [])
        #expect(buffer.blockIndex == 6)
        #expect(buffer.takeChangedBlockIndex() == nil)
    }
}
