import CoreGraphics
import Foundation
import Testing
@testable import LampCore

/// A picture behind a slide is cropped around its focus, never past its own
/// edge; a tint is drawn in the theme's colours; both open in an older deck.
struct LampPresentationPictureTests {
    private let portrait = CGSize(width: 900, height: 1_600)
    private let widescreen = 16.0 / 9.0

    @Test func noFocusCropsTheMiddleAsBefore() {
        let shown = LampPresentationFocus.shown(in: portrait, frameRatio: widescreen, focus: nil)
        #expect(shown.width == 900)
        #expect(abs(shown.height - 506.25) < 0.01)
        #expect(abs(shown.midY - 800) < 0.01)
    }

    @Test func aFocusNearTheTopKeepsTheTopAndStopsAtTheEdge() {
        let face = LampPresentationFocus.shown(
            in: portrait, frameRatio: widescreen, focus: .init(x: 0.5, y: 0.2)
        )
        #expect(abs(face.midY - 320) < 0.01)
        // Asked for the very top, the crop stops at the picture's edge.
        let top = LampPresentationFocus.shown(in: portrait, frameRatio: widescreen, focus: .init(x: 0.5, y: 0))
        #expect(top.minY == 0)
        let bottom = LampPresentationFocus.shown(in: portrait, frameRatio: widescreen, focus: .init(x: 0.5, y: 1))
        #expect(abs(bottom.maxY - 1_600) < 0.01)
    }

    @Test func aWidePictureSlidesSideways() {
        let wide = CGSize(width: 4_000, height: 1_000)
        let left = LampPresentationFocus.shown(in: wide, frameRatio: widescreen, focus: .init(x: 0.1, y: 0.9))
        #expect(left.minX == 0)
        #expect(left.minY == 0)
        #expect(left.height == 1_000)
    }

    @Test func aDuotoneRunsFromTheDarkerToTheLighterOfAccentAndGround() {
        let dark = LampPresentationImageTint.duotone(of: .lampDark)
        #expect(dark.dark == LampPresentationTheme.lampDark.backgroundColor)
        #expect(dark.light == LampPresentationTheme.lampDark.accentColor)
        let light = LampPresentationImageTint.duotone(of: .parchment)
        #expect(light.dark == LampPresentationTheme.parchment.accentColor)
        #expect(light.light == LampPresentationTheme.parchment.backgroundColor)
    }

    @Test func focusAndTintAreCheckedAndUnknownTintsOpen() throws {
        var picture = LampPresentationBlock(
            kind: .image, assetPath: "Assets/a.jpg", altText: "A", placement: .background,
            focus: .init(x: 1.2, y: 0.5), tint: .duotone
        )
        var deck = LampPresentationDeck(title: "Deck", slides: [.init(layout: .title, blocks: [
            .init(kind: .title, text: "T"), picture,
        ])])
        #expect(LampPresentationDeckValidator.validate(deck).contains {
            $0.path == "slides[0].blocks[1].focus" && $0.severity == .error
        })
        picture.focus = .init(x: 0.5, y: 0.2)
        picture.placement = nil
        deck.slides[0].blocks[1] = picture
        #expect(LampPresentationDeckValidator.validate(deck).contains {
            $0.path == "slides[0].blocks[1].focus" && $0.severity == .warning
        })
        let json = #"{"id":"b","kind":"image","text":"","tint":"sepia"}"#
        let decoded = try JSONDecoder().decode(LampPresentationBlock.self, from: Data(json.utf8))
        #expect(decoded.tint == LampPresentationImageTint.none)
        let written = String(decoding: try JSONEncoder().encode(LampPresentationBlock(kind: .body, text: "x")), as: UTF8.self)
        #expect(!written.contains("focus"))
        #expect(!written.contains("tint"))
    }

    @Test func aDriftStartsStillClosesInSlowlyAndComesBack() {
        typealias Motion = LampPresentationImageMotion
        #expect(Motion.driftScale(after: 0) == 1)
        #expect(Motion.driftScale(after: -5) == 1)
        #expect(Motion.driftScale(after: .nan) == 1)
        #expect(abs(Motion.driftScale(after: Motion.driftPeriod / 2) - (1 + Motion.driftReach)) < 1e-9)
        #expect(abs(Motion.driftScale(after: Motion.driftPeriod) - 1) < 1e-9)
        // Barely moving on arrival: a second in, well under a thousandth.
        #expect(Motion.driftScale(after: 1) - 1 < 0.0001)
        var previous = 1.0
        for second in stride(from: 1.0, through: Motion.driftPeriod / 2, by: 1) {
            let scale = Motion.driftScale(after: second)
            #expect(scale >= previous)
            previous = scale
        }
    }

    @Test func aDriftClosesInOnTheFocusWhereTheCropShowsIt() {
        typealias Motion = LampPresentationImageMotion
        let middle = Motion.driftAnchor(in: portrait, frameRatio: widescreen, focus: nil)
        #expect(abs(middle.x - 0.5) < 1e-9 && abs(middle.y - 0.5) < 1e-9)
        // A face a fifth of the way down sits mid-frame once cropped around.
        let face = Motion.driftAnchor(in: portrait, frameRatio: widescreen, focus: .init(x: 0.3, y: 0.2))
        #expect(abs(face.x - 0.3) < 1e-9)
        #expect(abs(face.y - 0.5) < 1e-9)
        // At the very top the crop stops at the edge, and so does the anchor.
        let top = Motion.driftAnchor(in: portrait, frameRatio: widescreen, focus: .init(x: 0.5, y: 0))
        #expect(top.y == 0)
        let invalid = Motion.driftAnchor(in: portrait, frameRatio: widescreen, focus: .init(x: 3, y: 0.2))
        #expect(abs(invalid.x - 0.5) < 1e-9 && abs(invalid.y - 0.5) < 1e-9)
    }

    @Test func aDriftingPictureIsReadUnderTheWordsAtEachStep() {
        typealias Motion = LampPresentationImageMotion
        let caption = CGRect(x: 0.1, y: 0.8, width: 0.5, height: 0.1)
        // About a top focus, what lies below the caption rises into it.
        let views = Motion.driftViews(of: caption, anchor: CGPoint(x: 0.5, y: 0.1))
        #expect(views.count == Motion.driftSteps + 1)
        #expect(views.first == caption)
        #expect(abs(views.last!.minY - (0.1 + 0.7 / 1.03)) < 1e-9)
        for (earlier, later) in zip(views, views.dropFirst()) {
            #expect(later.minY < earlier.minY)
            #expect(earlier.minY - later.minY < 0.0075)
        }
        #expect(Motion.driftViews(of: .null, anchor: .zero).count == 1)
    }

    @Test func motionIsCheckedAndUnknownMotionsOpenStill() throws {
        let deck = LampPresentationDeck(title: "Deck", slides: [.init(layout: .titleAndBody, blocks: [
            .init(kind: .title, text: "T"),
            .init(kind: .body, text: "B", motion: .drift),
            .init(kind: .image, assetPath: "Assets/a.jpg", altText: "A", placement: .background, motion: .drift),
        ])])
        let issues = LampPresentationDeckValidator.validate(deck).filter { $0.path.hasSuffix(".motion") }
        #expect(issues.map(\.path) == ["slides[0].blocks[1].motion"])
        #expect(issues.first?.severity == .warning)
        let json = #"{"id":"b","kind":"image","text":"","motion":"orbit"}"#
        let decoded = try JSONDecoder().decode(LampPresentationBlock.self, from: Data(json.utf8))
        #expect(decoded.motion == LampPresentationImageMotion.none)
        let written = String(decoding: try JSONEncoder().encode(LampPresentationBlock(kind: .body, text: "x")), as: UTF8.self)
        #expect(!written.contains("motion"))
    }

    @Test func aVideoIsCheckedAndOlderDecksOpenWithout() throws {
        #expect(LampPresentationVideo.isPlayable("Assets/loop.MP4"))
        #expect(LampPresentationVideo.isPlayable("Assets/a.b.mov"))
        #expect(!LampPresentationVideo.isPlayable("Assets/loop.avi"))
        #expect(!LampPresentationVideo.isPlayable("Assets/.mp4"))
        #expect(!LampPresentationVideo.isPlayable("Assets/mp4"))
        let deck = LampPresentationDeck(title: "Deck", slides: [.init(layout: .titleAndBody, blocks: [
            .init(kind: .title, text: "T"),
            .init(kind: .body, text: "B", video: "Assets/a.mp4"),
            .init(kind: .image, assetPath: "Assets/a.jpg", altText: "A", placement: .background, video: "Assets/a.avi"),
        ]), .init(layout: .image, blocks: [
            .init(kind: .image, assetPath: "Assets/b.jpg", altText: "B", video: "../b.mp4"),
        ]), .init(layout: .image, blocks: [
            .init(kind: .image, assetPath: "Assets/c.jpg", altText: "C", video: "Assets/c.mov"),
        ])])
        let issues = LampPresentationDeckValidator.validate(deck).filter { $0.path.hasSuffix(".video") }
        #expect(issues.map(\.path) == [
            "slides[0].blocks[1].video", "slides[0].blocks[2].video", "slides[1].blocks[0].video",
        ])
        #expect(issues.map(\.severity) == [.warning, .warning, .error])
        let written = String(decoding: try JSONEncoder().encode(LampPresentationBlock(kind: .image, assetPath: "Assets/a.jpg")), as: UTF8.self)
        #expect(!written.contains("video"))
        // One video a slide: the one behind it plays, though it comes second.
        let two = LampPresentationDeck(title: "Two", slides: [.init(layout: .titleAndBody, blocks: [
            .init(kind: .title, text: "T"),
            .init(kind: .image, assetPath: "Assets/c.jpg", altText: "C", video: "Assets/c.mp4"),
            .init(kind: .image, assetPath: "Assets/d.jpg", altText: "D", placement: .background, video: "Assets/d.mp4"),
        ])])
        #expect(LampPresentationDeckValidator.validate(two).filter { $0.path.hasSuffix(".video") }.map(\.path)
            == ["slides[0].blocks[1].video"])
    }
}
