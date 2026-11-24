import Foundation
import LampModuleKit
import Testing
@testable import LampCore

/// `devotional(moduleID:id:)` answers about one entry without reading the
/// collection it is in. What matters is that it answers *the same thing* the
/// whole-collection read does — the two share the row mapping so they cannot
/// drift, and these hold them to it for a writing of this device's and for an
/// installed collection alike.
struct LampSingleDevotionalReadTests {
    private func fixture() throws -> (library: LampLibrary, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-one-writing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (LampLibrary(rootURL: root.appendingPathComponent("Library")), root)
    }

    private func writing(_ index: Int) -> LampDevotional {
        LampDevotional(
            id: "writing-\(index)",
            moduleID: LampPersonalModule.writing.id,
            moduleName: LampPersonalModule.writing.name,
            title: "Writing \(index)",
            subtitle: "Number \(index)",
            author: "The Author",
            date: "2026-01-0\(index)",
            tags: ["one", "two"],
            category: "study",
            summary: "A summary.",
            content: "The body of writing \(index).",
            isEditable: true
        )
    }

    @Test func readsOneOfThisDevicesWritings() async throws {
        let (library, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 1...3 { _ = try await library.savePersonalDevotional(writing(index)) }

        let one = try await library.devotional(
            moduleID: LampPersonalModule.writing.id, id: "writing-2"
        )
        let fromTheWholeList = try await library.devotionals()
            .first { $0.id == "writing-2" }

        #expect(one == fromTheWholeList)
        #expect(one?.title == "Writing 2")
        #expect(try await library.devotional(
            moduleID: LampPersonalModule.writing.id, id: "writing-9"
        ) == nil)
    }

    @Test func readsOneEntryOfAnInstalledCollection() async throws {
        let (library, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try LampPersonalWritingFile.archive(
            (1...4).map(writing), moduleID: "a-collection", name: "A Collection"
        )
        let file = root.appendingPathComponent("a-collection.lamp")
        try archive.write(to: file)
        _ = try await library.install(from: file)

        let one = try await library.devotional(moduleID: "a-collection", id: "writing-3")
        let fromTheWholeList = try await library.devotionals(moduleIDs: ["a-collection"])
            .first { $0.id == "writing-3" }

        #expect(one != nil)
        #expect(one == fromTheWholeList)
        #expect(try await library.devotional(moduleID: "a-collection", id: "writing-9") == nil)
        // A module that is not installed, and one that is not a collection of
        // writings, are both simply nothing here rather than an error.
        #expect(try await library.devotional(moduleID: "not-installed", id: "writing-3") == nil)
    }
}
