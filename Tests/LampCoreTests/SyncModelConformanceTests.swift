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
        "decide", "importOutcome", "landing", "tombstone", "tombstoneMerge", "baselessReading",
        "namesSameRevision", "needsImport", "preferenceMerge", "replaceFile", "deckPull",
        "mergeMembership", "chooseWholeValue", "chooseReading", "folderSealAccepts",
        "confirmWrite", "webDAVPresence", "webDAVDirectoryReady",
        "guardedETagCondition", "cancellableRunTrace", "backendTransition",
        "selectedCandidateIndex", "resolvedRecordRevision", "moduleFolderListing", "initialSync",
        "mediaBatchComplete", "macHighlightAllowsPublish", "archiveCaptureChoice",
        "sameColumn", "manifestMerge", "recordWrite", "adoptFile", "pruneTombstone",
        "filePlanAction", "deleteTarget", "listedRevision", "settingsUpdate", "bundlePathHolds", "directoryWrite",
        "directoryDelete", "emptyBundlePath", "versionMerges", "settingsWrite", "versionMerge",
        "preferenceStamp", "bundleRead", "earlierLibrary", "mayClaim", "archiveKeeper", "entryFate",
        "macMigrationStep", "writeOutcome", "passTrace",
        "planMark", "planStamp", "planApply", "planVersionMerge", "planContribution",
    ]

    // MARK: - The model itself

    @Test func theModelChecks() throws {
        let run = SyncModel.run
        if let problem = run.problem { Issue.record("\(problem)"); return }
        #expect(run.status == 0, "Lean rejected the model:\n\(run.lines.prefix(40).joined(separator: "\n"))")
        // A warning — `sorry`, an unused hypothesis gone stale — is something
        // to read, so anything printed besides the tables fails too.
        let other = run.lines.filter { !$0.hasPrefix("CONFORMANCE ") && !$0.hasPrefix("SYSTEMCHECK ") }
        #expect(other.isEmpty, "Lean printed more than its tables:\n\(other.prefix(40).joined(separator: "\n"))")
    }

    /// The per-file system model's checks: every run up to the model's bound,
    /// settled, holds each property. Each line is a check, the runs made and
    /// the runs that failed.
    @Test func filePassesHold() throws {
        let run = SyncModel.run
        if let problem = run.problem { Issue.record("\(problem)"); return }
        let checks = run.lines.filter { $0.hasPrefix("SYSTEMCHECK ") }.map { $0.split(separator: " ").map(String.init) }
        #expect(Set(checks.map { $0[1] }) == ["converges", "quiet", "noLostEdit", "deletionSticks", "neverDeleted"])
        for check in checks {
            #expect(check.count == 4 && (Int(check[2]) ?? 0) > 0 && check[3] == "0", "\(check.joined(separator: " "))")
        }
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

    // MARK: - Plan progress

    @Test func planProgress() throws {
        typealias Mark = LampSyncPlanProgress.Mark
        func time(_ field: String) -> Int64? { Int64(field) }
        func text(_ time: Int64?) -> String { time.map(String.init) ?? "-" }
        // A mark with neither time stands for none at all: a ledger without the key.
        func mark(_ set: String, _ cleared: String) -> Mark? {
            set == "-" && cleared == "-" ? nil : Mark(presentSince: time(set), deletedAt: time(cleared))
        }
        // One plan and one reading, both "x", each with the mark: built from
        // the wire format, so the format is held to the model too.
        func ledger(_ mark: Mark?) throws -> LampSyncPlanProgress {
            struct File: Encodable {
                let formatVersion = LampSyncPlanProgress.formatVersion
                let readings: [String: Mark]
                let selections: [String: Mark]
            }
            let marks = mark.map { ["x": $0] } ?? [:]
            return try LampSyncPlanProgress.decode(JSONEncoder().encode(File(readings: marks, selections: marks)))
        }
        func part(_ code: String) throws -> Data? {
            guard code != "absent" else { return nil }
            let times = code.split(separator: ":").map(String.init)
            return try ledger(mark(times[0], times[1])).encoded()
        }
        func code(_ part: Data?) throws -> String {
            guard let part else { return "absent" }
            let progress = try LampSyncPlanProgress.decode(part)
            let reading = try #require(progress.readings["x"])
            #expect(progress.selections["x"] == reading)
            return text(reading.presentSince) + ":" + text(reading.deletedAt)
        }

        try conform("planMark") { f in
            LampSyncPlanProgress.isSet(Mark(presentSince: time(f[0]), deletedAt: time(f[1]))) == (f[2] == "true")
        }
        try conform("planStamp") { f in
            let now = try #require(Int64(f[0]))
            let set = LampSyncPlanProgress.set(mark(f[1], f[2]), at: now)
            let cleared = LampSyncPlanProgress.cleared(mark(f[1], f[2]), at: now)
            return [text(set.presentSince), text(set.deletedAt), text(cleared.presentSince), text(cleared.deletedAt)]
                == Array(f[3...6])
        }
        try conform("planApply") { f in
            let held = time(f[2])
            let change = switch LampSyncPlanProgress.apply(mark(f[0], f[1]), held: held) {
            case .leave: "leave"
            case .hold(let at): "hold:\(at)"
            case .drop: "drop"
            }
            guard change == f[3] else { return false }
            // And through what the apps call, for a reading and for a plan,
            // which isn't chosen again at a later time.
            let holding = held.map { ["x": $0] } ?? [:]
            let changes = try ledger(mark(f[0], f[1])).changes(toApplyTo: holding, selected: holding)
            let reading = changes.uncomplete.contains("x") ? "drop"
                : changes.complete["x"].map { "hold:\($0)" } ?? "leave"
            let plan = changes.deselect.contains("x") ? "drop" : changes.select.contains("x") ? "select" : "leave"
            let expectedPlan = f[3] == "drop" ? "drop" : f[3].hasPrefix("hold") && held == nil ? "select" : "leave"
            return reading == f[3] && plan == expectedPlan
        }
        try conform("planVersionMerge") { f in
            var merged = LampSyncSettingsBundle(planProgress: try part(f[0]))
            try merged.merge(version: LampSyncSettingsBundle(planProgress: try part(f[1])))
            return try code(merged.planProgress) == f[2]
        }
        try conform("planContribution") { f in
            let own = try part(f[0]).map(LampSyncPlanProgress.decode) ?? LampSyncPlanProgress()
            var bundle = LampSyncSettingsBundle(planProgress: try part(f[1]))
            try LampSyncBundleLedgers.Contribution(personal: LampPersonalDeletionLedger(), planProgress: own)
                .apply(to: &bundle)
            return try code(bundle.planProgress) == f[2]
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

    // MARK: - Files and decks

    @Test func fileOrder() throws {
        try conform("replaceFile") { f in
            let (current, incoming) = (version(f[0]), version(f[1]))
            // The incoming copy lands a fraction of a millisecond later, inside
            // the same bucket, as provider timestamps do.
            return LampSyncMerge.shouldReplaceFile(
                currentData: Data([UInt8(current.bytes)]),
                currentDate: Date(timeIntervalSince1970: TimeInterval(current.tick)),
                incomingData: Data([UInt8(incoming.bytes)]),
                incomingDate: Date(timeIntervalSince1970: TimeInterval(incoming.tick) + 0.0003)
            ) == (f[2] == "true")
        }
    }

    @Test func deckPull() throws {
        func revision(_ field: String) -> LampPresentationDeckRevision {
            let (tick, bytes) = version(field)
            return LampPresentationDeckRevision(
                deck: LampPresentationDeck(id: "deck", title: "Deck", slides: []),
                data: Data([UInt8(bytes)]),
                modifiedAt: Date(timeIntervalSince1970: TimeInterval(tick))
            )
        }
        try conform("deckPull") { f in
            var ledger = LampPresentationDeckDeletionLedger()
            if let deleted = Int(f[0]) {
                ledger.record("deck", at: Date(timeIntervalSince1970: TimeInterval(deleted)))
            }
            let installed = f[1] == "-" ? nil : revision(f[1])
            let incoming = f[2] == "-" ? [] : f[2].split(separator: ",").map { revision(String($0)) }
            let plan = LampPresentationDeckPortablePull.plan(
                incoming: incoming, deletions: ledger, local: installed.map { [$0] } ?? []
            )
            func name(_ revision: LampPresentationDeckRevision) -> String {
                "\(Int(revision.modifiedAt.timeIntervalSince1970)):\(revision.data.first ?? 0)"
            }
            let result: String = if plan.deckIDsToDelete.contains("deck") {
                "-"
            } else if let saved = plan.decksToSave.last(where: { $0.id == "deck" }) {
                name(saved)
            } else {
                installed.map(name) ?? "-"
            }
            return result == f[3]
        }
    }

    // MARK: - Settings planning

    @Test func threeWaySettings() throws {
        try conform("mergeMembership") { f in
            func members(_ field: String) -> Set<Int> { field == "true" ? [1] : [] }
            return LampSyncThreeWaySet.merge(base: members(f[0]), local: members(f[1]), remote: members(f[2]))
                .contains(1) == (f[3] == "true")
        }
        try conform("chooseWholeValue") { f in
            "\(LampSyncThreeWayValue.decide(base: Int(f[0])!, local: Int(f[1])!, remote: Int(f[2])!))" == f[3]
        }
        struct Reading: Equatable { let time: Int; let row: Int }
        try conform("chooseReading") { f in
            let local = Reading(time: Int(f[0])!, row: Int(f[2])!)
            let remote = Reading(time: Int(f[1])!, row: Int(f[3])!)
            do {
                let plan = try LampSyncSettingsPlanner.plan(
                    baseSettings: 0, baseReadingIDs: ["reading"],
                    localSettings: 0, localReadings: ["reading": local],
                    remoteSettings: 0, remoteReadings: ["reading": remote],
                    revision: { $0.time }
                )
                return (plan.readings["reading"] == local ? "local" : "remote") == f[4]
            } catch LampSyncSettingsPlanner.MergeError.concurrentReading {
                return f[4] == "conflict"
            }
        }
    }

    // MARK: - Folders and staged imports

    @Test func folderRecovery() throws {
        func files(_ field: String) -> [Int]? { field == "-" ? nil : field.split(separator: ",").compactMap { Int($0) } }
        try conform("folderSealAccepts") { f in
            LampSyncFolderPublisher.sealAccepts(
                committed: files(f[0])!, pending: files(f[1]), observed: files(f[2])!
            ) == (f[3] == "true")
        }
    }

    // MARK: - Writing to a server

    @Test func confirmingAWrite() async throws {
        try #require(SyncModel.run.problem == nil)
        let cases = SyncModel.cases("confirmWrite")
        #expect(!cases.isEmpty)
        func read(_ field: String) -> LampSyncRemoteFile? {
            guard field != "-" else { return nil }
            let parts = field.split(separator: ":").map(String.init)
            return LampSyncRemoteFile(data: Data([UInt8(parts[0])!]), revision: parts[1] == "-" ? nil : quoted(parts[1]))
        }
        await withTaskGroup(of: (fields: [String], result: String).self) { group in
            for f in cases {
                group.addTask {
                    let store = ScriptedRemoteStore()
                    // The PUT names no revision, so the write is confirmed by
                    // reading it back.
                    store.writeOutcomes["notes/a.lamp"] = .accept(nil)
                    store.scriptedReads = [read(f[0]), read(f[1]), LampSyncRemoteFile(data: Data([5]), revision: "\"9\"")]
                    let revision = try? await LampSyncConditionalWrite.writeAndConfirm(
                        Data([5]), to: "notes/a.lamp", in: store, condition: .unconditional
                    )
                    return (f, revision.map { LampSyncConditionalWrite.token(for: $0) } ?? "-")
                }
            }
            for await (fields, result) in group {
                #expect(result == fields[2], "confirmWrite \(fields.joined(separator: " "))")
            }
        }
    }

    // MARK: - WebDAV

    @Test func webDAVStatuses() throws {
        func answer(_ presence: LampWebDAVStorage.Presence) -> String {
            switch presence {
            case .absent: "false"
            case .present: "true"
            case .askGET, .failed: "-"
            }
        }
        try conform("webDAVPresence") { f in
            // As `exists` asks: HEAD, then GET only when HEAD is refused.
            let afterHEAD = LampWebDAVStorage.presence(afterHEAD: Int(f[0])!)
            let result = afterHEAD == .askGET
                ? answer(LampWebDAVStorage.presence(afterGET: Int(f[1])!)) : answer(afterHEAD)
            return result == f[2]
        }
        try conform("webDAVDirectoryReady") { f in
            let mkcol = Int(f[0])!
            let listing = [LampWebDAVItem(
                path: f[2] == "true" ? "/lamp/notes/" : "/lamp/other/", name: "notes",
                isDirectory: f[3] == "true", etag: nil, lastModified: nil, size: nil
            )]
            // As `createDirectory` asks: PROPFIND only after a 409, and a
            // PROPFIND that fails is no confirmation.
            let existing = mkcol == 409
                ? (LampWebDAVStorage.collectionConfirmed(
                    propfindStatus: Int(f[1])!,
                    listsCollection: { LampWebDAVStorage.listsCollection(listing, at: "lamp/notes") }
                ) ?? false)
                : false
            return LampWebDAVStorage.directoryReady(mkcolStatus: mkcol, existingCollection: existing)
                == (f[4] == "true")
        }
        try conform("guardedETagCondition") { f in
            let bytes = f[0] == "-" ? [] : f[0].split(separator: ".").map { UInt8($0)! }
            return LampWebDAVStorage.isStrongETag(String(decoding: bytes, as: UTF8.self)) == (f[1] == "true")
        }
    }

    // MARK: - Settings archive

    // MARK: - Reading without a precondition

    // MARK: - The pass itself

    @Test func passPhases() async throws {
        try #require(SyncModel.run.problem == nil)
        struct Failure: Error {}
        final class Record: @unchecked Sendable {
            var phases: [Int] = []
            var wiped = false, rolledBack = false, activated = false
        }
        let traces = SyncModel.cases("cancellableRunTrace")
        #expect(!traces.isEmpty)
        for f in traces {
            let flags = f.prefix(5).map { $0 == "true" }
            let record = Record()
            let task = Task {
                if flags[0] { withUnsafeCurrentTask { $0?.cancel() } }
                try await LampSyncEngine.run(
                    pullAndMerge: {
                        record.phases.append(0)
                        if flags[1] { withUnsafeCurrentTask { $0?.cancel() } }
                        if !flags[3] { throw Failure() }
                    },
                    publish: {
                        record.phases.append(1)
                        if flags[2] { withUnsafeCurrentTask { $0?.cancel() } }
                        if !flags[4] { throw Failure() }
                    },
                    complete: { record.phases.append(2) }
                )
            }
            _ = await task.result
            let trace = record.phases.isEmpty ? "-" : record.phases.map(String.init).joined()
            #expect(trace == f[5], "cancellableRunTrace \(f.joined(separator: " "))")
        }
        let transitions = SyncModel.cases("backendTransition")
        #expect(!transitions.isEmpty)
        for f in transitions {
            let flags = f.prefix(5).map { $0 == "true" }
            let record = Record()
            try? await LampSyncBackendTransition.run(
                wipeLocalAfterPublish: flags[3],
                pullAndMerge: { if !flags[0] { throw Failure() } },
                publish: { if !flags[1] { throw Failure() } },
                persistBackend: { () async throws -> Int in
                    if !flags[2] { throw Failure() }
                    return 1
                },
                wipeLocal: {
                    record.wiped = true
                    if !flags[4] { throw Failure() }
                },
                rollbackBackend: { _ in record.rolledBack = true },
                activateBackend: { _ in record.activated = true }
            )
            let observed = ["\(record.wiped)", "\(record.rolledBack)", "\(record.activated)"]
            #expect(observed == Array(f.suffix(3)), "backendTransition \(f.joined(separator: " "))")
        }
    }

    // MARK: - Module files

    @Test func moduleFiles() throws {
        try conform("selectedCandidateIndex") { f in
            // Paths lead with their position, so among two of one format the
            // earlier sorts first, as the model's first occurrence does.
            let candidates = f[1].split(separator: ",").enumerated().map { index, field in
                let parts = field.split(separator: ":").map(String.init)
                return LampSyncModuleFiles.Candidate(
                    identity: parts[0], path: "\(index)-\(parts[0]).\(parts[1])",
                    isSuperseded: parts.count > 2
                )
            }
            let selected = LampSyncModuleFiles.preferredCandidateIndices(candidates)
                .first { candidates[$0].identity == f[0] }
            return (selected.map(String.init) ?? "-") == f[2]
        }
    }

    // MARK: - Records, archive reads and folders

    @Test func resolvedRecordRevision() throws {
        try conform("resolvedRecordRevision") { f in
            LampSyncMerge.resolutionTimestamp(
                localModified: Int(f[0]), incomingModified: Int(f[1]), now: Int(f[2])!
            ) == Int(f[3])
        }
    }

    @Test func moduleFolderListing() async throws {
        try #require(SyncModel.run.problem == nil)
        let cases = SyncModel.cases("moduleFolderListing")
        #expect(!cases.isEmpty)
        for f in cases {
            let store = ScriptedRemoteStore()
            store.listOutcome = switch f[0] {
            case "error": .fail
            case "missing": .missing
            case "-": .entries([])
            default: .entries(f[0].split(separator: ",").enumerated().map { index, code in
                let name = "m\(index)" + (code.last == "s" ? ".lamp" : ".txt")
                return LampSyncRemoteEntry(
                    path: "modules/\(name)", name: name, isDirectory: code.first == "d",
                    revision: nil, modifiedAt: nil, size: nil
                )
            })
            }
            let kept = try? await LampSyncModuleFolder.list(in: store, directory: "modules")
            let shown = kept.map { entries in
                entries.isEmpty ? "-" : entries.map {
                    ($0.isDirectory ? "d" : "f") + ($0.name.hasSuffix(".lamp") ? "s" : "u")
                }.joined(separator: ",")
            } ?? "error"
            #expect(shown == f[1], "moduleFolderListing \(f.joined(separator: " "))")
        }
    }

    // MARK: - Gates and batches

    @Test func initialSyncGate() async throws {
        try #require(SyncModel.run.problem == nil)
        struct Failure: Error {}
        final class Ran: @unchecked Sendable { var succeeded = false, invoked = false }
        let cases = SyncModel.cases("initialSync")
        #expect(!cases.isEmpty)
        for f in cases {
            let once = LampSyncOnce()
            let ran = Ran()
            for earlier in f[0] == "-" ? [] : Array(f[0]) {
                try? await once.run {
                    guard earlier == "t" else { throw Failure() }
                    ran.succeeded = true
                }
            }
            let (succeeded, cancelled) = (f[1] == "true", f[2] == "true")
            // The caller is cancelled while it waits: during the attempt, or
            // before asking, when a run that already succeeded leaves nothing
            // to wait for.
            let alreadyRan = ran.succeeded
            let final = Task {
                if cancelled && alreadyRan { withUnsafeCurrentTask { $0?.cancel() } }
                try await once.run {
                    if cancelled { withUnsafeCurrentTask { $0?.cancel() } }
                    if !succeeded { throw Failure() }
                }
            }
            let continued = (try? await final.value) != nil
            let probe = Ran()
            try? await once.run { probe.invoked = true }
            #expect(["\(!probe.invoked)", "\(continued)"] == Array(f.suffix(2)), "initialSync \(f.joined(separator: " "))")
        }
    }

    @Test func mediaBatches() async throws {
        try #require(SyncModel.run.problem == nil)
        struct Failure: Error {}
        let outcomes = { (field: String) in field == "-" ? [] : field.map { $0 == "t" } }
        let batches = SyncModel.cases("mediaBatchComplete")
        #expect(!batches.isEmpty)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-batches-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        for (row, f) in batches.enumerated() {
            let results = outcomes(f[0])
            let items = results.indices.map {
                LampSyncReferencedMedia.Item(
                    remotePath: "\($0)", localURL: folder.appendingPathComponent("\(row)/\($0)")
                )
            }
            let uploaded = (try? await LampSyncReferencedMedia.uploadAll(
                items, readLocal: { _ in Data([1]) },
                publish: { path, _ in if !results[Int(path)!] { throw Failure() } }
            )) != nil
            let downloaded = (try? await LampSyncReferencedMedia.downloadMissing(
                items, readRemote: { path in
                    guard results[Int(path)!] else { throw Failure() }
                    return Data([1])
                }
            )) != nil
            #expect([uploaded, downloaded] == [f[1] == "true", f[1] == "true"], "mediaBatchComplete \(f.joined(separator: " "))")
        }
    }

    @Test func highlightExportGatesThePublish() async throws {
        try #require(SyncModel.run.problem == nil)
        struct Failure: Error {}
        let cases = SyncModel.cases("macHighlightAllowsPublish")
        #expect(cases.count == 3)
        for f in cases {
            // No highlights is a nil export, not a failure, so `try?` cannot tell them apart.
            var allowed = true
            do {
                _ = try await LampSyncPersonalExport.highlightsIfPresent { () async throws -> Int in
                    switch f[0] {
                    case "ready": return 1
                    case "empty": throw LampLibraryError.noPersonalHighlights(translationID: "kjv")
                    default: throw Failure()
                    }
                }
            } catch {
                allowed = false
            }
            #expect(allowed == (f[1] == "true"), "macHighlightAllowsPublish \(f.joined(separator: " "))")
        }
    }

    // MARK: - Capturing the library

    @Test func archiveCapture() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("archive-capture-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside")
        try Data([1]).write(to: outside)
        var row = 0
        try conform("archiveCaptureChoice") { f in
            row += 1
            let library = root.appendingPathComponent("library-\(row)")
            let folder = library.appendingPathComponent(
                f[0] == "true" ? LampPortableBackupLayout.mediaDirectory : "notes"
            )
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(f[1] == "true" ? ".attachment" : "attachment")
            if f[2] == "true" {
                try fileManager.createSymbolicLink(at: file, withDestinationURL: outside)
            } else {
                try Data([2]).write(to: file)
            }
            let choice: String
            do {
                choice = try LampSyncArchive.create(from: library).entries.isEmpty ? "skip" : "include"
            } catch LampSyncArchive.ArchiveError.unsafePath {
                choice = "reject"
            }
            return choice == f[3]
        }
    }

    @Test func storedValueComparison() throws {
        // Each side spells its value differently, so only the meaning can match.
        func stored(_ field: String, side: Int) -> String? {
            let parts = field.split(separator: ":").map(String.init)
            switch parts[0] {
            case "nothing": return side == 0 ? nil : " null "
            case "json": return side == 0 ? #"{"v":\#(parts[1]),"w":0}"# : #"{ "w" : 0, "v" : \#(parts[1]) }"#
            default: return "text \(parts[1])"
            }
        }
        try conform("sameColumn") { f in
            LampSyncJSONComparison.sameValue(stored(f[0], side: 0), stored(f[1], side: 1)) == (f[2] == "true")
        }
    }

    // MARK: - The per-file library

    /// A model manifest entry, "presentSince:revision:deletedAt:deletedRevision".
    private func manifestEntry(_ field: String, at path: String) -> LampSyncLibraryManifest.Entry {
        let parts = field.split(separator: ":").map(String.init)
        var entry = LampSyncLibraryManifest.Entry(path: path)
        entry.presentSince = Int64(parts[0])
        entry.revision = parts[1] == "-" ? nil : quoted(parts[1])
        entry.deletedAt = Int64(parts[2])
        entry.deletedRevision = parts[3] == "-" ? nil : quoted(parts[3])
        return entry
    }

    private func entryCode(_ entry: LampSyncLibraryManifest.Entry?) -> String {
        guard let entry else { return "-" }
        func revision(_ value: String?) -> String { value.map(LampSyncConditionalWrite.token(for:)) ?? "-" }
        return [entry.presentSince.map(String.init) ?? "-", revision(entry.revision),
                entry.deletedAt.map(String.init) ?? "-", revision(entry.deletedRevision)]
            .joined(separator: ":")
    }

    private func manifest(holding field: String, at path: String) -> LampSyncLibraryManifest {
        var manifest = LampSyncLibraryManifest()
        if field != "-" { manifest.entries[path] = manifestEntry(field, at: path) }
        return manifest
    }

    @Test func manifestStamps() throws {
        let path = "Notes/notes.lamp"
        try conform("manifestMerge") { f in
            let merged = manifest(holding: f[0], at: path).merged(with: manifest(holding: f[1], at: path))
            return entryCode(merged.entry(at: path)) == f[2] && merged.entry(at: path)?.isMember == (f[3] == "true")
        }
        try conform("recordWrite") { f in
            let recorded = try manifest(holding: f[0], at: path).recordingWrite(
                path, revision: quoted("4"), replacing: f[1] == "-" ? nil : quoted(f[1]), at: Int64(f[2])!
            )
            return entryCode(recorded.entry(at: path)) == f[3]
        }
        try conform("adoptFile") { f in
            let adopted = try manifest(holding: f[0], at: path).adopting(
                path, revision: quoted(f[1]), at: Int64(f[2])!
            )
            return entryCode(adopted.entry(at: path)) == f[3]
        }
        try conform("pruneTombstone") { f in
            let entry = manifestEntry(f[0], at: f[2] == "true" ? path : "DevotionalMedia/m/w/a.png")
            return LampSyncLibraryManifest.prunes(entry, now: Int64(f[1])!, present: f[3] == "true")
                == (f[4] == "true")
        }
    }

    @Test func filePlanAction() throws {
        // One real path of each class, deletable by a library or not.
        let paths = [
            "media:true": try LampSyncFolderLayout.deckAssetPath(filename: "a.png"),
            "media:false": "DevotionalMedia/m/w/a.png",
            "listed:true": try LampSyncFolderLayout.modulePath(kind: .translations, moduleID: "kjv"),
            "listed:false": "Notes/notes.lamp",
            "unlisted:false": "Workspaces/a.md",
        ]
        for (key, path) in paths {
            #expect(LampSyncLocalDeletion.target(of: path).isAllowed == key.hasSuffix(":true"), "\(path)")
        }
        func held(_ field: String, at path: String) -> [LampSyncFilePlan.Local] {
            guard field != "-" else { return [] }
            let parts = field.split(separator: ":").map(String.init)
            return [LampSyncFilePlan.Local(
                path: path, changedSinceUpload: parts[0] == "true",
                lastRevision: parts[1] == "-" ? nil : quoted(parts[1]), savedAt: Int64(parts[2])
            )]
        }
        func code(_ plan: LampSyncFilePlan.Plan, at path: String) -> String {
            func token(_ revision: String) -> String { LampSyncConditionalWrite.token(for: revision) }
            var tokens: [String] = []
            if plan.downloads.contains(path) { tokens.append("download") }
            if let revision = plan.merge[path] { tokens.append("merge:\(token(revision))") }
            switch plan.uploads[path] {
            case .ifAbsent: tokens.append("upload:ifAbsent")
            case .ifRevision(let revision): tokens.append("upload:ifRevision:\(token(revision))")
            case .unconditional: tokens.append("upload:unconditional")
            case nil: break
            }
            if plan.deleteLocally.contains(path) { tokens.append("deleteLocally") }
            if let revision = plan.adopt[path] { tokens.append("adopt:\(token(revision))") }
            if let time = plan.tombstone[path] { tokens.append("tombstone:\(time)") }
            if let revision = plan.reap[path] { tokens.append("reap:\(token(revision))") }
            if let time = plan.supersede[path] { tokens.append("supersede:\(time)") }
            return tokens.isEmpty ? "-" : tokens.joined(separator: ",")
        }
        try conform("filePlanAction") { f in
            let path = paths["\(f[0]):\(f[1])"]!
            let plan = LampSyncFilePlan.plan(
                manifest: manifest(holding: f[2], at: path),
                local: held(f[3], at: path),
                deletedLocally: f[4] == "-" ? [:] : [path: Int64(f[4])!],
                listing: f[5] == "-" ? [:] : [path: quoted(f[5])]
            )
            return code(plan, at: path) == f[6]
        }
    }

    /// Every path of a kind, as each client deletes it: a module names its
    /// own ID, and the two collections, whatever folder they share, are
    /// refused while any other module in that folder is not.
    @Test func deleteTarget() throws {
        let paths: [String: [String]] = [
            "module": [
                try LampSyncFolderLayout.modulePath(kind: .translations, moduleID: "kjv"),
                try LampSyncFolderLayout.modulePath(kind: .notes, moduleID: "grandads-notes"),
                try LampSyncFolderLayout.modulePath(kind: .devotionals, moduleID: "sermons"),
                try LampSyncFolderLayout.modulePath(kind: .highlights, moduleID: "set-1"),
            ],
            "collection": [
                try LampSyncFolderLayout.modulePath(kind: .notes, moduleID: LampSyncLocalDeletion.notesCollectionID),
                try LampSyncFolderLayout.modulePath(kind: .devotionals, moduleID: LampSyncLocalDeletion.writingCollectionID),
            ],
            "deck": [try LampSyncFolderLayout.deckPath(deckID: "easter")],
            "deckAsset": [try LampSyncFolderLayout.deckAssetPath(filename: "a.png")],
            "media": [
                try LampSyncFolderLayout.devotionalMediaPath(moduleID: "m", devotionalID: "w", filename: "a.png"),
                try LampSyncFolderLayout.bookMediaPath(moduleID: "b", path: "plates/a.png"),
            ],
            "workspaceFile": ["Workspaces/a.md"],
            "outside": ["Elsewhere/a.txt"],
        ]
        func name(_ target: LampSyncLocalDeletion, at path: String) -> String {
            switch target {
            case .module(let id):
                return id == LampSyncFolderLayout.remoteModuleID(of: path) ? "module:own" : "module:other"
            case .deck: return "deck"
            case .deckAsset: return "deckAsset"
            case .collection: return "collection"
            case .unsupported: return "unsupported"
            }
        }
        try conform("deleteTarget") { f in
            let examples = try #require(paths[f[0]])
            return examples.allSatisfy { path in
                let target = LampSyncLocalDeletion.target(of: path)
                return name(target, at: path) == f[1] && String(target.isAllowed) == f[2]
            }
        }
    }

    @Test func listedRevision() async throws {
        let cases = SyncModel.cases("listedRevision")
        #expect(!cases.isEmpty)
        let path = "Notes/notes.lamp"
        for f in cases {
            let store = ListingStore()
            store.items = [LampSyncRemoteEntry(
                path: "/dav/\(path)", name: "notes.lamp", isDirectory: false,
                revision: f[0] == "-" ? nil : quoted(f[0]), modifiedAt: nil, size: nil
            )]
            store.stored = f[2] == "-" ? nil : quoted(f[2])
            let state: String = switch f[1] {
            case "member:2": "1:2:-:-"
            case "member:-": "1:-:-:-"
            case "tombstone:2": "1:2:5:-"
            default: "-"
            }
            let listing = try await LampSyncFilePlan.listing(in: store, manifest: manifest(holding: state, at: path))
            let revision = listing[path].map(LampSyncConditionalWrite.token(for:)) ?? "-"
            #expect(revision == f[3] && store.asked == (f[4] == "true"), "listedRevision \(f.joined(separator: " "))")
        }
    }

    /// Through the engine itself: for each combination of work, a pass over a
    /// library holding exactly that work, with every step it takes written to
    /// one log, in the order it took them.
    @Test func passTrace() async throws {
        let cases = SyncModel.cases("passTrace")
        #expect(!cases.isEmpty)
        for f in cases {
            let flags = f[0..<6].map { $0 == "true" }
            let observed = try await passSteps(
                download: flags[0], merge: flags[1], uploadMedia: flags[2],
                uploadModule: flags[3], deleteLocally: flags[4], reap: flags[5]
            )
            #expect(observed == f[6], "passTrace \(f.joined(separator: " "))")
        }
    }

    /// One pass over a library holding exactly the work asked for, one file
    /// per kind, and the steps it took, in order.
    private func passSteps(
        download: Bool, merge: Bool, uploadMedia: Bool,
        uploadModule: Bool, deleteLocally: Bool, reap: Bool
    ) async throws -> String {
        let log = PassLog()
        let store = PassOrderStore(log: log)
        let source = LampSyncFileRecords.webDAVSource(URL(string: "https://dav.example.com/sync/")!)
        var manifest = LampSyncLibraryManifest()
        var records = LampSyncFileRecords()
        var gathered = LampSyncBundlePass.Gathered()
        var scratch: [URL] = []
        defer { for url in scratch { try? FileManager.default.removeItem(at: url) } }
        func file(_ text: String) throws -> URL {
            let url = LampSyncScratchFile.url()
            try Data(text.utf8).write(to: url)
            scratch.append(url)
            return url
        }
        func hold(_ path: String, _ text: String) throws {
            gathered.local.append(LampSyncLocalFile(
                path: path, kind: try #require(LampSyncFolderLayout.kind(of: path)), url: try file(text),
                digest: LampSyncContentRevision.digest(for: Data(text.utf8))
            ))
        }
        func onServer(_ path: String, _ revision: String) {
            store.bodies[path] = Data("server \(path)".utf8)
            store.revisions[path] = quoted(revision)
        }
        func member(_ path: String, _ revision: String) throws {
            manifest = try manifest.recordingWrite(path, revision: quoted(revision), replacing: nil, at: 1_000)
        }
        func uploaded(_ path: String, _ text: String, _ revision: String) {
            records.recordUpload(
                path, in: source, digest: LampSyncContentRevision.digest(for: Data(text.utf8)),
                revision: quoted(revision)
            )
            records.confirmRecorded([path: quoted(revision)], in: source)
        }
        if download {
            try member("Translations/kjv.lamp", "k1")
            onServer("Translations/kjv.lamp", "k1")
        }
        if merge {
            try member("Notes/notes.lamp", "n1")
            onServer("Notes/notes.lamp", "n2")
            try hold("Notes/notes.lamp", "mine")
            uploaded("Notes/notes.lamp", "before", "n1")
        }
        if uploadMedia {
            try hold("DevotionalMedia/w/d/a.png", "png")
        }
        if uploadModule {
            try member("Commentaries/c1.lamp", "c1")
            onServer("Commentaries/c1.lamp", "c1")
            try hold("Commentaries/c1.lamp", "edited")
            uploaded("Commentaries/c1.lamp", "before", "c1")
        }
        if deleteLocally {
            try member("Dictionaries/d1.lamp", "d1")
            manifest = try manifest.removing("Dictionaries/d1.lamp", at: 2_000, revision: quoted("d1"))
            try hold("Dictionaries/d1.lamp", "dictionary")
            uploaded("Dictionaries/d1.lamp", "dictionary", "d1")
        }
        if reap {
            try member("Plans/p1.lamp", "p1")
            onServer("Plans/p1.lamp", "p1")
            gathered.deletedLocally["Plans/p1.lamp"] = 2_500
        }
        var bundle = LampSyncSettingsBundle()
        bundle.manifest = manifest
        store.bodies[LampSyncSettingsStore.path] = try bundle.encoded()
        store.revisions[LampSyncSettingsStore.path] = quoted("b1")
        let merged = try file("merged")
        let library = PassOrderLibrary(log: log, merged: merged)
        let held = gathered
        _ = try await LampSyncBundlePass(store: store, library: library, source: source, now: { 3_000 }).run(
            gathering: { log.events.append("gather"); return held },
            records: &records, patience: .immediate,
            receiving: { _ in log.events.append("receive") }
        )
        return log.steps()
    }

    /// Through `LampSyncConditionalWrite.write` over a server that names no
    /// revision on PUT, as the user's Synology does, so every revision comes
    /// from a read-back.
    @Test func writeOutcome() async throws {
        let cases = SyncModel.cases("writeOutcome")
        #expect(!cases.isEmpty)
        for f in cases {
            let readBacks: [String] = f[1] == "empty" ? [] : f[1].split(separator: ",").map(String.init)
            let store = ScriptedRemoteStore()
            store.writeOutcomeSequence = [f[0] == "true" ? .accept(nil) : .refuse]
            store.scriptedReads = readBacks.map { code in
                guard code != "-" else { return nil }
                let parts = code.split(separator: ":").map(String.init)
                return LampSyncRemoteFile(data: Data(parts[0].utf8), revision: quoted(parts[1]))
            }
            let outcome = try await LampSyncConditionalWrite.write(
                Data("1".utf8), to: "Notes/notes.lamp", in: store, condition: .ifAbsent,
                patience: .init(confirm: Array(repeating: .zero, count: readBacks.count), retry: [])
            )
            let name: String = switch outcome {
            case .written(let revision): "written:" + LampSyncConditionalWrite.token(for: revision)
            case .writtenUnconfirmed: "writtenUnconfirmed"
            case .refused: "refused"
            }
            #expect(name == f[2], "writeOutcome \(f.joined(separator: " "))")
        }
    }

    @Test func settingsUpdate() async throws {
        let cases = SyncModel.cases("settingsUpdate")
        #expect(!cases.isEmpty)
        for f in cases {
            let store = ScriptedRemoteStore()
            store.files[LampSyncSettingsStore.path] = LampSyncRemoteFile(
                data: try LampSyncSettingsBundle().encoded(), revision: "\"1\""
            )
            let refusals = f[1] == "-" ? [] : f[1].map { $0 == "t" }
            store.writeOutcomeSequence = refusals.map { $0 ? .refuse : .accept("\"2\"") }
            let written: String
            do {
                try await LampSyncSettingsStore.update(in: store, attempts: Int(f[0])!, patience: .immediate) {
                    $0.userSettings = Data("changed".utf8)
                }
                written = String(store.writeLog.count)
            } catch LampSyncSettingsStore.StoreError.tooManyAttempts {
                written = "-"
            }
            #expect(written == f[2], "settingsUpdate \(f.joined(separator: " "))")
        }
    }

    /// The first bytes of a body with the model's header.
    private func header(_ field: String) -> Data {
        let header: String = switch field {
        case "entriesFirst": #"{"entries":[{"path":"manifest.json""#
        case "garbage": "PK\u{3}\u{4}"
        default: #"{"formatVersion":\#(field.dropFirst("version:".count)),"entries":["#
        }
        return Data(header.utf8)
    }

    @Test func bundlePathHolds() throws {
        try conform("bundlePathHolds") { f in
            let expected: LampSyncSettingsBundle.Contents = switch f[1] {
            case "bundle": .bundle
            case "archive": .archive
            case "damaged": .damaged
            default: .newerBundle(Int(f[1].dropFirst("newer:".count))!)
            }
            return LampSyncSettingsBundle.contents(ofHeader: header(f[0])) == expected
        }
        try conform("versionMerges") { f in
            LampSyncSettingsStore.versionMerges(LampSyncSettingsBundle.contents(ofHeader: header(f[0])))
                == (f[1] == "true")
        }
    }

    /// Through the whole read, over a real folder: an earlier sync's marker
    /// or a module file, with nothing at the bundle path.
    @Test func emptyBundlePath() async throws {
        let cases = SyncModel.cases("emptyBundlePath")
        #expect(!cases.isEmpty)
        for f in cases {
            let read = try await readFolder(bundle: false, marker: f[0] == "true", content: f[1] == "true")
            #expect((read == "notMigrated") == (f[2] == "true"), "emptyBundlePath \(f.joined(separator: " "))")
        }
    }

    /// A library with a bundle reads it, whatever else is there.
    @Test func bundleRead() async throws {
        let cases = SyncModel.cases("bundleRead")
        #expect(!cases.isEmpty)
        for f in cases {
            let read = try await readFolder(bundle: f[0] == "true", marker: f[1] == "true", content: f[2] == "true")
            #expect(read == f[3], "bundleRead \(f.joined(separator: " "))")
        }
    }

    /// Who kept a real folder: the Mac's seal, the phone's settings folder,
    /// a module file.
    @Test func earlierLibrary() async throws {
        let cases = SyncModel.cases("earlierLibrary")
        #expect(!cases.isEmpty)
        for f in cases {
            let root = try folder(mac: f[0] == "true", phone: f[1] == "true", content: f[2] == "true")
            defer { try? FileManager.default.removeItem(at: root) }
            let earlier = try await LampSyncSettingsStore.earlierLibrary(in: LampSyncDirectoryStore(root: root))
            #expect(earlier.map { "\($0)" } ?? "-" == f[3], "earlierLibrary \(f.joined(separator: " "))")
        }
    }

    /// Through the two ways a pass starts: `readOrClaim`, and
    /// `migratePhoneLibrary` once the person has agreed.
    @Test func mayClaim() async throws {
        let cases = SyncModel.cases("mayClaim")
        #expect(!cases.isEmpty)
        for f in cases {
            let root = try folder(mac: f[1] == "mac", phone: f[1] == "phone", content: f[1] != "-")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = LampSyncDirectoryStore(root: root)
            let claimed: Bool
            do {
                _ = f[0] == "true"
                    ? try await LampSyncSettingsStore.migratePhoneLibrary(in: store, patience: .immediate)
                    : try await LampSyncSettingsStore.readOrClaim(from: store, patience: .immediate)
                claimed = true
            } catch LampSyncSettingsStore.StoreError.notMigrated(nil) {
                claimed = false
            }
            let written = FileManager.default.fileExists(
                atPath: root.appendingPathComponent(LampSyncSettingsStore.path).path
            )
            #expect(claimed == (f[2] == "true") && written == claimed, "mayClaim \(f.joined(separator: " "))")
        }
    }

    /// Through `earlierLibrary(in:)` over a real archive at the bundle path:
    /// one starting with a module is judged from its first entry, the rest
    /// unpacked.
    @Test func archiveKeeper() async throws {
        let paths: [String: String] = [
            "phoneSettings": LampSyncSettingsArchive.path,
            "legacyManifest": LampSyncSettingsArchive.legacyManifestPath,
            "preferences": LampPortableBackupLayout.sharedPreferencesPath,
            "portableManifest": LampPortableBackupLayout.manifestPath,
            "macSettings": LampPortableBackupLayout.settingsPath,
            "module": "Modules/kjv.lamp",
        ]
        let cases = SyncModel.cases("archiveKeeper")
        #expect(!cases.isEmpty)
        for f in cases {
            let entries = (f[0] == "-" ? [] : f[0].split(separator: ",")).map { name in
                let data = Data(name.utf8)
                return LampSyncArchive.Entry(
                    path: paths[String(name)]!, data: data, modifiedAt: Date(timeIntervalSince1970: 0),
                    sha256: LampSyncContentRevision.digest(for: data)
                )
            }.sorted { $0.path < $1.path }
            let store = ScriptedRemoteStore()
            store.files[LampSyncSettingsStore.path] = LampSyncRemoteFile(
                data: try LampSyncArchive(entries: entries).compressedData(), revision: "\"a\""
            )
            let keeper = try await LampSyncSettingsStore.earlierLibrary(in: store)
            #expect(keeper.map { "\($0)" } == f[1], "archiveKeeper \(f.joined(separator: " "))")
        }
    }

    /// A path of each kind an archive or folder tree can hold.
    @Test func entryFate() throws {
        let paths: [String: [String]] = [
            "macSettings": ["settings.plist"],
            "phoneSettings": ["UserData/user-settings.db"],
            "preferences": ["Settings/shared-preferences.json"],
            "personalLedger": ["Deletions/ledger.json"],
            "deckLedger": ["Workspaces/Presentations/deleted-decks.json"],
            "legacyManifest": ["Settings/legacy-ios-settings.json"],
            "compatibilityManifest": ["Compatibility/manifest.json"],
            "portableManifest": ["manifest.json"],
            "seal": ["lamp-sync-snapshot.json"],
            "archiveIndex": ["lamp-bible.lampsync.index.json"],
            "hidden": ["Media/.DS_Store", ".DS_Store", "Translations/.kjv.lamp.icloud"],
            "retiredAlias": ["Notes/bible-notes.lamp"],
            "portableModule": ["Modules/9f86d081884c7d65.lamp"],
            "study": ["Study/Notes/john.json", "Study/Highlights/set.json"],
            "writingDocument": ["Devotionals/daily.json"],
            "media": ["Media/Devotionals/daily/a.png"],
            "workspaceFile": ["Workspaces/Presentations/easter.lampdeck", "Workspaces/sermon/notes.md"],
            "compatibleModule": ["Compatibility/Notes/notes.lamp"],
            "perFile": ["Translations/kjv.lamp", "Devotionals/daily.lamp", "DevotionalMedia/w/d/a.png"],
            "unknown": ["Backups/old.zip", "Devotionals/daily.md", "UserData/other.db", "notes.txt"],
        ]
        try conform("entryFate") { f in
            try #require(paths[f[0]]).allSatisfy { "\(LampSyncLibraryMigration.fate(of: $0))" == f[1] }
        }
    }

    @Test func macMigrationStep() throws {
        try conform("macMigrationStep") { f in
            let keeper: LampSyncSettingsStore.EarlierLibrary? = switch f[3] {
            case "mac": .mac
            case "phone": .phone
            default: nil
            }
            let step = LampSyncLibraryMigration.step(
                bundlePresent: f[0] == "true", imported: f[1] == "-" ? nil : quoted(f[1]),
                current: f[2] == "-" ? nil : quoted(f[2]), keeper: keeper
            )
            let name: String = switch step {
            case .alreadyMigrated: "alreadyMigrated"
            case .write(.ifAbsent): "write:ifAbsent"
            case .write(.ifRevision(let revision)): "write:ifRevision:" + LampSyncConditionalWrite.token(for: revision)
            case .write(.unconditional): "write:unconditional"
            case .importAgain: "importAgain"
            case .notTheMacs: "notTheMacs"
            }
            return name == f[4]
        }
    }

    /// A real folder with the Mac's seal, the phone's settings folder and a
    /// module file, as asked. The caller removes it.
    private func folder(mac: Bool, phone: Bool, content: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-earlier-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Notes"), withIntermediateDirectories: true
        )
        if mac {
            try Data("{}".utf8).write(to: root.appendingPathComponent(LampSyncFolderPublisher.snapshotPath))
        }
        if phone {
            let settings = root.appendingPathComponent(LampSyncLayout.userSettingsPath)
            try FileManager.default.createDirectory(
                at: settings.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("settings".utf8).write(to: settings)
        }
        if content {
            try Data("notes".utf8).write(to: root.appendingPathComponent("Notes/notes.lamp"))
        }
        return root
    }

    /// What `read` makes of a real folder holding a bundle, an earlier
    /// sync's marker and a module file, as asked.
    private func readFolder(bundle: Bool, marker: Bool, content: Bool) async throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-bundle-read-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Notes"), withIntermediateDirectories: true
        )
        if bundle {
            try LampSyncSettingsBundle().encoded().write(to: root.appendingPathComponent(LampSyncSettingsStore.path))
        }
        if marker {
            try Data("{}".utf8).write(to: root.appendingPathComponent(LampSyncFolderPublisher.snapshotPath))
        }
        if content {
            try Data("notes".utf8).write(to: root.appendingPathComponent("Notes/notes.lamp"))
        }
        do {
            return try await LampSyncSettingsStore.read(from: LampSyncDirectoryStore(root: root)) == nil
                ? "fresh" : "bundle"
        } catch LampSyncSettingsStore.StoreError.notMigrated(nil) {
            return "notMigrated"
        }
    }

    @Test func settingsWrite() throws {
        try conform("settingsWrite") { f in
            let write = LampSyncSettingsStore.write(
                current: f[0] == "true", versions: f[1] == "true", merges: f[2] == "true", changed: f[3] == "true"
            )
            return "\(write)" == f[4]
        }
    }

    /// Through the three-way merge: a local edit over the field the device
    /// last agreed on, or over nothing.
    @Test func preferenceStamp() throws {
        let key = "plans.reminder.hour"
        try conform("preferenceStamp") { f in
            let base = f[1] == "-" ? nil : LampSharedPreferenceLedger(fields: [
                key: .init(value: .integer(1), modifiedAt: Int64(f[1]))
            ])
            let merge = try LampSharedPreferenceLedger.merge(
                local: [key: .integer(2)], base: base, remote: base, now: Int64(f[0])!
            )
            return merge.publishable.fields[key]?.modifiedAt == Int64(f[2])
        }
    }

    /// Through `merge(version:)` on real bundles: a manifest entry, a shared
    /// preference field, and the app's own settings.
    @Test func versionMerge() throws {
        let path = "Notes/notes.lamp"
        let key = "reader.fontSize"
        func revision(_ n: String) -> String { "00000000-0000-0000-0000-" + String(repeating: "0", count: 12 - n.count) + n }
        func copy(_ stamp: String, _ entry: String, _ own: String) -> LampSyncSettingsBundle {
            let parts = stamp.split(separator: ":").map(String.init)
            let field = LampSharedPreferenceLedger.Field(
                value: .number(Double((Int(parts[0]) ?? 0) * 10 + Int(parts[1])!)),
                revision: revision(parts[1]), modifiedAt: Int64(parts[0])
            )
            return LampSyncSettingsBundle(
                userSettings: Data(own.utf8),
                preferences: LampSharedPreferenceLedger(fields: [key: field]),
                manifest: manifest(holding: entry, at: path)
            )
        }
        try conform("versionMerge") { f in
            var merged = copy(f[0], f[1], f[2])
            try merged.merge(version: copy(f[3], f[4], f[5]))
            let field = try #require(merged.preferences.fields[key])
            let stamp = "\(field.modifiedAt.map(String.init) ?? "-"):\(Int(field.revision.suffix(12))!)"
            return stamp == f[6] && entryCode(merged.manifest.entry(at: path)) == f[7]
                && merged.userSettings == Data(f[8].utf8)
        }
    }

    @Test func directoryWritesAndDeletes() throws {
        func ask(_ f: [String], _ decide: (LampSyncWriteCondition, Bool, () throws -> String, Bool, Bool) throws
            -> LampSyncDirectoryStore.Outcome) throws -> Bool {
            let condition: LampSyncWriteCondition = switch f[0] {
            case "unconditional": .unconditional
            case "ifAbsent": .ifAbsent
            default: .ifRevision(quoted(String(f[0].dropFirst("ifRevision:".count))))
            }
            let outcome = try decide(
                condition, f[1] != "-", { LampSyncDirectoryStore.revision(forDigest: f[1]) },
                f[2] == "true", f[3] == "true"
            )
            return "\(outcome)" == f[4]
        }
        try conform("directoryWrite") { f in
            try ask(f) {
                try LampSyncDirectoryStore.writeOutcome(
                    condition: $0, exists: $1, currentRevision: $2, placeholderVisible: $3, unresolved: $4
                )
            }
        }
        try conform("directoryDelete") { f in
            try ask(f) {
                try LampSyncDirectoryStore.deleteOutcome(
                    condition: $0, exists: $1, currentRevision: $2, placeholderVisible: $3, unresolved: $4
                )
            }
        }
    }

    // MARK: - Helpers

    /// A model file version, "tick:bytes".
    private func version(_ field: String) -> (tick: Int, bytes: Int) {
        let parts = field.split(separator: ":").compactMap { Int($0) }
        return (parts[0], parts[1])
    }

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

/// A server whose writes and reads are scripted per test: a write may be
/// accepted (with or without a revision), refused on its precondition, or
/// fail outright; reads may be answered from a queue to stand for a server
/// still settling a write. The third scripted read is never reached by a
/// rule that asks twice.
private final class ScriptedRemoteStore: LampSyncRemoteStore, @unchecked Sendable {
    enum WriteOutcome { case accept(String?), refuse, fail }
    enum ListOutcome { case fail, missing, entries([LampSyncRemoteEntry]) }

    var files: [String: LampSyncRemoteFile] = [:]
    var writeOutcomes: [String: WriteOutcome] = [:]
    /// Outcomes for successive writes to any path, ahead of `writeOutcomes`.
    var writeOutcomeSequence: [WriteOutcome] = []
    var scriptedReads: [LampSyncRemoteFile?]?
    var listOutcome = ListOutcome.missing
    private(set) var readCount = 0
    private(set) var writeLog: [String] = []

    func list(directory: String) async throws -> [LampSyncRemoteEntry]? {
        switch listOutcome {
        case .fail: throw URLError(.notConnectedToInternet)
        case .missing: return nil
        case .entries(let entries): return entries
        }
    }

    func read(path: String) async throws -> LampSyncRemoteFile? {
        readCount += 1
        if var queue = scriptedReads {
            let next = queue.isEmpty ? nil : queue.removeFirst()
            scriptedReads = queue
            return next
        }
        return files[path]
    }

    func revision(path: String) async throws -> String? { files[path]?.revision }

    func write(_ data: Data, to path: String, condition: LampSyncWriteCondition) async throws -> String? {
        writeLog.append(path)
        let outcome = writeOutcomeSequence.isEmpty ? writeOutcomes[path] : writeOutcomeSequence.removeFirst()
        switch outcome ?? .accept("\"w\"") {
        case .accept(let revision):
            files[path] = LampSyncRemoteFile(data: data, revision: revision)
            return revision
        case .refuse:
            throw LampSyncConditionalWrite.WriteError.conflict
        case .fail:
            throw URLError(.notConnectedToInternet)
        }
    }
}

/// One listed folder holding one file, which counts the revisions it is asked for.
private final class ListingStore: LampSyncRemoteStore, @unchecked Sendable {
    var items: [LampSyncRemoteEntry] = []
    var stored: String?
    private(set) var asked = false

    func list(directory: String) async throws -> [LampSyncRemoteEntry]? {
        directory == "Notes/" ? items : nil
    }

    func read(path: String) async throws -> LampSyncRemoteFile? { nil }

    func revision(path: String) async throws -> String? {
        asked = true
        return stored
    }

    func write(_ data: Data, to path: String, condition: LampSyncWriteCondition) async throws -> String? { nil }
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

/// One timeline for a pass: the store's requests and the library's calls,
/// in the order they happened.
private final class PassLog: @unchecked Sendable {
    var events: [String] = []

    /// The steps the events amount to, in the model's names.
    func steps() -> String {
        var steps: [String] = []
        var claimed = false
        for event in events {
            let parts = event.split(separator: " ", maxSplits: 1).map(String.init)
            let path = parts.count > 1 ? parts[1] : ""
            let step: String? = switch parts[0] {
            case "read" where path == LampSyncSettingsStore.path && !claimed: "claim"
            case "receive": "receive"
            case "gather": "gather"
            case "install": "download"
            case "reconcile": "merge"
            case "finish": "finishInstalling"
            case "write" where path == LampSyncSettingsStore.path: "writeBundle"
            case "write": (LampSyncFolderLayout.kind(of: path)?.isMedia ?? false) ? "uploadMedia" : "uploadModule"
            case "deleteLocally": "deleteLocally"
            case "delete": "reap"
            default: nil
            }
            if step == "claim" { claimed = true }
            if let step, steps.last != step { steps.append(step) }
        }
        return steps.joined(separator: ",")
    }
}

/// A WebDAV server with strong revisions that logs each request to the pass's
/// timeline.
private final class PassOrderStore: LampSyncRemoteStore, @unchecked Sendable {
    let log: PassLog
    var bodies: [String: Data] = [:]
    var revisions: [String: String] = [:]
    private var counter = 0

    init(log: PassLog) { self.log = log }

    func list(directory: String) async throws -> [LampSyncRemoteEntry]? {
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        let entries = bodies.keys.filter { $0.hasPrefix(prefix) }.sorted().map { path in
            LampSyncRemoteEntry(
                path: path, name: String(path.dropFirst(prefix.count)), isDirectory: false,
                revision: revisions[path], modifiedAt: nil, size: nil
            )
        }
        return entries.isEmpty ? nil : entries
    }

    func read(path: String) async throws -> LampSyncRemoteFile? {
        log.events.append("read \(path)")
        return bodies[path].map { LampSyncRemoteFile(data: $0, revision: revisions[path]) }
    }

    func revision(path: String) async throws -> String? { revisions[path] }

    func write(_ data: Data, to path: String, condition: LampSyncWriteCondition) async throws -> String? {
        switch condition {
        case .ifAbsent where bodies[path] != nil:
            throw LampSyncConditionalWrite.WriteError.conflict
        case .ifRevision(let expected) where revisions[path] != expected:
            throw LampSyncConditionalWrite.WriteError.conflict
        default:
            break
        }
        log.events.append("write \(path)")
        counter += 1
        bodies[path] = data
        revisions[path] = "\"w\(counter)\""
        return revisions[path]
    }

    func delete(path: String, condition: LampSyncWriteCondition) async throws {
        log.events.append("delete \(path)")
        bodies[path] = nil
        revisions[path] = nil
    }
}

/// A library that logs each call to the pass's timeline. A merge publishes
/// the file `merged`.
private final class PassOrderLibrary: LampSyncPassLibrary, @unchecked Sendable {
    let log: PassLog
    let merged: URL

    init(log: PassLog, merged: URL) {
        self.log = log
        self.merged = merged
    }

    func install(_ path: String, from url: URL) async throws -> String? {
        log.events.append("install \(path)")
        return nil
    }

    func reconcile(_ downloaded: [String: URL]) async throws -> [String: URL] {
        log.events.append("reconcile")
        return downloaded.mapValues { _ in merged }
    }

    func deleteLocally(_ path: String) async throws { log.events.append("deleteLocally \(path)") }

    func finishInstalling() async throws { log.events.append("finish") }
}

