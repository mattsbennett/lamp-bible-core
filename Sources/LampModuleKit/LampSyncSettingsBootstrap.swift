/// Chooses the first settings sync step without depending on the provider,
/// local database format, or UI lifecycle.
public enum LampSyncSettingsBootstrap {
    public enum Action: Equatable, Sendable {
        case missingRequiredRemote
        case createRemote
        case adoptRemote
        case guardedFirstUpload
        case merge
    }

    public static func action(
        remoteExists: Bool,
        requireRemote: Bool,
        hasApplicableBase: Bool,
        hasStoredToken: Bool,
        freshInstall: Bool,
        hasUnsyncedChanges: Bool
    ) -> Action {
        guard remoteExists else {
            return requireRemote ? .missingRequiredRemote : .createRemote
        }
        if !hasApplicableBase && !hasStoredToken && freshInstall {
            return .adoptRemote
        }
        if !hasApplicableBase && hasUnsyncedChanges {
            return .guardedFirstUpload
        }
        return .merge
    }

    /// Whether a guarded first upload may write before it merges: only while
    /// the server still holds the revision this device last observed, which
    /// an unknown revision on either side cannot show.
    ///
    /// Otherwise the merge runs on its own and reconciles through
    /// `LampSyncSettingsPlanner.planWithoutBase`. Refusing instead settled
    /// nothing — the inputs were unchanged by the refusal, so every later
    /// poll failed the same way and the device never earned a baseline.
    /// (`Verification/SyncMerge.lean`: `uploadsBeforeMerge`.)
    public static func uploadsBeforeMerge(
        action: Action,
        observedToken: String?,
        remoteToken: String?
    ) -> Bool {
        guard action == .guardedFirstUpload,
              let observedToken, let remoteToken else { return false }
        return LampSyncConditionalWrite.namesSameRevision(observedToken, remoteToken)
    }
}
