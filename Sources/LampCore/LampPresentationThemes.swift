import Foundation

/// Lamp's own deck themes, and the rules that keep a deck readable when its
/// colours change: switching theme, or setting a slide's own ground.
///
/// Every theme holds its words to 4.5:1 against its ground and its accent and
/// highlight colours to 3:1, as the validator asks of any deck.
extension LampPresentationTheme {
    public static let oliveGrove = LampPresentationTheme(
        id: "olive-grove",
        backgroundColor: "#1C251C",
        foregroundColor: "#F2EFE4",
        accentColor: "#C8B35A"
    )

    public static let linen = LampPresentationTheme(
        id: "linen",
        backgroundColor: "#F8F6F1",
        foregroundColor: "#1C1C1E",
        accentColor: "#B4432C"
    )

    public static let harbour = LampPresentationTheme(
        id: "harbour",
        backgroundColor: "#E9EEF2",
        foregroundColor: "#13202C",
        accentColor: "#1F5FA8"
    )

    public static let vespers = LampPresentationTheme(
        id: "vespers",
        backgroundColor: "#241318",
        foregroundColor: "#F7EEE9",
        accentColor: "#E39B5C"
    )

    public static let nocturne = LampPresentationTheme(
        id: "nocturne",
        backgroundColor: "#0E1A2B",
        foregroundColor: "#EEF3F8",
        accentColor: "#7DB7E8"
    )

    /// Lamp's themes, in the order a picker shows them: the two the deck
    /// format has always had, then the rest.
    public static let builtIn: [LampPresentationTheme] = [
        .lampDark, .parchment, .oliveGrove, .linen, .harbour, .vespers, .nocturne,
    ]

    /// What a picker calls a theme: its name for one of Lamp's, nil for a
    /// deck's own.
    public static func displayName(of id: String) -> String? {
        switch id {
        case lampDark.id: "Lamp Dark"
        case parchment.id: "Parchment"
        case oliveGrove.id: "Olive Grove"
        case linen.id: "Linen"
        case harbour.id: "Harbour"
        case vespers.id: "Vespers"
        case nocturne.id: "Nocturne"
        default: nil
        }
    }

    /// Highlight colours chosen for one of Lamp's themes, each reading on its
    /// ground and apart from its accent and from each other: a blue, a red, a
    /// green and a violet, as the ground allows. Empty for a deck's own
    /// theme.
    ///
    /// Not stored in a deck. A deck's highlights are its own names for its
    /// own ideas; this is what they are coloured from when the theme changes.
    public static func highlightPalette(of id: String) -> [String] {
        switch id {
        case lampDark.id: ["#60A5FA", "#F87171", "#34D399", "#C4B5FD"]
        case parchment.id: ["#1E5A8C", "#A3242C", "#3F6B2A", "#6B3F8C"]
        case oliveGrove.id: ["#8EC5E8", "#E8968A", "#A8D08D", "#C9A8E0"]
        case linen.id: ["#1F5FA8", "#8E2C5A", "#2E6B3A", "#7A4FA0"]
        case harbour.id: ["#0F6E78", "#B3261E", "#2E6B3A", "#7A4FA0"]
        case vespers.id: ["#8FB8E8", "#F28B9B", "#9FD19A", "#C9A8E8"]
        case nocturne.id: ["#F2B66D", "#F28B9B", "#8FD3A8", "#C9A8E8"]
        default: []
        }
    }

    /// `self`, one of Lamp's themes, as a deck that had `current` takes it:
    /// the author's typefaces kept, and each of the author's highlight names
    /// kept and coloured from this theme's palette, by the colour nearest in
    /// hue to the one it had. A deck that drew grace in blue on a dark ground
    /// draws it in this theme's blue, which reads on this ground.
    public func applied(over current: LampPresentationTheme) -> LampPresentationTheme {
        var theme = self
        theme.typeface = current.typeface
        theme.headingTypeface = current.headingTypeface
        let palette = Self.highlightPalette(of: id)
        guard let highlights = current.highlights, !highlights.isEmpty else {
            theme.highlights = current.highlights
            return theme
        }
        guard !palette.isEmpty else {
            theme.highlights = highlights
            return theme
        }
        var recoloured: [String: String] = [:]
        // Hues first, so a grey takes a palette colour no hue has claimed.
        for (name, old) in highlights.sorted(by: { $0.key < $1.key }) {
            guard let hue = Self.hue(of: old) else { continue }
            recoloured[name] = palette.min { a, b in
                Self.hueDistance(hue, Self.hue(of: a) ?? 0) < Self.hueDistance(hue, Self.hue(of: b) ?? 0)
            } ?? old
        }
        // A grey has no hue to match. It stays where it still reads on this
        // ground; otherwise it takes a palette colour not yet in use, which
        // reads by construction, so a light grey set apart on a dark ground
        // is not left nearly invisible on a light one.
        for (name, old) in highlights.sorted(by: { $0.key < $1.key }) where recoloured[name] == nil {
            let reads = LampPresentationColor(hex: old).flatMap { color in
                LampPresentationColor(hex: backgroundColor).map { LampPresentationColor.contrast(color, $0) }
            }.map { $0 >= 3 } ?? false
            recoloured[name] = reads
                ? old
                : palette.first { !recoloured.values.contains($0) } ?? palette[0]
        }
        theme.highlights = recoloured
        return theme
    }

    /// The colours words take on a slide whose ground is `background`
    /// instead of the theme's.
    ///
    /// The words take whichever of the theme's two ground colours contrasts
    /// more with it, so a slide set in the accent, or in the words' own
    /// colour, still reads. The accent and each highlight are kept where they
    /// reach 3:1 on it and take the words' colour where they do not, as over
    /// a picture.
    public func ink(on background: String) -> LampPresentationInk? {
        guard let ground = LampPresentationColor(hex: background) else { return nil }
        func contrast(_ hex: String) -> Double {
            LampPresentationColor(hex: hex).map { LampPresentationColor.contrast($0, ground) } ?? 0
        }
        let text = contrast(foregroundColor) >= contrast(backgroundColor) ? foregroundColor : backgroundColor
        func kept(_ hex: String) -> String { contrast(hex) >= 3 ? hex : text }
        return LampPresentationInk(
            text: text,
            accent: kept(accentColor),
            highlights: (highlights ?? [:]).mapValues(kept),
            contrast: contrast(text)
        )
    }

    /// Hue in degrees, nil for a grey, which has none to match.
    static func hue(of hex: String) -> Double? {
        guard let color = LampPresentationColor(hex: hex) else { return nil }
        let high = max(color.red, color.green, color.blue)
        let low = min(color.red, color.green, color.blue)
        let range = high - low
        guard range > 0.04 else { return nil }
        let hue: Double = if high == color.red {
            ((color.green - color.blue) / range).truncatingRemainder(dividingBy: 6)
        } else if high == color.green {
            (color.blue - color.red) / range + 2
        } else {
            (color.red - color.green) / range + 4
        }
        let degrees = hue * 60
        return degrees < 0 ? degrees + 360 : degrees
    }

    private static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let difference = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(difference, 360 - difference)
    }
}

/// The colours a slide's words are drawn in when they are not the theme's own:
/// on a slide's own ground (`LampPresentationTheme.ink(on:)`).
public struct LampPresentationInk: Equatable, Sendable {
    public var text: String
    public var accent: String
    public var highlights: [String: String]
    /// How well the words read on the ground, from 1 to 21.
    public var contrast: Double
}
