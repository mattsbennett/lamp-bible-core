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

/// How a picture moves while its slide is presented. Absent, it is still.
///
/// `drift` closes in on the picture so slowly the room should not see it
/// move, only find the picture a little nearer than it was: `driftReach` in
/// `driftPeriod / 2`, then as slowly back, for as long as the slide is up.
/// It closes in on the picture's focus, so the subject stays where it is and
/// the edges go. Nothing moves in a thumbnail, in Slide Studio, in a PDF, or
/// with Reduce Motion on; only the slide in front of the room.
public enum LampPresentationImageMotion: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case drift

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: "Still"
        case .drift: "Drift"
        }
    }

    /// A motion this app does not know is drawn still, so a deck written by
    /// a newer app still opens rather than failing as a whole.
    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .none
    }

    /// How much nearer a drifting picture comes at most: 3%.
    public static let driftReach = 0.03

    /// How long a drift takes to close in and come back again.
    public static let driftPeriod: TimeInterval = 120

    /// A drifting picture's scale `elapsed` seconds after its slide arrived:
    /// 1 on arrival, gathering and easing as a cosine does, so it never
    /// starts, stops or turns with a jolt.
    public static func driftScale(after elapsed: TimeInterval) -> Double {
        guard elapsed.isFinite, elapsed > 0 else { return 1 }
        let phase = elapsed.truncatingRemainder(dividingBy: driftPeriod) / driftPeriod
        return 1 + driftReach * (1 - cos(2 * .pi * phase)) / 2
    }

    /// Where on a frame of `frameRatio` a `pictureSize` picture that fills
    /// it (`LampPresentationFocus.shown`) has its `focus`, as fractions of
    /// the frame: the point a drift closes in on.
    public static func driftAnchor(
        in pictureSize: CGSize,
        frameRatio: Double,
        focus: LampPresentationFocus?
    ) -> CGPoint {
        let focus = focus.flatMap { $0.isValid ? $0 : nil } ?? .centre
        let shown = LampPresentationFocus.shown(in: pictureSize, frameRatio: frameRatio, focus: focus)
        guard shown.width > 0, shown.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let x = (focus.x * Double(pictureSize.width) - Double(shown.minX)) / Double(shown.width)
        let y = (focus.y * Double(pictureSize.height) - Double(shown.minY)) / Double(shown.height)
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    /// What lies under `region` at points along a drift about `anchor`,
    /// both as fractions of the frame, from at rest to nearest.
    ///
    /// Closed in by a scale `s`, the picture shows at a frame point `p` what
    /// lay at `anchor + (p - anchor) / s`. The words over a drifting picture
    /// are coloured for every one of these, each held to reading on its own,
    /// so they read throughout and never change colour as it moves. Each is
    /// judged whole: one region spanning the whole path would let a patch
    /// that fills the words at one moment count for little of the path.
    /// Steps of a quarter of the reach move a region at most 0.75% of the
    /// frame, less than a line of the smallest words on a slide.
    public static func driftViews(of region: CGRect, anchor: CGPoint) -> [CGRect] {
        guard !region.isNull, !region.isEmpty, !region.isInfinite else { return [region] }
        return (0...driftSteps).map { step in
            guard step > 0 else { return region }
            let scale = 1 + driftReach * Double(step) / Double(driftSteps)
            return CGRect(
                x: anchor.x + (region.minX - anchor.x) / scale,
                y: anchor.y + (region.minY - anchor.y) / scale,
                width: region.width / scale,
                height: region.height / scale
            )
        }
    }

    /// How many steps along a drift the words are judged at, past at rest.
    public static let driftSteps = 4
}

/// A picture that plays as a video while its slide is presented: silent,
/// looping, drawn just as the picture is, cropped around its focus, in its
/// tint, drifting if it drifts.
///
/// The block's picture is the video's still and stays required: thumbnails,
/// Slide Studio, PDFs, Reduce Motion, and an older Lamp that does not know
/// `video` all show it, and the words over it are coloured for it. So the
/// still should be a frame of the video, which Slide Studio takes for you.
public enum LampPresentationVideo {
    /// What Lamp plays, by file extension.
    public static let extensions: Set<String> = ["mp4", "mov", "m4v"]

    /// The largest video Slide Studio copies into a deck. Every file a deck
    /// names travels with it to each Mac, iPhone and iPad it syncs to, so a
    /// background loop is kept to a short clip.
    public static let largestFileBytes: Int64 = 100_000_000

    /// Whether Lamp plays the video at `path`, judged by its extension.
    public static func isPlayable(_ path: String) -> Bool {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return extensions.contains(name[name.index(after: dot)...].lowercased())
    }
}
