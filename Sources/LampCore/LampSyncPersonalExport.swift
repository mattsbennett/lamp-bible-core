/// Classifies the one expected empty personal highlight export. Other export
/// failures must reach the sync runner so it cannot report a complete publish.
public enum LampSyncPersonalExport {
    public static func highlightsIfPresent<Value>(
        _ export: () async throws -> Value
    ) async throws -> Value? {
        do {
            return try await export()
        } catch LampLibraryError.noPersonalHighlights {
            return nil
        }
    }
}
