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

    /// Reading state travels in its own part, joined, and not in the
    /// Mac's settings, where the newer copy would replace it whole.
    @Test func theMacsSettingsLeaveBookReadingToItsPart() {
        #expect(!LampPortableSettingsCodec.syncedKeys.contains(LampBookReadingStateStore.defaultsKey))
    }

    // MARK: - Finding the block again

    private func paragraph(_ text: String) -> LampBookContentBlock {
        LampBookContentBlock(type: "paragraph", content: LampBookAnnotatedText(text: text))
    }

    private let opening = "In the beginning of the third chapter the writer turns to the promises."
    private let middle = "These promises were made to Abraham and to his seed, which is Christ."
    private let closing = "So the inheritance is not of the law, but of promise."

    @Test func anAnchorIsTheStartOfABlocksTextWithItsSpacingCollapsed() {
        let anchor = LampBookReadingPosition.anchor(of: paragraph("  In the\n beginning   of the third chapter the writer turns"))
        #expect(anchor == "In the beginning of the third chapter the writer")
        #expect(anchor?.count == LampBookReadingPosition.anchorLength)
        #expect(LampBookReadingPosition.anchor(of: LampBookContentBlock(type: "image", mediaID: "m1")) == nil)
    }

    @Test func aPositionAtTheTopOfASectionHasNoAnchor() {
        let blocks = [paragraph(opening)]
        #expect(LampBookReadingPosition(sectionID: "ch-3", blockIndex: -1, in: blocks).anchor == nil)
        #expect(LampBookReadingPosition(sectionID: "ch-3", blockIndex: 0, in: blocks).anchor != nil)
    }

    @Test func aBlockStillWhereItWasOpensThere() {
        let blocks = [paragraph(opening), paragraph(middle), paragraph(closing)]
        let position = LampBookReadingPosition(sectionID: "ch-3", blockIndex: 1, in: blocks)
        #expect(position.blockIndex(in: blocks) == 1)
    }

    /// A rebuild that joins a paragraph to the one before it: the place is
    /// inside the joined paragraph, not the block that took its number.
    @Test func aParagraphJoinedToTheOneBeforeItIsFoundInside() {
        let before = [paragraph(opening), paragraph(middle), paragraph(closing)]
        let position = LampBookReadingPosition(sectionID: "ch-3", blockIndex: 1, in: before)
        let after = [paragraph(opening + " " + middle), paragraph(closing)]

        #expect(position.blockIndex(in: after) == 0)
    }

    @Test func aParagraphMovedByABlockBeforeItIsFoundWhereItWent() {
        let before = [paragraph(opening), paragraph(middle), paragraph(closing)]
        let position = LampBookReadingPosition(sectionID: "ch-3", blockIndex: 2, in: before)
        let after = [paragraph("A heading"), paragraph(opening), paragraph(middle), paragraph(closing)]

        #expect(position.blockIndex(in: after) == 3)
    }

    /// Of two blocks holding the anchor, the one nearer where it was, so a
    /// recurring line opens at the same block on both apps.
    @Test func aRepeatedPassageOpensAtTheNearerOne() {
        let blocks = [paragraph(middle), paragraph(opening), paragraph(opening), paragraph(closing), paragraph(middle)]
        let position = LampBookReadingPosition(sectionID: "ch-3", blockIndex: 3, anchor: String(middle.prefix(48)))
        #expect(position.blockIndex(in: blocks) == 4)
        // Two as near, 0 and 4 from 2: the earlier.
        let between = LampBookReadingPosition(sectionID: "ch-3", blockIndex: 2, anchor: String(middle.prefix(48)))
        #expect(between.blockIndex(in: blocks) == 0)
    }

    /// With no anchor, or one no block holds, the index is all there is: its
    /// own while the section reaches it, or else the top.
    @Test func withNothingToFindTheIndexStandsOrTheTop() {
        let blocks = [paragraph(opening), paragraph(closing)]
        #expect(LampBookReadingPosition(sectionID: "ch-3", blockIndex: 1).blockIndex(in: blocks) == 1)
        #expect(LampBookReadingPosition(sectionID: "ch-3", blockIndex: 7).blockIndex(in: blocks) == -1)
        let lost = LampBookReadingPosition(sectionID: "ch-3", blockIndex: 1, anchor: "Words no block holds any longer")
        #expect(lost.blockIndex(in: blocks) == 1)
        #expect(LampBookReadingPosition(sectionID: "ch-3", blockIndex: -1).blockIndex(in: blocks) == -1)
    }

    /// A position with no anchor encodes as it did before anchors, so a reader
    /// from then sees nothing new.
    @Test func aPositionWithoutAnAnchorEncodesAsBefore() throws {
        let plain = try JSONEncoder().encode(LampBookReadingPosition(sectionID: "ch-1", blockIndex: 2, at: 5))
        #expect(!String(decoding: plain, as: UTF8.self).contains("anchor"))

        var reading = LampSyncBookReading()
        reading.record(LampBookReadingPosition(sectionID: "ch-1", blockIndex: 2, at: 5, anchor: "In the beginning"), for: "book")
        #expect(try LampSyncBookReading.decode(reading.encoded()).positions["book"]?.anchor == "In the beginning")
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
