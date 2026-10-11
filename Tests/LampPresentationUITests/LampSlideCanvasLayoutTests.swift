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
        toTop: Double,
        fromLeft: Double = 0,
        toLeft: Double = 1
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
        let firstColumn = Int(Double(image.width) * fromLeft)
        let lastColumn = min(Int(Double(image.width) * toLeft), image.width)
        var differing = 0
        var total = 0
        for y in first..<last {
            for x in stride(from: firstColumn, to: lastColumn, by: 2) {
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

    // MARK: - Content the renderer used to drop

    @Test("A quotation slide draws every quotation, not only the first")
    func quotationSlideDrawsEveryQuotation() throws {
        let one = LampPresentationSlide(layout: .scripture, blocks: [
            .init(kind: .scripture, text: "In the beginning was the Word."),
        ])
        let three = LampPresentationSlide(layout: .scripture, blocks: [
            .init(kind: .scripture, text: "In the beginning was the Word."),
            .init(kind: .scripture, text: "And the Word was with God."),
            .init(kind: .scripture, text: "And the Word was God."),
        ])
        // Three verses put more ink on the slide than one. Before this, the
        // second and third were discarded and both slides drew identically.
        let single = try inkFraction(in: try render(one, deck: deck), fromTop: 0, toTop: 1)
        let several = try inkFraction(in: try render(three, deck: deck), fromTop: 0, toTop: 1)
        #expect(several > single * 1.5)
    }

    @Test("A quotation slide draws every citation")
    func quotationSlideDrawsEveryCitation() throws {
        let slide = LampPresentationSlide(layout: .quotation, blocks: [
            .init(kind: .quotation, text: "A quoted sentence."),
            .init(kind: .citation, text: "First source"),
            .init(kind: .citation, text: "Second source"),
        ])
        let one = LampPresentationSlide(layout: .quotation, blocks: [
            .init(kind: .quotation, text: "A quoted sentence."),
            .init(kind: .citation, text: "First source"),
        ])
        let both = try inkFraction(in: try render(slide, deck: deck), fromTop: 0, toTop: 1)
        let single = try inkFraction(in: try render(one, deck: deck), fromTop: 0, toTop: 1)
        #expect(both > single)
    }

    @Test("A quotation slide draws a picture beside the quotation")
    func quotationSlideDrawsImageBesideText() throws {
        let slide = LampPresentationSlide(layout: .quotation, blocks: [
            .init(kind: .quotation, text: "A quoted sentence that carries the slide."),
            .init(kind: .citation, text: "A source"),
            .init(kind: .image, assetPath: "Assets/missing.png", altText: "A cover"),
        ])
        let image = try render(slide, deck: deck)
        // The placeholder fills its half, so the right side carries far more
        // ink than text alone would. Images used to draw on image slides only.
        let right = try inkFraction(in: image, fromTop: 0.2, toTop: 0.8, fromLeft: 0.62, toLeft: 0.98)
        #expect(right > 0.3)
        // And the quotation still holds the left.
        let left = try inkFraction(in: image, fromTop: 0.2, toTop: 0.8, fromLeft: 0.02, toLeft: 0.5)
        #expect(left > 0.01)
    }

    @Test("A title-and-body slide draws its citation")
    func titleAndBodyDrawsCitation() throws {
        let withCitation = LampPresentationSlide(layout: .titleAndBody, blocks: [
            .init(kind: .title, text: "Three Movements"),
            .init(kind: .body, text: "Body text"),
            .init(kind: .citation, text: "Source: a book worth naming"),
        ])
        let without = LampPresentationSlide(layout: .titleAndBody, blocks: [
            .init(kind: .title, text: "Three Movements"),
            .init(kind: .body, text: "Body text"),
        ])
        let cited = try inkFraction(in: try render(withCitation, deck: deck), fromTop: 0, toTop: 1)
        let plain = try inkFraction(in: try render(without, deck: deck), fromTop: 0, toTop: 1)
        #expect(cited > plain)
    }

    @Test("A title-and-body slide draws every body block")
    func titleAndBodyDrawsEveryBody() throws {
        let two = LampPresentationSlide(layout: .titleAndBody, blocks: [
            .init(kind: .title, text: "Three Movements"),
            .init(kind: .body, text: "The first movement."),
            .init(kind: .body, text: "The second movement."),
        ])
        let one = LampPresentationSlide(layout: .titleAndBody, blocks: [
            .init(kind: .title, text: "Three Movements"),
            .init(kind: .body, text: "The first movement."),
        ])
        let both = try inkFraction(in: try render(two, deck: deck), fromTop: 0, toTop: 1)
        let single = try inkFraction(in: try render(one, deck: deck), fromTop: 0, toTop: 1)
        #expect(both > single)
    }

    @Test("A title-and-body slide draws a picture beside its body")
    func titleAndBodyDrawsImageBesideBody() throws {
        let slide = LampPresentationSlide(layout: .titleAndBody, blocks: [
            .init(kind: .title, text: "Three Movements"),
            .init(kind: .body, text: "The idea this slide carries."),
            .init(kind: .image, assetPath: "Assets/missing.png", altText: "A cover"),
        ])
        let image = try render(slide, deck: deck)
        let right = try inkFraction(in: image, fromTop: 0.3, toTop: 0.8, fromLeft: 0.62, toLeft: 0.98)
        #expect(right > 0.3)
    }

    @Test("A quotation slide without a picture still fills the slide width")
    func quotationSlideWithoutImageIsUnchanged() throws {
        let slide = LampPresentationSlide(layout: .scripture, blocks: [
            .init(kind: .scripture, text: String(repeating: "A long quotation. ", count: 14)),
            .init(kind: .citation, text: "John 1:1"),
        ])
        let image = try render(slide, deck: deck)
        // No image means no column reserved for one: the text reaches well
        // past the midpoint, as it always did.
        let reach = try inkFraction(in: image, fromTop: 0.2, toTop: 0.8, fromLeft: 0.6, toLeft: 0.95)
        #expect(reach > 0.01)
    }
}
