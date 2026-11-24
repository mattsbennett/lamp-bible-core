import Foundation
import LampModuleKit
import Testing
@testable import LampCore

/// `Documentation/decisions/0005`: what a module is survives a launch.
///
/// A launch is a fresh `LampLibrary` over the same folder, so that is what
/// these make. The index is a cache of an answer about a file, so each of
/// these tries to make it answer for a file it should not: changed, replaced,
/// deleted, and an index that cannot be read at all.
struct LampInstalledModuleIndexTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-module-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func bookModule(_ id: String, title: String) -> String {
        """
        {"meta":{"schemaVersion":"1.0","id":"\(id)","type":"book","title":"\(title)","language":"en"},
         "sections":[{"id":"one","type":"chapter","title":"One",
           "content":[{"type":"paragraph","content":{"text":"A lamp to the feet."}}]}]}
        """
    }

    @discardableResult
    private func install(
        _ id: String, title: String, in root: URL, library: LampLibrary
    ) async throws -> URL {
        let archive = root.appendingPathComponent("\(id).lamp")
        _ = try LampModuleCompiler().compile(
            data: Data(bookModule(id, title: title).utf8),
            sourceFilename: "\(id).json",
            destinationURL: archive
        )
        _ = try await library.install(from: archive)
        return archive
    }

    @Test func aLaunchDoesNotInspectWhatTheLastOneDid() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryRoot = root.appendingPathComponent("Library")
        let first = LampLibrary(rootURL: libraryRoot)
        try await install("A", title: "Alpha", in: root, library: first)
        try await install("B", title: "Beta", in: root, library: first)
        _ = try await first.installedModules()

        // A launch: a new library over the same folder, nothing in memory.
        let next = LampLibrary(rootURL: libraryRoot)
        let modules = try await next.installedModules()

        #expect(modules.map(\.name).sorted() == ["Alpha", "Beta"])
        #expect(await next.installedModuleInspections == 0)
    }

    @Test func aChangedFileIsInspectedAgain() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryRoot = root.appendingPathComponent("Library")
        let first = LampLibrary(rootURL: libraryRoot)
        try await install("A", title: "Alpha", in: root, library: first)
        _ = try await first.installedModules()

        // The same module ID, rewritten with a different name, as reinstalling
        // an updated module does.
        let second = LampLibrary(rootURL: libraryRoot)
        try await install("A", title: "Alpha Revised", in: root, library: second)
        let modules = try await second.installedModules()

        #expect(modules.map(\.name) == ["Alpha Revised"])
        #expect(await second.installedModuleInspections >= 1)
    }

    @Test func aModuleThatIsGoneIsGone() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryRoot = root.appendingPathComponent("Library")
        let first = LampLibrary(rootURL: libraryRoot)
        try await install("A", title: "Alpha", in: root, library: first)
        try await install("B", title: "Beta", in: root, library: first)
        _ = try await first.installedModules()
        try await first.remove(moduleID: "B")

        let next = LampLibrary(rootURL: libraryRoot)
        #expect(try await next.installedModules().map(\.name) == ["Alpha"])
    }

    /// The index is a cache, so it has to be safe to lose or to find damaged.
    @Test func anIndexThatWillNotReadIsSimplyAbsent() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryRoot = root.appendingPathComponent("Library")
        let first = LampLibrary(rootURL: libraryRoot)
        try await install("A", title: "Alpha", in: root, library: first)
        _ = try await first.installedModules()

        let index = libraryRoot.appendingPathComponent("Indexes/InstalledModules.json")
        try Data("not an index".utf8).write(to: index)
        let next = LampLibrary(rootURL: libraryRoot)

        #expect(try await next.installedModules().map(\.name) == ["Alpha"])
        #expect(await next.installedModuleInspections == 1)
        // And it is written again, so the launch after this one is cheap.
        let after = LampLibrary(rootURL: libraryRoot)
        #expect(try await after.installedModules().map(\.name) == ["Alpha"])
        #expect(await after.installedModuleInspections == 0)
    }

    /// A module's `.lamp` file is beside its database and carries the size the
    /// library reports; changing one without the other re-inspects, and the
    /// index has to record the new count or every launch re-inspects again.
    /// Found by a Codex review of the first version, which compared only the
    /// file revisions.
    @Test func aChangedArchiveSizeIsRecorded() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryRoot = root.appendingPathComponent("Library")
        let first = LampLibrary(rootURL: libraryRoot)
        try await install("A", title: "Alpha", in: root, library: first)
        _ = try await first.installedModules()

        // The published `.lamp` beside the database, replaced at a different
        // size — as a module republished by another device arrives.
        let archive = try #require(
            try FileManager.default.contentsOfDirectory(
                at: libraryRoot.appendingPathComponent("Modules", isDirectory: true),
                includingPropertiesForKeys: nil
            ).first { $0.pathExtension == "lamp" },
            "the install should have kept the module's file"
        )
        let held = try Data(contentsOf: archive)
        try (held + Data(repeating: 0x20, count: 64)).write(to: archive)

        let next = LampLibrary(rootURL: libraryRoot)
        #expect(try await next.installedModules().count == 1)
        #expect(await next.installedModuleInspections == 1)

        let after = LampLibrary(rootURL: libraryRoot)
        #expect(try await after.installedModules().count == 1)
        #expect(await after.installedModuleInspections == 0)
    }
}

/// `Documentation/decisions/0006`: the open-database cache is bounded,
/// because each connection holds a file descriptor and an app launched from
/// the Finder gets 256 of them in all.
struct LampOpenDatabaseBoundTests {
    @Test func readingManyModulesDoesNotHoldADescriptorForEachForEver() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-fd-bound-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))

        // More modules than the cache keeps, each read once.
        let count = 60
        for index in 0..<count {
            let id = "BOUND\(index)"
            let archive = root.appendingPathComponent("\(id).lamp")
            _ = try LampModuleCompiler().compile(
                data: Data("""
                    {"meta":{"schemaVersion":"1.0","id":"\(id)","type":"book","title":"Book \(index)","language":"en"},
                     "sections":[{"id":"one","type":"chapter","title":"One",
                       "content":[{"type":"paragraph","content":{"text":"A lamp."}}]}]}
                    """.utf8),
                sourceFilename: "\(id).json",
                destinationURL: archive
            )
            _ = try await library.install(from: archive)
            try? FileManager.default.removeItem(at: archive)
        }

        let opened = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        for id in (0..<count).map({ "BOUND\($0)" }) {
            _ = try? await library.bookSections(moduleID: id)
        }
        let after = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count

        // Reading sixty modules must not leave sixty files open. The bound is
        // forty-eight, and installs opened some of these already, so the test
        // is that the count did not grow by one per module.
        #expect(after - opened < count, "held \(after - opened) descriptors for \(count) modules")
    }
}
