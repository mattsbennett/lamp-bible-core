import Foundation
import Testing
@testable import LampCore

/// The Lean model of agent chats on the phone, checked with the other suites
/// and held to the Swift it describes.
///
/// `Verification/AgentRemote.lean` proves properties of the pairing window,
/// a channel's frame order, which proofs a host lets in, and the update
/// contract between host and device, and prints a conformance table for
/// each. This asks the shipped Swift every question in those tables. Lean
/// comes from elan, as for the sync model; `LAMP_SKIP_LEAN=1` skips these.
enum AgentRemoteModel {
    static let modelURL = SyncModel.packageRoot.appendingPathComponent("Verification/AgentRemote.lean")

    static let run: SyncModel.Run = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            ProcessInfo.processInfo.environment["LAMP_ELAN"],
            "\(home)/.elan/bin/elan",
            "/opt/homebrew/bin/elan",
            "/usr/local/bin/elan",
        ].compactMap { $0 }
        guard let elan = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return SyncModel.Run(status: -1, lines: [], problem: "elan was not found; see Verification/README.md.")
        }
        let toolchain = (try? String(
            contentsOf: SyncModel.packageRoot.appendingPathComponent("lean-toolchain"), encoding: .utf8
        ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "stable"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: elan)
        process.arguments = ["run", toolchain, "lean", modelURL.path]
        process.currentDirectoryURL = SyncModel.packageRoot
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch {
            return SyncModel.Run(status: -1, lines: [], problem: "Could not run Lean: \(error)")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return SyncModel.Run(status: process.terminationStatus, lines: lines, problem: nil)
    }()

    static func cases(_ rule: String) -> [[String]] {
        run.lines.compactMap { line in
            let fields = line.split(separator: " ").map(String.init)
            guard fields.count > 2, fields[0] == "CONFORMANCE", fields[1] == rule else { return nil }
            return Array(fields.dropFirst(2))
        }
    }

    static func systemCheck(_ name: String) -> String? {
        run.lines.lazy.compactMap { line -> String? in
            let fields = line.split(separator: " ").map(String.init)
            return fields.count == 3 && fields[0] == "SYSTEMCHECK" && fields[1] == name ? fields[2] : nil
        }.first
    }
}

@Suite(.disabled(if: SyncModel.skipped, "LAMP_SKIP_LEAN=1"))
struct AgentRemoteModelConformanceTests {
    static let checkedRules: Set<String> = ["pairingWindow", "channelOpens", "admit", "chatPlan", "approvalAnswer"]

    @Test func theModelChecks() {
        let run = AgentRemoteModel.run
        if let problem = run.problem { Issue.record("\(problem)"); return }
        #expect(run.status == 0, "Lean rejected the model:\n\(run.lines.prefix(40).joined(separator: "\n"))")
        // Anything besides the tables — a warning, a `sorry` — fails too.
        let other = run.lines.filter { !$0.hasPrefix("CONFORMANCE ") && !$0.hasPrefix("SYSTEMCHECK ") }
        #expect(other.isEmpty, "Lean printed:\n\(other.prefix(20).joined(separator: "\n"))")
        let rules = Set(run.lines.compactMap { line -> String? in
            let fields = line.split(separator: " ")
            return fields.count > 1 && fields[0] == "CONFORMANCE" ? String(fields[1]) : nil
        })
        #expect(rules == Self.checkedRules, "tables and checks differ: \(rules.symmetricDifference(Self.checkedRules))")
    }

    @Test func noOrdinaryChangeNeedsASnapshot() {
        #expect(AgentRemoteModel.systemCheck("chatPlanOrdinaryNeedsNoSnapshot") == "0")
    }

    private func conform(_ rule: String, _ check: ([String]) throws -> Bool) rethrows {
        let rows = AgentRemoteModel.cases(rule)
        #expect(!rows.isEmpty, "no \(rule) table")
        for row in rows {
            let agrees = try check(row)
            #expect(agrees, "\(rule) \(row.joined(separator: " "))")
            if !agrees { return }
        }
    }

    // MARK: - Pairing window

    @Test func pairingWindow() {
        conform("pairingWindow") { f in
            var window = LampAgentRemotePairingWindow(allowedFailures: Int(f[0])!)
            var pairings = 0
            for attempt in f[1] == "-" ? [] : Array(f[1]) {
                if attempt == "r" {
                    if window.credential != nil { window.paired(); pairings += 1 }
                } else {
                    window.failed()
                }
            }
            return "\(window.isClosed)" == f[2] && "\(pairings)" == f[3]
        }
    }

    // MARK: - Channel

    private func channels() throws -> (send: LampAgentRemoteSecureChannel, receive: LampAgentRemoteSecureChannel) {
        let host = LampAgentRemoteHandshake.hostStart(hostSecret: nil)
        let credential = try #require(LampAgentRemoteCredential.device(.generate()))
        let device = try LampAgentRemoteHandshake.respond(to: host.hello, with: credential)
        let accepted = try LampAgentRemoteHandshake.accept(device.auth, start: host, candidates: [credential])
        return (device.channel, accepted.channel)
    }

    @Test func channelOpens() throws {
        try conform("channelOpens") { f in
            let (send, receive) = try channels()
            let frames = try (0..<3).map { _ in try send.seal(.ping) }
            var opened = 0
            for counter in f[0] == "-" ? [] : f[0].split(separator: ".").map({ Int($0)! }) {
                var buffer = frames[counter]
                guard (try? receive.open(from: &buffer)) != nil else { break }
                opened += 1
            }
            return "\(opened)" == f[1]
        }
    }

    // MARK: - Admission

    @Test func admit() throws {
        try conform("admit") { f in
            let paired = LampAgentRemoteDeviceCredential.generate()
            var window: LampAgentRemotePairingWindow? = LampAgentRemotePairingWindow()
            if f[2] == "false" { window?.paired() }
            let offered: LampAgentRemoteCredential
            switch f[0] {
            case "device": offered = try #require(LampAgentRemoteCredential.device(paired))
            case "pairingCode":
                let code = try #require(window?.code)
                offered = try #require(LampAgentRemoteCredential.pairing(code: code))
            default: offered = try #require(LampAgentRemoteCredential.device(.generate()))
            }
            var host = LampAgentRemoteHostConnection(hostSecret: nil)
            var hello = host.opening
            let start = try #require(try LampAgentRemoteFraming.decode(LampAgentRemoteHello.self, from: &hello))
            let auth = try LampAgentRemoteHandshake.respond(to: start, with: offered).auth
            let effects = host.receive(
                try LampAgentRemoteFraming.encode(auth),
                trusted: [try #require(LampAgentRemoteCredential.device(paired))],
                revoked: f[1] == "true" ? [paired.deviceID] : [],
                pairing: &window
            )
            let answer = effects.contains(.pairedByCode) ? "pairedByCode"
                : effects.contains(.acceptedDevice(paired.deviceID)) ? "acceptedDevice"
                : effects == [.close] ? "close" : "?"
            return answer == f[3]
        }
    }

    // MARK: - The update contract

    private static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    private static func number(_ id: UUID?) -> String {
        id.map { String(Int($0.uuidString.suffix(12))!) } ?? "-"
    }

    private static func message(_ name: Substring) -> LampAgentRemoteChatMessage {
        let n = Int(name.dropFirst())!
        return LampAgentRemoteChatMessage(
            id: id(n), role: name.first == "u" ? LampAgentRemoteChatMessage.user : LampAgentRemoteChatMessage.assistant,
            text: "m\(n)", date: Date(timeIntervalSince1970: Double(n))
        )
    }

    private static func name(_ message: LampAgentRemoteChatMessage) -> String {
        (message.role == LampAgentRemoteChatMessage.user ? "u" : "a") + number(message.id)
    }

    private static func state(_ field: String) -> LampAgentRemoteChatState {
        let parts = field.split(separator: "/", omittingEmptySubsequences: false)
        let arriving = Int(parts[2])!, activity = Int(parts[3])!, failure = Int(parts[4])!, waiting = Int(parts[5])!
        return LampAgentRemoteChatState(
            messages: parts[0] == "-" ? [] : parts[0].split(separator: ".").map(message),
            arriving: arriving == 0 ? "" : "t\(arriving)",
            activity: activity == 0 ? nil : LampAgentRemoteActivity(kind: "k\(activity)"),
            isRunning: parts[1] == "r",
            failure: failure == 0 ? nil : "f\(failure)",
            approvals: waiting == 0 ? [] : [approval(waiting)]
        )
    }

    private static func approval(_ n: Int) -> LampAgentRemoteApproval {
        LampAgentRemoteApproval(id: "p\(n)", provider: "codex", kind: LampAgentRemoteApproval.command, title: "Run", command: "make \(n)", canAllow: true)
    }

    private static func name(_ event: LampAgentRemoteChatEvent) -> String {
        let turn = number(event.turnID)
        func value(_ text: String?) -> String { text.map { $0.isEmpty ? "0" : String($0.dropFirst()) } ?? "0" }
        switch event.kind {
        case LampAgentRemoteChatEvent.turnStarted: return "S\(turn):" + (event.message.map(name) ?? "-")
        case LampAgentRemoteChatEvent.fragment: return "F\(turn):" + value(event.text)
        case LampAgentRemoteChatEvent.activity: return "A\(turn):" + value(event.activity?.kind)
        case LampAgentRemoteChatEvent.reply: return "R\(turn):" + (event.message.map(name) ?? "-")
        case LampAgentRemoteChatEvent.failed: return "X\(turn):" + value(event.text)
        case LampAgentRemoteChatEvent.turnEnded: return "E\(turn)"
        case LampAgentRemoteChatEvent.approvals:
            return "P\(turn):" + (event.approvals?.first.map { String($0.id.dropFirst()) } ?? "0")
        default: return "?"
        }
    }

    @Test func chatPlan() {
        conform("chatPlan") { f in
            let old = Self.state(f[0]), new = Self.state(f[1])
            let answer: String
            if LampAgentRemoteChatUpdates.needsSnapshot(from: old, to: new) {
                answer = "snapshot"
            } else {
                let events = LampAgentRemoteChatUpdates.events(chatID: "c", from: old, to: new)
                answer = events.isEmpty ? "none" : events.map(Self.name).joined(separator: ",")
            }
            return answer == f[2]
        }
    }

    // MARK: - A device's answer to a request

    @Test func approvalAnswer() {
        conform("approvalAnswer") { f in
            let decision: String? = ["allowOnce": LampAgentRemoteApprovalAnswer.allowOnce, "deny": LampAgentRemoteApprovalAnswer.deny][f[0]] ?? "always-allow"
            let sameTurn = f[1] == "true", waiting = f[2] == "true", unchanged = f[3] == "true", canAllow = f[4] == "true"
            let turn = Self.id(1)
            var request = Self.approval(1)
            request.canAllow = canAllow
            // What the device showed: this request, or another of the same
            // id where it changed since.
            var shown = request
            if !unchanged { shown.command = "make 2" }
            let outcome = LampAgentRemoteApprovalAnswer.decide(
                decision: decision, approvalID: request.id,
                digest: LampAgentRemoteApproval.digest(chatID: "c", turnID: sameTurn ? turn : Self.id(2), approval: shown),
                shownTurn: sameTurn ? turn : Self.id(2), chatID: "c", currentTurn: turn,
                waiting: waiting ? [request] : [Self.approval(9)]
            )
            return outcome.rawValue == f[5]
        }
    }
}
