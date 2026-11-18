import Foundation
import Testing
@testable import LampCore

/// What a list of the library's decks shows, on the Mac and the phone.
struct LampPresentationShelfTests {
    private func day(_ n: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + n * 86_400) }

    private var shelf: LampPresentationShelf {
        LampPresentationShelf(decks: [
            .init(id: "easter", title: "Easter Sunday 2026", writingID: nil, writingTitle: nil, modified: day(1)),
            .init(id: "gideon", title: "Gideon: The Upper Hand", writingID: "w-gideon", writingTitle: "Gideon", modified: day(9)),
            .init(id: "psalm", title: "Psalm 23 Meditation", writingID: nil, writingTitle: nil, modified: day(5)),
            .init(id: "versions", title: "Why So Many Versions?", writingID: "w-versions",
                  writingTitle: "Why are there so many Bible versions?", modified: day(5)),
        ])
    }

    @Test func aFiltersCountFollowsTheSearch() {
        #expect(shelf.count(of: .all, query: "") == 4)
        #expect(shelf.count(of: .fromWriting, query: "") == 2)
        #expect(shelf.count(of: .standalone, query: "") == 2)
        // Judged: "All 8" over a search showing one deck said the opposite
        // of what was beneath it.
        #expect(shelf.count(of: .all, query: "easter") == 1)
        #expect(shelf.count(of: .fromWriting, query: "easter") == 0)
        #expect(shelf.count(of: .standalone, query: " Easter ") == 1)
    }

    @Test func aDeckIsFoundByItsWritingsTitleToo() {
        #expect(shelf.shown(filter: .all, sort: .title, query: "bible versions").map(\.id) == ["versions"])
        #expect(shelf.shown(filter: .standalone, sort: .title, query: "bible versions").isEmpty)
    }

    @Test func recentFirstOrByTitleAndTiesByTitle() {
        #expect(shelf.shown(filter: .all, sort: .recent, query: "").map(\.id) == ["gideon", "psalm", "versions", "easter"])
        #expect(shelf.shown(filter: .all, sort: .title, query: "").map(\.id) == ["easter", "gideon", "psalm", "versions"])
        #expect(shelf.shown(filter: .fromWriting, sort: .recent, query: "").map(\.id) == ["gideon", "versions"])
    }

    @Test func aDeckIsListedWithItsWritingOnlyWhenBuiltFromOne() {
        let deck = LampPresentationDeck.starter(
            title: "Gideon", source: LampPresentationSource(kind: .devotional, id: "w-gideon")
        )
        let listed = LampPresentationShelf.Deck(deck, modified: day(0)) { $0 == "w-gideon" ? "Gideon" : nil }
        #expect(listed.writingID == "w-gideon" && listed.writingTitle == "Gideon")
        let standalone = LampPresentationShelf.Deck(
            LampPresentationDeck.starter(title: "Easter"), modified: day(0)
        ) { _ in "unused" }
        #expect(standalone.writingID == nil && standalone.writingTitle == nil)
        // The format's other name for a writing counts the same.
        let named = LampPresentationShelf.Deck(
            LampPresentationDeck.starter(title: "Gideon", source: LampPresentationSource(kind: .writing, id: "w-gideon")),
            modified: day(0)
        ) { $0 == "w-gideon" ? "Gideon" : nil }
        #expect(named.writingID == "w-gideon" && named.writingTitle == "Gideon")
        let fromScripture = LampPresentationDeck.starter(title: "John 1", source: LampPresentationSource(kind: .scripture, id: "43001"))
        #expect(fromScripture.writingID == nil)
    }

    @Test func aDecksDateIsItsFilesByTheStoresOwnName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lamp-shelf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LampPresentationDeckStore(rootURL: root)
        var deck = LampPresentationDeck.starter(title: "Odd id")
        deck.id = "talks/deck: watch"
        try store.save(deck)
        let written = try #require(try store.deckFileURL(for: deck.id).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        #expect(store.modificationDate(ofDeck: deck.id) == written)
        #expect(store.modificationDate(ofDeck: "no such deck") == .distantPast)
    }
}
