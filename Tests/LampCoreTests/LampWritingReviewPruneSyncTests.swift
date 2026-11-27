import Foundation
import Testing
@testable import LampCore

/// Devices passing a review record through a server, as both apps' passes
/// do: one that downloads takes the copy in, and one whose file then differs
/// from the copy it last agreed with sends it up. What is counted is the
/// uploads, since a record that is resent for nothing is resent on every
/// pass, for ever.
///
/// It holds the prune of old retirements and restorations to settling
/// (`Documentation/ReviewPrunePlan.md`). A device writing a change prunes
/// what is past its lifetime; a device taking a copy in lets go of what it
/// kept past its lifetime only where the copy has let go of it. An older
/// build that does neither is a device here too, with today's merge kept as
/// its reference.
struct LampWritingReviewPruneSyncTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let lifetime = LampWritingReviewStore.retirementLifetime
    static let old = now.addingTimeInterval(-lifetime - 24 * 60 * 60)
    static let young = now.addingTimeInterval(-24 * 60 * 60)

    static func id(_ n: Int) -> UUID { ReviewFixtures.id(n) }

    static func mark(_ n: Int, version: Int = 1) -> LampWritingReview.Mark {
        .init(
            id: id(n), pieces: [.init(text: "mark \(n) at \(version)", before: "", after: "", hint: 0)],
            version: version, markedAt: young, turnID: nil
        )
    }

    final class Server {
        var data: Data?
        var uploads = 0
    }

    final class Device {
        let store: LampWritingReviewStore
        /// Whether this is a build that prunes, or one from before.
        let prunes: Bool
        /// How far this device's clock is from the others'.
        let skew: TimeInterval
        /// The bytes it last agreed with the server on.
        var agreed: Data?

        init(_ root: URL, _ name: String, prunes: Bool = true, skew: TimeInterval = 0) {
            store = LampWritingReviewStore(rootURL: root.appendingPathComponent(name, isDirectory: true))
            self.prunes = prunes
            self.skew = skew
        }

        var clock: Date { LampWritingReviewPruneSyncTests.now.addingTimeInterval(skew) }

        var file: Data? { try? Data(contentsOf: store.url(writingID: "w")) }

        var review: LampWritingReview { (try? store.review(writingID: "w")) ?? LampWritingReview(writingID: "w") }

        /// Starts from `review`, agreed with the server, as a device that has
        /// synced does.
        func start(_ review: LampWritingReview, on server: Server) throws {
            try store.save(review)
            agreed = file
            server.data = file
        }

        /// A change the writer makes here.
        func write(_ change: (LampWritingReview) -> LampWritingReview) throws {
            if prunes {
                try store.update(writingID: "w", now: clock, change)
            } else {
                try store.save(change(review))
            }
        }

        func pass(_ server: Server) throws {
            if let remote = server.data, remote != agreed {
                if prunes {
                    try store.takeIn(downloaded: remote, writingID: "w", now: clock)
                } else {
                    // The merge as a build from before the prune makes it.
                    try store.save(review.merged(with: LampWritingReview.decoded(from: remote)))
                }
                agreed = remote
            }
            if let local = file, local != agreed {
                server.data = local
                agreed = local
                server.uploads += 1
            }
        }
    }

    static func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Passes in turn until `rounds` go by, returning the uploads they made.
    static func settle(_ devices: [Device], _ server: Server, rounds: Int = 10) throws -> Int {
        let before = server.uploads
        for _ in 0..<rounds { for device in devices { try device.pass(server) } }
        return server.uploads - before
    }

    /// A record with one live mark and one mark retired long ago.
    static let worn = LampWritingReview(
        writingID: "w", marks: [mark(1)], retired: [.init(id: id(2), retiredAt: old)]
    )

    static func addingMark(_ n: Int) -> (LampWritingReview) -> LampWritingReview {
        { var review = $0; review.marks.append(mark(n)); return review }
    }

    @Test func aWriteBetweenDevicesOfOneBuildPrunesBothAndThenIsQuiet() throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = Server()
        let a = Device(root, "a"), b = Device(root, "b")
        try a.start(Self.worn, on: server)
        try b.start(Self.worn, on: server)
        try a.write(Self.addingMark(3))
        #expect(try Self.settle([a, b], server) == 1)
        #expect(a.file == b.file)
        #expect(a.review.retired.isEmpty)
        #expect(a.review.marks.map(\.id) == [Self.id(1), Self.id(3)])
        #expect(try Self.settle([a, b], server) == 0)
    }

    /// Against an older build the entries come back once, and then nothing
    /// moves: the cost is one upload each way for each write, until the
    /// older device updates.
    @Test func aWriteAgainstAnOlderBuildCostsOneRoundTripAndSettles() throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = Server()
        let a = Device(root, "a"), b = Device(root, "b", prunes: false)
        try a.start(Self.worn, on: server)
        try b.start(Self.worn, on: server)
        try a.write(Self.addingMark(3))
        #expect(try Self.settle([a, b], server) == 2)
        #expect(a.file == b.file)
        #expect(try Self.settle([a, b], server) == 0)
    }

    /// A prune rides a write and never makes one.
    @Test func aChangeThatChangesNothingWritesNothing() throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = Device(root, "a")
        try a.start(Self.worn, on: Server())
        let url = try a.store.url(writingID: "w")
        let dated = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        let bytes = a.file
        try a.write { $0 }
        #expect(a.file == bytes)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == dated)
        #expect(a.review.retired.count == 1)
    }

    /// A device back with a clear it never sent, long ago, meeting a copy
    /// that still shows the mark: the clear is kept and goes up, and the
    /// mark goes everywhere.
    @Test func anOldClearNeverSentStillReachesTheOthers() throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = Server()
        let a = Device(root, "a"), b = Device(root, "b")
        let shown = LampWritingReview(writingID: "w", marks: [Self.mark(1), Self.mark(2)])
        try a.start(shown, on: server)
        try b.start(shown, on: server)
        // Cleared on `a` long ago, and never sent; meanwhile `b` has
        // written, so `a` takes in a copy that still shows the mark.
        try a.store.save(LampWritingReview(writingID: "w", marks: [Self.mark(1)], retired: [.init(id: Self.id(2), retiredAt: Self.old)]))
        try b.write(Self.addingMark(3))
        try b.pass(server)
        #expect(try Self.settle([a, b], server) == 1)
        #expect(!b.review.marks.contains { $0.id == Self.id(2) })
        #expect(b.review.retired.map(\.id) == [Self.id(2)])
    }

    /// A retirement the other copy lacks but that is not yet old is news,
    /// and goes up.
    @Test func aYoungRetirementTheOtherCopyLacksIsSent() throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = Server()
        let a = Device(root, "a"), b = Device(root, "b")
        let shown = LampWritingReview(writingID: "w", marks: [Self.mark(1)])
        try a.start(shown, on: server)
        try b.start(shown, on: server)
        try a.store.save(LampWritingReview(
            writingID: "w", marks: [Self.mark(1)], retired: [.init(id: Self.id(9), retiredAt: Self.young)]
        ))
        #expect(try Self.settle([a, b], server) == 1)
        #expect(b.review.retired.map(\.id) == [Self.id(9)])
    }

    /// A copy arriving with a wording whose mark has gone, which a merge
    /// can leave: taking it in adds nothing to send back.
    @Test func anOrphanWordingArrivingSendsNothingBack() throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = Server()
        let a = Device(root, "a"), b = Device(root, "b")
        try a.start(Self.worn, on: server)
        try b.start(Self.worn, on: server)
        var orphaned = Self.worn
        orphaned.wordings.append(.init(
            markID: Self.id(7), old: "before", lead: "", trail: "", markedDigest: "d", wasUnread: false
        ))
        try b.store.save(orphaned)
        #expect(try Self.settle([a, b], server) == 1)
        #expect(a.file == b.file)
    }

    /// A device whose clock is an hour behind holds on to an entry the
    /// others have just found old: one more upload, then quiet.
    @Test func aClockBehindCostsOneUploadThenNone() throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = Server()
        let edge = Self.now.addingTimeInterval(-Self.lifetime - 30 * 60)
        let record = LampWritingReview(writingID: "w", marks: [Self.mark(1)], retired: [.init(id: Self.id(2), retiredAt: edge)])
        let a = Device(root, "a"), b = Device(root, "b", skew: -60 * 60)
        try a.start(record, on: server)
        try b.start(record, on: server)
        try a.write(Self.addingMark(3))
        #expect(try Self.settle([a, b], server) == 2)
        #expect(a.file == b.file)
        #expect(try Self.settle([a, b], server) == 0)
    }

    /// A restore drops the restorations past their week, and the other
    /// device lets them go too rather than handing them back. Before the
    /// follow, each restore cost a round trip.
    @Test func aRestorationDroppedIsFollowedWithNoUpload() throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = Server()
        let stale = LampWritingReview.Restoration(
            markID: Self.id(5), turnID: nil, restored: "a", discarded: "b",
            restoredAt: Self.now.addingTimeInterval(-LampWritingReview.restorationWindow - 60 * 60)
        )
        let record = LampWritingReview(writingID: "w", marks: [Self.mark(1)], restorations: [stale])
        let a = Device(root, "a"), b = Device(root, "b")
        try a.start(record, on: server)
        try b.start(record, on: server)
        try a.write { var review = $0; review.restorations = []; review.marks.append(Self.mark(3)); return review }
        #expect(try Self.settle([a, b], server) == 1)
        #expect(b.review.restorations.isEmpty)
        #expect(a.file == b.file)
    }

    /// The cost, named: a device away for longer than the lifetime, still
    /// holding a mark the others retired and have since let go of, brings
    /// it back.
    @Test func aDeviceAwayPastTheLifetimeBringsBackAMarkTheOthersLetGo() throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = Server()
        let a = Device(root, "a"), b = Device(root, "b"), away = Device(root, "away")
        try a.start(Self.worn, on: server)
        try b.start(Self.worn, on: server)
        try away.store.save(LampWritingReview(writingID: "w", marks: [Self.mark(1), Self.mark(2)]))
        away.agreed = away.file
        try a.write(Self.addingMark(3))
        _ = try Self.settle([a, b], server)
        _ = try Self.settle([a, b, away], server)
        #expect(a.review.marks.contains { $0.id == Self.id(2) })
    }

    /// A wording a merge left, which every copy holds alike, is not
    /// tidied away by a write: the others would hand it back.
    @Test func aWriteLeavesASharedOrphanWordingAlone() throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = Server()
        var orphaned = Self.worn
        orphaned.wordings.append(.init(
            markID: Self.id(7), old: "before", lead: "", trail: "", markedDigest: "d", wasUnread: false
        ))
        let a = Device(root, "a"), b = Device(root, "b")
        try a.start(orphaned, on: server)
        try b.start(orphaned, on: server)
        try a.write(Self.addingMark(3))
        #expect(try Self.settle([a, b], server) == 1)
        #expect(a.file == b.file)
        #expect(a.review.wordings.count == 1)
    }

    /// A change that only reorders what the record holds writes the same
    /// bytes, so it writes nothing, and prunes nothing.
    @Test func aChangeThatOnlyReordersPrunesNothing() throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        var record = Self.worn
        record.marks.append(Self.mark(3))
        let a = Device(root, "a")
        try a.start(record, on: Server())
        let bytes = a.file
        try a.write { var review = $0; review.marks.reverse(); return review }
        #expect(a.file == bytes)
        #expect(a.review.retired.count == 1)
    }

    /// The merge keeps only the newest restorations. One of this copy's
    /// that is past its week, and newer than the oldest the incoming copy
    /// holds, is let go before that cap rather than after it, so it cannot
    /// push out one the incoming copy holds.
    @Test func aRestorationLetGoDoesNotPushOutOneTheIncomingCopyHolds() throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LampWritingReviewStore(rootURL: root)
        let day: TimeInterval = 24 * 60 * 60
        func restoration(_ n: Int, daysAgo: Double) -> LampWritingReview.Restoration {
            .init(markID: Self.id(100 + n), turnID: nil, restored: "a\(n)", discarded: "b\(n)",
                  restoredAt: Self.now.addingTimeInterval(-daysAgo * day))
        }
        let held = (0..<LampWritingReview.restorationsKept).map { restoration($0, daysAgo: 30 - Double($0)) }
        let incoming = LampWritingReview(writingID: "w", marks: [Self.mark(1)], restorations: held)
        let mine = LampWritingReview(
            writingID: "w", marks: [Self.mark(1)], restorations: held + [restoration(50, daysAgo: 9)]
        )
        try store.save(mine)
        let differs = try store.takeIn(downloaded: incoming.encoded(), writingID: "w", now: Self.now)
        #expect(!differs)
        #expect(try Data(contentsOf: store.url(writingID: "w")) == incoming.encoded())
    }
}

