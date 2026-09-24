import Foundation

/// Pairs a provider body with its token when the provider cannot return both
/// from one response. Content-digest providers can also bind the returned
/// body to both token probes. This cannot make a later write conditional on
/// the observed token.
public enum LampSyncStableRead {
    public enum ReadError: Error, LocalizedError {
        case changedDuringRead
        case missingRevision

        public var errorDescription: String? {
            switch self {
            case .changedDuringRead:
                "The remote file changed while it was being read."
            case .missingRevision:
                "The remote file has no revision for a safe read."
            }
        }
    }

    public static func read(
        revision: () async -> String?,
        data: () async throws -> Data,
        bodyRevision: ((Data) -> String)? = nil
    ) async throws -> LampSyncRemoteFile {
        let before = await revision()
        let body = try await data()
        let after = await revision()
        guard before == after else { throw ReadError.changedDuringRead }
        guard after != nil else { throw ReadError.missingRevision }
        if let bodyRevision, bodyRevision(body) != after {
            throw ReadError.changedDuringRead
        }
        return LampSyncRemoteFile(data: body, revision: after)
    }
}
