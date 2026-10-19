import Foundation

/// Whether a sync pass that failed is worth running again.
///
/// A pass reads the archive at its start and writes it at its end, on the
/// condition that the server still holds what it read. When another device
/// publishes in between, that write is refused — correctly, because what this
/// pass built does not contain what the other device wrote. Nothing is wrong:
/// the pass is out of date, and one more pass starting from what won is the
/// whole remedy. Only one, though. A library someone keeps publishing to is
/// better reported than chased. (`Verification/SyncMerge.lean`: `passRetry`.)
public enum LampSyncPassRetry {
    /// The most passes one sync request runs.
    public static let maximumPasses = 2

    /// Whether a refused archive write lost to another device: the server's
    /// revision has moved off the one this pass read. An archive that was
    /// absent when read and is there now has moved too.
    public static func lostRace(read observed: String?, serverNow: String?) -> Bool {
        !LampSyncConditionalWrite.namesSameRevision(observed, serverNow)
    }

    /// Whether to run another pass, after `passesRun` of them.
    public static func shouldRunAgain(
        passesRun: Int,
        lastPassSucceeded: Bool,
        lostRace: Bool
    ) -> Bool {
        !lastPassSucceeded && lostRace && passesRun < maximumPasses
    }
}
