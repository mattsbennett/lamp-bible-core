import Foundation

/// A record that two devices changed to different content at the same moment.
///
/// Sync chooses by modification time, so when both sides carry the same one it
/// has nothing left to choose with. Rather than guess, it keeps what is on this
/// device, sets the incoming copy aside here, and lets the run finish — one
/// disagreement over one writing should not stop a library from syncing.
///
/// The copy set aside is the whole incoming record, because a person choosing
/// between two versions may do so days later, long after the file it arrived in
/// has gone.
public struct LampSyncConflict: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case devotional
    }

    /// Which version of the record to keep.
    public enum Side: String, Sendable {
        /// What this device already had.
        case thisDevice
        /// What arrived from sync.
        case otherDevice
    }

    public let id: String
    public let kind: Kind
    /// The conflicted record's own identifier, as its table knows it.
    public let itemKey: String
    public let title: String
    public let thisDeviceModified: Date?
    public let otherDeviceModified: Date?
    /// A few lines of each version, enough to tell them apart without opening
    /// either one.
    public let thisDevicePreview: String
    public let otherDevicePreview: String
    public let detected: Date

    public init(
        id: String,
        kind: Kind,
        itemKey: String,
        title: String,
        thisDeviceModified: Date?,
        otherDeviceModified: Date?,
        thisDevicePreview: String,
        otherDevicePreview: String,
        detected: Date
    ) {
        self.id = id
        self.kind = kind
        self.itemKey = itemKey
        self.title = title
        self.thisDeviceModified = thisDeviceModified
        self.otherDeviceModified = otherDeviceModified
        self.thisDevicePreview = thisDevicePreview
        self.otherDevicePreview = otherDevicePreview
        self.detected = detected
    }

    /// True when the two versions differ by more than their body text, so a
    /// caller can say that choosing a side also drops the other's title or date.
    public var differsBeyondBody: Bool {
        thisDevicePreview == otherDevicePreview
    }

    public static func identifier(kind: Kind, itemKey: String) -> String {
        "\(kind.rawValue):\(itemKey)"
    }
}

/// How a conflicted record is summarised for someone choosing between versions.
enum LampSyncConflictPreview {
    /// Flattened to one block of plain text, shortened, because a preview that
    /// runs to the length of the writing is no longer a preview.
    static func text(_ body: String, limit: Int = 280) -> String {
        let collapsed = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }
}
