import Foundation
import Testing
@testable import LampCore
@testable import LampModuleKit

/// The Lean sync model, checked with the other suites, and held to the Swift
/// code it describes.
///
/// `Verification/SyncMerge.lean` proves properties of small models of the
/// sync decisions, and prints a `CONFORMANCE` table of each model's answers.
/// These tests check the proofs go through, then ask the shipped Swift
/// decision every question in each table. A decision changed on one side and
/// not the other fails here, which is what keeps the model from drifting.
///
/// Lean comes from elan (`brew install elan-init`); the version is pinned by
/// `lean-toolchain`. On a machine without it, `LAMP_SKIP_LEAN=1` skips these
/// tests by name rather than letting them pass.
enum SyncModel {
    struct Run {
        let status: Int32
        let lines: [String]
        let problem: String?
    }

    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let modelURL = packageRoot.appendingPathComponent("Verification/SyncMerge.lean")

    static var skipped: Bool {
        ProcessInfo.processInfo.environment["LAMP_SKIP_LEAN"] == "1"
    }

    /// One run of the model, shared by every test here: checking it takes a
    /// few seconds, and its tables do not change within a test run.
    static let run: Run = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            ProcessInfo.processInfo.environment["LAMP_ELAN"],
            "\(home)/.elan/bin/elan",
            "/opt/homebrew/bin/elan",
            "/usr/local/bin/elan",
        ].compactMap { $0 }
        guard let elan = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return Run(
                status: -1, lines: [],
                problem: "Lean checks the sync model, and elan was not found. Install it with "
                    + "`brew install elan-init` (see Verification/README.md), or set "
                    + "LAMP_SKIP_LEAN=1 on a machine that cannot."
            )
        }
        let toolchain = (try? String(
            contentsOf: packageRoot.appendingPathComponent("lean-toolchain"), encoding: .utf8
        ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "stable"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: elan)
        process.arguments = ["run", toolchain, "lean", modelURL.path]
        process.currentDirectoryURL = packageRoot
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            return Run(status: -1, lines: [], problem: "Could not run Lean: \(error)")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        return Run(status: process.terminationStatus, lines: lines, problem: nil)
    }()

    /// The inputs and answer of every case the model printed for `rule`.
    static func cases(_ rule: String) -> [[String]] {
        run.lines.compactMap { line in
            let fields = line.split(separator: " ").map(String.init)
            guard fields.count > 2, fields[0] == "CONFORMANCE", fields[1] == rule else { return nil }
            return Array(fields.dropFirst(2))
        }
    }

    static var rules: Set<String> {
        Set(run.lines.compactMap { line in
            let fields = line.split(separator: " ")
            return fields.count > 1 && fields[0] == "CONFORMANCE" ? String(fields[1]) : nil
        })
    }
}

@Suite(.disabled(if: SyncModel.skipped, "LAMP_SKIP_LEAN=1"))
struct SyncModelConformanceTests {
    /// Every rule the model prints, with the Swift decision it describes.
    static let checkedRules: Set<String> = [
        "decide", "importOutcome", "landing", "tombstone", "tombstoneMerge",
        "baselessReading", "shouldRunAgain", "lostRace", "uploadsBeforeMerge",
        "namesSameRevision", "needsImport", "indexTrusted", "mayAdvanceWithoutFetch",
        "reuseArchive", "preferenceMerge",
    ]

    // MARK: - The model itself

    @Test func theModelChecks() throws {
        let run = SyncModel.run
        if let problem = run.problem { Issue.record("\(problem)"); return }
        #expect(run.status == 0, "Lean rejected the model:\n\(run.lines.prefix(40).joined(separator: "\n"))")
        // A warning — `sorry`, an unused hypothesis gone stale — is something
        // to read, so anything printed besides the tables fails too.
        let other = run.lines.filter { !$0.hasPrefix("CONFORMANCE ") }
        #expect(other.isEmpty, "Lean printed more than its tables:\n\(other.prefix(40).joined(separator: "\n"))")
    }

    /// A table nobody checks is a model nobody holds to the code, and a
    /// checker with no table checks nothing.
    @Test func everyTableIsCheckedAndEveryCheckHasATable() throws {
        try #require(SyncModel.run.problem == nil)
        #expect(SyncModel.rules.subtracting(Self.checkedRules).isEmpty,
                "Tables with no Swift check: \(SyncModel.rules.subtracting(Self.checkedRules).sorted())")
        #expect(Self.checkedRules.subtracting(SyncModel.rules).isEmpty,
                "Swift checks with no table: \(Self.checkedRules.subtracting(SyncModel.rules).sorted())")
    }

    // MARK: - Record decisions

    @Test func recordDecision() throws {
        try conform("decide") { f in
            name(LampSyncMerge.decide(
                localModified: Int(f[0]), incomingModified: Int(f[1]), sameContent: f[2] == "true"
            )) == f[3]
        }
    }

    @Test func importOutcome() throws {
        try conform("importOutcome") { f in
            let decision = LampSyncMerge.decide(
                localModified: Int(f[1]), incomingModified: Int(f[2]), sameContent: f[3] == "true"
            )
            return "\(LampSyncMerge.importOutcome(decision, forSync: f[0] == "true"))" == f[4]
        }
    }

    @Test func baselessReading() throws {
        struct Reading: Equatable { let revision: Int; let body: Int }
        func row(_ field: String) -> [String: Reading] {
            guard field != "-" else { return [:] }
            let parts = field.split(separator: ":").compactMap { Int($0) }
            return ["reading": Reading(revision: parts[0], body: parts[1])]
        }
        try conform("baselessReading") { f in
            let plan = try LampSyncSettingsPlanner.planWithoutBase(
                localSettings: 0, localRevision: 1, localReadings: row(f[0]),
                remoteSettings: 0, remoteRevision: 2, remoteReadings: row(f[1]),
                revision: { $0.revision }
            )
            let merged = plan.readings["reading"].map { "\($0.revision):\($0.body)" } ?? "-"
            return merged == f[2]
        }
    }

    // MARK: - Writes

    @Test func writeLanding() throws {
        try conform("landing") { f in
            let condition: LampSyncWriteCondition = switch f[0] {
            case "unconditional": .unconditional
            case "ifAbsent": .ifAbsent
            default: .ifRevision(quoted(String(f[0].dropFirst("ifRevision:".count))))
            }
            let landing = LampSyncConditionalWrite.landing(
                condition: condition, serverRevision: f[1] == "-" ? nil : quoted(f[1])
            )
            return "\(landing)" == f[2]
        }
    }

    @Test func passRetry() throws {
        try conform("shouldRunAgain") { f in
            LampSyncPassRetry.shouldRunAgain(
                passesRun: Int(f[0])!, lastPassSucceeded: f[1] == "true", lostRace: f[2] == "true"
            ) == (f[3] == "true")
        }
        try conform("lostRace") { f in
            LampSyncPassRetry.lostRace(
                read: f[0] == "-" ? nil : quoted(f[0]), serverNow: f[1] == "-" ? nil : quoted(f[1])
            ) == (f[2] == "true")
        }
    }

    @Test func firstSettingsUpload() throws {
        try conform("uploadsBeforeMerge") { f in
            LampSyncSettingsBootstrap.uploadsBeforeMerge(
                action: f[0] == "true" ? .guardedFirstUpload : .merge,
                observedToken: f[1] == "-" ? nil : f[1],
                remoteToken: f[2] == "-" ? nil : f[2]
            ) == (f[3] == "true")
        }
    }

    // MARK: - Revisions

    @Test func revisionTokens() throws {
        try conform("namesSameRevision") { f in
            LampSyncConditionalWrite.namesSameRevision(spelled(f[0]), spelled(f[1])) == (f[2] == "true")
        }
    }

    @Test func moduleImportGate() throws {
        try conform("needsImport") { f in
            LampSyncModuleFiles.needsImport(
                isNew: f[0] == "true",
                installedPath: "notes/a.lamp",
                remotePath: f[1] == "true" ? "notes/a.lamp" : "notes/b.lamp",
                installedRevision: f[2] == "-" ? nil : f[2],
                remoteRevision: spelled(f[3])
            ) == (f[4] == "true")
        }
    }

    // MARK: - Archive index and reuse

    @Test func archiveIndexTrust() async throws {
        for f in SyncModel.cases("indexTrusted") {
            let store = InMemoryRemoteStore()
            if f[1] != "-" {
                let index = LampSyncArchiveIndex(
                    formatVersion: f[1].hasSuffix("u") ? LampSyncArchiveIndex.currentFormatVersion + 1
                        : LampSyncArchiveIndex.currentFormatVersion,
                    archiveRevision: quoted(String(f[1].dropLast())),
                    digests: ["notes/a.lamp": "digest"]
                )
                store.files[LampSyncLayout.archiveIndexPath] = try JSONEncoder().encode(index)
            }
            let known: String? = switch f[0] {
            case "-": nil
            case "w1": "W/\"1\""
            default: quoted(f[0])
            }
            let trusted = await LampSyncArchiveIndex.availability(in: store, knownRevision: known).index != nil
            #expect(trusted == (f[2] == "true"), "indexTrusted \(f.joined(separator: " "))")
        }
        #expect(!SyncModel.cases("indexTrusted").isEmpty)
    }

    @Test func advancingWithoutFetch() throws {
        func index(_ entries: String) -> LampSyncArchiveIndex {
            LampSyncArchiveIndex(
                archiveRevision: "\"1\"",
                digests: ["notes/a.lamp": entries == "A" ? "first" : "second"]
            )
        }
        try conform("mayAdvanceWithoutFetch") { f in
            LampSyncArchiveIndex.mayAdvanceWithoutFetch(
                cacheUsable: f[0] == "true",
                appliedFingerprint: f[1] == "-" ? nil : index(f[1]).importableFingerprint,
                availability: f[2] == "-" ? .absent : .current(index(f[2]))
            ) == (f[3] == "true")
        }
    }

    @Test func archiveReuse() throws {
        try conform("reuseArchive") { f in
            let candidate: String? = f[0] == "-" ? nil
                : f[1] == "true" ? quoted(f[0]) : "W/" + quoted(f[0])
            return LampSyncSettingsArchive.mayReuse(
                candidateRevision: candidate,
                serverRevision: f[2] == "-" ? nil : quoted(f[2])
            ) == (f[3] == "true")
        }
    }

    // MARK: - Deletion ledgers

    @Test func deletionLedgers() throws {
        func milliseconds(_ field: String) -> Int64? { Int64(field).map { $0 * 1_000 } }
        try conform("tombstone") { f in
            // Personal content: save and deletion in milliseconds, the copy's
            // modification in seconds, as the database records each.
            let personal = LampPersonalDeletionLedger.Entry(
                presentSince: milliseconds(f[0]), deletedAt: milliseconds(f[1])
            ).isDeleted(itemModified: Int(f[2]))
            guard personal == (f[3] == "true") else { return false }
            // Decks keep no saves of their own; the copy's date stands in.
            guard f[0] == "-", let copy = Int(f[2]) else { return true }
            var ledger = LampPresentationDeckDeletionLedger()
            if let deleted = Int(f[1]) {
                ledger.record("deck", at: Date(timeIntervalSince1970: TimeInterval(deleted)))
            }
            return ledger.deletes("deck", modifiedAt: Date(timeIntervalSince1970: TimeInterval(copy)))
                == (f[3] == "true")
        }
        try conform("tombstoneMerge") { f in
            let merged = LampPersonalDeletionLedger.Entry(presentSince: Int64(f[0]), deletedAt: Int64(f[1]))
                .merged(with: .init(presentSince: Int64(f[2]), deletedAt: Int64(f[3])))
            return merged.presentSince.map { "\($0)" } ?? "-" == f[4]
                && merged.deletedAt.map { "\($0)" } ?? "-" == f[5]
        }
    }

    // MARK: - Shared preferences

    @Test func preferenceMerge() throws {
        let key = "plans.reminder.hour"
        func uuid(_ revision: String) -> String {
            "00000000-0000-0000-0000-" + String(repeating: "0", count: 12 - revision.count) + revision
        }
        func field(_ text: String) -> LampSharedPreferenceLedger.Field? {
            guard text != "-" else { return nil }
            let parts = text.split(separator: "@").map(String.init)
            return .init(value: Int(parts[0]).map { .integer($0) }, revision: uuid(parts[1]))
        }
        let inputRevisions = Set(["10", "11"].map(uuid))
        func matches(_ actual: LampSharedPreferenceLedger.Field?, _ expected: String) -> Bool {
            guard expected != "-" else { return actual == nil }
            guard let actual else { return false }
            let parts = expected.split(separator: "@").map(String.init)
            guard actual.value == Int(parts[0]).map({ .integer($0) }) else { return false }
            return parts[1] == "fresh" ? !inputRevisions.contains(actual.revision)
                : actual.revision == uuid(parts[1])
        }
        try conform("preferenceMerge") { f in
            let base: LampSharedPreferenceLedger? = f[0] == "true"
                ? .init(fields: field(f[1]).map { [key: $0] } ?? [:]) : nil
            let remote = LampSharedPreferenceLedger(fields: field(f[2]).map { [key: $0] } ?? [:])
            let local: [String: LampSharedPreferenceLedger.Value] = Int(f[3]).map { [key: .integer($0)] } ?? [:]
            let merge = try LampSharedPreferenceLedger.merge(local: local, base: base, remote: remote)
            let published = merge.publishable.fields[key]
            // Applying means this device takes what is published; not
            // applying means the field is left out, so its value stands.
            let applied = f[5] == "true"
                ? merge.applicable.fields[key] == published
                : merge.applicable.fields[key] == nil
            return matches(published, f[4])
                && applied
                && matches(merge.baseline.fields[key], f[6])
                && merge.disputed.contains(key) == (f[7] == "true")
        }
    }

    // MARK: - Helpers

    /// Asks `answer` every case of `rule`, recording each disagreement.
    private func conform(
        _ rule: String,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ answer: ([String]) throws -> Bool
    ) throws {
        try #require(SyncModel.run.problem == nil, sourceLocation: sourceLocation)
        let cases = SyncModel.cases(rule)
        #expect(!cases.isEmpty, "The model printed no \(rule) table", sourceLocation: sourceLocation)
        for fields in cases {
            if try !answer(fields) {
                Issue.record(
                    "Swift disagrees with the model: \(rule) \(fields.joined(separator: " "))",
                    sourceLocation: sourceLocation
                )
            }
        }
    }

    private func name(_ decision: LampSyncMergeDecision) -> String {
        switch decision {
        case .local: "local"
        case .incoming: "incoming"
        case .conflict: "conflict"
        }
    }

    private func quoted(_ tag: String) -> String { "\"\(tag)\"" }

    /// The model's revision spellings: q quoted, b bare, w weak.
    private func spelled(_ field: String) -> String? {
        guard field != "-", let form = field.first else { return nil }
        let tag = String(field.dropFirst())
        return switch form {
        case "q": quoted(tag)
        case "w": "W/" + quoted(tag)
        default: tag
        }
    }
}

/// A server reduced to what the archive index reads: files by path.
private final class InMemoryRemoteStore: LampSyncRemoteStore, @unchecked Sendable {
    var files: [String: Data] = [:]

    func list(directory: String) async throws -> [LampSyncRemoteEntry]? { nil }

    func read(path: String) async throws -> LampSyncRemoteFile? {
        files[path].map { LampSyncRemoteFile(data: $0, revision: "\"r\"") }
    }

    func revision(path: String) async throws -> String? {
        files[path] == nil ? nil : "\"r\""
    }

    func write(_ data: Data, to path: String, condition: LampSyncWriteCondition) async throws -> String? {
        files[path] = data
        return "\"r\""
    }
}
