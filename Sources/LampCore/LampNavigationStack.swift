import Foundation

/// Back/current/forward navigation for readers that retain distinct locations,
/// including translation and verse position. Its encoded keys match the Mac
/// reader's existing saved history.
public struct LampNavigationStack<Location: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public private(set) var backStack: [Location]
    public private(set) var current: Location?
    public private(set) var forwardStack: [Location]
    public let capacity: Int

    public init(
        backStack: [Location] = [],
        current: Location? = nil,
        forwardStack: [Location] = [],
        capacity: Int = 100
    ) {
        self.backStack = backStack
        self.current = current
        self.forwardStack = forwardStack
        self.capacity = max(capacity, 1)
        trimToCapacity()
    }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    public mutating func visit(_ location: Location) {
        guard current != location else { return }
        if let current { backStack.append(current) }
        current = location
        forwardStack = []
        trimToCapacity()
    }

    @discardableResult
    public mutating func goBack() -> Location? {
        guard let destination = backStack.popLast() else { return nil }
        if let current { forwardStack.append(current) }
        current = destination
        trimToCapacity()
        return destination
    }

    @discardableResult
    public mutating func goForward() -> Location? {
        guard let destination = forwardStack.popLast() else { return nil }
        if let current { backStack.append(current) }
        current = destination
        trimToCapacity()
        return destination
    }

    public mutating func clear(keeping location: Location? = nil) {
        backStack = []
        current = location
        forwardStack = []
    }

    private mutating func trimToCapacity() {
        if backStack.count > capacity {
            backStack.removeFirst(backStack.count - capacity)
        }
        if forwardStack.count > capacity {
            forwardStack.removeFirst(forwardStack.count - capacity)
        }
    }
}
