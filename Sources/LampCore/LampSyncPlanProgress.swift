import Foundation
import LampModuleKit

/// Which reading plans a person follows and which readings they have finished,
/// as every device has recorded them: the settings bundle's plan-progress part.
///
/// A join, unlike the apps' own settings, which merge three ways against what
/// each client last applied. An app from before this part decodes the bundle,
/// passes over the key it doesn't know, and writes the bundle back without it.
/// Under a three-way merge the part's absence would read as every reading
/// unticked on another device. Joined, a missing part or a missing mark says
/// nothing, and the next client to contribute puts its marks back. A join also
/// folds two copies of the bundle written at once, which have no base, as the
/// bundle's other shared parts do.
///
/// Each plan and each reading has a mark: when it was last set (selected,
/// ticked) and last cleared (deselected, unticked), in milliseconds since 1970,
/// joined by the later of each. It is set when it was set no earlier than it
/// was cleared. A tie keeps the tick, because losing someone's progress is what
/// this part exists to prevent; the deletion ledger, whose marks these are,
/// breaks a tie the other way, because there a tie would bring a deleted thing
/// back.
///
/// Each client keeps its own ledger beside its plan tables and records every
/// change into it in the same transaction as the change itself. Recorded apart,
/// a crash between the two leaves the ledger, which is what syncs, saying
/// something the device's own screen never showed.
/// (`Verification/SyncMerge.lean`: `planMarkIsSet`, `planApply`.)
public struct LampSyncPlanProgress: Equatable, Sendable {
    public typealias Mark = LampPersonalDeletionLedger.Entry

    /// By plan ID.
    public private(set) var selections: [String: Mark] = [:]
    /// By reading ID, spelled as `LampLibrary.completedReadingID` spells it.
    public private(set) var readings: [String: Mark] = [:]

    public init() {}

    public var isEmpty: Bool { selections.isEmpty && readings.isEmpty }

    /// Whether a mark is set: set at all, and no earlier than it was cleared.
    public static func isSet(_ mark: Mark) -> Bool {
        guard let set = mark.presentSince else { return false }
        return mark.deletedAt.map { set >= $0 } ?? true
    }

    public var selectedPlanIDs: Set<String> {
        Set(selections.compactMap { Self.isSet($0.value) ? $0.key : nil })
    }

    /// Each finished reading, with when it was last finished.
    public var completedReadings: [String: Int64] {
        readings.reduce(into: [:]) { result, item in
            if Self.isSet(item.value), let at = item.value.presentSince { result[item.key] = at }
        }
    }

    // MARK: - Recording

    public mutating func recordSelection(_ planID: String, at time: Int64) {
        selections[planID] = Self.set(selections[planID], at: time)
    }

    public mutating func recordDeselection(_ planID: String, at time: Int64) {
        selections[planID] = Self.cleared(selections[planID], at: time)
    }

    public mutating func recordCompletion(_ readingID: String, at time: Int64) {
        readings[readingID] = Self.set(readings[readingID], at: time)
    }

    public mutating func recordUncompletion(_ readingID: String, at time: Int64) {
        readings[readingID] = Self.cleared(readings[readingID], at: time)
    }

    /// Records what this device holds: each finished reading at the time it
    /// was finished, each followed plan at the time it was chosen, or 0 where
    /// the device never kept one.
    ///
    /// For a device's first ledger, and safe to repeat on every pass: it only
    /// sets, at times no later than the device's own, so it never clears
    /// anything and never beats a change recorded since. A time of 0 says
    /// "held, since when unknown", so any recorded change outranks it: a plan
    /// another device deselected stays deselected, and one nobody has a record
    /// of stays chosen. "Now" would undo the deselection everywhere.
    public mutating func recordHeld(completed: [String: Int64], selected: [String: Int64]) {
        for (readingID, at) in completed {
            readings[readingID] = (readings[readingID] ?? Mark()).merged(with: Mark(presentSince: at))
        }
        for (planID, at) in selected {
            selections[planID] = (selections[planID] ?? Mark()).merged(with: Mark(presentSince: at))
        }
    }

    /// A mark set at `now`, but never before it was last cleared: so a tick
    /// beats the untick it undoes even on a clock behind the device that
    /// unticked it. (`Verification/SyncMerge.lean`: `stampSet`.)
    static func set(_ mark: Mark?, at now: Int64) -> Mark {
        let mark = mark ?? Mark()
        let at = max(now, mark.deletedAt.map { $0 + 1 } ?? now)
        return mark.merged(with: Mark(presentSince: at))
    }

    /// A mark cleared at `now`, but never before it was last set.
    /// (`Verification/SyncMerge.lean`: `stampCleared`.)
    static func cleared(_ mark: Mark?, at now: Int64) -> Mark {
        let mark = mark ?? Mark()
        let at = max(now, mark.presentSince.map { $0 + 1 } ?? now)
        return mark.merged(with: Mark(deletedAt: at))
    }

    // MARK: - Joining

    /// Per plan and per reading, the later of each time.
    public mutating func merge(_ other: LampSyncPlanProgress) {
        selections.merge(other.selections) { $0.merged(with: $1) }
        readings.merge(other.readings) { $0.merged(with: $1) }
    }

    // MARK: - Applying

    /// What a client does to its own tables to hold what this ledger says.
    public struct Changes: Equatable, Sendable {
        /// Readings to hold as finished at this time: ones it doesn't hold,
        /// and ones it holds as finished earlier.
        public var complete: [String: Int64] = [:]
        public var uncomplete: Set<String> = []
        /// Plans to start following. A followed plan isn't re-chosen at a
        /// later time: nothing reads when a plan was chosen.
        public var select: Set<String> = []
        public var deselect: Set<String> = []

        public init() {}

        public var isEmpty: Bool {
            complete.isEmpty && uncomplete.isEmpty && select.isEmpty && deselect.isEmpty
        }
    }

    /// What to change so that a client holding `completed` and `selected` (each
    /// with its time, or 0 where the client keeps none) holds what this ledger
    /// says. Call it with the ledger already joined with the client's own.
    ///
    /// Nothing is taken away without a mark clearing it later than the client's
    /// own copy, so a ledger missing a reading, or missing altogether, takes
    /// nothing away.
    public func changes(toApplyTo completed: [String: Int64], selected: [String: Int64]) -> Changes {
        var changes = Changes()
        for readingID in Set(readings.keys).union(completed.keys) {
            switch Self.apply(readings[readingID], held: completed[readingID]) {
            case .leave: break
            case .hold(let at): changes.complete[readingID] = at
            case .drop: changes.uncomplete.insert(readingID)
            }
        }
        for planID in Set(selections.keys).union(selected.keys) {
            let held = selected[planID]
            switch Self.apply(selections[planID], held: held) {
            case .hold where held == nil: changes.select.insert(planID)
            case .drop: changes.deselect.insert(planID)
            case .leave, .hold: break
            }
        }
        return changes
    }

    enum Change: Equatable {
        case leave
        case hold(at: Int64)
        case drop
    }

    /// One plan's or reading's change: the client's own copy counts as a mark
    /// set at its time, so a copy newer than the clearing stays.
    /// (`Verification/SyncMerge.lean`: `planApply`.)
    static func apply(_ mark: Mark?, held: Int64?) -> Change {
        let joined = (mark ?? Mark()).merged(with: Mark(presentSince: held))
        guard isSet(joined), let at = joined.presentSince else {
            return held == nil ? .leave : .drop
        }
        return held == at ? .leave : .hold(at: at)
    }

    // MARK: - Reading IDs

    /// A reading ID's parts, the inverse of `LampLibrary.completedReadingID`.
    ///
    /// Read from the right: a plan ID can itself hold underscores, and the
    /// phone's `plan_id` column, which takes the first part, holds "the" for
    /// "the_bible_companion". Nil for an ID that isn't one.
    public static func readingParts(
        of readingID: String
    ) -> (planID: String, day: Int, readingIndex: Int, year: Int)? {
        let parts = readingID.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count >= 4,
              let year = Int(parts[parts.count - 1]),
              let index = Int(parts[parts.count - 2]),
              let day = Int(parts[parts.count - 3]) else { return nil }
        let planID = parts.dropLast(3).joined(separator: "_")
        guard !planID.isEmpty else { return nil }
        return (planID, day, index, year)
    }

    // MARK: - File format

    private struct File: Codable {
        var formatVersion: Int
        var selections: [String: Mark]?
        var readings: [String: Mark]?
    }

    public static let formatVersion = 1

    /// The same ledger always encodes to the same bytes.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(File(
            formatVersion: Self.formatVersion, selections: selections, readings: readings
        ))
    }

    /// A ledger of a later format is refused rather than read in part: a
    /// client that rewrote it would drop what it couldn't read.
    public static func decode(_ data: Data) throws -> LampSyncPlanProgress {
        let file = try JSONDecoder().decode(File.self, from: data)
        guard file.formatVersion == formatVersion else { throw CocoaError(.coderReadCorrupt) }
        var progress = LampSyncPlanProgress()
        progress.selections = file.selections ?? [:]
        progress.readings = file.readings ?? [:]
        return progress
    }
}
