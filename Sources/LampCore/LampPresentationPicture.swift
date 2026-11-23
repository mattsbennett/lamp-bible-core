import CoreGraphics
import Foundation

/// Where a picture's subject is, as fractions of the picture: `x` from its
/// left edge, `y` from its top, each 0 to 1.
///
/// A picture behind a slide fills it, so what overflows is cropped. Centred,
/// a portrait photograph behind a widescreen slide lost the face at the top
/// of it. With a focus, the crop is moved to keep that point as near the
/// middle as the picture allows. Nothing is ever stretched or left uncovered:
/// the crop only slides along the side that overflows.
public struct LampPresentationFocus: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let centre = LampPresentationFocus(x: 0.5, y: 0.5)

    /// Whether both lie within the picture.
    public var isValid: Bool {
        x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y)
    }

    /// The part of a `pictureSize` picture that a frame of `frameRatio`
    /// (width over height) shows when the picture fills it, with `focus` as
    /// near the middle as the picture allows. In the picture's own units,
    /// measured from its top left.
    ///
    /// One answer for every place that needs it: the canvas that draws the
    /// picture, and the sampler that reads it to colour the words over it.
    /// Two answers would set words over one part of a picture in colours
    /// chosen for another.
    public static func shown(
        in pictureSize: CGSize,
        frameRatio: Double,
        focus: LampPresentationFocus?
    ) -> CGRect {
        guard pictureSize.width > 0, pictureSize.height > 0, frameRatio > 0 else {
            return CGRect(origin: .zero, size: pictureSize)
        }
        let focus = focus.flatMap { $0.isValid ? $0 : nil } ?? .centre
        let pictureRatio = Double(pictureSize.width / pictureSize.height)
        if pictureRatio > frameRatio {
            let width = Double(pictureSize.height) * frameRatio
            let x = min(max(focus.x * Double(pictureSize.width) - width / 2, 0), Double(pictureSize.width) - width)
            return CGRect(x: x, y: 0, width: width, height: Double(pictureSize.height))
        }
        let height = Double(pictureSize.width) / frameRatio
        let y = min(max(focus.y * Double(pictureSize.height) - height / 2, 0), Double(pictureSize.height) - height)
        return CGRect(x: 0, y: y, width: Double(pictureSize.width), height: height)
    }
}

/// A picture drawn in the deck's colours, so pictures from different places
/// look as if they belong to one deck.
///
/// `duotone` draws the picture in two colours, the theme's accent and its
/// ground, darks in the darker and lights in the lighter: Lamp Dark's navy to
/// amber, Parchment's brown to cream. `muted` takes most of a picture's colour
/// out and washes it toward the theme's ground, so a busy photograph sits
/// quietly behind words. Absent, a picture is drawn as it is.
public enum LampPresentationImageTint: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case duotone
    case muted

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: "None"
        case .duotone: "Duotone"
        case .muted: "Muted"
        }
    }

    /// A tint this app does not know is drawn as nothing, so a deck written
    /// by a newer app still opens rather than failing as a whole.
    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .none
    }

    /// The two colours a duotone runs between, darker first: the theme's
    /// accent and its ground.
    public static func duotone(of theme: LampPresentationTheme) -> (dark: String, light: String) {
        let accent = LampPresentationColor(hex: theme.accentColor)?.luminance ?? 0
        let ground = LampPresentationColor(hex: theme.backgroundColor)?.luminance ?? 0
        return accent < ground
            ? (theme.accentColor, theme.backgroundColor)
            : (theme.backgroundColor, theme.accentColor)
    }

    /// How much of its colour a muted picture keeps, and how far it is washed
    /// toward the theme's ground.
    public static let mutedSaturation = 0.25
    public static let mutedWash = 0.3
}
