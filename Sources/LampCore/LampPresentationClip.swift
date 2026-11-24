import Foundation

/// A video shown as content: played to the room with its sound, once, from
/// `start` to `end`, and held on its last frame. Set on an image block, whose
/// picture is the clip's still: shown before it plays, in thumbnails, Slide
/// Studio and PDFs, and by anything that cannot play it.
///
/// Not a picture's `video`, which loops silently behind or beside the words
/// as a moving picture. A clip is something the talk stops to watch.
///
/// The clip is a file in the deck's assets, or a YouTube or Vimeo video
/// played in that site's own player, which needs the internet while the deck
/// is presented and shows the still with a note where there is none.
public struct LampPresentationClip: Codable, Equatable, Sendable {
    /// A path inside the presentation folder, such as `Assets/interview.mp4`,
    /// or a YouTube or Vimeo address.
    public var source: String
    /// Seconds into the clip to start from. Absent means the beginning.
    public var start: Double?
    /// Seconds into the clip to stop at. Absent means its end.
    public var end: Double?
    /// When the clip plays. Absent means on a click.
    public var starts: Starting?

    public enum Starting: String, Codable, CaseIterable, Identifiable, Sendable {
        /// On the presenter's click, as a step of the slide's reveal.
        case click
        /// As soon as the slide is shown.
        case arrival

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .click: "On Click"
            case .arrival: "When the Slide Appears"
            }
        }

        /// A way of starting this app does not know waits for a click, which
        /// never surprises a room with sound.
        public init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .click
        }
    }

    public init(source: String, start: Double? = nil, end: Double? = nil, starts: Starting? = nil) {
        self.source = source
        self.start = start
        self.end = end
        self.starts = starts
    }

    private enum CodingKeys: String, CodingKey {
        case source, start, end, starts
    }

    /// Opens whatever a newer app wrote: a field of the wrong kind reads as
    /// absent, so the deck opens and the validator says what is wrong.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = (try? container.decode(String.self, forKey: .source)) ?? ""
        start = try? container.decodeIfPresent(Double.self, forKey: .start)
        end = try? container.decodeIfPresent(Double.self, forKey: .end)
        starts = try? container.decodeIfPresent(Starting.self, forKey: .starts)
    }

    /// The largest clip file Slide Studio copies into a deck. A deck's files
    /// travel with it to every Mac it syncs to; a longer clip streams from
    /// YouTube or Vimeo instead.
    public static let largestFileBytes: Int64 = 250_000_000

    /// Where a clip plays from.
    public enum Origin: Equatable, Sendable {
        /// A file in the deck's assets.
        case file(String)
        /// A YouTube video, by its eleven-character id.
        case youtube(String)
        /// A Vimeo video, by its number, and the key a private link carries.
        case vimeo(String, hash: String?)
        /// Nothing Lamp can play.
        case unplayable
    }

    /// Where this clip plays from.
    public var origin: Origin { Self.origin(of: source) }

    /// Reads `source`: a safe relative path to a playable file, or a YouTube
    /// or Vimeo address in any of the forms those sites hand out.
    public static func origin(of source: String) -> Origin {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .unplayable }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = url.host?.lowercased()
        else {
            return LampPresentationDeckValidator.isSafeAssetPath(text) && LampPresentationVideo.isPlayable(text)
                ? .file(text) : .unplayable
        }
        let parts = url.path.split(separator: "/").map(String.init)
        let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        func youtube(_ id: String?) -> Origin {
            guard let id, id.count == 11,
                  id.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") })
            else { return .unplayable }
            return .youtube(id)
        }
        switch bareHost {
        case "youtube.com", "m.youtube.com", "music.youtube.com", "youtube-nocookie.com":
            if parts.first == "watch" || parts.isEmpty {
                return youtube(URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "v" }?.value)
            }
            if ["embed", "shorts", "live", "v"].contains(parts.first ?? ""), parts.count >= 2 {
                return youtube(parts[1])
            }
            return .unplayable
        case "youtu.be":
            return youtube(parts.first)
        case "vimeo.com", "player.vimeo.com":
            // vimeo.com/123, vimeo.com/123/abcdef (a private link's key, which
            // can be all digits), player.vimeo.com/video/123?h=abcdef,
            // vimeo.com/channels/x/123, vimeo.com/showcase/9/video/123: the
            // number after "video" where there is one, else the first.
            func isNumber(_ part: String) -> Bool { !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber } }
            let afterVideo = parts.indices.first { index in
                index > 0 && ["video", "videos"].contains(parts[index - 1]) && isNumber(parts[index])
            }
            guard let index = afterVideo ?? parts.indices.first(where: { isNumber(parts[$0]) }) else { return .unplayable }
            let id = parts[index]
            let queryHash = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "h" }?.value
            let pathHash = parts.indices.contains(index + 1) ? parts[index + 1] : nil
            let hash = (queryHash ?? pathHash).flatMap { value in
                value.allSatisfy { $0.isLetter || $0.isNumber } ? value : nil
            }
            return .vimeo(id, hash: hash)
        default:
            return .unplayable
        }
    }

    /// The asset path this clip names, where it is a file.
    public var assetPath: String? {
        if case .file(let path) = origin { return path }
        return nil
    }

    /// Whether the clip streams from a site, and so needs the internet.
    public var isStreamed: Bool {
        switch origin {
        case .youtube, .vimeo: true
        case .file, .unplayable: false
        }
    }
}
