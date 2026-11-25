import Foundation
import Testing
@testable import LampCore

/// `Documentation/decisions/0003`: a listing decodes only the deck files that
/// moved.
///
/// The decision rests on one claim — that a file's identity as `stat` reports
/// it cannot stay the same across a change — so these are mostly attempts to
/// change a deck without the cache noticing: rewritten in place, rewritten
/// with its date put back, replaced wholesale, removed and put back.
struct LampPresentationDeckListingCacheTests {
    private func store() throws -> (store: LampPresentationDeckStore, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-deck-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (LampPresentationDeckStore(rootURL: root), root)
    }

    private func deck(_ id: String, title: String) -> LampPresentationDeck {
        LampPresentationDeck(
            id: id,
            title: title,
            slides: [
                LampPresentationSlide(
                    layout: .titleAndBody,
                    blocks: [
                        LampPresentationBlock(kind: .title, text: title),
                        LampPresentationBlock(kind: .body, text: "A line of prose."),
                    ],
                    speakerNotes: "Notes."
                ),
            ]
        )
    }

    /// How many times this deck's own file has been read. Per file, because
    /// these tests run beside each other over libraries of their own.
    private func reads(_ store: LampPresentationDeckStore, _ id: String) -> Int {
        LampPresentationDeckCache.shared.readCount(at: store.deckFileURL(for: id))
    }

    @Test func listsAgainWithoutReadingTheFiles() throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 1...3 {
            let url = try store.save(deck("deck-\(index)", title: "Deck \(index)"))
            // Forget what the save remembered, so the first listing is cold.
            LampPresentationDeckCache.shared.forget(at: url)
        }

        let first = try store.decks()
        let second = try store.decks()

        #expect(first.count == 3)
        #expect(second == first)
        #expect((1...3).allSatisfy { reads(store, "deck-\($0)") == 1 })
    }

    /// A save drops what was held for that file rather than remembering what
    /// it wrote, so the deck a listing hands out always came from the file as
    /// it stands. The saving the cache is for is the decks nobody touched.
    @Test func aSavedDeckIsReadBackOnceAndThenNotAgain() throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.save(deck("deck-1", title: "Deck One"))

        #expect(try store.decks().map(\.title) == ["Deck One"])
        #expect(reads(store, "deck-1") == 1)
        #expect(try store.decks().map(\.title) == ["Deck One"])
        #expect(reads(store, "deck-1") == 1)

        // And a save over it is seen, which is the case the seeding risked:
        // the file's identity would have matched while the cache held the
        // deck from before.
        _ = try store.save(deck("deck-1", title: "Deck Two"))
        #expect(try store.decks().map(\.title) == ["Deck Two"])
    }

    /// The case `decisions/0001` refused to trust a modification date for: the
    /// file is rewritten in place, at the same size, with its date put back.
    /// The inode has not moved and `mtime` matches; `st_ctime` is the kernel's
    /// and has.
    /// On a volume whose identities mean nothing, every listing reads every
    /// file — which is the behaviour `0001` required and `0007` kept for the
    /// digest cache. The deck cache went in without that gate.
    ///
    /// The gate itself is the volume's device, so this asks the cache the
    /// question a listing asks it, with a device that is not the file's.
    @Test func onAnUntrustedVolumeNothingIsAnsweredFromTheCache() throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try store.save(deck("deck-1", title: "Deck"))
        let revision = try #require(try? LampDatabaseFileRevision(url: url))
        let cache = LampPresentationDeckCache.shared
        cache.forget(at: url)

        // Nothing vouched for: neither kept nor answered.
        cache.remember(deck("deck-1", title: "Deck"), at: url, revision: revision, on: nil)
        #expect(cache.deck(at: url, revision: revision, on: nil) == nil)
        // And not answered even once it is held, if the volume is not the
        // one the caller trusts.
        cache.remember(
            deck("deck-1", title: "Deck"), at: url, revision: revision, on: revision.device
        )
        #expect(cache.deck(at: url, revision: revision, on: revision.device) != nil)
        #expect(
            cache.deck(at: url, revision: revision, on: revision.device &+ 1) == nil,
            "a file on another device must not be answered for"
        )
    }

    @Test func noticesARewriteInPlaceWithTheDatePutBack() throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try store.save(deck("deck-1", title: "AAAA"))
        #expect(try store.decks().map(\.title) == ["AAAA"])
        let was = try #require(try url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate)
        let identityBefore = try LampDatabaseFileRevision(url: url)

        // Same length, so the file's size cannot give it away. Written in
        // place rather than atomically, so the inode cannot either.
        let rewritten = try LampPresentationDeckStore.encodedUnvalidated(
            deck("deck-1", title: "BBBB")
        )
        let original = try Data(contentsOf: url)
        #expect(rewritten.count == original.count)
        try rewritten.write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: was], ofItemAtPath: url.path
        )

        let after = try LampDatabaseFileRevision(url: url)
        #expect(after != identityBefore)
        #expect(try store.decks().map(\.title) == ["BBBB"])
    }

    @Test func noticesAReplacementAndARemoval() throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.save(deck("deck-1", title: "First"))
        _ = try store.save(deck("deck-2", title: "Second"))
        #expect(try store.decks().count == 2)

        // Replaced wholesale, as an agent or a sync pass writes one.
        try LampPresentationDeckStore.encodedUnvalidated(deck("deck-1", title: "Replaced"))
            .write(to: store.deckFileURL(for: "deck-1"), options: [.atomic])
        #expect(try store.decks().map(\.title).sorted() == ["Replaced", "Second"])

        try store.delete(id: "deck-2")
        #expect(try store.decks().map(\.title) == ["Replaced"])
    }

    /// A file the build cannot read is left out of the listing, and nothing is
    /// remembered about it — so when it becomes readable it appears, rather
    /// than staying absent because a listing once failed on it.
    @Test func aFileThatWillNotDecodeIsNotRemembered() throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.save(deck("deck-1", title: "Real"))
        let broken = store.deckFileURL(for: "deck-2")
        try Data("{ not a deck".utf8).write(to: broken)

        #expect(try store.decks().map(\.title) == ["Real"])
        try LampPresentationDeckStore.encodedUnvalidated(deck("deck-2", title: "Fixed"))
            .write(to: broken, options: [.atomic])
        #expect(try store.decks().map(\.title).sorted() == ["Fixed", "Real"])
    }

    /// Two stores on the same library share the cache, since the store is a
    /// value that callers make wherever they need one.
    @Test func twoStoresOverOneLibraryShareWhatWasRead() throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try store.save(deck("deck-1", title: "Shared"))
        LampPresentationDeckCache.shared.forget(at: url)
        _ = try store.decks()

        #expect(try LampPresentationDeckStore(rootURL: root).decks().map(\.title) == ["Shared"])
        #expect(reads(store, "deck-1") == 1)
    }
}
