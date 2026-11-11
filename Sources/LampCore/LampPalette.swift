import Foundation

/// The colours Lamp Bible gives a meaning to, the same on every platform.
///
/// Red is the app; blue takes you somewhere in the text; every other colour
/// carries one meaning and only that one. The rules in full, with what each
/// role is never for, are in Documentation/ColorRules.md.
///
/// Values are sRGB, for light and dark appearance. Where a role is a system
/// colour (original language, find match, the statuses), these are that
/// colour's values, for the places that have no system colour to ask for: the
/// writing editor's CSS, exported files, the widget. In app UI each platform
/// uses its own system colour, which matches.
public enum LampColorRole: String, CaseIterable, Sendable {
    /// Lamp red. Controls and the app's own chrome, what's selected or
    /// current, a control's own state (a reading's tick), and your own things
    /// in a conversation. Never links in text, search matches, tags or status,
    /// and nothing inside scripture text.
    case accent
    /// Lamp's link blue. Anything in Bible, module, note, devotional or chat
    /// text that takes you somewhere: verse references, cross-references,
    /// footnote markers and labels, web links. Never a control, and never on
    /// text that opens nothing. A step deeper than the system blue on white
    /// and a step softer on dark, so a paragraph dense with references, such
    /// as a lexicon sense, is still read for its words.
    case link
    /// System purple. Strong's numbers, Greek and Hebrew words, and lexicon
    /// references: links of one kind, kept apart from verse references where
    /// both run together, as in commentary.
    case originalLanguage
    /// Red-letter text, and only that. Never a sign of something to tap,
    /// which is why scripture text holds no accent.
    case wordsOfChrist
    /// System yellow, drawn as a background behind the words searched for,
    /// at `findMatchOpacity`; the current match solid, with black text.
    case findMatch
    /// System green: synced, saved, connected.
    case success
    /// System orange: waiting, a conflict, something missing.
    case warning
    /// System red: failed or unavailable, destructive, recording. Always with
    /// an icon or words, since it sits close to the accent.
    case error

    public var color: LampThemedColor {
        switch self {
        case .accent: LampThemedColor(light: 0xDB344A, dark: 0xEF4F63)
        case .link: LampThemedColor(light: 0x1A61CC, dark: 0x78ABF5)
        case .originalLanguage: LampThemedColor(light: 0xAF52DE, dark: 0xBF5AF2)
        case .wordsOfChrist: LampThemedColor(light: 0xBF4848, dark: 0xE07272)
        case .findMatch: LampThemedColor(light: 0xFFCC00, dark: 0xFFD60A)
        case .success: LampThemedColor(light: 0x34C759, dark: 0x30D158)
        case .warning: LampThemedColor(light: 0xFF9500, dark: 0xFF9F0A)
        case .error: LampThemedColor(light: 0xFF3B30, dark: 0xFF453A)
        }
    }

    /// How strongly a find match's background is drawn, behind text that
    /// keeps its own colour. In light appearance only: see
    /// `findMatchDarkGround`.
    public static let findMatchOpacity = 0.4

    /// A find match's ground in dark appearance: solid deep amber, under
    /// cream words (`findMatchDarkText`). The yellow's own wash goes muddy
    /// olive on charcoal; a light gold block with dark text glares, and a
    /// list of matches looks stamped; and yellow words on amber, though
    /// 6.5:1, read as dimmer than the text round them. Solid rather than a
    /// wash, so a selected row's fill can't show through.
    public static let findMatchDarkGround = LampRGB(0x4A3A0E)

    /// The words on `findMatchDarkGround`: cream, 9.9:1 against it (APCA Lc
    /// 91), as readable as body text on the dark window.
    public static let findMatchDarkText = LampRGB(0xFFF2C7)
}

/// A colour as it is in light and in dark appearance.
public struct LampThemedColor: Equatable, Sendable {
    public var light: LampRGB
    public var dark: LampRGB

    public init(light: LampRGB, dark: LampRGB) {
        self.light = light
        self.dark = dark
    }

    public init(light: UInt32, dark: UInt32) {
        self.init(light: LampRGB(light), dark: LampRGB(dark))
    }
}

/// An sRGB colour: the one core already has, named for the decks it was
/// first written for.
public typealias LampRGB = LampPresentationColor

extension LampPresentationColor {
    /// From `0xRRGGBB`.
    public init(_ hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// Six uppercase hex digits, without `#`, as highlights are stored.
    public var hex: String {
        let value = [red, green, blue]
            .map { UInt32((min(max($0, 0), 1) * 255).rounded()) }
            .reduce(0) { $0 << 8 | $1 }
        return String(format: "%06X", value)
    }
}

/// The highlight colours offered to choose from. Highlights are the person's
/// own: the app never uses one of these to say anything.
public enum LampHighlightPalette {
    public struct Entry: Equatable, Sendable {
        public var name: String
        /// Six uppercase hex digits, without `#`, as highlights are stored.
        public var hex: String
    }

    public static let yellow = Entry(name: "Yellow", hex: "FFCC00")
    public static let green = Entry(name: "Green", hex: "34C759")
    public static let blue = Entry(name: "Blue", hex: "007AFF")
    public static let pink = Entry(name: "Pink", hex: "FF2D55")
    public static let orange = Entry(name: "Orange", hex: "FF9500")
    public static let purple = Entry(name: "Purple", hex: "AF52DE")
    public static let red = Entry(name: "Red", hex: "FF3B30")
    public static let gray = Entry(name: "Gray", hex: "8E8E93")

    public static let all = [yellow, green, blue, pink, orange, purple, red, gray]

    /// What a new library offers before the person changes it.
    public static let offeredByDefault = [yellow, green, blue, pink]

    /// A highlight with no colour, or one that can't be read, is yellow.
    public static let fallback = yellow
}
