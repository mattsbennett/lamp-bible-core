import Foundation
import LampModuleKit
import Testing
@testable import LampCore

@Suite("Portable presentation decks")
struct LampPresentationDeckPortableTests {
    private func revision(
        _ deck: LampPresentationDeck,
        modifiedAt: Date
    ) throws -> LampPresentationDeckRevision {
        let store = LampPresentationDeckStore(rootURL: FileManager.default.temporaryDirectory)
        return LampPresentationDeckRevision(
            deck: deck,
            data: try store.encoded(deck),
            modifiedAt: modifiedAt
        )
    }

    private func entry(
        _ revision: LampPresentationDeckRevision,
        filename: String? = nil
    ) -> LampSyncArchive.Entry {
        let name = filename ?? "\(revision.id).lampdeck"
        return LampSyncArchive.Entry(
            path: "\(LampPresentationDeckPortableLayout.directoryPath)/\(name)",
            data: revision.data,
            modifiedAt: revision.modifiedAt
        )
    }

    @Test("The portable deck path matches the Mac's published folder layout")
    func layoutPaths() {
        #expect(LampPresentationDeckPortableLayout.directoryPath == "Workspaces/Presentations")
        #expect(
            LampPresentationDeckPortableLayout.deletionsPath
                == "Workspaces/Presentations/deleted-decks.json"
        )
        #expect(LampPresentationDeckPortableLayout.isDeckPath("Workspaces/Presentations/a.lampdeck"))
        #expect(LampPresentationDeckPortableLayout.isDeckPath("Workspaces/Presentations/A.LAMPDECK"))
    }

    @Test("Only deck files directly inside the presentations directory are read")
    func layoutRejectsOtherPaths() {
        let rejected = [
            "Workspaces/Presentations/deleted-decks.json",
            "Workspaces/Presentations/nested/a.lampdeck",
            "Workspaces/Presentations/.hidden.lampdeck",
            "Presentations/a.lampdeck",
            "Workspaces/Skills/a.lampdeck",
            "Workspaces/Presentations/a.json",
        ]
        for path in rejected {
            #expect(!LampPresentationDeckPortableLayout.isDeckPath(path), "accepted \(path)")
        }
    }

    @Test("Decks and deletions are read out of a decoded sync archive")
    func archiveReading() throws {
        let deck = try revision(
            LampPresentationDeck.starter(title: "Living Hope"),
            modifiedAt: Date(timeIntervalSince1970: 1_000)
        )
        var ledger = LampPresentationDeckDeletionLedger()
        ledger.record("removed-deck", at: Date(timeIntervalSince1970: 2_000))

        let archive = LampSyncArchive(entries: [
            entry(deck),
            LampSyncArchive.Entry(
                path: LampPresentationDeckPortableLayout.deletionsPath,
                data: try ledger.encoded(),
                modifiedAt: Date(timeIntervalSince1970: 2_000)
            ),
            LampSyncArchive.Entry(
                path: "Workspaces/Presentations/notes.txt",
                data: Data("ignored".utf8),
                modifiedAt: Date(timeIntervalSince1970: 3_000)
            ),
        ])

        let decks = archive.presentationDeckRevisions()
        #expect(decks.count == 1)
        #expect(decks.first?.deck.title == "Living Hope")
        #expect(archive.presentationDeckDeletions().deletedAt["removed-deck"] != nil)
    }

    @Test("An unreadable deck is skipped rather than failing the whole pull")
    func archiveSkipsInvalidDeck() throws {
        let good = try revision(
            LampPresentationDeck.starter(title: "Good"),
            modifiedAt: Date(timeIntervalSince1970: 1_000)
        )
        let archive = LampSyncArchive(entries: [
            entry(good),
            LampSyncArchive.Entry(
                path: "\(LampPresentationDeckPortableLayout.directoryPath)/broken.lampdeck",
                data: Data("{\"schemaVersion\":9}".utf8),
                modifiedAt: Date(timeIntervalSince1970: 5_000)
            ),
        ])

        #expect(archive.presentationDeckRevisions().map(\.deck.title) == ["Good"])
    }

    @Test("A damaged deletion ledger decodes as empty")
    func ledgerTolerance() {
        #expect(LampPresentationDeckDeletionLedger.decoded(from: Data("nonsense".utf8)).isEmpty)
        let future = Data("{\"formatVersion\":99,\"deletedAt\":{\"a\":0}}".utf8)
        #expect(LampPresentationDeckDeletionLedger.decoded(from: future).isEmpty)
    }

    @Test("A new deck is saved and a newer local copy is kept")
    func pullMergesByModificationTime() throws {
        var newer = LampPresentationDeck.starter(title: "Newer Local")
        newer.id = "shared"
        var older = LampPresentationDeck.starter(title: "Older Remote")
        older.id = "shared"
        let fresh = LampPresentationDeck.starter(title: "Only Remote")

        let plan = LampPresentationDeckPortablePull.plan(
            incoming: [
                try revision(older, modifiedAt: Date(timeIntervalSince1970: 100)),
                try revision(fresh, modifiedAt: Date(timeIntervalSince1970: 100)),
            ],
            deletions: LampPresentationDeckDeletionLedger(),
            local: [try revision(newer, modifiedAt: Date(timeIntervalSince1970: 900))]
        )

        #expect(plan.decksToSave.map(\.deck.title) == ["Only Remote"])
        #expect(plan.deckIDsToDelete.isEmpty)
    }

    @Test("An incoming deck newer than the local copy replaces it")
    func pullReplacesStaleLocalCopy() throws {
        var local = LampPresentationDeck.starter(title: "Stale")
        local.id = "shared"
        var incoming = LampPresentationDeck.starter(title: "Revised")
        incoming.id = "shared"

        let plan = LampPresentationDeckPortablePull.plan(
            incoming: [try revision(incoming, modifiedAt: Date(timeIntervalSince1970: 900))],
            deletions: LampPresentationDeckDeletionLedger(),
            local: [try revision(local, modifiedAt: Date(timeIntervalSince1970: 100))]
        )

        #expect(plan.decksToSave.map(\.deck.title) == ["Revised"])
    }

    @Test("A deletion stops a stale copy from coming back")
    func pullHonoursDeletions() throws {
        var deck = LampPresentationDeck.starter(title: "Deleted Elsewhere")
        deck.id = "shared"
        var ledger = LampPresentationDeckDeletionLedger()
        ledger.record("shared", at: Date(timeIntervalSince1970: 500))

        let plan = LampPresentationDeckPortablePull.plan(
            incoming: [try revision(deck, modifiedAt: Date(timeIntervalSince1970: 100))],
            deletions: ledger,
            local: []
        )

        #expect(plan.decksToSave.isEmpty)
        #expect(plan.deckIDsToDelete.isEmpty)
    }

    @Test("A deck deleted elsewhere is removed locally")
    func pullDeletesLocalCopy() throws {
        var deck = LampPresentationDeck.starter(title: "Going Away")
        deck.id = "shared"
        var ledger = LampPresentationDeckDeletionLedger()
        ledger.record("shared", at: Date(timeIntervalSince1970: 500))

        let plan = LampPresentationDeckPortablePull.plan(
            incoming: [],
            deletions: ledger,
            local: [try revision(deck, modifiedAt: Date(timeIntervalSince1970: 100))]
        )

        #expect(plan.decksToSave.isEmpty)
        #expect(plan.deckIDsToDelete == ["shared"])
    }

    @Test("A deck saved after it was deleted elsewhere survives")
    func pullKeepsDeckSavedAfterDeletion() throws {
        var deck = LampPresentationDeck.starter(title: "Resaved")
        deck.id = "shared"
        var ledger = LampPresentationDeckDeletionLedger()
        ledger.record("shared", at: Date(timeIntervalSince1970: 500))

        let plan = LampPresentationDeckPortablePull.plan(
            incoming: [try revision(deck, modifiedAt: Date(timeIntervalSince1970: 900))],
            deletions: ledger,
            local: []
        )

        #expect(plan.decksToSave.map(\.deck.title) == ["Resaved"])
        #expect(plan.deckIDsToDelete.isEmpty)
    }

    @Test("Two copies of the same deck resolve to the newest once")
    func pullResolvesDuplicateIDs() throws {
        var old = LampPresentationDeck.starter(title: "Old")
        old.id = "shared"
        var new = LampPresentationDeck.starter(title: "New")
        new.id = "shared"

        let plan = LampPresentationDeckPortablePull.plan(
            incoming: [
                try revision(new, modifiedAt: Date(timeIntervalSince1970: 900)),
                try revision(old, modifiedAt: Date(timeIntervalSince1970: 100)),
            ],
            deletions: LampPresentationDeckDeletionLedger(),
            local: []
        )

        #expect(plan.decksToSave.map(\.deck.title) == ["New"])
    }
}
