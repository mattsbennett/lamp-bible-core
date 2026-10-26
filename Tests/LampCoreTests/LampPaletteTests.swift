import Testing
@testable import LampCore

struct LampPaletteTests {
    /// The backgrounds text sits on: a plain page in light, and in dark the
    /// raised surface, which is the lighter and so the harder of the two.
    private let lightBackground = LampRGB(0xFFFFFF)
    private let darkBackground = LampRGB(0x1C1C1E)

    @Test func lampsOwnColorsReadAsBodyText() {
        // The accent and red-letter text are Lamp's own values, with no
        // system colour vouching for them, so they're held to 4.5:1 here.
        for role in [LampColorRole.accent, .wordsOfChrist] {
            #expect(LampRGB.contrast(role.color.light, lightBackground) >= 4.5, "\(role) light")
            #expect(LampRGB.contrast(role.color.dark, darkBackground) >= 4.5, "\(role) dark")
        }
    }

    /// A filled control's label belongs to the platform, and the platform
    /// draws it white. Held to 3:1 rather than 4.5:1 on purpose: Apple's own
    /// accents are no better against white, and reaching 4.5:1 would mean a
    /// darker red than either platform's chrome. Documentation/ColorRules.md
    /// has the numbers and the trade.
    @Test func aWhiteLabelOnTheAccentClearsTheFillBar() {
        let white = LampRGB(0xFFFFFF)
        #expect(LampRGB.contrast(white, LampColorRole.accent.color.light) >= 3)
        #expect(LampRGB.contrast(white, LampColorRole.accent.color.dark) >= 3)
    }

    /// The current match is drawn solid, with black text on it.
    @Test func blackTextReadsOnASolidFindMatch() {
        let black = LampRGB(0x000000)
        #expect(LampRGB.contrast(black, LampColorRole.findMatch.color.light) >= 4.5)
        #expect(LampRGB.contrast(black, LampColorRole.findMatch.color.dark) >= 4.5)
    }

    @Test func redLetterTextIsNotTheAccent() {
        #expect(LampColorRole.wordsOfChrist.color != LampColorRole.accent.color)
    }

    @Test func hexRoundTrips() {
        #expect(LampRGB(0xDB344A).hex == "DB344A")
        #expect(LampRGB(hex: "#db344a") == LampRGB(0xDB344A))
        #expect(LampRGB(hex: "DB344") == nil)
        #expect(LampHighlightPalette.all.allSatisfy { LampRGB(hex: $0.hex)?.hex == $0.hex })
    }

    @Test func aHighlightWithNoColorIsTheFallback() {
        #expect(LampHighlightSearch.normalizedColor(nil) == LampHighlightPalette.fallback.hex)
    }
}
