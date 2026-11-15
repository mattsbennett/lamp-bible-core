import Foundation
import GRDB
import Testing
@testable import LampModuleKit

/// Bundle format 4 renames writing in the per-file layout. These hold the
/// rename itself and the move a format-4 client makes of a format-3 library
/// the first time it reads one.
struct LampSyncFormatFourMoveTests {
    // MARK: - The rename

    @Test func writingIsRenamedAndEverythingElseStays() {
        let cases: [(String, String?)] = [
            ("Devotionals/devotionals.lamp", "Writing/writing.lamp"),
            ("Devotionals/sermons.lamp", "Writing/sermons.lamp"),
            // A module already called `writing` is not carried: its new path
            // is the collection's.
            ("Devotionals/writing.lamp", nil),
            ("DevotionalMedia/writing/w1/a.jpg", nil),
            ("DevotionalMedia/devotionals/w1/a.jpg", "WritingMedia/writing/w1/a.jpg"),
            ("DevotionalMedia/sermons/w1/a.jpg", "WritingMedia/sermons/w1/a.jpg"),
            ("Translations/kjv.lamp", "Translations/kjv.lamp"),
            ("Notes/notes.lamp", "Notes/notes.lamp"),
            ("NoteMedia/notes/43011035/x.png", "NoteMedia/notes/43011035/x.png"),
            ("BookMedia/atonement/plate.jpg", "BookMedia/atonement/plate.jpg"),
            ("Workspaces/Presentations/talk.lampdeck", "Workspaces/Presentations/talk.lampdeck"),
            ("Workspaces/Devotionals/talk/Documents/a.md", "Workspaces/Devotionals/talk/Documents/a.md"),
            // Format 3 held nothing in format 4's folders.
            ("Writing/writing.lamp", nil),
            ("WritingMedia/writing/w1/a.jpg", nil),
            // Nor these, which neither layout holds.
            ("Devotionals/daily.md", nil),
            ("Devotionals/daily.json", nil),
            ("DevotionalMedia/m/a.png", nil),
            ("Devotionals/.hidden.lamp", nil),
            ("Unknown/a.lamp", nil),
            ("lamp-bible.lampsync", nil),
        ]
        for (formatThree, formatFour) in cases {
            #expect(LampSyncFolderLayout.formatFourPath(ofFormatThree: formatThree) == formatFour, "\(formatThree)")
        }
    }

    /// What it moves to is format 4's layout, and the same kind it was.
    @Test func aRenamedPathIsInFormatFoursLayoutAsTheSameKind() {
        #expect(LampSyncFolderLayout.kind(of: "Writing/writing.lamp") == .module(.devotionals))
        #expect(LampSyncFolderLayout.kind(of: "WritingMedia/writing/w1/a.jpg") == .devotionalMedia)
        #expect(LampSyncFolderLayout.kind(of: "Devotionals/devotionals.lamp") == nil)
        #expect(LampSyncFolderLayout.kind(of: "DevotionalMedia/devotionals/w1/a.jpg") == nil)
        #expect(LampSyncLocalDeletion.target(of: "Writing/writing.lamp") == .collection)
        #expect(LampSyncLocalDeletion.target(of: "Writing/devotionals.lamp") == .module("devotionals"))
    }

    /// Where a format-4 writing path was moved from, which a late arrival is
    /// looked for beside.
    @Test func eachMovedPathSaysWhereItCameFrom() {
        for path in ["Devotionals/devotionals.lamp", "Devotionals/sermons.lamp", "DevotionalMedia/devotionals/w/a.png",
                     "DevotionalMedia/sermons/w/a.png", "Translations/kjv.lamp"] {
            let moved = LampSyncFolderLayout.formatFourPath(ofFormatThree: path)!
            #expect(LampSyncFolderLayout.formatThreePath(ofFormatFour: moved) == path)
        }
    }

    // MARK: - The manifest

    @Test func theManifestMovesWithItsTimesAndWithoutItsOldRevisions() throws {
        let manifest = try formatThreeManifest([
            ("Devotionals/devotionals.lamp", 5, "\"a\"", nil, nil),
            ("Devotionals/sermons.lamp", 6, "\"b\"", nil, nil),
            ("Devotionals/old.lamp", 1, "\"c\"", 9, "\"c\""),
            ("Translations/kjv.lamp", 4, "\"d\"", nil, nil),
            ("Future/thing.lamp", 3, "\"e\"", nil, nil),
            ("Writing/stray.lamp", 3, "\"f\"", nil, nil),
        ])
        let moved = manifest.formatFour(copied: ["Devotionals/devotionals.lamp": "\"w1\""])

        #expect(moved.paths == [
            "Writing/writing.lamp", "Writing/sermons.lamp", "Writing/old.lamp",
            "Translations/kjv.lamp", "Future/thing.lamp",
        ])
        let collection = try #require(moved.entry(at: "Writing/writing.lamp"))
        #expect(collection.isMember && collection.presentSince == 5 && collection.revision == "\"w1\"")
        // Not copied: a member still, compared by value when next seen.
        let sermons = try #require(moved.entry(at: "Writing/sermons.lamp"))
        #expect(sermons.isMember && sermons.revision == nil)
        // Still deleted, of whatever copy turns up.
        let old = try #require(moved.entry(at: "Writing/old.lamp"))
        #expect(!old.isMember && old.deletedAt == 9 && old.revision == nil && old.deletedRevision == nil)
        // Untouched by the rename.
        #expect(moved.entry(at: "Translations/kjv.lamp") == manifest.entry(at: "Translations/kjv.lamp"))
        #expect(moved.entry(at: "Future/thing.lamp") == manifest.entry(at: "Future/thing.lamp"))
    }

    // MARK: - The bundle

    @Test func formatThreeIsToldApartAndReadOnlyForTheMove() throws {
        let bundle = LampSyncSettingsBundle(manifest: try formatThreeManifest([
            ("Devotionals/devotionals.lamp", 5, "\"a\"", nil, nil),
        ]))
        let three = try bundle.encoded(version: 3)
        #expect(LampSyncSettingsBundle.contents(ofHeader: try LampSyncSettingsBundle.header(of: three)) == .formatThreeBundle)
        #expect(throws: LampSyncSettingsBundle.BundleError.isFormatThree) { try LampSyncSettingsBundle.decode(three) }
        #expect(try LampSyncSettingsBundle.decodeFormatThree(three) == bundle)

        let four = try bundle.encoded()
        #expect(LampSyncSettingsBundle.contents(ofHeader: try LampSyncSettingsBundle.header(of: four)) == .bundle)
        #expect(throws: LampSyncSettingsBundle.BundleError.damaged) { try LampSyncSettingsBundle.decodeFormatThree(four) }

        let five = try bundle.encoded(version: 5)
        #expect(throws: LampSyncSettingsBundle.BundleError.unsupportedVersion(5)) { try LampSyncSettingsBundle.decode(five) }
        // Said in words a person can act on.
        #expect(LampSyncSettingsBundle.BundleError.unsupportedVersion(5).localizedDescription.contains("Update Lamp Bible"))
    }

    // MARK: - The move

    @Test func aReadMovesAFormatThreeLibrary() async throws {
        let store = MoveStore()
        let collection = try writingCollection(id: "devotionals")
        store.put("Devotionals/devotionals.lamp", collection, "\"a\"")
        store.put("Devotionals/sermons.lamp", Data("sermons".utf8), "\"b\"")
        store.put("DevotionalMedia/devotionals/w1/a.jpg", Data("jpeg".utf8), "\"c\"")
        store.put("Translations/kjv.lamp", Data("kjv".utf8), "\"d\"")
        store.put("Devotionals/old.lamp", Data("deleted, not yet reaped".utf8), "\"e\"")
        // Dropped in by hand: no manifest names it, and a listing finds it.
        store.put("Devotionals/dropped.lamp", Data("dropped".utf8), "\"f\"")
        let formatThree = LampSyncSettingsBundle(
            userSettings: Data("settings".utf8),
            manifest: try formatThreeManifest([
                ("Devotionals/devotionals.lamp", 5, "\"a\"", nil, nil),
                ("Devotionals/sermons.lamp", 6, "\"b\"", nil, nil),
                ("DevotionalMedia/devotionals/w1/a.jpg", 6, "\"c\"", nil, nil),
                ("Translations/kjv.lamp", 4, "\"d\"", nil, nil),
                ("Devotionals/old.lamp", 1, "\"e\"", 9, "\"e\""),
                // A member nobody uploaded yet.
                ("Devotionals/pending.lamp", 7, nil, nil, nil),
            ])
        )
        store.put(LampSyncSettingsStore.path, try formatThree.encoded(version: 3), "\"bundle3\"")

        let snapshot = try #require(try await LampSyncSettingsStore.read(from: store, patience: .immediate))

        // Written as format 4, under the revision read.
        #expect(!snapshot.mustBeWritten)
        let written = try #require(store.data(LampSyncSettingsStore.path))
        #expect(try LampSyncSettingsBundle.decode(written) == snapshot.bundle)
        #expect(store.conditions[LampSyncSettingsStore.path] == [.ifRevision("\"bundle3\"")])
        #expect(snapshot.bundle.userSettings == Data("settings".utf8))

        let manifest = snapshot.bundle.manifest
        #expect(manifest.paths == [
            "Writing/writing.lamp", "Writing/sermons.lamp", "WritingMedia/writing/w1/a.jpg",
            "Translations/kjv.lamp", "Writing/old.lamp", "Writing/pending.lamp",
        ])
        for path in ["Writing/writing.lamp", "Writing/sermons.lamp", "WritingMedia/writing/w1/a.jpg"] {
            #expect(manifest.entry(at: path)?.revision == store.revision(of: path), "\(path)")
        }
        #expect(manifest.entry(at: "Writing/pending.lamp")?.isMember == true)
        #expect(manifest.entry(at: "Writing/old.lamp")?.isMember == false)

        // Each member copied; the collection says what it is now called.
        #expect(store.data("Writing/sermons.lamp") == Data("sermons".utf8))
        #expect(store.data("WritingMedia/writing/w1/a.jpg") == Data("jpeg".utf8))
        #expect(store.data("Writing/dropped.lamp") == Data("dropped".utf8))
        let renamed = try moduleIDs(inCollection: try #require(store.data("Writing/writing.lamp")))
        #expect(renamed == ["module_format": ["writing"], "module_meta": ["writing"], "devotional_entries": ["writing", "writing"]])
        #expect(try writingTitles(inCollection: try #require(store.data("Writing/writing.lamp"))) == ["Morning", "Evening"])
        // A deletion's file is not carried, and nothing old is removed.
        #expect(store.data("Writing/old.lamp") == nil)
        #expect(store.data("Devotionals/devotionals.lamp") == collection)
        #expect(store.data("Translations/kjv.lamp") == Data("kjv".utf8))
        // Every copy only where nothing was.
        for path in ["Writing/writing.lamp", "Writing/sermons.lamp", "WritingMedia/writing/w1/a.jpg", "Writing/dropped.lamp"] {
            #expect(store.conditions[path] == [.ifAbsent], "\(path)")
        }
    }

    @Test func aMovedLibraryIsReadAsItIs() async throws {
        let store = MoveStore()
        store.put("Devotionals/sermons.lamp", Data("sermons".utf8), "\"b\"")
        store.put(LampSyncSettingsStore.path, try LampSyncSettingsBundle(manifest: try formatThreeManifest([
            ("Devotionals/sermons.lamp", 6, "\"b\"", nil, nil),
        ])).encoded(version: 3), "\"bundle3\"")
        let first = try #require(try await LampSyncSettingsStore.read(from: store, patience: .immediate))
        let writes = store.writeCount

        let second = try #require(try await LampSyncSettingsStore.read(from: store, patience: .immediate))
        #expect(second == first)
        #expect(store.writeCount == writes)
    }

    /// Another device wrote the bundle after the copies and before the move's
    /// write: a format-3 device, editing one writing module and publishing
    /// another the copies missed. The write is refused, and the move reads
    /// again, carries the new one, and replaces its own copy of the old.
    @Test func aBundleWrittenDuringTheMoveIsMovedAgain() async throws {
        let store = MoveStore()
        store.put("Devotionals/sermons.lamp", Data("sermons".utf8), "\"b\"")
        let before = LampSyncSettingsBundle(manifest: try formatThreeManifest([
            ("Devotionals/sermons.lamp", 6, "\"b\"", nil, nil),
        ]))
        store.put(LampSyncSettingsStore.path, try before.encoded(version: 3), "\"bundle3\"")
        let after = LampSyncSettingsBundle(manifest: try formatThreeManifest([
            ("Devotionals/sermons.lamp", 9, "\"b2\"", nil, nil),
            ("Devotionals/advent.lamp", 8, "\"g\"", nil, nil),
        ]))
        store.beforeBundleWrite = {
            store.put("Devotionals/sermons.lamp", Data("sermons, edited".utf8), "\"b2\"")
            store.put("Devotionals/advent.lamp", Data("advent".utf8), "\"g\"")
            store.put(LampSyncSettingsStore.path, try after.encoded(version: 3), "\"bundle3b\"")
        }

        let snapshot = try #require(try await LampSyncSettingsStore.read(from: store, patience: .immediate))

        #expect(snapshot.bundle.manifest.paths == ["Writing/sermons.lamp", "Writing/advent.lamp"])
        #expect(store.data("Writing/advent.lamp") == Data("advent".utf8))
        #expect(store.data("Writing/sermons.lamp") == Data("sermons, edited".utf8))
        #expect(snapshot.bundle.manifest.entry(at: "Writing/sermons.lamp")?.revision == store.revision(of: "Writing/sermons.lamp"))
        #expect(store.conditions[LampSyncSettingsStore.path] == [.ifRevision("\"bundle3\""), .ifRevision("\"bundle3b\"")])
    }

    /// A copy already there that holds what the move would write, from
    /// another device moving at the same time or a move that stopped, is
    /// kept, and the manifest names it.
    @Test func aCopyAlreadyThereIsKept() async throws {
        let store = MoveStore()
        store.put("Devotionals/sermons.lamp", Data("sermons".utf8), "\"b\"")
        store.put("Writing/sermons.lamp", Data("sermons".utf8), "\"x\"")
        store.put(LampSyncSettingsStore.path, try LampSyncSettingsBundle(manifest: try formatThreeManifest([
            ("Devotionals/sermons.lamp", 6, "\"b\"", nil, nil),
        ])).encoded(version: 3), "\"bundle3\"")

        let snapshot = try #require(try await LampSyncSettingsStore.read(from: store, patience: .immediate))

        #expect(store.data("Writing/sermons.lamp") == Data("sermons".utf8))
        #expect(store.conditions["Writing/sermons.lamp"] == nil)
        #expect(snapshot.bundle.manifest.entry(at: "Writing/sermons.lamp")?.revision == "\"x\"")
    }

    /// A module already called `writing` is left where it was, and its entry
    /// with it, outside format 4's layout: the collection takes the name.
    @Test func aModuleCalledWritingIsLeftBehindAndTheCollectionMoves() async throws {
        let store = MoveStore()
        store.put("Devotionals/devotionals.lamp", try writingCollection(id: "devotionals"), "\"a\"")
        store.put("Devotionals/writing.lamp", Data("someone's".utf8), "\"b\"")
        store.put(LampSyncSettingsStore.path, try LampSyncSettingsBundle(manifest: try formatThreeManifest([
            ("Devotionals/devotionals.lamp", 5, "\"a\"", nil, nil),
            ("Devotionals/writing.lamp", 6, "\"b\"", nil, nil),
        ])).encoded(version: 3), "\"bundle3\"")

        let snapshot = try #require(try await LampSyncSettingsStore.read(from: store, patience: .immediate))

        #expect(snapshot.bundle.manifest.paths == ["Writing/writing.lamp", "Devotionals/writing.lamp"])
        #expect(try moduleIDs(inCollection: try #require(store.data("Writing/writing.lamp")))["module_meta"] == ["writing"])
        #expect(store.data("Devotionals/writing.lamp") == Data("someone's".utf8))
    }

    /// Once another device has moved the library, a file at a new path may
    /// be one a format-4 device published since, and is never written over,
    /// even where it differs.
    @Test func aFileAnotherDeviceWroteIsNeverWrittenOver() async throws {
        let store = MoveStore()
        store.put("Devotionals/sermons.lamp", Data("sermons".utf8), "\"b\"")
        store.put("Writing/sermons.lamp", Data("sermons, published since".utf8), "\"x\"")
        store.put(LampSyncSettingsStore.path, try LampSyncSettingsBundle(manifest: try formatThreeManifest([
            ("Devotionals/sermons.lamp", 6, "\"b\"", nil, nil),
        ])).encoded(version: 3), "\"bundle3\"")
        // Another device's move lands while this one looks at the new path.
        store.beforeReading["Writing/sermons.lamp"] = {
            store.put(LampSyncSettingsStore.path, try LampSyncSettingsBundle(manifest: LampSyncLibraryManifest()).encoded(), "\"bundle4\"")
        }

        let snapshot = try #require(try await LampSyncSettingsStore.read(from: store, patience: .immediate))

        #expect(store.data("Writing/sermons.lamp") == Data("sermons, published since".utf8))
        #expect(store.conditions["Writing/sermons.lamp"] == nil)
        #expect(snapshot.revision == "\"bundle4\"")
    }

    /// A move cut short before it wrote the bundle left a copy; a format-3
    /// device then wrote the old path again. While that format-3 bundle still
    /// stands, the copy left is a move's, and it is replaced with what the old
    /// path holds now.
    @Test func aCopyAMoveCutShortLeftIsReplaced() async throws {
        let store = MoveStore()
        store.put("Devotionals/sermons.lamp", Data("sermons, edited".utf8), "\"b2\"")
        store.put("Writing/sermons.lamp", Data("sermons".utf8), "\"x\"")
        store.put(LampSyncSettingsStore.path, try LampSyncSettingsBundle(manifest: try formatThreeManifest([
            ("Devotionals/sermons.lamp", 9, "\"b2\"", nil, nil),
        ])).encoded(version: 3), "\"bundle3\"")

        let snapshot = try #require(try await LampSyncSettingsStore.read(from: store, patience: .immediate))

        #expect(store.data("Writing/sermons.lamp") == Data("sermons, edited".utf8))
        #expect(store.conditions["Writing/sermons.lamp"] == [.ifRevision("\"x\"")])
        #expect(snapshot.bundle.manifest.entry(at: "Writing/sermons.lamp")?.revision == store.revision(of: "Writing/sermons.lamp"))
    }

    /// A format-3 bundle written over by `update` is a format-4 one, even
    /// when the change leaves the bundle as it was.
    @Test func anUpdateOfAFormatThreeLibraryWritesFormatFour() async throws {
        let store = MoveStore()
        store.put(LampSyncSettingsStore.path, try LampSyncSettingsBundle().encoded(version: 3), "\"bundle3\"")

        let snapshot = try await LampSyncSettingsStore.update(in: store, patience: .immediate) { _ in }

        #expect(LampSyncSettingsBundle.contents(
            ofHeader: try LampSyncSettingsBundle.header(of: try #require(store.data(LampSyncSettingsStore.path)))
        ) == .bundle)
        #expect(snapshot.revision == store.revision(of: LampSyncSettingsStore.path))
    }

    @Test func aFormatThreeVersionMergesAsFormatFour() {
        #expect(LampSyncSettingsStore.versionMerges(.formatThreeBundle))
        #expect(LampSyncSettingsStore.versionMerges(.bundle))
        #expect(!LampSyncSettingsStore.versionMerges(.newerBundle(5)))
        #expect(!LampSyncSettingsStore.versionMerges(.archive))
    }

    // MARK: - What review found

    /// A writing's media and a module no manifest names, as the phone's own
    /// library held them before it had a bundle, are carried by the phone's
    /// move as by any other.
    @Test func filesNoManifestNamesAreCarriedMediaAndAll() async throws {
        let store = MoveStore()
        store.put("Devotionals/dropped.lamp", Data("dropped".utf8), "\"a\"")
        store.put("DevotionalMedia/devotionals/w1/a.jpg", Data("a".utf8), "\"b\"")
        store.put("DevotionalMedia/dropped/w2/b.m4a", Data("b".utf8), "\"c\"")
        store.put("DevotionalMedia/.DS_Store", Data(), "\"d\"")

        let copied = try await LampSyncFormatFourMove.copy(members: [], in: store, patience: .immediate)

        #expect(Set(copied.keys) == [
            "Devotionals/dropped.lamp", "DevotionalMedia/devotionals/w1/a.jpg", "DevotionalMedia/dropped/w2/b.m4a",
        ])
        #expect(store.data("WritingMedia/writing/w1/a.jpg") == Data("a".utf8))
        #expect(store.data("WritingMedia/dropped/w2/b.m4a") == Data("b".utf8))
        #expect(store.data("Writing/dropped.lamp") == Data("dropped".utf8))
    }

    /// A copy put back by hand after its module was deleted is carried and
    /// adopted, as a pass would have adopted it at the old path. The copy a
    /// deletion was of is not carried, and its tombstone deletes any copy.
    @Test func aCopyPutBackAfterADeletionIsCarriedAndTheDeletionIsNot() async throws {
        let store = MoveStore()
        store.put("Devotionals/sermons.lamp", Data("put back".utf8), "\"new\"")
        store.put("Devotionals/old.lamp", Data("deleted".utf8), "\"old\"")
        store.put(LampSyncSettingsStore.path, try LampSyncSettingsBundle(manifest: try formatThreeManifest([
            ("Devotionals/sermons.lamp", 1, "\"gone\"", 5, "\"gone\""),
            ("Devotionals/old.lamp", 1, "\"old\"", 5, "\"old\""),
        ])).encoded(version: 3), "\"bundle3\"")

        let snapshot = try #require(try await LampSyncSettingsStore.read(from: store, patience: .immediate))

        #expect(store.data("Writing/sermons.lamp") == Data("put back".utf8))
        #expect(store.data("Writing/old.lamp") == nil)
        let adopted = try #require(snapshot.bundle.manifest.entry(at: "Writing/sermons.lamp"))
        #expect(adopted.isMember && adopted.revision == store.revision(of: "Writing/sermons.lamp"))
        let deleted = try #require(snapshot.bundle.manifest.entry(at: "Writing/old.lamp"))
        #expect(!deleted.isMember && deleted.deletes(revision: "\"anything\""))
    }

    /// A member whose file iCloud had not delivered when the library moved
    /// is copied once it reaches the old path.
    @Test func aMemberThatArrivesLateIsCopiedWhenItDoes() async throws {
        let store = MoveStore()
        store.put(LampSyncSettingsStore.path, try LampSyncSettingsBundle(manifest: try formatThreeManifest([
            ("Devotionals/devotionals.lamp", 5, "\"a\"", nil, nil),
            ("DevotionalMedia/devotionals/w1/a.jpg", 5, "\"b\"", nil, nil),
        ])).encoded(version: 3), "\"bundle3\"")
        let moved = try #require(try await LampSyncSettingsStore.read(from: store, patience: .immediate))
        #expect(moved.bundle.manifest.entry(at: "Writing/writing.lamp")?.revision == nil)
        #expect(store.data("Writing/writing.lamp") == nil)

        store.put("Devotionals/devotionals.lamp", try writingCollection(id: "devotionals"), "\"a\"")
        store.put("DevotionalMedia/devotionals/w1/a.jpg", Data("a".utf8), "\"b\"")
        let arrived = try #require(try await LampSyncSettingsStore.read(from: store, patience: .immediate))

        #expect(try moduleIDs(inCollection: try #require(store.data("Writing/writing.lamp")))["module_meta"] == ["writing"])
        #expect(store.data("WritingMedia/writing/w1/a.jpg") == Data("a".utf8))
        // Recorded by the next write, after which nothing is looked for.
        #expect(arrived.mustBeWritten)
        #expect(arrived.bundle.manifest.entry(at: "Writing/writing.lamp")?.revision == store.revision(of: "Writing/writing.lamp"))
        let written = try await LampSyncSettingsStore.update(in: store, patience: .immediate) { _ in }
        #expect(written.bundle.manifest.entry(at: "WritingMedia/writing/w1/a.jpg")?.revision != nil)
        let writes = store.writeCount
        let settled = try #require(try await LampSyncSettingsStore.read(from: store, patience: .immediate))
        #expect(!settled.mustBeWritten && store.writeCount == writes)
    }

    /// A module called `writing` that was deleted does not stop the move, and
    /// does not delete the collection it would have met.
    @Test func aDeletedModuleCalledWritingIsNoCollision() async throws {
        let store = MoveStore()
        store.put("Devotionals/devotionals.lamp", try writingCollection(id: "devotionals"), "\"a\"")
        store.put(LampSyncSettingsStore.path, try LampSyncSettingsBundle(manifest: try formatThreeManifest([
            ("Devotionals/devotionals.lamp", 5, "\"a\"", nil, nil),
            ("Devotionals/writing.lamp", 1, "\"w\"", 9, "\"w\""),
        ])).encoded(version: 3), "\"bundle3\"")

        let snapshot = try #require(try await LampSyncSettingsStore.read(from: store, patience: .immediate))

        #expect(snapshot.bundle.manifest.entry(at: "Writing/writing.lamp")?.isMember == true)
    }

    /// The collection's extension in another case is still the collection,
    /// and its copy is rewritten to its new ID.
    @Test func theCollectionIsRewrittenWhateverTheCaseOfItsExtension() async throws {
        let store = MoveStore()
        store.put("Devotionals/devotionals.LAMP", try writingCollection(id: "devotionals"), "\"a\"")

        _ = try await LampSyncFormatFourMove.copy(members: ["Devotionals/devotionals.LAMP"], in: store, patience: .immediate)

        #expect(try moduleIDs(inCollection: try #require(store.data("Writing/writing.lamp")))["module_format"] == ["writing"])
    }

    /// A format-3 bundle beside a format-3 iCloud version: no write lands
    /// while the version stands, so the move copies both copies' files and
    /// leaves the bundle to `update`, which merges the version, moved too,
    /// and writes format 4.
    @Test func aFormatThreeVersionsFilesAreCopiedAndUpdateWritesFormatFour() async throws {
        let store = VersionedMoveStore()
        store.put("Devotionals/sermons.lamp", Data("sermons".utf8), "\"b\"")
        store.put("DevotionalMedia/advent/w1/only-in-the-version.jpg", Data("jpeg".utf8), "\"v\"")
        store.put(LampSyncSettingsStore.path, try LampSyncSettingsBundle(manifest: try formatThreeManifest([
            ("Devotionals/sermons.lamp", 6, "\"b\"", nil, nil),
        ])).encoded(version: 3), "\"bundle3\"")
        store.versions[LampSyncSettingsStore.path] = [(try LampSyncSettingsBundle(manifest: try formatThreeManifest([
            ("DevotionalMedia/advent/w1/only-in-the-version.jpg", 7, "\"v\"", nil, nil),
        ])).encoded(version: 3), "\"version3\"")]

        let read = try #require(try await LampSyncSettingsStore.read(from: store, patience: .immediate))
        #expect(read.mustBeWritten)
        #expect(read.bundle.manifest.paths == ["Writing/sermons.lamp"])
        #expect(read.versions.map(\.bundle.manifest.paths) == [["WritingMedia/advent/w1/only-in-the-version.jpg"]])
        #expect(store.data("WritingMedia/advent/w1/only-in-the-version.jpg") == Data("jpeg".utf8))

        let written = try await LampSyncSettingsStore.update(
            in: store, patience: .immediate,
            mergingVersion: { bundle, version in bundle.manifest = bundle.manifest.merged(with: version.bundle.manifest) }
        ) { _ in }

        #expect(LampSyncSettingsBundle.contents(
            ofHeader: try LampSyncSettingsBundle.header(of: try #require(store.data(LampSyncSettingsStore.path)))
        ) == .bundle)
        #expect(written.bundle.manifest.paths == ["Writing/sermons.lamp", "WritingMedia/advent/w1/only-in-the-version.jpg"])
        #expect(store.versions[LampSyncSettingsStore.path]?.isEmpty == true)
    }

    // MARK: - Fixtures

    /// A manifest as a format-3 client wrote it, at paths this version's
    /// layout no longer holds, so made by decoding, as it arrives.
    private func formatThreeManifest(
        _ entries: [(String, Int64?, String?, Int64?, String?)]
    ) throws -> LampSyncLibraryManifest {
        let json: [[String: Any]] = entries.map { path, present, revision, deleted, deletedRevision in
            var entry: [String: Any] = ["path": path]
            if let present { entry["presentSince"] = present }
            if let revision { entry["revision"] = revision }
            if let deleted { entry["deletedAt"] = deleted }
            if let deletedRevision { entry["deletedRevision"] = deletedRevision }
            return entry
        }
        let data = try JSONSerialization.data(withJSONObject: ["entries": json])
        return try JSONDecoder().decode(LampSyncLibraryManifest.self, from: data)
    }

    /// A writing collection as the apps publish one: zlib SQLite naming its
    /// module in `module_format`, `module_meta` and each entry.
    private func writingCollection(id: String) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("collection-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE module_format (format_version TEXT NOT NULL, module_type TEXT NOT NULL, module_id TEXT NOT NULL);
                CREATE TABLE module_meta (id TEXT PRIMARY KEY, name TEXT NOT NULL);
                CREATE TABLE devotional_entries (id TEXT PRIMARY KEY, module_id TEXT NOT NULL, title TEXT NOT NULL);
                """)
            try db.execute(sql: "INSERT INTO module_format VALUES ('1.0', 'devotional', ?)", arguments: [id])
            try db.execute(sql: "INSERT INTO module_meta VALUES (?, 'My Writing')", arguments: [id])
            try db.execute(sql: "INSERT INTO devotional_entries VALUES ('w1', ?, 'Morning'), ('w2', ?, 'Evening')", arguments: [id, id])
        }
        try queue.close()
        return try (Data(contentsOf: url) as NSData).compressed(using: .zlib) as Data
    }

    private func opened<T>(_ collection: Data, _ read: (Database) throws -> T) throws -> T {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("read-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        try ((collection as NSData).decompressed(using: .zlib) as Data).write(to: url)
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }
        return try queue.read(read)
    }

    private func moduleIDs(inCollection collection: Data) throws -> [String: [String]] {
        try opened(collection) { db in
            [
                "module_format": try String.fetchAll(db, sql: "SELECT module_id FROM module_format"),
                "module_meta": try String.fetchAll(db, sql: "SELECT id FROM module_meta"),
                "devotional_entries": try String.fetchAll(db, sql: "SELECT module_id FROM devotional_entries ORDER BY id"),
            ]
        }
    }

    private func writingTitles(inCollection collection: Data) throws -> [String] {
        try opened(collection) { db in try String.fetchAll(db, sql: "SELECT title FROM devotional_entries ORDER BY id") }
    }
}

private extension LampSyncConditionalWrite.Patience {
    static let immediate = LampSyncConditionalWrite.Patience(confirm: [.zero], retry: [.zero])
}

/// One file per path, a folder listed by its immediate files, and conditional
/// writes enforced as a server would.
private class MoveStore: LampSyncRemoteStore, @unchecked Sendable {
    fileprivate var files: [String: (Data, String)] = [:]
    private(set) var conditions: [String: [LampSyncWriteCondition]] = [:]
    private(set) var writeCount = 0
    var beforeBundleWrite: (() throws -> Void)?
    var beforeReading: [String: () throws -> Void] = [:]
    private var counter = 0

    func put(_ path: String, _ data: Data, _ revision: String) { files[path] = (data, revision) }
    func data(_ path: String) -> Data? { files[path]?.0 }
    func revision(of path: String) -> String? { files[path]?.1 }

    func list(directory: String) async throws -> [LampSyncRemoteEntry]? {
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        var entries: [String: LampSyncRemoteEntry] = [:]
        for path in files.keys where path.hasPrefix(prefix) {
            let rest = path.dropFirst(prefix.count)
            let name = String(rest.prefix { $0 != "/" })
            let isDirectory = rest.contains("/")
            entries[name] = LampSyncRemoteEntry(
                path: prefix + name, name: name, isDirectory: isDirectory,
                revision: isDirectory ? nil : files[path]?.1, modifiedAt: nil, size: nil
            )
        }
        return entries.isEmpty ? nil : entries.keys.sorted().compactMap { entries[$0] }
    }

    func read(path: String) async throws -> LampSyncRemoteFile? {
        if let hook = beforeReading.removeValue(forKey: path) { try hook() }
        return files[path].map { LampSyncRemoteFile(data: $0.0, revision: $0.1) }
    }

    func revision(path: String) async throws -> String? { files[path]?.1 }

    func readPrefix(path: String, count: Int) async throws -> LampSyncRemoteFile? {
        files[path].map { LampSyncRemoteFile(data: $0.0.prefix(count), revision: $0.1) }
    }

    func write(_ data: Data, to path: String, condition: LampSyncWriteCondition) async throws -> String? {
        if path == LampSyncSettingsStore.path, let beforeBundleWrite {
            self.beforeBundleWrite = nil
            try beforeBundleWrite()
        }
        conditions[path, default: []].append(condition)
        switch condition {
        case .ifAbsent where files[path] != nil:
            throw LampSyncConditionalWrite.WriteError.conflict
        case .ifRevision(let revision) where files[path]?.1 != revision:
            throw LampWebDAVStorage.StorageError.preconditionFailed
        default:
            break
        }
        writeCount += 1
        counter += 1
        let revision = "\"m\(counter)\""
        files[path] = (data, revision)
        return revision
    }
}

/// iCloud's way with a file two devices wrote at once: both copies kept, the
/// later one current, the other an unresolved version, and a write refused
/// while versions stand.
private final class VersionedMoveStore: MoveStore, LampSyncVersionedStore {
    var versions: [String: [(Data, String)]] = [:]

    func readWithVersions(
        path: String, into destination: URL
    ) async throws -> (current: LampSyncDownloadedFile?, versions: [LampSyncDownloadedFile]) {
        guard let file = files[path] else { return (nil, []) }
        try file.0.write(to: destination)
        let saved = try (versions[path] ?? []).map { data, revision in
            let url = LampSyncScratchFile.url()
            try data.write(to: url)
            return LampSyncDownloadedFile(url: url, revision: revision)
        }
        return (LampSyncDownloadedFile(url: destination, revision: file.1), saved)
    }

    func resolveVersions(
        of path: String, writing data: Data, ifRevision revision: String, resolving resolved: Set<String>
    ) async throws -> String {
        guard files[path]?.1 == revision else { throw LampWebDAVStorage.StorageError.preconditionFailed }
        versions[path] = (versions[path] ?? []).filter { !resolved.contains($0.1) }
        put(path, data, "\"resolved\"")
        return "\"resolved\""
    }

    func hasVersions(path: String) async throws -> Bool { !(versions[path] ?? []).isEmpty }

    override func write(_ data: Data, to path: String, condition: LampSyncWriteCondition) async throws -> String? {
        if !(versions[path] ?? []).isEmpty { throw LampSyncConditionalWrite.WriteError.conflict }
        return try await super.write(data, to: path, condition: condition)
    }
}
