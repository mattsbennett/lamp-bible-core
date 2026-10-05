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

@Suite("Slide labels")
struct LampPresentationSlideLabelTests {
    private func slide(
        _ layout: LampPresentationSlideLayout,
        _ blocks: [LampPresentationBlock]
    ) -> LampPresentationSlide {
        LampPresentationSlide(layout: layout, blocks: blocks)
    }

    @Test("A title block names the slide")
    func prefersTitle() {
        let subject = slide(.titleAndBody, [
            .init(kind: .title, text: "Three Movements"),
            .init(kind: .body, text: "A long body that should not be used as the label"),
        ])
        #expect(subject.displayTitle == "Three Movements")
    }

    @Test("A scripture slide is named by its citation, not its passage")
    func prefersCitation() {
        let subject = slide(.scripture, [
            .init(
                kind: .scripture,
                text: "But while he was still a long way off, his father saw him and was filled with compassion for him."
            ),
            .init(kind: .citation, text: "Luke 15:20 (NIV)"),
        ])
        #expect(subject.displayTitle == "Luke 15:20 (NIV)")
    }

    @Test("A subtitle is used before body text")
    func prefersSubtitle() {
        let subject = slide(.title, [
            .init(kind: .subtitle, text: "Evening Service"),
            .init(kind: .body, text: "Some much longer supporting sentence goes here"),
        ])
        #expect(subject.displayTitle == "Evening Service")
    }

    @Test("Body text falls back to one shortened line")
    func shortensBody() {
        let subject = slide(.quotation, [
            .init(
                kind: .quotation,
                text: "He was not received as a servant, which is what he asked for, but as a son."
            ),
        ])
        let label = subject.displayTitle
        #expect(label.hasSuffix("…"))
        #expect(label.count <= 49)
        #expect(!label.contains("\n"))
        #expect(label.hasPrefix("He was not received as a servant"))
    }

    @Test("A short body is used whole, without an ellipsis")
    func keepsShortBody() {
        let subject = slide(.blank, [.init(kind: .body, text: "Pause here")])
        #expect(subject.displayTitle == "Pause here")
    }

    @Test("A multi-line list collapses to one line")
    func collapsesLists() {
        let subject = slide(.titleAndBody, [
            .init(kind: .body, text: "Pray\nListen\nRespond", listStyle: .ordered),
        ])
        #expect(subject.displayTitle == "Pray Listen Respond")
    }

    @Test("An image slide is named by its description")
    func usesAltText() {
        let subject = slide(.image, [
            .init(kind: .image, assetPath: "Assets/d/photo.jpg", altText: "The father embracing his son"),
        ])
        #expect(subject.displayTitle == "The father embracing his son")
    }

    @Test("A slide with nothing to say falls back to its layout")
    func fallsBackToLayout() {
        #expect(slide(.blank, []).displayTitle == "Blank")
        #expect(slide(.twoColumn, [.init(kind: .body, text: "   ")]).displayTitle == "Two Columns")
    }
}

@Suite("Presentation assets")
struct LampPresentationAssetTests {
    private func store() -> LampPresentationDeckStore {
        LampPresentationDeckStore(
            rootURL: URL(fileURLWithPath: "/tmp/lamp-library-\(UUID().uuidString)")
        )
    }

    @Test("An asset resolves beside the decks")
    func resolvesInsideTheLibrary() {
        let store = store()
        let url = store.assetURL(forAssetPath: "Assets/photo.jpg")
        #expect(url?.path == store.assetsDirectoryURL.appendingPathComponent("photo.jpg").path)
    }

    @Test("A path that climbs out of the library resolves to nothing")
    func refusesEscapingPaths() {
        let store = store()
        let refused = [
            "../../../etc/passwd",
            "Assets/../../secrets.txt",
            "/etc/passwd",
            "~/secrets.txt",
            "..",
            "",
            "   ",
            "Assets//photo.jpg",
            "Assets/.hidden.jpg",
            "C:\\Windows\\win.ini",
            "Assets\\photo.jpg",
        ]
        for path in refused {
            #expect(store.assetURL(forAssetPath: path) == nil, "resolved \(path)")
            #expect(!LampPresentationDeckValidator.isSafeAssetPath(path), "accepted \(path)")
        }
    }

    @Test("A deck naming a file outside the library fails validation")
    func validationRejectsEscapingPaths() {
        var deck = LampPresentationDeck.starter(title: "Pictures")
        deck.slides.append(
            LampPresentationSlide(
                layout: .image,
                blocks: [
                    LampPresentationBlock(
                        kind: .image,
                        assetPath: "../../../etc/passwd",
                        altText: "Nothing good"
                    ),
                ]
            )
        )

        let errors = LampPresentationDeckValidator.errors(in: deck)
        #expect(errors.contains { $0.path.hasSuffix("assetPath") })

        // And so cannot be decoded at all.
        let encoder = JSONEncoder()
        let data = try? encoder.encode(deck)
        #expect(data != nil)
        #expect((try? LampPresentationDeckStore.decode(data ?? Data())) == nil)
    }

    @Test("A well-formed image deck validates and resolves")
    func acceptsWellFormedAssets() throws {
        var deck = LampPresentationDeck.starter(title: "Pictures")
        deck.slides.append(
            LampPresentationSlide(
                layout: .image,
                blocks: [
                    LampPresentationBlock(
                        kind: .image,
                        assetPath: "Assets/\(UUID().uuidString.lowercased()).jpg",
                        altText: "The father embracing his son"
                    ),
                ]
            )
        )

        #expect(LampPresentationDeckValidator.errors(in: deck).isEmpty)
        let block = deck.slides.last!.blocks.first!
        #expect(store().assetURL(for: block) != nil)
    }

    @Test("Assets are read out of a sync archive, nested paths ignored")
    func readsAssetsFromArchive() {
        let archive = LampSyncArchive(entries: [
            .init(
                path: "\(LampPresentationDeckPortableLayout.assetsDirectoryPath)/photo.jpg",
                data: Data("image".utf8),
                modifiedAt: Date(timeIntervalSince1970: 100)
            ),
            .init(
                path: "\(LampPresentationDeckPortableLayout.assetsDirectoryPath)/nested/photo.jpg",
                data: Data("nope".utf8),
                modifiedAt: Date(timeIntervalSince1970: 200)
            ),
            .init(
                path: "\(LampPresentationDeckPortableLayout.directoryPath)/deck.lampdeck",
                data: Data("{}".utf8),
                modifiedAt: Date(timeIntervalSince1970: 300)
            ),
        ])

        let assets = archive.presentationAssetRevisions()
        #expect(assets.map(\.name) == ["photo.jpg"])
    }
}
