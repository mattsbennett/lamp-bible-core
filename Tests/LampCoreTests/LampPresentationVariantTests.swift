import Foundation
import Testing
@testable import LampCore

/// A layout's forms: a word slide's plan, columns to four, and a comparison
/// that marks only the words the columns do not share.
struct LampPresentationVariantTests {
    @Test func aWordSlideDrawsItsTransliterationAndItsGloss() {
        let slide = LampPresentationSlide(layout: .title, blocks: [
            .init(id: "w", kind: .title, text: "ἀγάπη"),
            .init(id: "t", kind: .subtitle, text: "agapē"),
            .init(id: "g", kind: .body, text: "love"),
            .init(id: "v", kind: .scripture, text: "God is love."),
            .init(id: "c", kind: .citation, text: "1 John 4:8"),
        ], variant: .word)
        let plan = slide.plan
        #expect(plan.title?.id == "w")
        #expect(plan.subtitle?.id == "t")
        #expect(plan.detail?.id == "g")
        #expect(plan.ignored.isEmpty)
        // A plain title slide has room for one line under its heading.
        var plain = slide
        plain.variant = nil
        #expect(plain.plan.ignored.map(\.id) == ["g"])
    }

    @Test func aVariantOnTheWrongLayoutIsDrawnPlainAndSaidToBe() {
        let slide = LampPresentationSlide(
            layout: .scripture, blocks: [.init(kind: .scripture, text: "Words.")], variant: .statement
        )
        #expect(slide.drawnVariant == .none)
        let issues = LampPresentationDeckValidator.validate(LampPresentationDeck(title: "D", slides: [slide]))
        #expect(issues.contains { $0.path == "slides[0].variant" && $0.severity == .warning })
        let unknown = #"{"id":"s","layout":"title","blocks":[],"speakerNotes":"","isHidden":false,"variant":"banner"}"#
        let decoded = try? JSONDecoder().decode(LampPresentationSlide.self, from: Data(unknown.utf8))
        #expect(decoded?.variant == LampPresentationSlideVariant.none)
    }

    @Test func columnsDrawUpToFour() {
        let slide = LampPresentationSlide(layout: .twoColumn, blocks: (1...5).map {
            .init(id: "c\($0)", kind: .body, text: "Column \($0)")
        })
        #expect(slide.plan.columnGroups.count == 4)
        #expect(slide.plan.ignored.map(\.id) == ["c5"])
    }

    @Test func aComparisonMarksOnlyTheWordsTheColumnsDoNotShare() throws {
        let slide = LampPresentationSlide(layout: .twoColumn, blocks: [
            .init(id: "h1", kind: .subtitle, text: "KJV"),
            .init(id: "k", kind: .scripture, text: "For God so loved the world, that he gave his only begotten Son"),
            .init(id: "h2", kind: .subtitle, text: "ESV"),
            .init(id: "e", kind: .scripture, text: "For God so loved the world, that he gave his only Son"),
        ], variant: .comparison)
        let marked = slide.markingComparison()
        let kjv = try #require(marked.blocks.first { $0.id == "k" })
        #expect(kjv.emphasis?.map(\.text) == ["begotten"])
        let kjvRuns = kjv.drawnRuns(on: .twoColumn).filter { $0.mark != nil }.map(\.text)
        #expect(kjvRuns == ["begotten"])
        // Nothing in the ESV lacks a match in the KJV.
        #expect(marked.blocks.first { $0.id == "e" }?.emphasis == nil)
        // The headings are never compared.
        #expect(marked.blocks.first { $0.id == "h1" }?.emphasis == nil)
    }

    @Test func aRepeatedWordIsMarkedOnlyWhereItDiffers() throws {
        let slide = LampPresentationSlide(layout: .twoColumn, blocks: [
            .init(id: "a", kind: .body, text: "the Word was with God and the Word was God"),
            .init(id: "b", kind: .body, text: "the Word was with God and the Word was divine"),
        ], variant: .comparison)
        let marked = slide.markingComparison()
        let a = try #require(marked.blocks.first { $0.id == "a" })
        #expect(a.emphasis?.map(\.text) == ["God"])
        #expect(a.emphasis?.first?.occurrence == 2)
        let runs = a.drawnRuns(on: .twoColumn)
        // Only the second "God" is marked.
        #expect(runs.filter { $0.mark != nil }.count == 1)
        #expect(runs.last?.mark != nil)
        // Its emphasis lights on a step of its own when asked.
        var lit = slide
        lit.revealsEmphasis = true
        #expect(lit.revealPlan.emphasisStep)
    }

    @Test func withThreeColumnsTheFirstIsAPlainReference() throws {
        let slide = LampPresentationSlide(layout: .twoColumn, blocks: [
            .init(id: "a", kind: .body, text: "his only begotten Son"),
            .init(id: "b", kind: .body, text: "his only Son"),
            .init(id: "c", kind: .body, text: "his one and only Son"),
        ], variant: .comparison)
        let marked = slide.markingComparison()
        #expect(marked.blocks.first { $0.id == "a" }?.emphasis == nil)
        #expect(marked.blocks.first { $0.id == "b" }?.emphasis == nil)
        #expect(marked.blocks.first { $0.id == "c" }?.emphasis?.map(\.text) == ["one", "and"])
    }

    @Test func neighbouringDifferencesAreOnePhraseAndPunctuationIsNotAWord() throws {
        let slide = LampPresentationSlide(layout: .twoColumn, blocks: [
            .init(id: "a", kind: .body, text: "Blessed are the poor in spirit,"),
            .init(id: "b", kind: .body, text: "Blessed are the poor."),
        ], variant: .comparison)
        let a = try #require(slide.markingComparison().blocks.first { $0.id == "a" })
        #expect(a.emphasis?.map(\.text) == ["in", "spirit"])
    }

    @Test func bothSidesOfAPairReadOneAlignment() throws {
        let slide = LampPresentationSlide(layout: .twoColumn, blocks: [
            .init(id: "a", kind: .body, text: "Christ Jesus"),
            .init(id: "b", kind: .body, text: "Jesus Christ"),
        ], variant: .comparison).markingComparison()
        let a = try #require(slide.blocks.first { $0.id == "a" }?.emphasis?.map(\.text))
        let b = try #require(slide.blocks.first { $0.id == "b" }?.emphasis?.map(\.text))
        // The word left plain is the same word on both sides.
        #expect(Set(["Christ", "Jesus"]).subtracting(a) == Set(["Christ", "Jesus"]).subtracting(b))
    }

    @Test func repeatsAuthorsEmphasisAndDashesAreHandled() throws {
        let repeated = LampPresentationSlide(layout: .twoColumn, blocks: [
            .init(id: "a", kind: .body, text: "very very very good"),
            .init(id: "b", kind: .body, text: "very good"),
        ], variant: .comparison).markingComparison()
        let runs = try #require(repeated.blocks.first { $0.id == "a" }).drawnRuns(on: .twoColumn)
        #expect(runs.filter { $0.mark != nil }.map(\.text).joined(separator: "|") == "very|very")

        let authored = LampPresentationSlide(layout: .twoColumn, blocks: [
            .init(id: "a", kind: .body, text: "his only begotten Son", emphasis: [.init(text: "begotten")]),
            .init(id: "b", kind: .body, text: "his Son"),
        ], variant: .comparison).markingComparison()
        let marks = try #require(authored.blocks.first { $0.id == "a" }).drawnRuns(on: .twoColumn)
            .filter { $0.mark != nil }.map(\.text)
        #expect(marks.contains("only"))
        #expect(marks.contains("begotten"))

        let dashes = LampPresentationSlide(layout: .twoColumn, blocks: [
            .init(id: "a", kind: .body, text: "God\u{2014}who is love"),
            .init(id: "b", kind: .body, text: "God \u{2014} who is love"),
        ], variant: .comparison).markingComparison()
        #expect(dashes.blocks.allSatisfy { $0.emphasis == nil })
    }
}
