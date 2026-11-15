import Foundation
@testable import LampCore
import LampModuleKit
import Testing

/// The writing import: a folder or a file of Markdown, planned against the
/// library, then applied. Fixtures are cut from the shapes of the owner's own
/// writing (bible-studies): files with no front matter, titled by a heading or
/// not at all, with tables, HTML collapsibles and links to sibling files.
struct LampWritingImportTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-writing-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    @discardableResult
    private func write(
        _ text: String, to path: String, in root: URL, modified: Date? = nil
    ) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    private let exhortation = """
        For this morning’s exhortation, I’d like to take some thoughts from Matthew chapter 24-25.

        (Matthew 24:1-3 ESV)

        Jesus left the temple and was going away.
        """

    private let handout = """
        # The Man of Sin: 2 Thessalonians 2

        ## Class Outline

        Victoria Christadelphian Ecclesia, Adult Sunday School, Feb. 2026

        | Section | Format | Time |
        |---------|--------|------|
        | I. Review | Presentation | ~10 min |
        """

    @Test func aFolderOfPlainMarkdownImportsOnceAndThenReadsUnchanged() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let studies = root.appendingPathComponent("bible-studies")
        try write(exhortation, to: "exhortations/2026JAN18.md", in: studies)
        try write(handout, to: "studies/thessalonians/ManOfSin_Handout.md", in: studies)
        try write("# Package\n\nNot writing.", to: "node_modules/pkg/README.md", in: studies)
        try write("# Hidden\n\nNot writing.", to: ".obsidian/notes.md", in: studies)
        try write("Not Markdown", to: "deck.txt", in: studies)

        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let files = try LampWritingImport.files(at: studies)
        #expect(files.map(\.path) == [
            "bible-studies/exhortations/2026JAN18.md",
            "bible-studies/studies/thessalonians/ManOfSin_Handout.md",
        ])

        let plan = try await library.planWritingImport(files)
        #expect(plan.items.map(\.action) == [.create, .create])
        let bare = try #require(plan.items.first)
        #expect(bare.title == "2026JAN18")
        #expect(bare.idDerived)
        #expect(bare.warnings.contains { $0.contains("No title") })
        let titled = plan.items[1]
        #expect(titled.title == "The Man of Sin: 2 Thessalonians 2")
        #expect(titled.normalized.contains { $0.contains("heading the file opens with") })

        let result = try await library.applyWritingImport(
            plan, selecting: Set(plan.items.map(\.id))
        )
        #expect(result.imported.count == 2)
        let saved = try await library.personalDevotionals()
        let man = try #require(saved.first { $0.title == titled.title })
        #expect(man.content.hasPrefix("## Class Outline"))
        #expect(man.content.contains("| Section | Format | Time |"))

        let again = try await library.planWritingImport(LampWritingImport.files(at: studies))
        #expect(again.items.map(\.action) == [.unchanged, .unchanged])
        #expect(try await library.personalDevotionals().count == 2)
    }

    @Test func oneFileAndItsFolderGiveTheSameIDAndTwoTalksDoNot() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try write("# Talk\n\nOne.", to: "howgodspoke/talk.md", in: root)
        try write("# Talk\n\nTwo.", to: "manofsin/talk.md", in: root)

        let alone = try LampWritingImport.files(at: first)
        let inFolder = try LampWritingImport.files(at: root.appendingPathComponent("howgodspoke"))
        #expect(alone.map(\.path) == ["howgodspoke/talk.md"])
        #expect(alone.map(\.path) == inFolder.map(\.path))
        let other = try LampWritingImport.files(at: root.appendingPathComponent("manofsin"))
        #expect(LampWritingImport.derivedID(path: alone[0].path)
            != LampWritingImport.derivedID(path: other[0].path))
        #expect(LampWritingImport.derivedID(path: "HowGodSpoke/Talk.md")
            == LampWritingImport.derivedID(path: "howgodspoke/talk.md"))
        #expect(LampModuleIdentifier.isValid(LampWritingImport.derivedID(path: alone[0].path)))
    }

    @Test func aFileSavedLaterUpdatesButAnEditInLampIsAConflict() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("writing")
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        try write("# Watch\n\nFirst draft.", to: "watch.md", in: folder, modified: earlier)
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let first = try await library.planWritingImport(LampWritingImport.files(at: folder))
        try await library.applyWritingImport(first, selecting: Set(first.items.map(\.id)))
        #expect(try await library.personalDevotionals().first?.lastModified == earlier)

        // Saved again outside Lamp: newer than Lamp's copy, so an update.
        let later = earlier.addingTimeInterval(3_600)
        try write("# Watch\n\nSecond draft.", to: "watch.md", in: folder, modified: later)
        let second = try await library.planWritingImport(LampWritingImport.files(at: folder))
        #expect(second.items.map(\.action) == [.update])
        #expect(second.items[0].changes == ["text"])
        #expect(second.items[0].importsByDefault)
        try await library.applyWritingImport(second, selecting: Set(second.items.map(\.id)))
        #expect(try await library.personalDevotionals().first?.content == "Second draft.")

        // Edited in Lamp since: Lamp's copy is newer than the file.
        let local = try #require(try await library.personalDevotionals().first)
        try await library.savePersonalDevotional(LampDevotional(
            id: local.id, moduleID: local.moduleID, moduleName: local.moduleName,
            title: local.title, content: "Edited in Lamp.", created: local.created
        ))
        try write("# Watch\n\nThird draft.", to: "watch.md", in: folder, modified: later.addingTimeInterval(60))
        let third = try await library.planWritingImport(LampWritingImport.files(at: folder))
        #expect(third.items.map(\.action) == [.conflict])
        #expect(!third.items[0].importsByDefault)
        try await library.applyWritingImport(third, selecting: [])
        #expect(try await library.personalDevotionals().first?.content == "Edited in Lamp.")

        // Chosen, it replaces Lamp's copy and is dated after both, so sync
        // carries the choice to the other devices.
        let edited = try #require(try await library.personalDevotionals().first?.lastModified)
        try await library.applyWritingImport(third, selecting: Set(third.items.map(\.id)))
        let replaced = try #require(try await library.personalDevotionals().first)
        #expect(replaced.content == "Third draft.")
        #expect(try #require(replaced.lastModified) > edited)
    }

    @Test func aPlanIsRefusedWhereTheLibraryChangedAfterIt() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("# Note\n\nFrom the file.", to: "w/note.md", in: root)
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let plan = try await library.planWritingImport(LampWritingImport.files(at: file))
        let id = plan.items[0].writingID
        try await library.savePersonalDevotional(LampDevotional(
            id: id, moduleID: "personal-devotionals", moduleName: "My Writing",
            title: "Note", content: "Written in Lamp meanwhile."
        ))
        let result = try await library.applyWritingImport(plan, selecting: [plan.items[0].id])
        #expect(result.imported.isEmpty)
        #expect(result.refused.map(\.id) == [plan.items[0].id])
        #expect(try await library.personalDevotionals().first?.content == "Written in Lamp meanwhile.")
    }

    @Test func frontMatterIsHonouredAndTidiedAndSaysWhatItChanged() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("""
            ---
            id: "exhortation-2026-01-18"
            title: "The Days of Noah"
            author: Matthew Bennett
            date: 2026-01-18
            category: Sermon
            tags: [Matthew, preparedness]
            series:
              name: Parables
              order: 3
            keyScriptures:
              - ref: "Matthew 24:36-44"
              - ref: "Psalm 23"
              - ref: "Hezekiah 4:1"
            created: 2026-01-18T09:00:00Z
            lastModified: 2026-01-19T09:00:00Z
            source: exhortations/2026JAN18.md
            mood: hopeful
            ---
            # The Days of Noah

            As it was in the days of Noah.
            """, to: "bundle/noah.md", in: root)
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let plan = try await library.planWritingImport(LampWritingImport.files(at: file))
        let item = try #require(plan.items.first)
        #expect(item.action == .create)
        #expect(item.writingID == "exhortation-2026-01-18")
        #expect(!item.idDerived)
        #expect(item.normalized.contains { $0.contains("repeated the title") })
        #expect(item.normalized.contains { $0.contains("“Sermon” filed as “exhortation”") })
        #expect(item.warnings.contains { $0.contains("mood") })
        #expect(item.warnings.contains { $0.contains("Hezekiah 4:1") })
        #expect(!item.warnings.contains { $0.contains("source") })

        try await library.applyWritingImport(plan, selecting: [item.id])
        let writing = try #require(try await library.personalDevotionals().first)
        #expect(writing.content == "As it was in the days of Noah.")
        #expect(writing.author == "Matthew Bennett")
        #expect(writing.date == "2026-01-18")
        #expect(writing.category == "exhortation")
        #expect(writing.tags == ["Matthew", "preparedness"])
        #expect(writing.seriesName == "Parables")
        #expect(writing.seriesOrder == 3)
        #expect(writing.keyScriptures.map(\.startReference) == [40_024_036, 19_023_001])
        #expect(writing.keyScriptures.map(\.endReference) == [40_024_044, 19_023_006])
        #expect(writing.created == LampWritingImport.timestamp("2026-01-18T09:00:00Z"))
        #expect(writing.lastModified == LampWritingImport.timestamp("2026-01-19T09:00:00Z"))
    }

    @Test func problemsRejectAFileOrWarnAboutIt() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("bundle")
        try write("---\nid: \"bad/id\"\ntitle: Bad id\n---\nText.", to: "a-bad-id.md", in: folder)
        try write("# Verse\n\nSee [Matthew 99:1](lampbible://verse/40099001).", to: "b-verse.md", in: folder)
        try write("# Picture\n\n![A map](media/map.png)", to: "c-media.md", in: folder)
        try write("---\nid: same\ntitle: One\n---\nOne.", to: "d-one.md", in: folder)
        try write("---\nid: same\ntitle: Two\n---\nTwo.", to: "e-two.md", in: folder)
        try write("# Empty\n\n", to: "f-empty.md", in: folder)
        try write("""
            # Discussion

            See [Matthew 24:36](lampbible://verse/40024036) and [the audit](../audits/2PE.md).

            <details>
            <summary>Lecturer notes</summary>

            A point.[^1] Another.[^missing]
            </details>

            ```
            <div>an example, not the writing's own HTML</div>
            ```

            ---

            [^1]: Defined.
            """, to: "g-warnings.md", in: folder)

        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let plan = try await library.planWritingImport(LampWritingImport.files(at: folder))
        let byFile = Dictionary(uniqueKeysWithValues: plan.items.map {
            (($0.path as NSString).lastPathComponent, $0)
        })
        #expect(byFile["a-bad-id.md"]?.action == .rejected)
        #expect(byFile["b-verse.md"]?.errors.first?.contains("not a verse") == true)
        #expect(byFile["c-media.md"]?.errors.first?.contains("media/map.png") == true)
        #expect(byFile["d-one.md"]?.errors.first?.contains("e-two.md") == true)
        #expect(byFile["e-two.md"]?.action == .rejected)
        #expect(byFile["f-empty.md"]?.errors == ["The writing has no text."])

        let warned = try #require(byFile["g-warnings.md"])
        #expect(warned.action == .create)
        #expect(warned.errors.isEmpty)
        #expect(warned.warnings.contains { $0.contains("../audits/2PE.md") })
        #expect(warned.warnings.contains { $0.contains("<details>, <summary>") && !$0.contains("<div>") })
        #expect(warned.warnings.contains { $0.contains("[^missing]") && !$0.contains("[^1]") })

        let result = try await library.applyWritingImport(plan, selecting: Set(plan.items.map(\.id)))
        #expect(result.imported.map(\.path) == [warned.path])
    }

    @Test func aDeletedWritingComesBackWhenImportedAgainAndSaysSo() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("# Kept\n\nText.", to: "w/kept.md", in: root,
                             modified: Date(timeIntervalSince1970: 1_600_000_000))
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let plan = try await library.planWritingImport(LampWritingImport.files(at: file))
        try await library.applyWritingImport(plan, selecting: [plan.items[0].id])
        try await library.deletePersonalDevotional(id: plan.items[0].writingID)

        let again = try await library.planWritingImport(LampWritingImport.files(at: file))
        #expect(again.items[0].action == .create)
        #expect(again.items[0].warnings.contains { $0.contains("deleted from Lamp") })
        try await library.applyWritingImport(again, selecting: [again.items[0].id])
        #expect(try await library.personalDevotionals().count == 1)
        #expect(try await library.writingDeletion(id: plan.items[0].writingID)?
            .isDeleted(itemModified: 1_600_000_000) == false)
    }

    @Test func aManifestNamesTheWritingAmongWorkingFiles() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("bundle")
        try write("# Kept\n\nText.", to: "out/kept.md", in: folder)
        try write("# Notes to self\n\nScratch.", to: "STATUS.md", in: folder)
        try write(#"{"formatVersion": 1, "writings": [{"file": "out/kept.md"}]}"#,
                  to: "lamp-import.json", in: folder)
        #expect(try LampWritingImport.files(at: folder).map(\.path) == ["bundle/out/kept.md"])

        try write(#"{"writings": [{"file": "../outside.md"}]}"#, to: "lamp-import.json", in: folder)
        #expect(throws: LampLibraryError.self) { try LampWritingImport.files(at: folder) }
    }

    @Test func lampsOwnMarkdownExportComesBackAsItsWritings() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = ["Morning", "Evening"].map { title in
            LampPersonalMarkdownWriter.devotionalEntry(LampMarkdownDevotionalEntry(
                title: title, author: "M.", tags: ["daily"], content: "\(title) text."
            ))
        }
        let markdown = (["# My Writing"] + entries).joined(separator: "\n\n---\n\n")
        let file = try write(markdown, to: "export/My Writing.md", in: root)
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let plan = try await library.planWritingImport(LampWritingImport.files(at: file))
        #expect(plan.items.map(\.title) == ["Morning", "Evening"])
        #expect(plan.items.map(\.action) == [.create, .create])
        #expect(Set(plan.items.map(\.id)).count == 2)
        try await library.applyWritingImport(plan, selecting: Set(plan.items.map(\.id)))
        #expect(try await library.personalDevotionals().first { $0.title == "Morning" }?.tags == ["daily"])
        let again = try await library.planWritingImport(LampWritingImport.files(at: file))
        #expect(again.items.map(\.action) == [.unchanged, .unchanged])
    }

    @Test func anAgentWithoutPersonalContentGetsTheFilesCheckedButNotCompared() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("# Watch\n\nText.", to: "w/watch.md", in: root)
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let plan = try await library.planWritingImport(LampWritingImport.files(at: file))
        try await library.applyWritingImport(plan, selecting: [plan.items[0].id])

        let closed = LampAgentLibrary(library: library, policy: LampAgentAccessPolicy(
            isEnabled: true, includesPersonalContent: false
        ))
        let blind = try await closed.planWritingImport(LampWritingImport.files(at: file))
        #expect(blind.items.map(\.action) == [.create])
        #expect(blind.items[0].warnings.contains { $0.contains("Not compared") })
        let open = LampAgentLibrary(library: library, policy: LampAgentAccessPolicy(
            isEnabled: true, includesPersonalContent: true
        ))
        let report = try await open.planWritingImport(LampWritingImport.files(at: file)).report
        #expect(report.unchanged == 1)
        #expect(try JSONDecoder().decode(
            LampWritingImportReport.self, from: JSONEncoder().encode(report)
        ) == report)
    }

    @Test func aFileImportedAloneOrFromASubfolderFindsTheWritingItsParentImported() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let studies = root.appendingPathComponent("bible-studies")
        let talk = try write("# Talk\n\nOne.", to: "exhortations/talk.md", in: studies)
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let whole = try await library.planWritingImport(LampWritingImport.files(at: studies))
        try await library.applyWritingImport(whole, selecting: Set(whole.items.map(\.id)))

        try write("# Talk\n\nOne, revised.", to: "exhortations/talk.md", in: studies,
                  modified: Date().addingTimeInterval(60))
        // Found by its path, so offered for review rather than ticked: a path
        // alone does not prove it is the same file.
        let alone = try await library.planWritingImport(LampWritingImport.files(at: talk))
        #expect(alone.items.map(\.action) == [.conflict])
        #expect(!alone.items[0].importsByDefault)
        #expect(alone.items[0].writingID == whole.items[0].writingID)
        #expect(alone.items[0].normalized.contains { $0.contains("bible-studies/exhortations/talk.md") })
        let sub = try await library.planWritingImport(
            LampWritingImport.files(at: studies.appendingPathComponent("exhortations"))
        )
        #expect(sub.items[0].writingID == whole.items[0].writingID)

        // The other way round: imported alone first, then with its folder.
        let other = try write("# Other\n\nTwo.", to: "studies/other.md", in: studies)
        let first = try await library.planWritingImport(LampWritingImport.files(at: other))
        try await library.applyWritingImport(first, selecting: Set(first.items.map(\.id)))
        let again = try await library.planWritingImport(LampWritingImport.files(at: studies))
        #expect(again.items.first { $0.path.hasSuffix("other.md") }?.writingID == first.items[0].writingID)
        #expect(try await library.personalDevotionals().count == 2)
    }

    @Test func twoDocumentsWithOnePathCannotStandInForEachOther() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let plan = try await library.planWritingImport([
            LampWritingImportFile(path: "talks/a.md", markdown: "---\nid: one\ntitle: One\n---\nFirst."),
            LampWritingImportFile(path: "talks/a.md", markdown: "---\nid: two\ntitle: Two\n---\nSecond."),
        ])
        #expect(Set(plan.items.map(\.id)).count == 2)
        #expect(plan.items.map(\.action) == [.create, .rejected])
        try await library.applyWritingImport(plan, selecting: Set(plan.items.map(\.id)))
        #expect(try await library.personalDevotionals().map(\.title) == ["One"])
    }

    @Test func aDocumentThatGivesNoTimeCannotOverwriteAnEditInLamp() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let document = LampWritingImportFile(path: "talks/watch.md", markdown: "# Watch\n\nFirst.")
        let first = try await library.planWritingImport([document])
        try await library.applyWritingImport(first, selecting: Set(first.items.map(\.id)))
        #expect(try await library.personalDevotionals().first?.lastModified != nil)

        let local = try #require(try await library.personalDevotionals().first)
        try await library.savePersonalDevotional(LampDevotional(
            id: local.id, moduleID: local.moduleID, moduleName: local.moduleName,
            title: local.title, content: "Edited in Lamp.", created: local.created
        ))
        let again = try await library.planWritingImport([document])
        #expect(again.items.map(\.action) == [.conflict])
        #expect(!again.items[0].importsByDefault)
    }

    @Test func aChangeInTheSameSecondAsThePlanIsStillCaught() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let moment = Date(timeIntervalSince1970: 1_700_000_000)
        try await library.savePersonalDevotional(LampDevotional(
            id: "watch", moduleID: "personal-devotionals", moduleName: "My Writing",
            title: "Watch", content: "In Lamp.", lastModified: moment
        ), preserveLastModified: true)
        let plan = try await library.planWritingImport([LampWritingImportFile(
            path: "talks/watch.md", markdown: "---\nid: watch\ntitle: Watch\n---\nFrom the file.",
            modified: moment.addingTimeInterval(60)
        )])
        #expect(plan.items.map(\.action) == [.update])
        try await library.savePersonalDevotional(LampDevotional(
            id: "watch", moduleID: "personal-devotionals", moduleName: "My Writing",
            title: "Watch", content: "Changed again in Lamp.", lastModified: moment
        ), preserveLastModified: true)
        let result = try await library.applyWritingImport(plan, selecting: Set(plan.items.map(\.id)))
        #expect(result.imported.isEmpty)
        #expect(try await library.personalDevotionals().first?.content == "Changed again in Lamp.")
    }

    @Test func aWritingBroughtBackIsDatedNowSoAnOlderCopyCannotWin() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let file = try write("# Kept\n\nText.", to: "w/kept.md", in: root, modified: old)
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let plan = try await library.planWritingImport(LampWritingImport.files(at: file))
        try await library.applyWritingImport(plan, selecting: [plan.items[0].id])
        #expect(try await library.personalDevotionals().first?.lastModified == old)
        try await library.deletePersonalDevotional(id: plan.items[0].writingID)

        let before = Date().addingTimeInterval(-1)
        let deletedAt = try #require(try await library.writingDeletion(id: plan.items[0].writingID)?.deletedAt)
        let deleted = Int((deletedAt + 999) / 1_000)
        let again = try await library.planWritingImport(LampWritingImport.files(at: file))
        try await library.applyWritingImport(again, selecting: [again.items[0].id])
        let stamp = try #require(try await library.personalDevotionals().first?.lastModified)
        #expect(stamp > before)
        #expect(Int(stamp.timeIntervalSince1970) > deleted, "dated after the deletion it undoes")
    }

    @Test func aPathMatchIsNeverTakenWhenItCouldBeMoreThanOneWritingOrAnotherFilesOwn() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        // Two earlier imports, each of which a file at a/b/talk.md could be.
        let earlier = try await library.planWritingImport([
            LampWritingImportFile(path: "b/talk.md", markdown: "# Short\n\nOne."),
            LampWritingImportFile(path: "x/a/b/talk.md", markdown: "# Long\n\nTwo."),
        ])
        try await library.applyWritingImport(earlier, selecting: Set(earlier.items.map(\.id)))
        let ambiguous = try await library.planWritingImport([LampWritingImportFile(
            path: "a/b/talk.md", markdown: "# Talk\n\nThree.", ancestry: ["x"]
        )])
        #expect(ambiguous.items.map(\.action) == [.create])
        #expect(ambiguous.items[0].warnings.contains { $0.contains("More than one writing") })

        // A copy of the same path, rejected, does not stop the first finding
        // its writing.
        let twice = try await library.planWritingImport([
            LampWritingImportFile(path: "y/b/talk.md", markdown: "# Short\n\nOne, again."),
            LampWritingImportFile(path: "y/b/talk.md", markdown: "# Short\n\nOne, again."),
        ])
        #expect(twice.items.map(\.action) == [.conflict, .rejected])
        #expect(twice.items[0].writingID == earlier.items[0].writingID)
    }

    @Test func aRowKeyNeverTakesAnotherFilesPath() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let plan = try await library.planWritingImport([
            LampWritingImportFile(path: "w/talk.md", markdown: "# One\n\nOne."),
            LampWritingImportFile(path: "w/talk.md", markdown: "# Two\n\nTwo."),
            LampWritingImportFile(path: "w/talk.md#copy2", markdown: "# Three\n\nThree."),
        ])
        #expect(Set(plan.items.map(\.id)).count == 3)
        #expect(plan.items.map(\.action) == [.create, .rejected, .create])
        #expect(plan.items[2].id == "w/talk.md#copy2")
    }

    @Test func aStructuredBodyChangedInTheSameSecondIsStillCaught() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let moment = Date(timeIntervalSince1970: 1_700_000_000)
        func save(_ blocks: String) async throws {
            try await library.savePersonalDevotional(LampDevotional(
                id: "watch", moduleID: "personal-devotionals", moduleName: "My Writing",
                title: "Watch", content: "In Lamp.", contentJSON: blocks, lastModified: moment
            ), preserveLastModified: true)
        }
        try await save(#"[{"type":"paragraph"}]"#)
        let plan = try await library.planWritingImport([LampWritingImportFile(
            path: "talks/watch.md", markdown: "---\nid: watch\ntitle: Watch\n---\nFrom the file.",
            modified: moment.addingTimeInterval(60)
        )])
        try await save(#"[{"type":"heading"}]"#)
        let result = try await library.applyWritingImport(plan, selecting: Set(plan.items.map(\.id)))
        #expect(result.imported.isEmpty)
        #expect(try await library.personalDevotionals().first?.content == "In Lamp.")
    }

    @Test func lampsExportDetailsInsideACodeBlockDoNotMakeAnExport() {
        #expect(!LampWritingImport.isLampMarkdownExport("""
            # Talk

            ## Introduction

            How Lamp writes its details:

            ```
            **Author:** A Reader
            ```
            """))
        #expect(!LampWritingImport.isLampMarkdownExport("""
            # Talk

            ## Introduction

            Some prose first.

            More prose.

            **Author:** much later
            """))
        #expect(LampWritingImport.isLampMarkdownExport("""
            # My Writing

            ## Morning Hope

            *Beginning well*

            **Author:** A Reader | **Date:** 2026-08-03
            """))
    }

    private let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

    @Test func picturesComeInWithTheirWritingAndASecondImportChangesNothing() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("talks")
        try write("# Map\n\n![The journeys](images/map%20one.png)\n\nAgain: ![](images/map%20one.png)",
                  to: "map.md", in: folder)
        let image = folder.appendingPathComponent("images/map one.png")
        try FileManager.default.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
        try onePixelPNG.write(to: image)
        try write("# Lost\n\n![Gone](images/none.png)", to: "lost.md", in: folder)

        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let plan = try await library.planWritingImport(LampWritingImport.files(at: folder))
        #expect(plan.items.map(\.action) == [.rejected, .create])
        #expect(plan.items[0].errors.first?.contains("images/none.png") == true)
        try await library.applyWritingImport(plan, selecting: Set(plan.items.map(\.id)))

        let writing = try #require(try await library.personalDevotionals().first)
        let reference = try #require(writing.mediaReferences.first)
        #expect(writing.mediaReferences.count == 1, "the same picture twice is one file")
        #expect(writing.content.contains("](media/\(reference.id))"))
        #expect(!writing.content.contains("images/"))
        #expect(reference.type == .image)
        #expect(reference.width == 1)
        #expect(reference.alt == "The journeys")
        let stored = try #require(LampPortableDevotionalMedia.folderURL(
            rootURL: library.rootURL, scope: .devotional, ownerID: writing.id
        )).appendingPathComponent(reference.filename)
        #expect(try Data(contentsOf: stored) == onePixelPNG)

        let again = try await library.planWritingImport(LampWritingImport.files(at: folder))
        #expect(again.items.map(\.action) == [.rejected, .unchanged])
    }

    private func deckJSON(id: String, title: String, asset: String? = nil) throws -> String {
        var blocks: [LampPresentationBlock] = [.init(kind: .title, text: title)]
        if let asset { blocks.append(.init(kind: .image, assetPath: asset, altText: "Cover")) }
        let deck = LampPresentationDeck(id: id, title: title, slides: [
            LampPresentationSlide(layout: asset == nil ? .title : .image, blocks: blocks),
        ])
        return String(decoding: try JSONEncoder().encode(deck), as: UTF8.self)
    }

    @Test func aDeckBesideAWritingComesInAsItsDeckWithItsPictures() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("talks")
        try write("# Watch\n\nBe ready.", to: "watch.md", in: folder)
        try write(try deckJSON(id: "talks/deck:watch", title: "Watch", asset: "Assets/cover.png"),
                  to: "watch.lampdeck", in: folder)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        try onePixelPNG.write(to: folder.appendingPathComponent("Assets/cover.png"))

        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let plan = try await library.planWritingImport(LampWritingImport.files(at: folder))
        #expect(plan.items.map(\.kind) == [.writing, .deck])
        #expect(plan.items.map(\.action) == [.create, .create])
        try await library.applyWritingImport(plan, selecting: Set(plan.items.map(\.id)))

        let store = LampPresentationDeckStore(rootURL: library.rootURL)
        let deck = try #require(try store.deck(id: "talks/deck:watch"))
        #expect(deck.source == LampPresentationSource(kind: .writing, id: plan.items[0].writingID))
        // Stored under a name of the deck's own, so another deck's
        // cover.png is never overwritten.
        let asset = try #require(deck.slides.flatMap(\.blocks).compactMap(\.assetPath).first)
        #expect(asset.hasPrefix("Assets/") && asset.hasSuffix("-cover.png"))
        #expect(!asset.dropFirst("Assets/".count).contains("/"), "flat in Assets, as sync needs")
        #expect(try Data(contentsOf: store.decksDirectoryURL.appendingPathComponent(asset)) == onePixelPNG)

        let again = try await library.planWritingImport(LampWritingImport.files(at: folder))
        #expect(again.items.map(\.action) == [.unchanged, .unchanged])

        // Changed in Slide Studio since: the file's copy waits to be chosen.
        var edited = deck
        edited.title = "Watch, revised"
        try store.save(edited)
        let third = try await library.planWritingImport(LampWritingImport.files(at: folder))
        #expect(third.items.map(\.action) == [.unchanged, .conflict])
        #expect(!third.items[1].importsByDefault)
    }

    @Test func linksBetweenFilesOfOneImportOpenTheirWritings() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("study")
        try write("# One\n\nSee [the second](part/two.md#questions), not [this](../elsewhere.md).\n\n```\n[code](part/two.md)\n```",
                  to: "one.md", in: folder)
        try write("# Two\n\nBack to [one](../one.md).", to: "part/two.md", in: folder)
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let plan = try await library.planWritingImport(LampWritingImport.files(at: folder))
        let one = try #require(plan.items.first { $0.path == "study/one.md" })
        let two = try #require(plan.items.first { $0.path == "study/part/two.md" })
        #expect(one.warnings.contains { $0.contains("../elsewhere.md") })
        try await library.applyWritingImport(plan, selecting: Set(plan.items.map(\.id)))
        let writings = Dictionary(uniqueKeysWithValues: try await library.personalDevotionals().map { ($0.id, $0) })
        let first = try #require(writings[one.writingID])
        #expect(first.content.contains("[the second](lampbible://writing/\(two.writingID))"))
        #expect(first.content.contains("```\n[code](part/two.md)\n```"), "code is left as written")
        #expect(writings[two.writingID]?.content.contains("lampbible://writing/\(one.writingID)") == true)
        #expect(LampApplicationLink(url: LampApplicationLink.writingURL(id: two.writingID))
            == .writing(id: two.writingID))
    }

    @Test func undoingAnImportPutsBackWhatItChangedAndLeavesWhatChangedSince() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("w")
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        try write("# Kept\n\nFirst.", to: "kept.md", in: folder, modified: earlier)
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let first = try await library.planWritingImport(LampWritingImport.files(at: folder))
        try await library.applyWritingImport(first, selecting: Set(first.items.map(\.id)))

        try write("# Kept\n\nSecond.", to: "kept.md", in: folder, modified: earlier.addingTimeInterval(60))
        try write("# New\n\nBrand new.", to: "new.md", in: folder, modified: earlier.addingTimeInterval(60))
        try write("# Other\n\nAnother.", to: "other.md", in: folder, modified: earlier.addingTimeInterval(60))
        let second = try await library.planWritingImport(LampWritingImport.files(at: folder))
        let result = try await library.applyWritingImport(second, selecting: Set(second.items.map(\.id)))
        #expect(result.undo.writings.count == 3)

        // Edited after the import: undo leaves it.
        let other = try #require(try await library.personalDevotionals().first { $0.title == "Other" })
        try await library.savePersonalDevotional(LampDevotional(
            id: other.id, moduleID: other.moduleID, moduleName: other.moduleName,
            title: "Other", content: "Edited after.", created: other.created
        ))
        let undone = try await library.undoWritingImport(result.undo)
        #expect(Set(undone.undone) == ["Kept", "New"])
        #expect(undone.kept == ["Other"])
        let left = Dictionary(uniqueKeysWithValues: try await library.personalDevotionals().map { ($0.title, $0) })
        #expect(left["Kept"]?.content == "First.")
        #expect(left["New"] == nil)
        #expect(left["Other"]?.content == "Edited after.")
        #expect(try #require(left["Kept"]?.lastModified) > earlier.addingTimeInterval(60),
                "the undoing is dated after the import, so sync carries it")
    }

    /// A store that is not a `LampLibrary`, as the phone's is, and keeps no
    /// decks.
    private actor PhoneStore: LampWritingImportStore {
        var writings: [String: LampDevotional] = [:]
        var present: [String] = []
        func importableWritings() -> [LampDevotional] { Array(writings.values) }
        /// The phone's subscription writings, held but not offered.
        let held: Set<String> = ["subscribed"]
        func writingDeletion(id: String) -> LampPersonalDeletionLedger.Entry? { nil }
        func writingRefusal(id: String) -> String? {
            held.contains(id) ? "This is a subscribed writing, which an import leaves alone." : nil
        }
        func saveImportedWriting(_ writing: LampDevotional, expecting current: LampDevotional?) -> LampDevotional? {
            guard writings[writing.id] == current else { return nil }
            writings[writing.id] = writing
            return writing
        }
        func recordWritingsPresent(_ ids: [String]) { present += ids }
        func deleteImportedWriting(id: String, expecting current: LampDevotional) -> Bool {
            guard writings[id] == current else { return false }
            writings[id] = nil
            return true
        }
        func changeBehindTheImport(_ writing: LampDevotional) { writings[writing.id] = writing }
        func storeImportedMedia(from url: URL, writingID: String) -> String { url.lastPathComponent }
        func removeImportedMedia(writingID: String, filename: String) {}
        nonisolated var supportsDecks: Bool { false }
    }

    @Test func aStoreOtherThanTheLibraryPlansAndAppliesAlikeAndRefusesDecks() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("talks")
        try write("# Watch\n\nBe ready.", to: "watch.md", in: folder)
        try write(try deckJSON(id: "deck-watch", title: "Watch"), to: "watch.lampdeck", in: folder)
        let store = PhoneStore()
        let plan = try await LampWritingImport.plan(LampWritingImport.files(at: folder), in: store)
        #expect(plan.items.map(\.action) == [.create, .rejected])
        #expect(plan.items[1].errors == ["Decks are imported on the Mac."])
        let result = try await LampWritingImport.apply(plan, selecting: Set(plan.items.map(\.id)), to: store)
        #expect(result.imported.map(\.kind) == [.writing])
        #expect(await store.present == [plan.items[0].writingID])
        let again = try await LampWritingImport.plan(LampWritingImport.files(at: folder), in: store)
        #expect(again.items[0].action == .unchanged)

        // A writing the store holds but does not offer is refused by id.
        let held = try await LampWritingImport.plan([LampWritingImportFile(
            path: "talks/sub.md", markdown: "---\nid: subscribed\ntitle: Sub\n---\nText."
        )], in: store)
        #expect(held.items.map(\.action) == [.rejected])
        #expect(held.items[0].errors == ["This is a subscribed writing, which an import leaves alone."])

        // Changed by something else between the plan and the save: refused,
        // not overwritten, though the plan's own check saw nothing.
        try write("# Watch\n\nRevised.", to: "watch.md", in: folder, modified: Date().addingTimeInterval(60))
        let revised = try await LampWritingImport.plan(LampWritingImport.files(at: folder), in: store)
        #expect(revised.items[0].action == .update)
        let racing = try #require(await store.writings.values.first)
        let racedStore = RacingStore(inner: store, race: racing.withContent("Edited meanwhile."))
        let raced = try await LampWritingImport.apply(
            revised, selecting: [revised.items[0].id], to: racedStore
        )
        #expect(raced.imported.isEmpty)
        #expect(raced.refused.map(\.id) == [revised.items[0].id])
        #expect(await store.writings.values.first?.content == "Edited meanwhile.")
    }

    /// A store whose writing changes just after apply has read it, as a sync
    /// on another thread can on the phone.
    private struct RacingStore: LampWritingImportStore {
        let inner: PhoneStore
        let race: LampDevotional
        func importableWritings() async throws -> [LampDevotional] {
            let writings = await inner.importableWritings()
            await inner.changeBehindTheImport(race)
            return writings
        }
        func writingDeletion(id: String) async -> LampPersonalDeletionLedger.Entry? { nil }
        func saveImportedWriting(_ writing: LampDevotional, expecting current: LampDevotional?) async -> LampDevotional? {
            await inner.saveImportedWriting(writing, expecting: current)
        }
        func recordWritingsPresent(_ ids: [String]) async { await inner.recordWritingsPresent(ids) }
        func deleteImportedWriting(id: String, expecting current: LampDevotional) async -> Bool {
            await inner.deleteImportedWriting(id: id, expecting: current)
        }
        func storeImportedMedia(from url: URL, writingID: String) -> String { url.lastPathComponent }
        func removeImportedMedia(writingID: String, filename: String) {}
    }

    @Test func aRowOfTheSyncFileReadsBackAsTheWritingItCameFrom() throws {
        let writing = LampDevotional(
            id: "w-1", moduleID: "personal-devotionals", moduleName: "My Writing",
            title: "Watch", subtitle: "Two lessons", author: "M.", date: "2026-01-18",
            tags: ["Matthew", "readiness"], category: "exhortation",
            seriesName: "Parables", seriesOrder: 3,
            keyScriptures: [LampScriptureLink(text: "Matthew 24:36", startReference: 40_024_036, endReference: nil)],
            summary: "Be ready.", content: "As in the days of Noah.[^1]",
            footnotes: "[^1]: Genesis 6.",
            created: Date(timeIntervalSince1970: 1_700_000_000),
            lastModified: Date(timeIntervalSince1970: 1_700_000_100), isEditable: true
        )
        let read = LampPersonalWritingFile.writing(from: try LampPersonalWritingFile.row(for: writing))
        #expect(read.differingAuthoredFields(from: writing).isEmpty)
        #expect(read.created == writing.created)
        #expect(read.lastModified == writing.lastModified)
    }

    @Test func aPictureKeepsItsIdWhateverFolderIsChosenAndAReplacedOneComesIn() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let talks = root.appendingPathComponent("talks")
        try write("---\nid: map-talk\ntitle: Map\n---\n![The journeys](map.png)", to: "sub/talk.md", in: talks,
                  modified: Date(timeIntervalSince1970: 1_700_000_000))
        try onePixelPNG.write(to: talks.appendingPathComponent("sub/map.png"))
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let whole = try await library.planWritingImport(LampWritingImport.files(at: talks))
        try await library.applyWritingImport(whole, selecting: Set(whole.items.map(\.id)))
        let alone = try await library.planWritingImport(
            LampWritingImport.files(at: talks.appendingPathComponent("sub/talk.md"))
        )
        #expect(alone.items.map(\.action) == [.unchanged])

        // The same name, other bytes: a new picture, and the text names it.
        var other = onePixelPNG
        other.append(0)
        try other.write(to: talks.appendingPathComponent("sub/map.png"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_100)],
            ofItemAtPath: talks.appendingPathComponent("sub/talk.md").path
        )
        let replaced = try await library.planWritingImport(LampWritingImport.files(at: talks))
        #expect(replaced.items.map(\.action) == [.update])
        try await library.applyWritingImport(replaced, selecting: Set(replaced.items.map(\.id)))
        let writing = try #require(try await library.personalDevotionals().first)
        let named = writing.mediaReferences.first { writing.content.contains("media/\($0.id)") }
        let file = try #require(LampPortableDevotionalMedia.folderURL(
            rootURL: library.rootURL, scope: .devotional, ownerID: writing.id
        )).appendingPathComponent(try #require(named).filename)
        #expect(try Data(contentsOf: file) == other)
    }

    @Test func undoLeavesAWritingChangedInTheSameSecondAndUndoesImportsInTurn() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let document = LampWritingImportFile(path: "w/a.md", markdown: "# A\n\nFirst.")
        let first = try await library.planWritingImport([document])
        let created = try await library.applyWritingImport(first, selecting: Set(first.items.map(\.id)))

        // Changed, keeping its very time: still a change.
        let stored = try #require(try await library.personalDevotionals().first)
        try await library.savePersonalDevotional(stored.withContent("Edited, same second."), preserveLastModified: true)
        let left = try await library.undoWritingImport(created.undo)
        #expect(left.kept == ["A"])
        #expect(try await library.personalDevotionals().first?.content == "Edited, same second.")

        // Two imports of one writing undo in turn, newest first.
        try await library.savePersonalDevotional(stored, preserveLastModified: true)
        let second = try await library.planWritingImport([LampWritingImportFile(
            path: "w/a.md", markdown: "# A\n\nSecond.", modified: Date().addingTimeInterval(120)
        )])
        let updated = try await library.applyWritingImport(second, selecting: Set(second.items.map(\.id)))
        let newest = try await library.undoWritingImport(updated.undo)
        #expect(newest.undone == ["A"])
        #expect(try await library.personalDevotionals().first?.content == "First.")
        let older = created.undo.carrying(restored: newest.restored)
        let oldest = try await library.undoWritingImport(older)
        #expect(oldest.undone == ["A"])
        #expect(try await library.personalDevotionals().isEmpty)
    }

    @Test func aBrokenDeckSaysWhereItIsBroken() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("talks")
        try write("# Watch\n\nText.", to: "watch.md", in: folder)
        try write(#"{"schemaVersion": 1, "id": "d", "title": "Watch", "aspectRatio": "widescreen", "slides": []}"#,
                  to: "watch.lampdeck", in: folder)
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let plan = try await library.planWritingImport(LampWritingImport.files(at: folder))
        #expect(plan.items[1].errors == ["The deck is not a Lamp deck: it has no theme."])
    }

    @Test func twoDecksWithOneIdAreNotBothImported() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("talks")
        for name in ["one", "two"] {
            try write("# \(name)\n\nText.", to: "\(name).md", in: folder)
            try write(try deckJSON(id: "same-deck", title: name), to: "\(name).lampdeck", in: folder)
        }
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let plan = try await library.planWritingImport(LampWritingImport.files(at: folder))
        #expect(plan.items.map(\.action) == [.create, .create, .create, .rejected])
        #expect(plan.items[3].errors.last?.contains("same id") == true)
    }

    @Test func aLinkToAWritingLeftOutGoesBackAsWrittenAndOneImportedBeforeIsKept() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("study")
        try write("# One\n\nSee [two](two.md) and `[code](two.md)`.", to: "one.md", in: folder)
        try write("# Two\n\nText.", to: "two.md", in: folder)
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let plan = try await library.planWritingImport(LampWritingImport.files(at: folder))
        let one = try #require(plan.items.first { $0.path == "study/one.md" })
        let two = try #require(plan.items.first { $0.path == "study/two.md" })
        try await library.applyWritingImport(plan, selecting: [one.id])
        #expect(try await library.personalDevotionals().first?.content
            == "See [two](two.md) and `[code](two.md)`.")

        try await library.applyWritingImport(
            try await library.planWritingImport(LampWritingImport.files(at: folder)), selecting: [two.id]
        )
        let both = try await library.planWritingImport(LampWritingImport.files(at: folder))
        try await library.applyWritingImport(both, selecting: Set(both.items.map(\.id)))
        // Imported alone now, its link still finds the writing imported
        // before, so nothing reads as changed.
        let alone = try await library.planWritingImport(
            LampWritingImport.files(at: folder.appendingPathComponent("one.md"))
        )
        #expect(alone.items.map(\.action) == [.unchanged])
        #expect(try await library.personalDevotionals().first { $0.id == one.writingID }?.content
            == "See [two](lampbible://writing/\(two.writingID)) and `[code](two.md)`.")
    }

    @Test func aFileThatIsNotTextIsItsOwnRejectedRow() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("talks")
        try write("# Good\n\nText.", to: "good.md", in: folder)
        try Data([0xFF, 0xFE, 0x00, 0xD8]).write(to: folder.appendingPathComponent("bad.md"))
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let plan = try await library.planWritingImport(LampWritingImport.files(at: folder))
        #expect(plan.items.map(\.path) == ["talks/bad.md", "talks/good.md"])
        #expect(plan.items.map(\.action) == [.rejected, .create])
        #expect(plan.items[0].errors == ["talks/bad.md is not UTF-8 text."])
    }

    @Test func aPictureInInlineCodeIsAnExampleNotAPicture() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let plan = try await library.planWritingImport([LampWritingImportFile(
            path: "w/how.md", markdown: "# How\n\nWrite `![a map](missing.png)` for a picture."
        )])
        #expect(plan.items.map(\.action) == [.create])
        try await library.applyWritingImport(plan, selecting: Set(plan.items.map(\.id)))
        let writing = try #require(try await library.personalDevotionals().first)
        #expect(writing.content == "Write `![a map](missing.png)` for a picture.")
        #expect(writing.mediaReferences.isEmpty)
    }

    @Test func oneItemFailingLeavesTheRestImportedAndUndoable() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("talks")
        // The failing file comes after one that succeeds.
        try write("# Map\n\n![The journeys](map.png)", to: "z-map.md", in: folder)
        try onePixelPNG.write(to: folder.appendingPathComponent("map.png"))
        try write("# Plain\n\nText.", to: "plain.md", in: folder)
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let plan = try await library.planWritingImport(LampWritingImport.files(at: folder))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("map.png"))
        let result = try await library.applyWritingImport(plan, selecting: Set(plan.items.map(\.id)))
        #expect(result.failed.map(\.item.path) == ["talks/z-map.md"])
        #expect(result.imported.map(\.path) == ["talks/plain.md"])
        #expect(result.undo.writings.map(\.title) == ["Plain"])
        #expect(try await library.personalDevotionals().map(\.title) == ["Plain"])
        let undone = try await library.undoWritingImport(result.undo)
        #expect(undone.undone == ["Plain"])
        #expect(try await library.personalDevotionals().isEmpty)
    }

    @Test func aWritingThatFailsIsNoLongerLinkedToAndEachLinkKeepsItsOwnTarget() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("study")
        try write("# One\n\nSee [first](two.md#first), then [second](two.md#second).", to: "one.md", in: folder)
        try write("# Two\n\n![Map](map.png)", to: "two.md", in: folder)
        try onePixelPNG.write(to: folder.appendingPathComponent("map.png"))
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let plan = try await library.planWritingImport(LampWritingImport.files(at: folder))
        // Two's picture goes after the plan, so Two fails to import.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("map.png"))
        let result = try await library.applyWritingImport(plan, selecting: Set(plan.items.map(\.id)))
        #expect(result.failed.map(\.item.path) == ["study/two.md"])
        let one = try #require(try await library.personalDevotionals().first)
        #expect(one.content == "See [first](two.md#first), then [second](two.md#second).")
        // And undo still knows it as the import left it.
        #expect(try await library.undoWritingImport(result.undo).undone == ["One"])
    }

    @Test func undoingAnImportThatAddedAPicturePutsBackAWritingWithNone() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("w")
        try write("---\nid: a\ntitle: A\n---\nFirst.", to: "a.md", in: folder,
                  modified: Date(timeIntervalSince1970: 1_700_000_000))
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let first = try await library.planWritingImport(LampWritingImport.files(at: folder))
        let created = try await library.applyWritingImport(first, selecting: Set(first.items.map(\.id)))

        try write("---\nid: a\ntitle: A\n---\nFirst.\n\n![Map](map.png)", to: "a.md", in: folder,
                  modified: Date(timeIntervalSince1970: 1_700_000_100))
        try onePixelPNG.write(to: folder.appendingPathComponent("map.png"))
        let second = try await library.planWritingImport(LampWritingImport.files(at: folder))
        let updated = try await library.applyWritingImport(second, selecting: Set(second.items.map(\.id)))
        #expect(try await library.personalDevotionals().first?.mediaReferences.count == 1)

        let newest = try await library.undoWritingImport(updated.undo)
        let back = try #require(try await library.personalDevotionals().first)
        #expect(newest.undone == ["A"])
        #expect(back.content == "First.")
        #expect(back.mediaJSON == nil, "no picture left listed with nothing to show")
        let oldest = try await library.undoWritingImport(created.undo.carrying(restored: newest.restored))
        #expect(oldest.undone == ["A"])
        #expect(try await library.personalDevotionals().isEmpty)
    }

    @Test func puttingLinksBackKeepsTheWritersOwnLinksAndTheBlocks() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("study")
        try write("# Two\n\nText.", to: "two.md", in: folder)
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let twoID = try #require(try await library.planWritingImport(LampWritingImport.files(at: folder)).items.first?.writingID)
        let text = "See [mine](lampbible://writing/\(twoID)) and [the file](two.md#part)."
        try write("---\nid: one\ntitle: One\n---\n" + text, to: "one.md", in: folder,
                  modified: Date(timeIntervalSince1970: 1_700_000_000))
        // One is in Lamp already, with blocks from the phone.
        try await library.savePersonalDevotional(LampDevotional(
            id: "one", moduleID: "personal-devotionals", moduleName: "My Writing", title: "Two old",
            content: text, contentJSON: #"[{"type":"paragraph"}]"#,
            lastModified: Date(timeIntervalSince1970: 1_600_000_000)
        ), preserveLastModified: true)
        let plan = try await library.planWritingImport(LampWritingImport.files(at: folder))
        let one = try #require(plan.items.first { $0.writingID == "one" })
        try await library.applyWritingImport(plan, selecting: [one.id])
        let stored = try #require(try await library.personalDevotional(id: "one"))
        #expect(stored.content == text, "the writer's own link is theirs, and Two's link goes back as written")
        #expect(stored.contentJSON == #"[{"type":"paragraph"}]"#, "the text is the same, so the blocks stay")
    }

    @Test func aPictureChangedAfterThePlanIsRefused() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("talks")
        try write("# Map\n\n![The journeys](map.png)", to: "map.md", in: folder)
        try onePixelPNG.write(to: folder.appendingPathComponent("map.png"))
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let plan = try await library.planWritingImport(LampWritingImport.files(at: folder))
        try (onePixelPNG + Data([0])).write(to: folder.appendingPathComponent("map.png"))
        let result = try await library.applyWritingImport(plan, selecting: Set(plan.items.map(\.id)))
        #expect(result.failed.first?.reason.contains("changed after the plan") == true)
        #expect(try await library.personalDevotionals().isEmpty)
    }

    @Test func codeAcrossALineBreakIsStillCode() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let plan = try await library.planWritingImport([LampWritingImportFile(
            path: "w/how.md", markdown: "# How\n\nWrite `a picture as\n![a map](missing.png)` in Markdown."
        )])
        #expect(plan.items.map(\.action) == [.create])
        #expect(plan.items[0].errors.isEmpty)
    }

    @Test func theOldMarkdownImportNoLongerAddsCopies() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write(handout, to: "w/handout.md", in: root)
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let first = try await library.importPersonalMarkdown(from: file, as: .devotionals)
        let second = try await library.importPersonalMarkdown(from: file, as: .devotionals)
        #expect(first.importedCount == 1)
        #expect(second.importedCount == 0)
        #expect(try await library.personalDevotionals().count == 1)
    }
}
