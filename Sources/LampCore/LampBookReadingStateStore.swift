import Foundation

/// This device's record of where each book was left and what is bookmarked in
/// it: one `LampSyncBookReading` in the defaults, under the key both apps use.
/// What the reader changes is what a sync pass contributes, in the same write.
public struct LampBookReadingStateStore {
    public static let defaultsKey = "books.readerState"

    /// One read, change and write at a time: the reader and a sync pass both
    /// write, and two interleaved would lose one of the changes.
    private static let lock = NSLock()

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    public func position(for moduleID: String) -> LampBookReadingPosition? {
        ledger().positions[moduleID]
    }

    /// Every book's position, by module ID.
    public func positions() -> [String: LampBookReadingPosition] {
        ledger().positions
    }

    public func save(position: LampBookReadingPosition, for moduleID: String) {
        update { $0.record(position, for: moduleID) }
    }

    public func bookmarkIDs(for moduleID: String) -> Set<String> {
        ledger().bookmarkedSections(in: moduleID)
    }

    /// Whether the section is bookmarked now.
    @discardableResult
    public func toggleBookmark(sectionID: String, for moduleID: String, at now: Date = Date()) -> Bool {
        let time = Int64((now.timeIntervalSince1970 * 1_000).rounded(.down))
        var isBookmarked = false
        update { ledger in
            isBookmarked = !ledger.bookmarkedSections(in: moduleID).contains(sectionID)
            if isBookmarked {
                ledger.recordBookmark(sectionID, in: moduleID, at: time)
            } else {
                ledger.recordUnbookmark(sectionID, in: moduleID, at: time)
            }
        }
        return isBookmarked
    }

    /// The whole record, which a sync pass contributes every time.
    public func ledger() -> LampSyncBookReading {
        guard let data = defaults.data(forKey: key),
              let ledger = try? LampSyncBookReading.decode(data) else { return LampSyncBookReading() }
        return ledger
    }

    /// Joins in what a sync pass brought back, and says whether that changed
    /// anything here.
    @discardableResult
    public func merge(_ incoming: LampSyncBookReading) -> Bool {
        var changed = false
        update { ledger in
            let before = ledger
            ledger.merge(incoming)
            changed = ledger != before
        }
        return changed
    }

    private func update(_ change: (inout LampSyncBookReading) -> Void) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var ledger = ledger()
        let before = ledger
        change(&ledger)
        guard ledger != before, let data = try? ledger.encoded() else { return }
        defaults.set(data, forKey: key)
    }
}

/// Keeps scrolling's constant changes of position in memory until the reader
/// settles, so that every scroll tick isn't a decode, an encode and a write
/// to the defaults.
public struct LampBookReadingPositionBuffer: Equatable, Sendable {
    public private(set) var blockIndex: Int
    private var persistedBlockIndex: Int

    public init(blockIndex: Int = -1) {
        let normalizedIndex = max(blockIndex, -1)
        self.blockIndex = normalizedIndex
        persistedBlockIndex = normalizedIndex
    }

    public mutating func observe(visibleBlockIndices: [Int]) {
        guard let firstVisibleIndex = visibleBlockIndices.min() else { return }
        blockIndex = max(firstVisibleIndex, -1)
    }

    /// The position, only when it has changed since the last time it was
    /// taken.
    public mutating func takeChangedBlockIndex() -> Int? {
        guard blockIndex != persistedBlockIndex else { return nil }
        persistedBlockIndex = blockIndex
        return blockIndex
    }
}
