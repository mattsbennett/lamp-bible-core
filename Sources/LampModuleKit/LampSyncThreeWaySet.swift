/// Merges set membership against the last set both sides had applied.
/// A deletion of an observed member wins over an unchanged copy; independent
/// additions on either side survive.
public enum LampSyncThreeWaySet {
    public static func merge<Element: Hashable>(
        base: Set<Element>,
        local: Set<Element>,
        remote: Set<Element>
    ) -> Set<Element> {
        let removed = base.subtracting(local).union(base.subtracting(remote))
        return local.union(remote).subtracting(removed)
    }
}

public enum LampSyncThreeWayDecision: Equatable, Sendable {
    case local
    case remote
    case conflict
}

/// Compares a whole value with the last value both sides applied. The caller
/// can use a normalized value that excludes local-only metadata and clocks.
public enum LampSyncThreeWayValue {
    public static func decide<Value: Equatable>(
        base: Value,
        local: Value,
        remote: Value
    ) -> LampSyncThreeWayDecision {
        if local == remote || remote == base { return .local }
        if local == base { return .remote }
        return .conflict
    }
}
