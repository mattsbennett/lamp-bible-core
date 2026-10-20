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
        // Only presence and revision matter here, so the body goes to a
        // scratch file and is dropped.
        let remote = try await LampSyncScratchFile.with { scratch in
            try await store.read(path: path, into: scratch)
        }
        if remote == nil && expectedToken != nil {
            throw WriteError.conflict
        }
        guard let remote else { return .ifAbsent }
        let writeCondition = try condition(forExistingRevision: remote.revision)
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
        try await confirm(
            store.write(data, to: path, condition: condition),
            of: { LampSyncContentRevision.digest(for: data) },
            at: path, in: store
        )
    }

    /// `writeAndConfirm` for a body on disk, sent and checked from the file.
    public static func writeAndConfirm(
        fileAt url: URL,
        to path: String,
        in store: any LampSyncRemoteStore,
        condition: LampSyncWriteCondition
    ) async throws -> String {
        try await confirm(
            store.write(fileAt: url, to: path, condition: condition),
            of: { try LampSyncContentRevision.digest(forFileAt: url) },
            at: path, in: store
        )
    }

    private static func confirm(
        _ responseRevision: String?,
        of sentDigest: () throws -> String,
        at path: String,
        in store: any LampSyncRemoteStore
    ) async throws -> String {
        if let responseRevision, LampWebDAVStorage.isStrongETag(responseRevision) {
            return responseRevision
        }
        // The write went through; what is left is naming the revision it
        // produced, by reading back what was just written.
        //
        // Read once and a server that has not finished settling a large
        // body answers with the version before it, which reads here as
        // somebody else having taken the write — reported to the user as a
        // lost race over a file that is on the server. Asking twice costs
        // one request on a path that is already failing, and a genuine
        // conflict still fails: the other device's bytes do not become ours
        // for being read again.
        //
        // Each read-back is streamed to disk and compared by digest, so it
        // never sits in memory beside the upload. Bytes are the right
        // comparison here, and only here: this is this client's own upload
        // against what the server returns for it. An import compares values
        // (`LampSyncJSONComparison`), because two clients encode one value
        // differently.
        let sent = try sentDigest()
        for attempt in 0..<2 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            let confirmed = try await LampSyncScratchFile.with { scratch -> String? in
                guard let readBack = try await store.read(path: path, into: scratch),
                      let revision = readBack.revision,
                      LampWebDAVStorage.isStrongETag(revision),
                      try LampSyncContentRevision.digest(forFileAt: readBack.url) == sent else {
                    return nil
                }
                return revision
            }
            if let confirmed { return confirmed }
        }
        throw WriteError.conflict
    }

    /// How long to wait for a server that answers reads with what it held
    /// before a write, as the user's Synology does after a PUT.
    public struct Patience: Sendable, Equatable {
        /// The wait before each read-back of a write whose response named no
        /// revision.
        public var confirm: [Duration]
        /// The wait before each retry of a refused write, so a read that
        /// follows sees what the server holds now.
        public var retry: [Duration]

        public init(confirm: [Duration], retry: [Duration]) {
            self.confirm = confirm
            self.retry = retry
        }

        /// About seven and a half seconds for a write to show back, and a
        /// wait before each retry.
        public static let standard = Patience(
            confirm: [.zero, .milliseconds(500), .seconds(1), .seconds(2), .seconds(4)],
            retry: [.milliseconds(500), .seconds(2)]
        )

        /// One read-back and no waiting, for stores that answer at once.
        public static let immediate = Patience(confirm: [.zero], retry: [])

        /// The wait before attempt `attempt`, counting the first as 0.
        public func retryWait(before attempt: Int) -> Duration {
            guard attempt > 0, let last = retry.last else { return .zero }
            return attempt - 1 < retry.count ? retry[attempt - 1] : last
        }
    }

    /// What became of a conditional write, with "taken but not yet shown
    /// back" kept apart from "refused". `writeAndConfirm` folds the two into
    /// one error; a loop that retries on a refusal must not, or a write the
    /// server took is retried against a server still showing what it held
    /// before, and refused for real. (`Verification/SyncMerge.lean`:
    /// `writeOutcome`.)
    public enum Outcome: Equatable, Sendable {
        /// Written, and read back as the bytes sent: its revision.
        case written(String)
        /// The server took the write but has not shown it back in the time
        /// allowed. It is there; only its revision is unknown.
        case writtenUnconfirmed
        /// The condition no longer held. Nothing was written.
        case refused
    }

    /// A write the server took and has not shown back yet. It is on the
    /// server, so the next read finds it. Never a refusal.
    public struct Unconfirmed: Error, LocalizedError, Equatable {
        public let path: String

        public init(path: String) { self.path = path }

        public var errorDescription: String? {
            "The server took the change to \(path) but has not shown it back yet. Nothing was lost: the next sync picks it up."
        }
    }

    /// Writes `data` under `condition` and says what became of it.
    ///
    /// A refusal is only the write's own. Once the server has taken the
    /// write, reading it back can only name its revision; a read that still
    /// shows the old body means the server has not caught up, so it waits
    /// and asks again. While the server still names the revision the write
    /// replaced, it asks by HEAD, so a library-sized body it is about to
    /// replace is never downloaded just to see it is still there.
    public static func write(
        _ data: Data,
        to path: String,
        in store: any LampSyncRemoteStore,
        condition: LampSyncWriteCondition,
        patience: Patience = .standard
    ) async throws -> Outcome {
        try await outcome(
            of: { try await store.write(data, to: path, condition: condition) },
            sent: { LampSyncContentRevision.digest(for: data) },
            at: path, in: store, condition: condition, patience: patience
        )
    }

    /// `write` for a body on disk, sent from the file and read back by its
    /// digest, so neither the upload nor the check holds it in memory.
    public static func write(
        fileAt url: URL,
        to path: String,
        in store: any LampSyncRemoteStore,
        condition: LampSyncWriteCondition,
        patience: Patience = .standard
    ) async throws -> Outcome {
        try await outcome(
            of: { try await store.write(fileAt: url, to: path, condition: condition) },
            sent: { try LampSyncContentRevision.digest(forFileAt: url) },
            at: path, in: store, condition: condition, patience: patience
        )
    }

    private static func outcome(
        of put: () async throws -> String?,
        sent sentDigest: () throws -> String,
        at path: String,
        in store: any LampSyncRemoteStore,
        condition: LampSyncWriteCondition,
        patience: Patience
    ) async throws -> Outcome {
        let response: String?
        do {
            response = try await put()
        } catch where isRefusal(error) {
            return .refused
        }
        if let response, LampWebDAVStorage.isStrongETag(response) { return .written(response) }
        let sent = try sentDigest()
        let replaced: String? = if case .ifRevision(let revision) = condition { revision } else { nil }
        for wait in patience.confirm {
            if wait > .zero { try? await Task.sleep(for: wait) }
            if let replaced, namesSameRevision(try await store.revision(path: path), replaced) { continue }
            let confirmed = try await LampSyncScratchFile.with { scratch -> String? in
                guard let readBack = try await store.read(path: path, into: scratch),
                      let revision = readBack.revision,
                      LampWebDAVStorage.isStrongETag(revision),
                      try LampSyncContentRevision.digest(forFileAt: readBack.url) == sent else {
                    return nil
                }
                return revision
            }
            if let confirmed { return .written(confirmed) }
        }
        return .writtenUnconfirmed
    }

    /// Whether a write failed because its condition no longer held: another
    /// device wrote first. A store may say so through this module's
    /// `WriteError.conflict`, through WebDAV's own 412 or 428, or through an
    /// error of its own that adopts `LampSyncRefusal`. An app that wraps
    /// these in its own error type must adopt it, or a refusal reads as a
    /// failure and nothing that retries on one ever retries.
    public static func isRefusal(_ error: any Error) -> Bool {
        if case WriteError.conflict = error { return true }
        if case LampWebDAVStorage.StorageError.preconditionFailed = error { return true }
        return (error as? any LampSyncRefusal)?.isRefusal ?? false
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

/// An app's own error that can stand for a refused conditional write.
public protocol LampSyncRefusal: Error {
    /// Whether this error is the refusal, rather than another failure.
    var isRefusal: Bool { get }
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
    /// The revision afterwards can show a write did not land — the file is
    /// still where the condition left it — but not that it did. A file that
    /// moved off its condition moved because something wrote it, and a
    /// conditional write is refused precisely when another device wrote
    /// first: the server then holds that device's revision, which is not the
    /// expected one either. Only the bytes can tell this write from that one,
    /// so every such case says it is undecidable rather than guessing.
    /// (`Verification/SyncMerge.lean`: `refusedWriteCanLookWritten` is the
    /// case the revision alone got wrong; `landingIsSound` the rule now.)
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
            // same ETag differently between a PROPFIND and a PUT. Any other
            // revision was written by this write or by the one that refused
            // it, and the revision cannot say which.
            namesSameRevision(expected, serverRevision) ? .didNotWrite : .undecidable
        case .ifAbsent:
            // Absent still: not written. Present: either this write put it
            // there or something else did, and the revision cannot say
            // which.
            serverRevision == nil ? .didNotWrite : .undecidable
        }
    }
}
