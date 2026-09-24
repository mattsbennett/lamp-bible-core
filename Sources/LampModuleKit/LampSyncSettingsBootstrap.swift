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
}
