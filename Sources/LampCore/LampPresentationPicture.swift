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

    /// Video codecs every iPhone and iPad Lamp runs on plays, by the sample
    /// entry's four characters: H.264, HEVC, and HEVC with Dolby Vision.
    /// AV1, ProRes, VP9 and Motion JPEG play only on some, or none.
    public static let everyDevicePlays: Set<String> = ["avc1", "avc3", "hvc1", "hev1", "dvh1", "dvhe"]

    /// A codec's name as a person would know it. H.264 in a profile only
    /// newer devices play is read as `avc1:<profile>`.
    public static func codecName(_ code: String) -> String {
        if code.hasPrefix("avc1:") || code.hasPrefix("avc3:") {
            switch code.dropFirst(5) {
            case "110": return "H.264 High 10"
            case "122": return "H.264 4:2:2"
            default: return "H.264 4:4:4"
            }
        }
        return switch code {
        case "av01": "AV1"
        case "vp09": "VP9"
        case "vp08": "VP8"
        case "apcn", "apch", "apcs", "apco", "ap4h", "ap4x": "ProRes"
        case "jpeg", "mjpa", "mjpb": "Motion JPEG"
        case "mp4v": "MPEG-4"
        default: "'\(code)'"
        }
    }
}

/// What a deck's validator needs of a video file it names: its size, against
/// the limit a deck carries, and its codec, against what every device plays.
///
/// Read from the file's own boxes, as `validate_deck.py` reads them, so both
/// validators give the same answer: the four characters of the first enabled
/// video track's sample entries (`moov/trak/mdia/minf/stbl/stsd`), the track
/// found by its handler, `vide`, and enabled by its header's flag; of its
/// entries, the first not every device plays, else the first. H.264 in High
/// 10, 4:2:2 or 4:4:4, by its `avcC` profile, is `avc1:<profile>`. Nil codec
/// for a file that is not an MP4 or QuickTime movie, has no such track, or
/// whose boxes don't hold together; such a file is no one's to warn about
/// here, and a malformed one is never more than unknown.
public struct LampPresentationVideoFacts: Equatable, Sendable {
    public var byteCount: Int64
    public var videoCodec: String?

    public init(byteCount: Int64, videoCodec: String?) {
        self.byteCount = byteCount
        self.videoCodec = videoCodec
    }

    /// The facts of the file at `url`, or nil where it can't be read.
    public static func read(at url: URL) -> LampPresentationVideoFacts? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return read(from: handle)
    }

    /// The facts of a file already open, as a caller that opened it by its
    /// own rules (a workspace walk that follows no link) reads the very file
    /// it checked.
    public static func read(from handle: FileHandle) -> LampPresentationVideoFacts? {
        guard let end = try? handle.seekToEnd() else { return nil }
        let reader = BoxReader(handle: handle)
        return LampPresentationVideoFacts(byteCount: Int64(end), videoCodec: reader.videoCodec(fileLength: end))
    }

    /// Walks a movie's boxes by seeking, reading only headers and the few
    /// small boxes it needs, so a long video costs what a short one does.
    /// Every size is the file's word, so each is checked against what is
    /// left before it is added to anything.
    private struct BoxReader {
        let handle: FileHandle

        private struct Box {
            let type: String
            let body: UInt64
            let end: UInt64
            var bodyLength: UInt64 { end - body }
        }

        private func bytes(at offset: UInt64, count: Int) -> [UInt8]? {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.read(upToCount: count), data.count == count
            else { return nil }
            return [UInt8](data)
        }

        /// `count` bytes `skip` into `box`'s body, only if they lie inside it.
        private func bytes(in box: Box, skip: UInt64, count: Int) -> [UInt8]? {
            guard box.bodyLength >= skip, box.bodyLength - skip >= UInt64(count) else { return nil }
            return bytes(at: box.body + skip, count: count)
        }

        private func number(_ bytes: ArraySlice<UInt8>) -> UInt64 {
            bytes.reduce(0) { $0 << 8 | UInt64($1) }
        }

        /// The boxes from `start` to `end`, up to and including the first of
        /// type `until` if one is named; it stops at the first that does not
        /// fit.
        private func boxes(from start: UInt64, to end: UInt64, until: String? = nil) -> [Box] {
            var found: [Box] = []
            var offset = start
            while end >= offset, end - offset >= 8, found.count < 4096 {
                guard let header = bytes(at: offset, count: 8) else { break }
                let left = end - offset
                var size = number(header[0..<4])
                let type = String(decoding: header[4..<8], as: UTF8.self)
                var headerLength: UInt64 = 8
                if size == 1 {
                    guard left >= 16, let large = bytes(at: offset + 8, count: 8) else { break }
                    size = number(large[0..<8])
                    headerLength = 16
                } else if size == 0 {
                    size = left
                }
                guard size >= headerLength, size <= left else { break }
                found.append(Box(type: type, body: offset + headerLength, end: offset + size))
                if type == until { break }
                offset += size
            }
            return found
        }

        private func child(_ type: String, of box: Box) -> Box? {
            boxes(from: box.body, to: box.end, until: type).first { $0.type == type }
        }

        /// The codes of `descriptions`' entries, each checked to lie inside it.
        private func entryCodes(_ descriptions: Box) -> [String] {
            guard let count = bytes(in: descriptions, skip: 4, count: 4) else { return [] }
            var codes: [String] = []
            var offset = descriptions.body + 8
            for _ in 0..<min(number(count[0..<4]), 64) {
                guard descriptions.end >= offset, descriptions.end - offset >= 8,
                      let header = bytes(at: offset, count: 8)
                else { break }
                let size = number(header[0..<4])
                guard size >= 8, size <= descriptions.end - offset else { break }
                var code = String(decoding: header[4..<8], as: UTF8.self)
                // A visual sample entry's 78 bytes of fields, then its boxes;
                // for H.264, `avcC`, whose second byte is the profile.
                if code == "avc1" || code == "avc3", size > 86,
                   let configuration = boxes(from: offset + 86, to: offset + size, until: "avcC").first(where: { $0.type == "avcC" }),
                   let profile = bytes(in: configuration, skip: 1, count: 1),
                   [110, 122, 244, 44].contains(profile[0]) {
                    code += ":\(profile[0])"
                }
                codes.append(code)
                offset += size
            }
            return codes
        }

        func videoCodec(fileLength: UInt64) -> String? {
            guard let movie = boxes(from: 0, to: fileLength, until: "moov").first(where: { $0.type == "moov" }) else { return nil }
            for track in boxes(from: movie.body, to: movie.end) where track.type == "trak" {
                // Only a track its header says is on: the flags, after the
                // version byte, end in "enabled".
                guard let header = child("tkhd", of: track),
                      let flags = bytes(in: header, skip: 0, count: 4), flags[3] & 1 == 1,
                      let media = child("mdia", of: track),
                      let handler = child("hdlr", of: media),
                      // version and flags, pre-defined, then the handler type
                      let kind = bytes(in: handler, skip: 8, count: 4),
                      String(decoding: kind, as: UTF8.self) == "vide",
                      let information = child("minf", of: media),
                      let table = child("stbl", of: information),
                      let descriptions = child("stsd", of: table)
                else { continue }
                let codes = entryCodes(descriptions)
                guard let first = codes.first else { continue }
                return codes.first { !LampPresentationVideo.everyDevicePlays.contains($0) } ?? first
            }
            return nil
        }
    }
}
