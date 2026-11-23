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
}
