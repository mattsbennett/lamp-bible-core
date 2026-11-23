import Foundation
import Testing
@testable import LampCore

/// Lamp's themes read well by the deck format's own measure, keep an author's
/// highlights in their hues when switched, and a slide's own ground gets the
/// words that read on it.
struct LampPresentationThemesTests {
    @Test(arguments: LampPresentationTheme.builtIn)
    func eachThemeAndItsPaletteReadOnItsGround(theme: LampPresentationTheme) throws {
        #expect(LampPresentationTheme.displayName(of: theme.id) != nil)
        var withPalette = theme
        let palette = LampPresentationTheme.highlightPalette(of: theme.id)
        #expect(palette.count == 4)
        withPalette.highlights = Dictionary(
            uniqueKeysWithValues: palette.enumerated().map { ("h\($0.offset)", $0.element) }
        )
        let deck = LampPresentationDeck(
            title: "Deck", theme: withPalette,
            slides: [.init(layout: .title, blocks: [.init(kind: .title, text: "Title")])]
        )
        // No contrast warning for the words, the accent or any highlight.
        #expect(LampPresentationDeckValidator.validate(deck).isEmpty)
    }

    @Test func switchingThemeKeepsEachHighlightInItsHue() {
        var current = LampPresentationTheme.parchment
        current.typeface = "system-serif"
        current.headingTypeface = "Baskerville"
        current.highlights = ["grace": "#1E5A8C", "law": "#A3242C"]
        let switched = LampPresentationTheme.lampDark.applied(over: current)
        #expect(switched.id == "lamp-dark")
        #expect(switched.typeface == "system-serif")
        #expect(switched.headingTypeface == "Baskerville")
        #expect(switched.highlights == ["grace": "#60A5FA", "law": "#F87171"])
    }

    @Test func wordsOnASlidesOwnGroundTakeTheThemeColourThatReads() throws {
        let theme = LampPresentationTheme.lampDark
        // The accent as a ground: dark words read on amber, so the words take
        // the theme's dark ground colour, and the accent, which would vanish,
        // takes the words' colour.
        let onAccent = try #require(theme.ink(on: theme.accentColor))
        #expect(onAccent.text == theme.backgroundColor)
        #expect(onAccent.accent == theme.backgroundColor)
        #expect(onAccent.contrast >= 4.5)
        // A ground like the theme's keeps the theme's words.
        #expect(theme.ink(on: "#1B2433")?.text == theme.foregroundColor)
        #expect(theme.ink(on: "not a colour") == nil)
    }

    @Test func aGroundNeitherThemeColourReadsOnIsSaid() {
        let deck = LampPresentationDeck(
            title: "Deck",
            slides: [.init(layout: .title, blocks: [.init(kind: .title, text: "T")], backgroundColor: "#808080")]
        )
        let issues = LampPresentationDeckValidator.validate(deck)
        #expect(issues.contains { $0.path == "slides[0].backgroundColor" && $0.severity == .warning })
        var broken = deck
        broken.slides[0].backgroundColor = "grey"
        #expect(LampPresentationDeckValidator.validate(broken).contains {
            $0.path == "slides[0].backgroundColor" && $0.severity == .error
        })
    }

    @Test func anOlderDeckHasNoneOfTheNewFields() throws {
        let theme = String(decoding: try JSONEncoder().encode(LampPresentationTheme.lampDark), as: UTF8.self)
        #expect(!theme.contains("headingTypeface"))
        let slide = String(decoding: try JSONEncoder().encode(LampPresentationSlide(layout: .blank)), as: UTF8.self)
        #expect(!slide.contains("backgroundColor"))
    }
}

extension LampPresentationThemesTests {
    @Test func aGreyHighlightThatWouldNotReadTakesAnUnusedPaletteColour() {
        var current = LampPresentationTheme.lampDark
        current.highlights = ["quiet": "#BBBBBB", "grace": "#60A5FA"]
        let switched = LampPresentationTheme.linen.applied(over: current)
        // Grace keeps its blue; the grey, unreadable on linen, takes the next
        // palette colour rather than the one grace has.
        #expect(switched.highlights?["grace"] == "#1F5FA8")
        #expect(switched.highlights?["quiet"] == "#8E2C5A")
        // On a ground it still reads on, a grey stays.
        let dark = LampPresentationTheme.nocturne.applied(over: current)
        #expect(dark.highlights?["quiet"] == "#BBBBBB")
    }
}
