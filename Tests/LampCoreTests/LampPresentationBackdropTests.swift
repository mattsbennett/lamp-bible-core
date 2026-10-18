import CoreGraphics
import Foundation
import Testing
@testable import LampCore

/// A picture behind a slide, and the words read over it.
///
/// The words' colour and the scrim behind them are chosen from the picture, so
/// the choice is tested here on pictures made of known colours rather than by
/// looking at renders.
struct LampPresentationBackdropTests {
    private let white = LampPresentationColor(red: 1, green: 1, blue: 1)
    private let black = LampPresentationColor(red: 0, green: 0, blue: 0)
    private let wholeSlide = [CGRect(x: 0, y: 0, width: 1, height: 1)]
    private let neutral = LampPresentationTheme(
        id: "neutral-stone",
        backgroundColor: "#F4F3F1",
        foregroundColor: "#1F1F1F",
        accentColor: "#5C5853"
    )

    private func background(_ path: String = "Assets/picture.jpg") -> LampPresentationBlock {
        .init(kind: .image, assetPath: path, altText: "A city at its height", placement: .background)
    }

    // MARK: The format

    @Test("An image's placement survives a round trip, and a deck without one reads as before")
    func placementRoundTrips() throws {
        let deck = LampPresentationDeck(title: "Backdrop", slides: [
            .init(layout: .title, blocks: [background(), .init(kind: .title, text: "Title")]),
        ])
        let data = try LampPresentationDeckStore.encodedUnvalidated(deck)
        #expect(String(decoding: data, as: UTF8.self).contains(#""placement" : "background""#))
        let decoded = try LampPresentationDeckStore.decode(data)
        #expect(decoded.slides[0].blocks[0].placement == .background)

        let older = #"{"id":"b","kind":"image","text":"","assetPath":"Assets/a.jpg","altText":"A"}"#
        let block = try JSONDecoder().decode(LampPresentationBlock.self, from: Data(older.utf8))
        #expect(block.placement == nil)
        #expect(!block.isBackground)
    }

    @Test("A placement on anything but an image is refused")
    func placementNeedsAnImage() {
        let deck = LampPresentationDeck(title: "Backdrop", slides: [
            .init(layout: .title, blocks: [.init(kind: .title, text: "Title", placement: .background)]),
        ])
        #expect(LampPresentationDeckValidator.errors(in: deck).contains {
            $0.path == "slides[0].blocks[0].placement"
        })
    }

    // MARK: The plan

    @Test("A title slide draws a picture behind it, which is not the picture beside its prose")
    func titleSlideTakesABackground() {
        let plan = LampPresentationSlide(layout: .title, blocks: [
            background(),
            .init(kind: .title, text: "Has Mankind Evolved?"),
        ]).plan
        #expect(plan.background?.assetPath == "Assets/picture.jpg")
        #expect(plan.image == nil)
        #expect(plan.ignored.isEmpty)
        #expect(plan.drawn.first?.isBackground == true)
    }

    @Test("A second picture behind the slide is reported, not drawn beside the prose")
    func secondBackgroundIsIgnored() {
        let slide = LampPresentationSlide(layout: .titleAndBody, blocks: [
            background("Assets/one.jpg"),
            .init(kind: .title, text: "Title"),
            .init(kind: .body, text: "Body"),
            background("Assets/two.jpg"),
        ])
        #expect(slide.plan.background?.assetPath == "Assets/one.jpg")
        #expect(slide.plan.image == nil)
        #expect(slide.plan.ignored.map(\.assetPath) == ["Assets/two.jpg"])
        let messages = LampPresentationDeckValidator.validate(
            LampPresentationDeck(title: "Backdrop", slides: [slide])
        ).map(\.message)
        #expect(messages.contains { $0.contains("image content behind it more than once") })
    }

    @Test("A caption credits the picture behind the slide when nothing is pictured beside the prose")
    func captionCreditsTheBackground() {
        let credited = LampPresentationSlide(layout: .title, blocks: [
            background(),
            .init(kind: .title, text: "Title"),
            .init(kind: .caption, text: "Thomas Cole, The Consummation of Empire (1836)"),
        ]).plan
        #expect(credited.caption?.text.hasPrefix("Thomas Cole") == true)
        #expect(credited.ignored.isEmpty)

        let beside = LampPresentationSlide(layout: .titleAndBody, blocks: [
            background(),
            .init(kind: .title, text: "Title"),
            .init(kind: .body, text: "Body"),
            .init(kind: .image, assetPath: "Assets/cover.jpg", altText: "A cover"),
            .init(kind: .caption, text: "The cover"),
        ]).plan
        #expect(beside.image?.assetPath == "Assets/cover.jpg")
        #expect(beside.caption?.text == "The cover")

        // Without a picture behind it, a title slide still has nothing to caption.
        let bare = LampPresentationSlide(layout: .title, blocks: [
            .init(kind: .title, text: "Title"),
            .init(kind: .caption, text: "A caption"),
        ]).plan
        #expect(bare.caption == nil)
        #expect(bare.ignored.map(\.kind) == [.caption])
    }

    // MARK: The words over the picture

    @Test("Words over a pale picture are set dark, and over a dark one light, with no scrim")
    func wordsTakeTheColourThatReads() {
        let overWhite = LampPresentationBackdrop.uniform(white)
            .treatment(for: wholeSlide, theme: .lampDark)
        #expect(overWhite.text == LampPresentationTheme.lampDark.backgroundColor)
        #expect(overWhite.scrimOpacity == 0)

        let overBlack = LampPresentationBackdrop.uniform(black)
            .treatment(for: wholeSlide, theme: neutral)
        #expect(overBlack.text == neutral.backgroundColor)
        #expect(overBlack.scrimOpacity == 0)
    }

    @Test("A mid-tone picture is covered just enough for the words to reach 4.5:1")
    func scrimIsTheLeastThatReads() {
        let grey = LampPresentationColor(hex: "#808080")!
        let backdrop = LampPresentationBackdrop.uniform(grey)
        let treatment = backdrop.treatment(for: wholeSlide, theme: neutral)
        #expect(treatment.scrimOpacity > 0)
        #expect(treatment.scrimOpacity < 0.5)
        #expect(treatment.contrast >= LampPresentationBackdrop.targetContrast)

        let ink = LampPresentationColor(hex: treatment.text)!
        let scrim = LampPresentationColor(hex: treatment.scrim)!
        let less = LampPresentationBackdrop.contrast(
            of: ink,
            over: backdrop.cells,
            scrim: scrim,
            // It is rounded up to the next hundredth, so one hundredth less
            // may still just pass; two may not.
            opacity: treatment.scrimOpacity - 0.02
        )
        #expect(less < LampPresentationBackdrop.targetContrast)
    }

    @Test("Only the picture under the words is read")
    func onlyTheWordsRegionCounts() {
        // Black on the left half, white on the right.
        let columns = 16
        let rows = 9
        let cells = (0..<rows).flatMap { _ in
            (0..<columns).map { column -> LampPresentationBackdrop.Cell in
                let color = column < columns / 2 ? black : white
                return .init(darkest: color, lightest: color)
            }
        }
        let backdrop = LampPresentationBackdrop(columns: columns, rows: rows, cells: cells)
        let left = backdrop.treatment(for: [CGRect(x: 0.05, y: 0.4, width: 0.3, height: 0.1)], theme: neutral)
        let right = backdrop.treatment(for: [CGRect(x: 0.6, y: 0.4, width: 0.3, height: 0.1)], theme: neutral)
        #expect(left.text == neutral.backgroundColor)
        #expect(right.text == neutral.foregroundColor)
        #expect(left.scrimOpacity == 0 && right.scrimOpacity == 0)
    }

    @Test("A glint under a few letters does not darken a whole title")
    func aFewHighlightsAreForgiven() {
        // Black throughout but for 3 of the 100 cells under the words.
        var cells = Array(repeating: LampPresentationBackdrop.Cell(darkest: black, lightest: black), count: 100)
        for index in [7, 42, 77] { cells[index] = .init(darkest: white, lightest: white) }
        let backdrop = LampPresentationBackdrop(columns: 10, rows: 10, cells: cells)
        let treatment = backdrop.treatment(for: wholeSlide, theme: neutral)
        #expect(treatment.text == neutral.backgroundColor)
        #expect(treatment.scrimOpacity == 0)
    }

    @Test("Fine black lines on white paper count as both, not as their grey average")
    func engravingIsReadAsLinesAndPaper() {
        let mixed = LampPresentationBackdrop.Cell(darkest: black, lightest: white)
        let engraving = LampPresentationBackdrop(columns: 4, rows: 4, cells: Array(repeating: mixed, count: 16))
        let average = LampPresentationBackdrop.uniform(LampPresentationColor(hex: "#BCBCBC")!)
        let overLines = engraving.treatment(for: wholeSlide, theme: neutral)
        let overAverage = average.treatment(for: wholeSlide, theme: neutral)
        #expect(overAverage.scrimOpacity == 0)
        #expect(overLines.scrimOpacity >= 0.4)
        #expect(overLines.contrast >= LampPresentationBackdrop.targetContrast)
    }

    @Test("An accent that would not read over the picture takes the words' colour")
    func accentFallsBackToTheText() {
        // Amber on white is about 2:1, short of the 3:1 an accent keeps to.
        let overWhite = LampPresentationBackdrop.uniform(white)
            .treatment(for: wholeSlide, theme: .lampDark)
        #expect(overWhite.accent == overWhite.text)

        let overBlack = LampPresentationBackdrop.uniform(black)
            .treatment(for: wholeSlide, theme: .lampDark)
        #expect(overBlack.accent == LampPresentationTheme.lampDark.accentColor)
    }

    @Test("A slide with no words leaves its picture alone")
    func noWordsNoScrim() {
        let treatment = LampPresentationBackdrop.uniform(LampPresentationColor(hex: "#808080")!)
            .treatment(for: [], theme: neutral)
        #expect(treatment.scrimOpacity == 0)
        #expect(treatment.text == neutral.foregroundColor)
    }
}
