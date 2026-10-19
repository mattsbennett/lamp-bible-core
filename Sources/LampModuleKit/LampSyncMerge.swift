import Foundation

/// The shared decision for two versions of the same editable record.
/// A conflict means both versions have the same timestamp but different content;
/// callers keep the local value until a user or a higher-level policy resolves it.
public enum LampSyncMergeDecision: Equatable, Sendable {
    case local
    case incoming
    case conflict
}

/// What an import does with one record once `LampSyncMerge.decide` has
/// spoken. (`Verification/SyncMerge.lean`: `portableImportOutcome`.)
public enum LampSyncImportOutcome: Equatable, Sendable {
    case keepLocal
    case takeIncoming
    /// Keep this device's copy, set the other aside for the person to choose
    /// from, and carry on with the rest of the import.
    case setAside
    /// Stop the import and say why.
    case stop
}

public extension LampSyncMerge {
    /// A sync run sets an equal-time disagreement aside rather than stopping:
    /// one record two devices disagree about is no reason to stop a library
    /// syncing, and only the person can say which version they meant. An
    /// import they asked for still stops, because they are there to be told.
    static func importOutcome(
        _ decision: LampSyncMergeDecision,
        forSync: Bool
    ) -> LampSyncImportOutcome {
        switch decision {
        case .incoming: .takeIncoming
        case .local: .keepLocal
        case .conflict: forSync ? .setAside : .stop
        }
    }
}

public struct LampSyncRecordConflict<Key: Hashable, Record> {
    public let key: Key
    public let local: Record
    public let incoming: Record
}

public struct LampSyncRecordMerge<Key: Hashable, Record> {
    public let recordsToSave: [Record]
    public let conflicts: [LampSyncRecordConflict<Key, Record>]
    public let incomingCount: Int
    public let localCount: Int
}

public enum LampSyncMerge {
    /// Choose a record by its stored modification time. Missing times are treated
    /// as zero, matching the legacy iOS note and devotional merge behavior.
    public static func decide(
        localModified: Int?,
        incomingModified: Int?,
        sameContent: Bool
    ) -> LampSyncMergeDecision {
        let local = localModified ?? 0
        let incoming = incomingModified ?? 0
        if incoming > local { return .incoming }
        if local > incoming { return .local }
        return sameContent ? .local : .conflict
    }

    /// A user-selected value must be newer than both conflicting copies so
    /// another device does not surface the same equal-time conflict again.
    /// Malformed revisions at Int.max cannot be advanced safely.
    public static func resolutionTimestamp(
        localModified: Int?,
        incomingModified: Int?,
        now: Int
    ) -> Int? {
        let latest = max(now, max(localModified ?? 0, incomingModified ?? 0))
        return latest == Int.max ? nil : latest + 1
    }

    /// Merge every key once, retaining a local value while a conflict awaits
    /// resolution. Duplicate input keys keep the first record, matching the
    /// legacy note merge and avoiding a crash on malformed remote data.
    public static func records<Key: Hashable, Record>(
        local: [Record],
        incoming: [Record],
        key: (Record) -> Key,
        modified: (Record) -> Int?,
        sameContent: (Record, Record) -> Bool
    ) -> LampSyncRecordMerge<Key, Record> {
        var localByKey: [Key: Record] = [:]
        var incomingByKey: [Key: Record] = [:]
        var orderedKeys: [Key] = []
        var seen = Set<Key>()
        for record in local {
            let id = key(record)
            if localByKey[id] == nil { localByKey[id] = record }
            if seen.insert(id).inserted { orderedKeys.append(id) }
        }
        for record in incoming {
            let id = key(record)
            if incomingByKey[id] == nil { incomingByKey[id] = record }
            if seen.insert(id).inserted { orderedKeys.append(id) }
        }

        var recordsToSave: [Record] = []
        var conflicts: [LampSyncRecordConflict<Key, Record>] = []
        var incomingCount = 0
        var localCount = 0
        for id in orderedKeys {
            switch (localByKey[id], incomingByKey[id]) {
            case (nil, let remote?):
                recordsToSave.append(remote)
                incomingCount += 1
            case (let current?, nil):
                recordsToSave.append(current)
                localCount += 1
            case (let current?, let remote?):
                switch decide(
                    localModified: modified(current),
                    incomingModified: modified(remote),
                    sameContent: sameContent(current, remote)
                ) {
                case .local:
                    recordsToSave.append(current)
                    if (modified(current) ?? 0) > (modified(remote) ?? 0) {
                        localCount += 1
                    }
                case .incoming:
                    recordsToSave.append(remote)
                    incomingCount += 1
                case .conflict:
                    recordsToSave.append(current)
                    conflicts.append(.init(key: id, local: current, incoming: remote))
                }
            case (nil, nil):
                break
            }
        }
        return LampSyncRecordMerge(
            recordsToSave: recordsToSave,
            conflicts: conflicts,
            incomingCount: incomingCount,
            localCount: localCount
        )
    }

    /// Workspace files use a total order so equal-time edits converge without
    /// an interactive conflict UI. Fixed millisecond buckets accommodate common
    /// provider timestamp precision without the cycles of a sliding tolerance.
    public static func shouldReplaceFile(
        currentData: Data,
        currentDate: Date?,
        incomingData: Data,
        incomingDate: Date?
    ) -> Bool {
        let currentTick = millisecondTick(currentDate)
        let incomingTick = millisecondTick(incomingDate)
        if incomingTick != currentTick { return incomingTick > currentTick }
        return currentData.lexicographicallyPrecedes(incomingData)
    }

    private static func millisecondTick(_ date: Date?) -> Int64 {
        guard let date else { return .min }
        let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded(.down)
        guard !milliseconds.isNaN else { return .min }
        if milliseconds >= Double(Int64.max) { return .max }
        if milliseconds <= Double(Int64.min) { return .min }
        return Int64(milliseconds)
    }
}
