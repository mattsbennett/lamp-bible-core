import Foundation

/// Shared schema for the richer devotional media metadata authored on iOS.
/// Clients may retain the original JSON alongside this decoded view so future
/// fields survive a round trip through an older app.
public enum LampDevotionalMediaType: String, Codable, Sendable {
    case image, audio
}

public struct LampDevotionalMediaReference: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var type: LampDevotionalMediaType
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
        type: LampDevotionalMediaType,
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
