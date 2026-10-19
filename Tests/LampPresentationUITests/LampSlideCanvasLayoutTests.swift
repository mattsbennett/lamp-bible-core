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

    /// Heights of contiguous runs of inked rows. Each run is roughly one line
    /// of text, so a run's height tracks the glyph size actually drawn — which
    /// is how "the list came out smaller than the prose" becomes measurable.
    ///
    /// `fromLeft` and `toLeft` narrow the columns read, which keeps a vertical
    /// rule — a quotation's accent bar, the divider between two columns — from
    /// joining every line beside it into one tall run.
    private func inkBandHeights(
        in image: CGImage,
        fromLeft: Double = 0,
        toLeft: Double = 1
    ) throws -> [Int] {
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

        let background = (r: 0x11, g: 0x18, b: 0x27)
        let firstColumn = Int(Double(image.width) * fromLeft)
        let lastColumn = min(Int(Double(image.width) * toLeft), image.width)
        var heights: [Int] = []
        var run = 0
        for y in 0..<image.height {
            var inked = false
            for x in stride(from: firstColumn, to: lastColumn, by: 2) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let distance = abs(Int(pixels[offset]) - background.r)
                    + abs(Int(pixels[offset + 1]) - background.g)
                    + abs(Int(pixels[offset + 2]) - background.b)
                if distance > 30 { inked = true; break }
            }
            if inked {
                run += 1
            } else if run > 0 {
                heights.append(run)
                run = 0
            }
        }
        if run > 0 { heights.append(run) }
        return heights
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

    @Test("A headed column draws both of its attributed passages")
    func twoColumnDrawsEveryCitationInEachColumn() throws {
        /// Each heading over a writer's sentence and the verse that answers
        /// him. The second passage used to become a third column and was never
        /// drawn, so the slide had to be split in two.
        let paired = LampPresentationSlide(layout: .twoColumn, blocks: [
            .init(kind: .title, text: "Two attitudes"),
            .init(kind: .subtitle, text: "Resignation"),
            .init(kind: .quotation, text: "Nothing to be done."),
            .init(kind: .citation, text: "Beckett"),
            .init(kind: .scripture, text: "We will not walk in it."),
            .init(kind: .citation, text: "Jeremiah 6:16"),
            .init(kind: .subtitle, text: "Expectancy"),
            .init(kind: .quotation, text: "Yet I will look again."),
            .init(kind: .citation, text: "Jonah 2:4"),
            .init(kind: .scripture, text: "and find rest for your souls."),
            .init(kind: .citation, text: "Jeremiah 6:16"),
        ])
        let single = LampPresentationSlide(layout: .twoColumn, blocks: [
            .init(kind: .title, text: "Two attitudes"),
            .init(kind: .subtitle, text: "Resignation"),
            .init(kind: .quotation, text: "Nothing to be done."),
            .init(kind: .citation, text: "Beckett"),
            .init(kind: .subtitle, text: "Expectancy"),
            .init(kind: .quotation, text: "Yet I will look again."),
            .init(kind: .citation, text: "Jonah 2:4"),
        ])
        let image = try render(paired, deck: deck)
        // Each half carries more than the same slide with one passage a side,
        // so the second passage and its citation reached both columns.
        for (fromLeft, toLeft) in [(0.02, 0.46), (0.54, 0.98)] {
            let both = try inkFraction(
                in: image, fromTop: 0.2, toTop: 0.98, fromLeft: fromLeft, toLeft: toLeft
            )
            let one = try inkFraction(
                in: try render(single, deck: deck),
                fromTop: 0.2, toTop: 0.98, fromLeft: fromLeft, toLeft: toLeft
            )
            #expect(both > one)
        }
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

    @Test("A list keeps its size when it shares a slide with a paragraph")
    func listIsNotCrushedBesideAParagraph() throws {
        let list = LampPresentationBlock(
            kind: .body,
            text: (1...8).map { "Point number \($0) in the sequence" }.joined(separator: "\n"),
            listStyle: .unordered
        )
        let paragraph = LampPresentationBlock(
            kind: .body,
            text: String(repeating: "A companion paragraph that takes real room. ", count: 6)
        )
        let shared = LampPresentationSlide(layout: .titleAndBody, blocks: [
            .init(kind: .title, text: "Heading"),
            list,
            paragraph,
        ])

        // Bands under 10px are rules and specks, not lines of text — the accent
        // rule beneath a heading is one of them. The tallest band is the
        // heading; the rest are list rows and paragraph lines.
        let bands = try inkBandHeights(in: try render(shared, deck: deck)).filter { $0 >= 10 }
        let lines = bands.sorted().dropLast()
        let smallest = try #require(lines.min())
        let largest = try #require(lines.max())

        // Each list row used to carry its own `minimumScaleFactor`, so a shared
        // slide squeezed the rows to little over half the size the paragraph
        // beside them kept. The slide now chooses one size for everything on
        // it, so a row and a line of the paragraph differ only by which
        // letters they happen to hold. The list drawn alone is no longer the
        // measure: a slide with less on it is set larger.
        #expect(
            Double(smallest) >= Double(largest) * 0.7,
            "lines came out between \(smallest)px and \(largest)px on one slide"
        )
    }

    // MARK: - Type sized to what the slide carries

    private func rows(_ count: Int) -> LampPresentationBlock {
        LampPresentationBlock(
            kind: .body,
            text: (1...count).map { "Point number \($0) in the sequence" }.joined(separator: "\n"),
            listStyle: .unordered
        )
    }

    private func tallestLine(
        of slide: LampPresentationSlide,
        fromLeft: Double = 0,
        toLeft: Double = 1
    ) throws -> Int {
        try #require(
            inkBandHeights(in: try render(slide, deck: deck), fromLeft: fromLeft, toLeft: toLeft)
                .filter { $0 >= 10 }
                .max()
        )
    }

    @Test("A slide with little on it sets its body larger than a full one")
    func sparseBodyIsSetLarger() throws {
        // No heading on either, so every band is a row of the list.
        let sparse = try tallestLine(of: .init(layout: .titleAndBody, blocks: [rows(2)]))
        let full = try tallestLine(of: .init(layout: .titleAndBody, blocks: [rows(12)]))
        // Both used to be drawn at the one size chosen for a full slide, which
        // left two lines small in the middle of an empty one.
        #expect(
            Double(sparse) >= Double(full) * 1.2,
            "two rows came out at \(sparse)px against \(full)px for twelve"
        )
    }

    @Test("A short quotation is set larger than a long one")
    func shortQuotationIsSetLarger() throws {
        // Read to the right of the accent rule, which runs the height of the
        // passage and would otherwise be measured instead of its lines.
        let short = try tallestLine(of: .init(layout: .quotation, blocks: [
            .init(kind: .quotation, text: "A long quotation."),
        ]), fromLeft: 0.1)
        let long = try tallestLine(of: .init(layout: .quotation, blocks: [
            .init(kind: .quotation, text: String(repeating: "A long quotation. ", count: 30)),
        ]), fromLeft: 0.1)
        #expect(
            Double(short) >= Double(long) * 1.2,
            "one sentence came out at \(short)px against \(long)px for thirty"
        )
    }

    @Test("Both columns of a two-column slide are set at one size")
    func columnsShareOneSize() throws {
        // The left column only, clear of the divider between the two.
        let besideLong = try tallestLine(of: .init(layout: .twoColumn, blocks: [
            .init(kind: .body, text: "Point number 1 in the sequence"),
            .init(
                kind: .body,
                text: (1...20).map { "Point number \($0) in the sequence" }.joined(separator: " ")
            ),
        ]), toLeft: 0.45)
        let besideShort = try tallestLine(of: .init(layout: .twoColumn, blocks: [
            .init(kind: .body, text: "Point number 1 in the sequence"),
            .init(kind: .body, text: "Point number 2 in the sequence"),
        ]), toLeft: 0.45)
        // Beside another short column the line is set large. Beside a long one
        // it takes the long one's size, so neither column reads as the lesser.
        #expect(
            besideLong < besideShort,
            "\(besideLong)px beside a long column, \(besideShort)px beside a short one"
        )
    }

    @Test("A column heading is drawn heavier than the prose under it")
    func columnHeadingIsHeavier() throws {
        let headed = LampPresentationSlide(layout: .twoColumn, blocks: [
            .init(kind: .subtitle, text: "The first search"),
            .init(kind: .body, text: "What was sought"),
            .init(kind: .subtitle, text: "The second search"),
            .init(kind: .body, text: "What was found"),
        ])
        // The same words with each heading typed as a line of its body, which
        // is how a heading had to be written before a column could carry one.
        let typed = LampPresentationSlide(layout: .twoColumn, blocks: [
            .init(kind: .body, text: "The first search\nWhat was sought"),
            .init(kind: .body, text: "The second search\nWhat was found"),
        ])
        let bold = try inkFraction(in: try render(headed, deck: deck), fromTop: 0, toTop: 1)
        let plain = try inkFraction(in: try render(typed, deck: deck), fromTop: 0, toTop: 1)
        #expect(bold > plain * 1.08, "headed \(bold) against typed \(plain)")
    }

    @Test("A column draws its citation")
    func columnDrawsItsCitation() throws {
        let cited = LampPresentationSlide(layout: .twoColumn, blocks: [
            .init(kind: .body, text: "What was sought"),
            .init(kind: .citation, text: "Ecclesiastes 7:25"),
            .init(kind: .body, text: "What was found"),
            .init(kind: .citation, text: "Ecclesiastes 7:29"),
        ])
        let bare = LampPresentationSlide(layout: .twoColumn, blocks: [
            .init(kind: .body, text: "What was sought"),
            .init(kind: .body, text: "What was found"),
        ])
        let with = try inkFraction(in: try render(cited, deck: deck), fromTop: 0, toTop: 1)
        let without = try inkFraction(in: try render(bare, deck: deck), fromTop: 0, toTop: 1)
        #expect(with > without)
    }
}
