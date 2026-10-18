import CoreGraphics
import Foundation

/// An sRGB colour as a deck stores it and a screen blends it: each channel
/// gamma-encoded, from 0 to 1.
public struct LampPresentationColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Six-digit hex, with or without a leading `#`.
    public init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xff) / 255,
            green: Double((rgb >> 8) & 0xff) / 255,
            blue: Double(rgb & 0xff) / 255
        )
    }

    /// WCAG relative luminance.
    public var luminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.039_28 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast between two colours, from 1 to 21.
    public static func contrast(_ first: Self, _ second: Self) -> Double {
        let a = first.luminance
        let b = second.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// This colour with `other` laid over it at `opacity`, blended channel by
    /// channel as SwiftUI composites in sRGB.
    public func under(_ other: Self, opacity: Double) -> Self {
        .init(
            red: red + (other.red - red) * opacity,
            green: green + (other.green - green) * opacity,
            blue: blue + (other.blue - blue) * opacity
        )
    }
}

/// What a picture behind a slide is like where the words fall, and what it
/// takes to read them over it.
///
/// The picture is divided into cells, each a little larger than a stroke of
/// body type, and each remembers the darkest and the lightest colour inside
/// it. An engraving's black lines on white paper are then two colours to read
/// against, not one mid-grey average that either colour of text would pass.
public struct LampPresentationBackdrop: Equatable, Sendable {
    /// One cell: the darkest and the lightest of the picture within it.
    public struct Cell: Equatable, Sendable {
        public var darkest: LampPresentationColor
        public var lightest: LampPresentationColor

        public init(darkest: LampPresentationColor, lightest: LampPresentationColor) {
            self.darkest = darkest
            self.lightest = lightest
        }
    }

    /// How a slide's words are drawn over its picture.
    public struct Treatment: Equatable, Sendable {
        /// The colour of the words: one of the theme's two ground colours.
        public var text: String
        /// Citations and rules: the theme's accent while it still reads over
        /// the picture, and otherwise the text colour.
        public var accent: String
        /// What the picture is darkened or lightened with behind the words:
        /// the theme's other ground colour.
        public var scrim: String
        /// From 0, where the picture is left alone, to 1, where it is hidden.
        public var scrimOpacity: Double
        /// The contrast the words have over at least `coverage` of what lies
        /// behind them, once the scrim is laid.
        public var contrast: Double

        public init(
            text: String,
            accent: String,
            scrim: String,
            scrimOpacity: Double,
            contrast: Double
        ) {
            self.text = text
            self.accent = accent
            self.scrim = scrim
            self.scrimOpacity = scrimOpacity
            self.contrast = contrast
        }
    }

    /// What every word on a slide is held to: WCAG's level for body text,
    /// which is also what the deck validator asks of a theme.
    public static let targetContrast = 4.5
    /// What an accent must keep to stay the accent, as for a theme.
    public static let accentContrast = 3.0
    /// The share of the picture behind the words that must meet the target.
    /// A glint or a candle flame under one letter should not darken a whole
    /// title.
    public static let coverage = 0.95

    public let columns: Int
    public let rows: Int
    /// Row by row from the top left.
    public let cells: [Cell]

    public init(columns: Int, rows: Int, cells: [Cell]) {
        precondition(columns > 0 && rows > 0 && cells.count == columns * rows)
        self.columns = columns
        self.rows = rows
        self.cells = cells
    }

    /// A picture of one colour throughout, for tests and placeholders.
    public static func uniform(_ color: LampPresentationColor, columns: Int = 16, rows: Int = 9) -> Self {
        .init(
            columns: columns,
            rows: rows,
            cells: Array(repeating: .init(darkest: color, lightest: color), count: columns * rows)
        )
    }

    /// The cells under `regions`, each given as a fraction of the slide from
    /// its top left. A cell is counted once however many regions cover it.
    func cells(under regions: [CGRect]) -> [Cell] {
        var indices = Set<Int>()
        for region in regions where !region.isNull && !region.isEmpty {
            let clipped = region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !clipped.isNull, !clipped.isEmpty else { continue }
            let first = (
                column: max(Int((clipped.minX * Double(columns)).rounded(.down)), 0),
                row: max(Int((clipped.minY * Double(rows)).rounded(.down)), 0)
            )
            let last = (
                column: min(Int((clipped.maxX * Double(columns)).rounded(.up)), columns) - 1,
                row: min(Int((clipped.maxY * Double(rows)).rounded(.up)), rows) - 1
            )
            guard first.column <= last.column, first.row <= last.row else { continue }
            for row in first.row...last.row {
                for column in first.column...last.column {
                    indices.insert(row * columns + column)
                }
            }
        }
        return indices.sorted().map { cells[$0] }
    }

    /// The contrast `ink` keeps over `coverage` of `cells`, with `scrim` laid
    /// over them at `opacity`.
    static func contrast(
        of ink: LampPresentationColor,
        over cells: [Cell],
        scrim: LampPresentationColor,
        opacity: Double
    ) -> Double {
        guard !cells.isEmpty else { return .infinity }
        // The ink is the same against every cell, and luminance is most of
        // the cost of a search that reads every cell a dozen times.
        let inkLuminance = ink.luminance
        func ratio(_ color: LampPresentationColor) -> Double {
            let luminance = color.luminance
            return (max(inkLuminance, luminance) + 0.05) / (min(inkLuminance, luminance) + 0.05)
        }
        let ratios = cells.map { cell in
            min(
                ratio(cell.darkest.under(scrim, opacity: opacity)),
                ratio(cell.lightest.under(scrim, opacity: opacity))
            )
        }
        .sorted()
        let index = min(Int((Double(ratios.count) * (1 - coverage)).rounded(.down)), ratios.count - 1)
        return ratios[index]
    }

    /// The least scrim that lets `ink` reach the target over `cells`.
    ///
    /// Laying more of the scrim always helps, because the scrim is the ground
    /// the ink was chosen against, so the search can halve its way there. It
    /// stops at hundredths: finer than anyone can see, and steady enough that
    /// a redraw never flickers between two answers.
    static func leastScrim(
        for ink: LampPresentationColor,
        over cells: [Cell],
        scrim: LampPresentationColor
    ) -> Double {
        let target = targetContrast
        if contrast(of: ink, over: cells, scrim: scrim, opacity: 0) >= target { return 0 }
        if contrast(of: ink, over: cells, scrim: scrim, opacity: 1) < target { return 1 }
        var low = 0.0
        var high = 1.0
        while high - low > 0.001 {
            let middle = (low + high) / 2
            if contrast(of: ink, over: cells, scrim: scrim, opacity: middle) >= target {
                high = middle
            } else {
                low = middle
            }
        }
        return min((high * 100).rounded(.up) / 100, 1)
    }

    /// How to draw words in `regions` of this picture in `theme`.
    ///
    /// The words take whichever of the theme's two ground colours needs less
    /// of the picture covered to be read, and the scrim is the other one. A
    /// dark theme over a pale photograph is set in its dark colour rather
    /// than drowning the picture in black, and the reverse.
    public func treatment(
        for regions: [CGRect],
        theme: LampPresentationTheme
    ) -> Treatment {
        let foreground = LampPresentationColor(hex: theme.foregroundColor)
            ?? .init(red: 1, green: 1, blue: 1)
        let ground = LampPresentationColor(hex: theme.backgroundColor)
            ?? .init(red: 0, green: 0, blue: 0)
        let behind = cells(under: regions)

        struct Option {
            var ink: LampPresentationColor
            var inkHex: String
            var scrim: LampPresentationColor
            var scrimHex: String
            var opacity: Double
            var contrast: Double
        }
        let options = [
            (foreground, theme.foregroundColor, ground, theme.backgroundColor),
            (ground, theme.backgroundColor, foreground, theme.foregroundColor),
        ].map { ink, inkHex, scrim, scrimHex in
            let opacity = Self.leastScrim(for: ink, over: behind, scrim: scrim)
            return Option(
                ink: ink,
                inkHex: inkHex,
                scrim: scrim,
                scrimHex: scrimHex,
                opacity: opacity,
                contrast: Self.contrast(of: ink, over: behind, scrim: scrim, opacity: opacity)
            )
        }
        // Less covered wins; where both leave the picture alone, the one that
        // reads more clearly. The theme's own foreground wins a tie, so a
        // slide looks like the rest of its deck when it can.
        let chosen = options.dropFirst().reduce(options[0]) { best, next in
            if next.opacity < best.opacity { return next }
            if next.opacity == best.opacity && next.contrast > best.contrast + 0.5 { return next }
            return best
        }

        var accentHex = theme.accentColor
        if let accent = LampPresentationColor(hex: theme.accentColor),
           Self.contrast(of: accent, over: behind, scrim: chosen.scrim, opacity: chosen.opacity)
               < Self.accentContrast {
            accentHex = chosen.inkHex
        }

        return Treatment(
            text: chosen.inkHex,
            accent: accentHex,
            scrim: chosen.scrimHex,
            scrimOpacity: chosen.opacity,
            contrast: chosen.contrast.isFinite ? chosen.contrast : LampPresentationColor.contrast(chosen.ink, chosen.scrim)
        )
    }
}
