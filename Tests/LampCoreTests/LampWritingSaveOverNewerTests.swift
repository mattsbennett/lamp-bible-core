import Foundation
import LampCore
import Testing

/// An editor saves only over the copy it began from, never over a newer one
/// sync brought in while it was open.
struct LampWritingSaveOverNewerTests {
    private func writing(_ content: String, modified: TimeInterval) -> LampDevotional {
        LampDevotional(
            id: "W1", moduleID: "personal-devotionals", moduleName: "My Writing",
            title: "Grace", content: content,
            created: Date(timeIntervalSince1970: 1_800_000_000),
            lastModified: Date(timeIntervalSince1970: modified)
        )
    }

    @Test func aSaveOverANewerCopyWritesNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root)
        // The copy the editor opened, then a newer one from the phone.
        try await library.savePersonalDevotional(writing("mine", modified: 1_800_000_100), preserveLastModified: true)
        let opened = Date(timeIntervalSince1970: 1_800_000_100.7)
        try await library.savePersonalDevotional(writing("phone", modified: 1_800_000_200), preserveLastModified: true)

        let refused = try await library.savePersonalDevotional(writing("mine, edited", modified: 0), ifNotNewerThan: opened)
        #expect(refused == nil)
        #expect(try await library.personalDevotional(id: "W1")?.content == "phone")

        // Saved over the copy it holds, in the same second, it goes in.
        let held = Date(timeIntervalSince1970: 1_800_000_200.4)
        let saved = try await library.savePersonalDevotional(writing("mine, after all", modified: 0), ifNotNewerThan: held)
        #expect(saved?.content == "mine, after all")

        // A writing not stored yet is no conflict.
        let fresh = LampDevotional(id: "W2", moduleID: "personal-devotionals", moduleName: "My Writing", title: "New", content: "x")
        #expect(try await library.savePersonalDevotional(fresh, ifNotNewerThan: .distantPast) != nil)
    }
}
