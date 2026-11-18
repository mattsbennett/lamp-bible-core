import XCTest
@testable import LampCore

final class LampAgentRemoteProtocolTests: XCTestCase {
    private let code = "ABCDEFGHJKLMNPQR"

    /// A handshake run through its frames, as a host and device would.
    private func connect(
        device credential: LampAgentRemoteCredential,
        hostAccepts candidates: [LampAgentRemoteCredential],
        hostSecret: String? = nil
    ) throws -> (device: LampAgentRemoteSecureChannel, host: LampAgentRemoteSecureChannel, matched: LampAgentRemoteCredential.Kind) {
        let start = LampAgentRemoteHandshake.hostStart(hostSecret: hostSecret)
        var toDevice = try LampAgentRemoteFraming.encode(start.hello)
        let hello = try XCTUnwrap(LampAgentRemoteFraming.decode(LampAgentRemoteHello.self, from: &toDevice))
        let (auth, device) = try LampAgentRemoteHandshake.respond(to: hello, with: credential)
        var toHost = try LampAgentRemoteFraming.encode(auth)
        let received = try XCTUnwrap(LampAgentRemoteFraming.decode(LampAgentRemoteAuth.self, from: &toHost))
        let (matched, host) = try LampAgentRemoteHandshake.accept(received, start: start, candidates: candidates)
        return (device, host, matched.kind)
    }

    func testAPairingCodeOpensAChannelBothWays() throws {
        let pairing = try XCTUnwrap(LampAgentRemoteCredential.pairing(code: code))
        let (device, host, matched) = try connect(device: pairing, hostAccepts: [pairing])
        XCTAssertEqual(matched, .pairing)

        let minted = LampAgentRemoteDeviceCredential.generate()
        var frames = try host.seal(.accepted(pairing: minted, hostSecret: "c2VjcmV0c2VjcmV0c2VjcmV0"))
        let accepted = try device.open(from: &frames)
        XCTAssertEqual(accepted.first?.deviceID, minted.deviceID)
        XCTAssertEqual(accepted.first?.deviceKey, minted.deviceKey)

        var request = try device.seal(.send("What does grace mean here?", to: "chat-1"))
        let opened = try host.open(from: &request)
        XCTAssertEqual(opened.first?.kind, .send)
        XCTAssertEqual(opened.first?.text, "What does grace mean here?")
        XCTAssertTrue(request.isEmpty)
    }

    func testAPairedDeviceIsKnownByItsKeyWithoutNamingItself() throws {
        let alice = LampAgentRemoteDeviceCredential.generate()
        let bob = LampAgentRemoteDeviceCredential.generate()
        let candidates = [alice, bob].compactMap(LampAgentRemoteCredential.device)
        let (_, _, matched) = try connect(device: try XCTUnwrap(.device(bob)), hostAccepts: candidates)
        XCTAssertEqual(matched, .device(id: bob.deviceID))
    }

    func testAForgottenDeviceOrAWrongCodeIsTurnedAway() throws {
        let forgotten = try XCTUnwrap(LampAgentRemoteCredential.device(.generate()))
        let kept = try XCTUnwrap(LampAgentRemoteCredential.device(.generate()))
        XCTAssertThrowsError(try connect(device: forgotten, hostAccepts: [kept])) {
            XCTAssertEqual($0 as? LampAgentRemoteError, .unknownDevice)
        }
        let wrongCode = try XCTUnwrap(LampAgentRemoteCredential.pairing(code: "ZZZZZZZZZZZZZZZZ"))
        let rightCode = try XCTUnwrap(LampAgentRemoteCredential.pairing(code: code))
        XCTAssertThrowsError(try connect(device: wrongCode, hostAccepts: [rightCode]))
    }

    /// Someone in between who swaps in their own key can't make a proof
    /// without the device's key, nor read what the host seals.
    func testAKeySwappedInBetweenFailsTheProof() throws {
        let credential = try XCTUnwrap(LampAgentRemoteCredential.device(.generate()))
        let start = LampAgentRemoteHandshake.hostStart(hostSecret: nil)
        var (auth, _) = try LampAgentRemoteHandshake.respond(to: start.hello, with: credential)
        let other = LampAgentRemoteHandshake.hostStart(hostSecret: nil)
        auth.ephemeralKey = other.hello.ephemeralKey
        XCTAssertThrowsError(try LampAgentRemoteHandshake.accept(auth, start: start, candidates: [credential])) {
            XCTAssertEqual($0 as? LampAgentRemoteError, .unknownDevice)
        }
    }

    func testEachConnectionHasItsOwnKeys() throws {
        let credential = try XCTUnwrap(LampAgentRemoteCredential.device(.generate()))
        let first = try connect(device: credential, hostAccepts: [credential])
        let second = try connect(device: credential, hostAccepts: [credential])
        var frame = try first.device.seal(.ping)
        XCTAssertThrowsError(try second.host.open(from: &frame)) {
            XCTAssertEqual($0 as? LampAgentRemoteError, .authenticationFailed)
        }
        var own = try second.device.seal(.ping)
        XCTAssertEqual(try second.host.open(from: &own).first?.kind, .ping)
    }

    /// Two references to one channel share its count, so neither can seal
    /// under a nonce the other has used.
    func testReferencesToAChannelNeverRepeatANonce() throws {
        let credential = try XCTUnwrap(LampAgentRemoteCredential.device(.generate()))
        let (device, host, _) = try connect(device: credential, hostAccepts: [credential])
        let other = device
        var frames = try device.seal(.send("one", to: "a")) + other.seal(.send("two", to: "a"))
        XCTAssertEqual(try host.open(from: &frames).compactMap(\.text), ["one", "two"])
    }

    func testAReplayedOrAlteredFrameDoesNotOpen() throws {
        let credential = try XCTUnwrap(LampAgentRemoteCredential.device(.generate()))
        let (device, host, _) = try connect(device: credential, hostAccepts: [credential])
        let frame = try device.seal(.listChats())
        var once = frame
        XCTAssertEqual(try host.open(from: &once).count, 1)
        var replay = frame
        XCTAssertThrowsError(try host.open(from: &replay))

        let (device2, host2, _) = try connect(device: credential, hostAccepts: [credential])
        var altered = try device2.seal(.listChats())
        altered[altered.count - 1] ^= 0x01
        XCTAssertThrowsError(try host2.open(from: &altered)) {
            XCTAssertEqual($0 as? LampAgentRemoteError, .authenticationFailed)
        }
    }

    func testFramesArrivingInPiecesOrTogetherOpenInOrder() throws {
        let credential = try XCTUnwrap(LampAgentRemoteCredential.device(.generate()))
        let (device, host, _) = try connect(device: credential, hostAccepts: [credential])
        let stream = try device.seal(.openChat("a")) + device.seal(.send("one", to: "a")) + device.seal(.ping)
        var buffer = Data()
        var opened: [LampAgentRemoteMessage] = []
        for byte in stream {
            buffer.append(byte)
            opened += try host.open(from: &buffer)
        }
        XCTAssertEqual(opened.map(\.kind), [.openChat, .send, .ping])
    }

    func testAKindThisVersionDoesNotKnowStillOpens() throws {
        let credential = try XCTUnwrap(LampAgentRemoteCredential.device(.generate()))
        let (device, host, _) = try connect(device: credential, hostAccepts: [credential])
        var frame = try device.seal(LampAgentRemoteMessage(kind: .init(rawValue: "something-later")))
        XCTAssertEqual(try host.open(from: &frame).first?.kind.rawValue, "something-later")
    }

    func testTheHostHintChangesEveryTimeButIsRecognised() throws {
        let secret = LampAgentRemoteHandshake.generateHostSecret()
        let first = LampAgentRemoteHandshake.hostStart(hostSecret: secret).hello
        let second = LampAgentRemoteHandshake.hostStart(hostSecret: secret).hello
        let hint = try XCTUnwrap(first.hostHint)
        XCTAssertNotEqual(hint, second.hostHint)
        XCTAssertTrue(LampAgentRemoteHandshake.hostMatches(secret: secret, hint: hint, nonce: first.nonce))
        XCTAssertFalse(LampAgentRemoteHandshake.hostMatches(secret: secret, hint: hint, nonce: second.nonce))
        XCTAssertFalse(LampAgentRemoteHandshake.hostMatches(
            secret: LampAgentRemoteHandshake.generateHostSecret(), hint: hint, nonce: first.nonce
        ))
    }

    func testAHelloFromAnotherVersionIsRefused() throws {
        var hello = LampAgentRemoteHandshake.hostStart(hostSecret: nil).hello
        hello.protocolVersion = 99
        let credential = try XCTUnwrap(LampAgentRemoteCredential.pairing(code: code))
        XCTAssertThrowsError(try LampAgentRemoteHandshake.respond(to: hello, with: credential)) {
            XCTAssertEqual($0 as? LampAgentRemoteError, .unsupportedVersion(99))
        }
    }

    func testThePairingQRRoundTrips() throws {
        let payload = try XCTUnwrap(LampAgentRemoteHandshake.qrPayload(for: code))
        XCTAssertEqual(LampAgentRemoteHandshake.code(fromQRPayload: payload), code)
        // The slide remote's QR is not this one's.
        let slides = try XCTUnwrap(LampPresentationRemotePairing.qrPayload(for: code))
        XCTAssertNil(LampAgentRemoteHandshake.code(fromQRPayload: slides))
    }

    func testASnapshotRoundTrips() throws {
        let credential = try XCTUnwrap(LampAgentRemoteCredential.device(.generate()))
        let (device, host, _) = try connect(device: credential, hostAccepts: [credential])
        let summary = LampAgentRemoteChatSummary(
            id: "w1/claude", title: "Romans 5", subtitle: "Reader", kind: LampAgentRemoteChatSummary.reader,
            provider: "claude", providerName: "Claude", updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            preview: "Grace abounds", isRunning: true, acceptsMessages: true
        )
        let snapshot = LampAgentRemoteChatSnapshot(
            summary: summary,
            messages: [LampAgentRemoteChatMessage(role: LampAgentRemoteChatMessage.user, text: "Why *abound*?", date: Date(timeIntervalSince1970: 1_800_000_000))],
            partialReply: "Paul's word is",
            activity: LampAgentRemoteActivity(kind: LampAgentRemoteActivity.tool, name: "read passage", summary: "Romans 5:20")
        )
        var frame = try host.seal(.snapshot(snapshot))
        XCTAssertEqual(try device.open(from: &frame).first?.snapshot, snapshot)
    }
}
