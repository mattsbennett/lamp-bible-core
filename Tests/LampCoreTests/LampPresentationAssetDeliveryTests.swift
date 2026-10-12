import Foundation
import Testing
@testable import LampCore

/// An agent writing a deck cannot put files in the library, so it leaves them
/// beside the deck and Lamp brings them in. These cover what it will and will
/// not accept from that folder.
struct LampPresentationAssetDeliveryTests {
    private struct Fixture {
        let root: URL
        let library: URL
        let delivery: URL
        let store: LampPresentationDeckStore

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            library = root.appendingPathComponent("Library", isDirectory: true)
            delivery = root.appendingPathComponent("Workspace", isDirectory: true)
            store = LampPresentationDeckStore(rootURL: library)
            try FileManager.default.createDirectory(
                at: delivery.appendingPathComponent("Assets", isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        func write(_ name: String, _ contents: String) throws {
            try Data(contents.utf8).write(
                to: delivery.appendingPathComponent("Assets/\(name)")
            )
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func deck(referencing paths: [String]) -> LampPresentationDeck {
        LampPresentationDeck(title: "Assets", slides: paths.enumerated().map { index, path in
            LampPresentationSlide(layout: .image, blocks: [
                .init(kind: .image, assetPath: path, altText: "Picture \(index)"),
            ])
        })
    }

    @Test func bringsInTheImagesADeckNames() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("cover.png", "cover bytes")
        try fixture.write("unused.png", "not referenced")

        let result = try fixture.store.importAssets(
            from: fixture.delivery,
            referencedBy: deck(referencing: ["Assets/cover.png"])
        )

        #expect(result.imported == ["Assets/cover.png"])
        #expect(result.missing.isEmpty)
        let landed = fixture.library
            .appendingPathComponent("Presentations/Assets/cover.png")
        #expect(try Data(contentsOf: landed) == Data("cover bytes".utf8))
        // A file the deck never mentions is not swept into the library.
        #expect(!FileManager.default.fileExists(
            atPath: fixture.library.appendingPathComponent("Presentations/Assets/unused.png").path
        ))
    }

    @Test func reportsAnImageThatWasNeverDelivered() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let result = try fixture.store.importAssets(
            from: fixture.delivery,
            referencedBy: deck(referencing: ["Assets/absent.png"])
        )
        #expect(result.imported.isEmpty)
        #expect(result.missing == ["Assets/absent.png"])
    }

    @Test func replacesAnImageWhoseBytesChanged() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let subject = deck(referencing: ["Assets/cover.png"])
        try fixture.write("cover.png", "first")
        try fixture.store.importAssets(from: fixture.delivery, referencedBy: subject)
        try fixture.write("cover.png", "second")
        try fixture.store.importAssets(from: fixture.delivery, referencedBy: subject)

        let landed = fixture.library.appendingPathComponent("Presentations/Assets/cover.png")
        #expect(try Data(contentsOf: landed) == Data("second".utf8))
    }

    @Test func refusesAPathThatClimbsOutOfTheDeliveredFolder() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let secret = fixture.root.appendingPathComponent("secret.txt")
        try Data("private".utf8).write(to: secret)

        // The validator refuses these too, but the copier must not depend on
        // having been validated.
        let result = try fixture.store.importAssets(
            from: fixture.delivery,
            referencedBy: deck(referencing: ["Assets/../../secret.txt"])
        )
        #expect(result.imported.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.library.appendingPathComponent("Presentations/secret.txt").path
        ))
    }

    @Test func doesNotFollowASymbolicLinkOutOfTheFolder() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let secret = fixture.root.appendingPathComponent("secret.txt")
        try Data("private".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(
            at: fixture.delivery.appendingPathComponent("Assets/link.txt"),
            withDestinationURL: secret
        )

        let result = try fixture.store.importAssets(
            from: fixture.delivery,
            referencedBy: deck(referencing: ["Assets/link.txt"])
        )
        #expect(result.imported.isEmpty)
        #expect(result.missing == ["Assets/link.txt"])
    }
}
