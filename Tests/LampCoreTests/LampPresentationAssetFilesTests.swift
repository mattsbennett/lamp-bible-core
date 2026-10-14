import Foundation
import Testing
@testable import LampCore

struct LampPresentationAssetFilesTests {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var store: LampPresentationDeckStore { .init(rootURL: root) }
        var assets: URL { store.assetsDirectoryURL }

        init() throws {
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        }

        func contents(_ name: String = "photo.jpg") throws -> String {
            String(decoding: try Data(contentsOf: assets.appendingPathComponent(name)), as: UTF8.self)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func revision(_ content: String, at time: TimeInterval = 100) -> LampPresentationAssetRevision {
        .init(name: "photo.jpg", data: Data(content.utf8), modifiedAt: Date(timeIntervalSince1970: time))
    }

    @Test func tiedImageEditsConvergeRegardlessOfArrivalOrder() throws {
        let first = try Fixture(), second = try Fixture()
        defer { first.remove(); second.remove() }
        try LampPresentationAssetFiles.merge([revision("alpha"), revision("zeta")], into: first.assets)
        try LampPresentationAssetFiles.merge([revision("zeta"), revision("alpha")], into: second.assets)
        #expect(try first.contents() == "zeta")
        #expect(try second.contents() == "zeta")
        #expect(try !LampPresentationAssetFiles.merge([revision("zeta")], into: first.assets))
    }

    @Test func aNewerImageWinsEvenWhenItsBytesSortEarlier() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try LampPresentationAssetFiles.merge([revision("zeta")], into: fixture.assets)
        try LampPresentationAssetFiles.merge([revision("old", at: 90)], into: fixture.assets)
        #expect(try fixture.contents() == "zeta")
        try LampPresentationAssetFiles.merge([revision("alpha", at: 110)], into: fixture.assets)
        #expect(try fixture.contents() == "alpha")
        #expect(try fixture.assets.appendingPathComponent("photo.jpg")
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            == Date(timeIntervalSince1970: 110))
    }

    @Test func invalidNamesAndLinkedFilesCannotWriteOutsideTheAssetFolder() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("private.txt")
        try Data("keep".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.assets.appendingPathComponent("linked.jpg"), withDestinationURL: outside
        )
        let incoming = ["../private.txt", "/private.txt", "folder/photo.jpg", "linked.jpg"].map {
            LampPresentationAssetRevision(name: $0, data: Data("overwrite".utf8), modifiedAt: Date())
        }
        #expect(try !LampPresentationAssetFiles.merge(incoming, into: fixture.assets))
        #expect(try Data(contentsOf: outside) == Data("keep".utf8))
        try LampPresentationAssetFiles.prune(in: fixture.assets, referencedNames: [])
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: fixture.assets.appendingPathComponent("linked.jpg").path
        ) == outside.path)
    }

    @Test func pruningKeepsAllImagesWhenAStoredDeckCannotBeRead() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try LampPresentationAssetFiles.merge([revision("keep")], into: fixture.assets)
        try Data("damaged deck".utf8).write(
            to: fixture.store.decksDirectoryURL.appendingPathComponent("damaged.lampdeck")
        )
        #expect(throws: (any Error).self) { try fixture.store.pruneUnreferencedAssets() }
        #expect(try fixture.contents() == "keep")
    }

    @Test func anAssetDirectoryLinkCannotBeReadMergedOrPruned() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let photo = outside.appendingPathComponent("photo.jpg")
        try Data("private".utf8).write(to: photo)
        try FileManager.default.removeItem(at: fixture.assets)
        try FileManager.default.createSymbolicLink(at: fixture.assets, withDestinationURL: outside)
        #expect(fixture.store.assetURL(forAssetPath: "Assets/photo.jpg") == nil)
        #expect(throws: (any Error).self) {
            try LampPresentationAssetFiles.merge([revision("overwrite")], into: fixture.assets)
        }
        #expect(throws: (any Error).self) {
            try fixture.store.pruneUnreferencedAssets()
        }
        #expect(try Data(contentsOf: photo) == Data("private".utf8))
    }
}
