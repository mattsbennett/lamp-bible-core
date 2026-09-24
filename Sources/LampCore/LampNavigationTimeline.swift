import Foundation

/// The reader's ordered visits and cursor, independent of UI and persistence.
/// Callers choose whether a visit to an existing identity should keep forward
/// visits (the iOS chapter history) or branch (the Mac reader history).
public struct LampNavigationTimeline<Entry: Equatable & Sendable>: Equatable, Sendable {
    public private(set) var entries: [Entry]
    public private(set) var currentIndex: Int
    public let capacity: Int

    public init(entries: [Entry] = [], currentIndex: Int = -1, capacity: Int = 100) {
        self.capacity = max(capacity, 1)
        self.entries = entries
        self.currentIndex = entries.isEmpty ? -1 : min(max(currentIndex, 0), entries.count - 1)
        trim()
    }

    public var current: Entry? {
        guard entries.indices.contains(currentIndex) else { return nil }
        return entries[currentIndex]
    }

    public var canGoBack: Bool { currentIndex > 0 }
    public var canGoForward: Bool { currentIndex >= 0 && currentIndex < entries.count - 1 }

    public mutating func visit(
        _ entry: Entry,
        identity: (Entry) -> AnyHashable,
        preserveForwardForExistingIdentity: Bool = false
    ) {
        if let current, identity(current) == identity(entry) { return }
        let alreadyVisited = entries.contains { identity($0) == identity(entry) }
        if !(preserveForwardForExistingIdentity && alreadyVisited) {
            entries = Array(entries.prefix(currentIndex + 1))
        }
        entries.removeAll { identity($0) == identity(entry) }
        entries.append(entry)
        currentIndex = entries.count - 1
        trim()
    }

    public mutating func replaceCurrent(with entry: Entry, when matches: (Entry, Entry) -> Bool) {
        guard let current, matches(current, entry) else { return }
        entries[currentIndex] = entry
    }

    @discardableResult
    public mutating func goBack() -> Entry? {
        guard canGoBack else { return nil }
        currentIndex -= 1
        return current
    }

    @discardableResult
    public mutating func goForward() -> Entry? {
        guard canGoForward else { return nil }
        currentIndex += 1
        return current
    }

    @discardableResult
    public mutating func goToIndex(_ index: Int) -> Entry? {
        guard entries.indices.contains(index) else { return nil }
        currentIndex = index
        return current
    }

    public mutating func clear(keeping entry: Entry? = nil) {
        entries = entry.map { [$0] } ?? []
        currentIndex = entry == nil ? -1 : 0
    }

    private mutating func trim() {
        guard entries.count > capacity else { return }
        let removed = entries.count - capacity
        entries.removeFirst(removed)
        currentIndex = max(0, currentIndex - removed)
    }
}
