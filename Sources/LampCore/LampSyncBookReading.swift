import Foundation
import LampModuleKit

/// Where a person last was in a book: the section, and the first block of it
/// in view.
public struct LampBookReadingPosition: Codable, Equatable, Sendable {
    public let sectionID: String
    /// The first block in view, or -1 for the top of the section.
    public let blockIndex: Int
    /// When it was recorded, in milliseconds since 1970.
    public let at: Int64
    /// The start of that block's text, to find it by when a rebuilt book has
    /// numbered its blocks differently (`blockIndex(in:)`). Nil for the top
    /// of a section, a block with no text, and a position recorded before
    /// anchors were kept.
    public let anchor: String?

    public init(sectionID: String, blockIndex: Int = -1, anchor: String? = nil, updatedAt: Date = Date()) {
        self.init(
            sectionID: sectionID,
            blockIndex: blockIndex,
            at: Int64((updatedAt.timeIntervalSince1970 * 1_000).rounded(.down)),
            anchor: anchor
        )
    }

    /// At a block of the section, anchored to it.
    public init(sectionID: String, blockIndex: Int, in blocks: [LampBookContentBlock], updatedAt: Date = Date()) {
        self.init(
            sectionID: sectionID,
            blockIndex: blockIndex,
            anchor: blocks.indices.contains(blockIndex) ? Self.anchor(of: blocks[blockIndex]) : nil,
            updatedAt: updatedAt
        )
    }

    init(sectionID: String, blockIndex: Int, at: Int64, anchor: String? = nil) {
        self.sectionID = sectionID
        self.blockIndex = max(blockIndex, -1)
        self.at = at
        self.anchor = anchor.flatMap { $0.isEmpty ? nil : $0 }
    }

    public var updatedAt: Date { Date(timeIntervalSince1970: Double(at) / 1_000) }

    // MARK: - Finding the block again

    /// How much of a block's text an anchor keeps: enough that two blocks
    /// rarely share it.
    static let anchorLength = 48

    /// The start of a block's text, whitespace collapsed, as a position keeps
    /// it. Nil for a block with no text, such as an image without a caption.
    public static func anchor(of block: LampBookContentBlock) -> String? {
        let text = searchableText(of: block)
        return text.isEmpty ? nil : String(text.prefix(anchorLength))
    }

    /// The block to open at: this position's own while it still starts with
    /// the anchor, or else the block holding the anchor anywhere in its text,
    /// which is where a paragraph joined to the one before it went. Of several
    /// that hold it, the nearest by index to this position's own, and of two
    /// as near, the earlier, so both apps open at the same one. Failing both,
    /// its own index, or -1 for the section's top when the section no longer
    /// has that many blocks.
    ///
    /// Only for opening: the position itself stays as it was recorded, since
    /// rewriting it would stamp a move nobody made after the other device's
    /// real one.
    public func blockIndex(in blocks: [LampBookContentBlock]) -> Int {
        let ownIndex = blocks.indices.contains(blockIndex) ? blockIndex : -1
        guard let anchor else { return ownIndex }
        if ownIndex >= 0, Self.anchor(of: blocks[ownIndex]) == anchor { return ownIndex }
        let holding = blocks.indices.filter { Self.searchableText(of: blocks[$0]).contains(anchor) }
        return holding.min { abs($0 - blockIndex) < abs($1 - blockIndex) } ?? ownIndex
    }

    /// Every word a block shows, in reading order, composed and with its
    /// whitespace collapsed, so a rebuild that only re-spaces a paragraph
    /// still matches.
    private static func searchableText(of block: LampBookContentBlock) -> String {
        var parts: [String] = []
        func add(_ item: LampBookListItem) {
            parts.append(item.content.text)
            item.children.forEach(add)
        }
        if let content = block.content { parts.append(content.text) }
        if let caption = block.caption { parts.append(caption.text) }
        block.items.forEach(add)
        for row in block.rows {
            parts.append(contentsOf: row.cells.map(\.content.text))
        }
        return parts.joined(separator: " ")
            .precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

/// Where a person is in each book and which sections they have bookmarked, as
/// every device has recorded them: the settings bundle's book-reading part,
/// and the format each app keeps its own in (`LampBookReadingStateStore`), so
/// a change and its record are one write.
///
/// A join, for the reason plan progress is one: an app from before this part
/// decodes the bundle, passes over the key it doesn't know, and writes the
/// bundle back without it. Joined, a missing part says nothing, and the next
/// client to contribute puts its records back.
///
/// A bookmark is a plan mark: when it was last set and last cleared, joined by
/// the later of each, and set when it was set no earlier than it was cleared.
/// A position is one value, so it isn't joined field by field: the later one
/// stands whole. Two recorded at the same millisecond are ordered by section,
/// block and anchor, so every device keeps the same one whatever order they
/// arrive in. (`Verification/SyncMerge.lean`: `planMarkIsSet`, `joinPosition`.)
public struct LampSyncBookReading: Equatable, Sendable {
    public typealias Mark = LampSyncPlanProgress.Mark

    /// By module ID.
    public private(set) var positions: [String: LampBookReadingPosition] = [:]
    /// By module ID, then section ID.
    public private(set) var bookmarks: [String: [String: Mark]] = [:]

    public init() {}

    public var isEmpty: Bool { positions.isEmpty && bookmarks.values.allSatisfy(\.isEmpty) }

    public func bookmarkedSections(in moduleID: String) -> Set<String> {
        Set((bookmarks[moduleID] ?? [:]).compactMap { LampSyncPlanProgress.isSet($0.value) ? $0.key : nil })
    }

    // MARK: - Recording

    /// Records a move, stamped after the position it replaces.
    ///
    /// A position already held records nothing, so returning to a book
    /// doesn't make the place another device left it at newer than it is.
    @discardableResult
    public mutating func record(_ position: LampBookReadingPosition, for moduleID: String) -> Bool {
        let current = positions[moduleID]
        guard current?.sectionID != position.sectionID || current?.blockIndex != position.blockIndex else {
            return false
        }
        positions[moduleID] = Self.stamped(position, after: current)
        return true
    }

    public mutating func recordBookmark(_ sectionID: String, in moduleID: String, at time: Int64) {
        bookmarks[moduleID, default: [:]][sectionID] = LampSyncPlanProgress.set(
            bookmarks[moduleID]?[sectionID], at: time
        )
    }

    public mutating func recordUnbookmark(_ sectionID: String, in moduleID: String, at time: Int64) {
        bookmarks[moduleID, default: [:]][sectionID] = LampSyncPlanProgress.cleared(
            bookmarks[moduleID]?[sectionID], at: time
        )
    }

    /// A position at its own time, but never at or before the one it replaces:
    /// so a move holds even on a clock behind the device that recorded where
    /// it moved from, as a tick holds against the untick it undoes.
    /// (`Verification/SyncMerge.lean`: `stampPosition`.)
    static func stamped(
        _ position: LampBookReadingPosition,
        after current: LampBookReadingPosition?
    ) -> LampBookReadingPosition {
        LampBookReadingPosition(
            sectionID: position.sectionID,
            blockIndex: position.blockIndex,
            at: max(position.at, current.map { $0.at + 1 } ?? position.at),
            anchor: position.anchor
        )
    }

    // MARK: - Joining

    /// Per book the later position, and per bookmark the later of each time.
    public mutating func merge(_ other: LampSyncBookReading) {
        positions.merge(other.positions) { Self.later($0, $1) }
        bookmarks.merge(other.bookmarks) { ours, theirs in
            ours.merging(theirs) { $0.merged(with: $1) }
        }
    }

    /// Ordered by time, then section, block and anchor, so that any two
    /// that differ have one later. (`Verification/SyncMerge.lean`:
    /// `laterPosition`.)
    static func later(
        _ a: LampBookReadingPosition,
        _ b: LampBookReadingPosition
    ) -> LampBookReadingPosition {
        (b.at, b.sectionID, b.blockIndex, b.anchor ?? "") > (a.at, a.sectionID, a.blockIndex, a.anchor ?? "") ? b : a
    }

    // MARK: - File format

    private struct File: Codable {
        var formatVersion: Int
        var positions: [String: LampBookReadingPosition]?
        var bookmarks: [String: [String: Mark]]?
    }

    /// What the Mac kept before this synced: no version, a position's time as
    /// Foundation's default date, and each book's bookmarks as a list.
    private struct UnversionedFile: Decodable {
        struct Position: Decodable {
            let sectionID: String
            let blockIndex: Int
            let updatedAt: Date
        }

        var positions: [String: Position]?
        var bookmarks: [String: [String]]?
    }

    private struct Version: Decodable {
        let formatVersion: Int?
    }

    public static let formatVersion = 1

    /// The same record always encodes to the same bytes.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(File(
            formatVersion: Self.formatVersion, positions: positions, bookmarks: bookmarks
        ))
    }

    /// Reads this format, or the Mac's from before it, whose bookmarks are
    /// held since a time unknown, 0, so that any recorded change outranks
    /// them. A later format is refused rather than read in part: a client that
    /// rewrote it would drop what it couldn't read.
    public static func decode(_ data: Data) throws -> LampSyncBookReading {
        let decoder = JSONDecoder()
        var reading = LampSyncBookReading()
        switch try decoder.decode(Version.self, from: data).formatVersion {
        case formatVersion?:
            let file = try decoder.decode(File.self, from: data)
            reading.positions = file.positions ?? [:]
            reading.bookmarks = file.bookmarks ?? [:]
        case nil:
            let file = try decoder.decode(UnversionedFile.self, from: data)
            reading.positions = (file.positions ?? [:]).mapValues {
                LampBookReadingPosition(sectionID: $0.sectionID, blockIndex: $0.blockIndex, updatedAt: $0.updatedAt)
            }
            reading.bookmarks = (file.bookmarks ?? [:]).mapValues { sections in
                Dictionary(sections.map { ($0, Mark(presentSince: 0)) }) { first, _ in first }
            }
        default:
            throw CocoaError(.coderReadCorrupt)
        }
        return reading
    }
}
