import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import LampCore
@testable import LampPresentationUI

/// Renders the canvas off-screen and reads the pixels back.
///
/// A slide's layout is the whole point of this view, and it is the one thing a
/// model test cannot see. Rendering at the deck's own design size makes
/// "the title is missing" an assertion rather than something you notice in a
/// screenshot weeks later.
@MainActor
struct LampSlideCanvasLayoutTests {
    private let width = 1_600.0
    private let height = 900.0

    private func render(_ slide: LampPresentationSlide, deck: LampPresentationDeck) throws -> CGImage {
        let renderer = ImageRenderer(
            content: LampPresentationSlideCanvas(slide: slide, deck: deck)
                .frame(width: width, height: height)
        )
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        return image
    }

    /// Fraction of pixels in a horizontal band that differ from the deck's
    /// background colour — ink, in other words.
    private func inkFraction(
        in image: CGImage,
        fromTop: Double,
        toTop: Double
    ) throws -> Double {
        let bytesPerPixel = 4
        let bytesPerRow = image.width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: image.height * bytesPerRow)
        let context = try #require(
            CGContext(
                data: &pixels,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        // #111827, the deck's background.
        let background = (r: 0x11, g: 0x18, b: 0x27)
        let first = Int(Double(image.height) * fromTop)
        let last = min(Int(Double(image.height) * toTop), image.height)
        var differing = 0
        var total = 0
        for y in first..<last {
            for x in stride(from: 0, to: image.width, by: 2) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let distance = abs(Int(pixels[offset]) - background.r)
                    + abs(Int(pixels[offset + 1]) - background.g)
                    + abs(Int(pixels[offset + 2]) - background.b)
                if distance > 30 { differing += 1 }
                total += 1
            }
        }
        return total == 0 ? 0 : Double(differing) / Double(total)
    }

    private var deck: LampPresentationDeck {
        LampPresentationDeck(title: "Layout", slides: [
            LampPresentationSlide(layout: .blank, blocks: [.init(kind: .body, text: "placeholder")]),
        ])
    }

    @Test("A title-and-body slide draws its title near the top")
    func titleAndBodyDrawsTitle() throws {
        let slide = LampPresentationSlide(layout: .titleAndBody, blocks: [
            .init(kind: .title, text: "Three Movements"),
            .init(kind: .body, text: "Body text"),
        ])
        let image = try render(slide, deck: deck)
        #expect(try inkFraction(in: image, fromTop: 0.05, toTop: 0.25) > 0.01)
    }

    @Test("An image slide draws its title, not only its picture")
    func imageSlideDrawsTitle() throws {
        let slide = LampPresentationSlide(layout: .image, blocks: [
            .init(kind: .title, text: "The Olive Grove"),
            .init(kind: .image, assetPath: "Assets/missing.png", altText: "A picture"),
            .init(kind: .caption, text: "Gethsemane, early morning"),
        ])
        let image = try render(slide, deck: deck)
        // The title band, above where the picture may start.
        #expect(try inkFraction(in: image, fromTop: 0.04, toTop: 0.16) > 0.005)
    }

    @Test("An image slide draws its caption")
    func imageSlideDrawsCaption() throws {
        let slide = LampPresentationSlide(layout: .image, blocks: [
            .init(kind: .title, text: "The Olive Grove"),
            .init(kind: .image, assetPath: "Assets/missing.png", altText: "A picture"),
            .init(kind: .caption, text: "Gethsemane, early morning"),
        ])
        let image = try render(slide, deck: deck)
        #expect(try inkFraction(in: image, fromTop: 0.86, toTop: 0.97) > 0.005)
    }

    /// The iOS viewer does not hand the canvas a 16:9 box. It letterboxes a
    /// full-screen frame, which is how the slide is actually sized in the app.
    private func renderAsViewer(
        _ slide: LampPresentationSlide,
        deck: LampPresentationDeck,
        screen: CGSize
    ) throws -> CGImage {
        let renderer = ImageRenderer(
            content: LampPresentationSlideCanvas(slide: slide, deck: deck)
                .aspectRatio(deck.aspectRatio.ratio, contentMode: .fit)
                .frame(width: screen.width, height: screen.height)
        )
        renderer.scale = 1
        return try #require(renderer.cgImage)
    }

    @Test("An image slide keeps its title when the viewer letterboxes it")
    func imageSlideDrawsTitleWhenLetterboxed() throws {
        let slide = LampPresentationSlide(layout: .image, blocks: [
            .init(kind: .title, text: "The Olive Grove"),
            .init(kind: .image, assetPath: "Assets/missing.png", altText: "A picture"),
            .init(kind: .caption, text: "Gethsemane, early morning"),
        ])
        // An iPhone held landscape: wider than 16:9, so the slide is letterboxed
        // left and right and fills the height.
        let image = try renderAsViewer(slide, deck: deck, screen: .init(width: 874, height: 402))
        #expect(try inkFraction(in: image, fromTop: 0.04, toTop: 0.16) > 0.005)
    }

    @Test("An image slide with no title still fills the slide")
    func imageSlideWithoutTitle() throws {
        let slide = LampPresentationSlide(layout: .image, blocks: [
            .init(kind: .image, assetPath: "Assets/missing.png", altText: "A picture"),
        ])
        let image = try render(slide, deck: deck)
        #expect(try inkFraction(in: image, fromTop: 0.3, toTop: 0.7) > 0.05)
    }
}
