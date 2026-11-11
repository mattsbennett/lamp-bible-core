import Foundation

/// Shared schema for the richer media metadata authored on iOS. Clients may
/// retain the original JSON alongside this decoded view so future fields
/// survive a round trip through an older app.
///
/// Named for devotionals when only they carried media. A note carries the
/// same thing — a file, its kind, its size, what it says — so this is the
/// shared shape rather than the devotional one, and
/// `LampDevotionalMediaReference` remains as its old name so nothing had to
/// move to use it.
public enum LampMediaType: String, Codable, Sendable {
    case image, audio
}

public typealias LampDevotionalMediaType = LampMediaType

/// Where a piece of media belongs, which decides the folder it is kept in
/// and the path it syncs under. Media was devotionals-only until notes
/// gained it, and the layout said so in a string in two places.
public enum LampMediaScope: String, Codable, Sendable, CaseIterable {
    case devotional
    case note

    /// The folder under `Media/` in a library, and in a portable archive.
    public var folder: String {
        switch self {
        case .devotional: "Devotionals"
        case .note: "Notes"
        }
    }

    /// The directory a client publishes this media under when syncing.
    public var remoteDirectory: String {
        switch self {
        case .devotional: "DevotionalMedia"
        case .note: "NoteMedia"
        }
    }
}

public struct LampMediaReference: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var type: LampMediaType
    public var filename: String
    public var mimeType: String
    public var size: Int?
    public var width: Int?
    public var height: Int?
    public var duration: Double?
    public var waveform: [Float]?
    public var transcription: String?
    public var alt: String?
    public var created: Int?

    public init(
        id: String = UUID().uuidString,
        type: LampMediaType,
        filename: String,
        mimeType: String,
        size: Int? = nil,
        width: Int? = nil,
        height: Int? = nil,
        duration: Double? = nil,
        waveform: [Float]? = nil,
        transcription: String? = nil,
        alt: String? = nil,
        created: Int? = nil
    ) {
        self.id = id
        self.type = type
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.width = width
        self.height = height
        self.duration = duration
        self.waveform = waveform
        self.transcription = transcription
        self.alt = alt
        self.created = created ?? Int(Date().timeIntervalSince1970)
    }
}

/// What this type was called when devotionals were the only thing with
/// media. Kept so the Mac, the phone and the archive readers need no change
/// to go on using it.
public typealias LampDevotionalMediaReference = LampMediaReference

public extension LampMediaReference {
    /// The references a stored media list holds, entry by entry.
    ///
    /// One entry this Lamp cannot read — a media type a later one knows —
    /// costs its own picture and no others. Decoding the array in one go
    /// made a single bad entry blank the lot, which is a fault we have
    /// already shipped once.
    static func list(fromJSON json: String?) -> [LampMediaReference] {
        guard let json, let data = json.data(using: .utf8),
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return [] }
        return entries.compactMap { entry in
            guard let body = try? JSONSerialization.data(withJSONObject: entry) else { return nil }
            return try? JSONDecoder().decode(LampMediaReference.self, from: body)
        }
    }
}
