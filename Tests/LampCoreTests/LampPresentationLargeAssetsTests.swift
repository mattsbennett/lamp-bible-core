import Foundation
import Testing
@testable import LampCore

/// A phone holds a deck's pictures always, and its videos and clips only
/// where downloading them is on, for the app or for that deck.
struct LampPresentationLargeAssetsTests {
    private func deck(_ id: String, picture: String, video: String? = nil, clip: String? = nil) -> LampPresentationDeck {
        LampPresentationDeck(id: id, title: id, slides: [.init(layout: .image, blocks: [
            .init(kind: .image, assetPath: "Assets/\(picture)", altText: "P", video: video.map { "Assets/\($0)" },
                  clip: clip.map { .init(source: "Assets/\($0)") }),
        ])])
    }

    @Test func videosAndClipsAreLargeAndPicturesAreNot() {
        let decks = [
            deck("a", picture: "a.jpg", video: "a.mp4"),
            deck("b", picture: "b.jpg", clip: "b.mov"),
            .init(id: "c", title: "c", slides: [.init(layout: .image, blocks: [
                .init(kind: .image, assetPath: "Assets/c.jpg", altText: "C", clip: .init(source: "https://youtu.be/dQw4w9WgXcQ")),
            ])]),
        ]
        #expect(LampPresentationLargeAssets.largeNames(in: decks) == ["a.mp4", "b.mov"])
    }

    @Test func aPhoneHoldsLargeFilesOnlyWhereAskedAndSharedFilesWhileAnyDeckWantsThem() {
        let a = deck("a", picture: "a.jpg", video: "shared.mp4")
        let b = deck("b", picture: "b.jpg", video: "shared.mp4", clip: "b.mov")
        let decks = [a, b]
        #expect(LampPresentationLargeAssets.wanted(decks: decks, downloadsLarge: false, decksDownloadingLarge: [])
            == ["a.jpg", "b.jpg"])
        #expect(LampPresentationLargeAssets.wanted(decks: decks, downloadsLarge: true, decksDownloadingLarge: [])
            == ["a.jpg", "b.jpg", "shared.mp4", "b.mov"])
        // One deck's override brings its files, including one it shares.
        #expect(LampPresentationLargeAssets.wanted(decks: decks, downloadsLarge: false, decksDownloadingLarge: ["a"])
            == ["a.jpg", "b.jpg", "shared.mp4"])
        #expect(!LampPresentationLargeAssets.shouldFetch("b.mov", decks: decks, downloadsLarge: false, decksDownloadingLarge: ["a"]))
    }

    @Test func whatADeckHoldsIsCountedFromTheDevice() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(count: 1_000).write(to: directory.appendingPathComponent("b.mov"))
        try Data(count: 10).write(to: directory.appendingPathComponent("b.jpg"))
        let held = LampPresentationLargeAssets.held(by: deck("b", picture: "b.jpg", clip: "b.mov"), in: directory)
        #expect(held.map(\.name) == ["b.mov"])
        #expect(held.map(\.bytes) == [1_000])
    }
}
