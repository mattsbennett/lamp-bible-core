/// Shared listing rule for the legacy module directories. Providers keep
/// transport errors visible; a missing directory has no module files.
public enum LampSyncModuleFolder {
    public static func list(
        in store: LampSyncRemoteStore,
        directory: String
    ) async throws -> [LampSyncRemoteEntry] {
        let path = directory.hasSuffix("/") ? directory : directory + "/"
        let entries = try await store.list(directory: path) ?? []
        return entries.filter { entry in
            !entry.isDirectory && LampSyncModuleFiles.moduleID(from: entry.name) != nil
        }
    }
}
