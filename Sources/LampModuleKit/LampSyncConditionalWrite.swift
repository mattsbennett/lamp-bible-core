import Foundation

/// Keeps revision checks and write confirmation consistent across sync clients.
public enum LampSyncConditionalWrite {
    public enum WriteError: Error, LocalizedError {
        case conflict

        public var errorDescription: String? {
            "The remote file changed before it could be saved."
        }
    }

    /// A missing file may be created. An existing file requires its exact,
    /// strong ETag so the provider can enforce the condition during PUT.
    public static func condition(for remote: LampSyncRemoteFile?) throws -> LampSyncWriteCondition {
        guard let remote else { return .ifAbsent }
        return try condition(forExistingRevision: remote.revision)
    }

    /// Use when the caller has already read and validated an existing file
    /// and needs to retain only its revision for the later conditional PUT.
    public static func condition(forExistingRevision revision: String?) throws -> LampSyncWriteCondition {
        guard let revision,
              LampWebDAVStorage.isStrongETag(revision) else {
            throw WriteError.conflict
        }
        return .ifRevision(revision)
    }

    /// Prepare an upload against the revision last merged by this client.
    /// A missing HEAD ETag is checked with GET before assuming absence.
    public static func condition(
        for path: String,
        in store: any LampSyncRemoteStore,
        matching expectedToken: String?
    ) async throws -> LampSyncWriteCondition {
        if let revision = try await store.revision(path: path) {
            guard LampWebDAVStorage.isStrongETag(revision),
                  token(for: revision) == expectedToken else {
                throw WriteError.conflict
            }
            return .ifRevision(revision)
        }
        let remote = try await store.read(path: path)
        if remote == nil && expectedToken != nil {
            throw WriteError.conflict
        }
        let writeCondition = try condition(for: remote)
        if case .ifRevision(let revision) = writeCondition,
           token(for: revision) != expectedToken {
            throw WriteError.conflict
        }
        return writeCondition
    }

    /// A PUT response may omit ETag. Confirm the uploaded body and revision
    /// from one GET response rather than pairing a GET body with a later HEAD.
    public static func writeAndConfirm(
        _ data: Data,
        to path: String,
        in store: any LampSyncRemoteStore,
        condition: LampSyncWriteCondition
    ) async throws -> String {
        let responseRevision = try await store.write(data, to: path, condition: condition)
        if let responseRevision, LampWebDAVStorage.isStrongETag(responseRevision) {
            return responseRevision
        }
        guard let remote = try await store.read(path: path),
              remote.data == data,
              let revision = remote.revision,
              LampWebDAVStorage.isStrongETag(revision) else {
            throw WriteError.conflict
        }
        return revision
    }

    /// The iOS settings cache stores an ETag without HTTP quote delimiters.
    /// Whether two revisions name the same body.
    ///
    /// One may have come from a PROPFIND and the other from a GET, and a
    /// server is free to spell the same ETag differently between them —
    /// quoted in one, bare or weak in the other. Compared as written, such a
    /// pair reads as the body having changed when nothing has, which is why
    /// everything here compares tokens rather than text. Two absent
    /// revisions name nothing and so name the same nothing; one absent and
    /// one present do not.
    public static func namesSameRevision(_ one: String?, _ other: String?) -> Bool {
        one.map(token(for:)) == other.map(token(for:))
    }

    public static func token(for revision: String) -> String {
        var value = revision
        if value.hasPrefix("W/") { value.removeFirst(2) }
        if value.hasPrefix("\"") && value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    /// Only a complete strong entity-tag can identify an applied remote base.
    public static func strongToken(for revision: String?) -> String? {
        guard let revision, LampWebDAVStorage.isStrongETag(revision) else {
            return nil
        }
        return token(for: revision)
    }
}

public extension LampSyncConditionalWrite {
    /// Whether a write landed, judged afterwards from the server's revision.
    ///
    /// `writeAndConfirm` raises the same refusal when the server rejected a
    /// write and when it accepted one and then answered with a revision too
    /// weak to confirm it by. Only the first leaves the file unpublished, and
    /// a client that cannot tell them apart will either claim a file is
    /// missing when it is not, or lose one silently.
    enum Landing: Equatable, Sendable {
        case wrote
        case didNotWrite
        /// The revision cannot settle it, and only the bytes can.
        case undecidable
    }

    /// Judge a write by what the server holds now.
    ///
    /// A write that landed moved the file off the revision it was
    /// conditioned on, so the condition and the revision afterwards are
    /// enough — except for one case, which says so rather than guessing.
    static func landing(
        condition: LampSyncWriteCondition,
        serverRevision: String?
    ) -> Landing {
        switch condition {
        case .unconditional:
            // Nothing was asserted, so nothing could be refused: a failure
            // here came from confirming, after the write had gone through.
            .wrote
        case .ifRevision(let expected):
            // Still the revision we expected to replace means it was not
            // replaced. Compared as tokens, since a server may spell the
            // same ETag differently between a PROPFIND and a PUT.
            namesSameRevision(expected, serverRevision) ? .didNotWrite : .wrote
        case .ifAbsent:
            // Absent still: not written. Present: either this write put it
            // there or something else did, and the revision cannot say
            // which.
            serverRevision == nil ? .didNotWrite : .undecidable
        }
    }
}
