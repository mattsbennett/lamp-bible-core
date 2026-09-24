import Testing
@testable import LampModuleKit

struct LampSyncSettingsBootstrapTests {
    @Test func missingRemoteHonorsRequirement() {
        #expect(LampSyncSettingsBootstrap.action(
            remoteExists: false, requireRemote: true,
            hasApplicableBase: false, hasStoredToken: false,
            freshInstall: true, hasUnsyncedChanges: false
        ) == .missingRequiredRemote)
        #expect(LampSyncSettingsBootstrap.action(
            remoteExists: false, requireRemote: false,
            hasApplicableBase: false, hasStoredToken: false,
            freshInstall: true, hasUnsyncedChanges: false
        ) == .createRemote)
    }

    @Test func freshAdoptionPrecedesGuardedUpload() {
        #expect(LampSyncSettingsBootstrap.action(
            remoteExists: true, requireRemote: false,
            hasApplicableBase: false, hasStoredToken: false,
            freshInstall: true, hasUnsyncedChanges: true
        ) == .adoptRemote)
    }

    @Test func dirtyWithoutBaseNeedsGuardedUpload() {
        #expect(LampSyncSettingsBootstrap.action(
            remoteExists: true, requireRemote: false,
            hasApplicableBase: false, hasStoredToken: true,
            freshInstall: false, hasUnsyncedChanges: true
        ) == .guardedFirstUpload)
        #expect(LampSyncSettingsBootstrap.action(
            remoteExists: true, requireRemote: false,
            hasApplicableBase: true, hasStoredToken: true,
            freshInstall: false, hasUnsyncedChanges: true
        ) == .merge)
    }
}
