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

    func testThePairingQRCarriesTheMacsTailnetAddresses() throws {
        let addresses = [
            LampAgentRemoteAddress(host: "100.90.115.76"),
            LampAgentRemoteAddress(host: "fd7a:115c:a1e0::9c01:734c", port: 50192),
        ]
        let payload = try XCTUnwrap(LampAgentRemoteHandshake.qrPayload(for: code, addresses: addresses))
        XCTAssertEqual(LampAgentRemoteHandshake.addresses(fromQRPayload: payload), addresses)
        // A device that reads only the code still reads it.
        XCTAssertEqual(LampAgentRemoteHandshake.code(fromQRPayload: payload), code)
        // No addresses: the QR is what it always was.
        XCTAssertEqual(
            LampAgentRemoteHandshake.qrPayload(for: code, addresses: []),
            LampAgentRemoteHandshake.qrPayload(for: code)
        )
        XCTAssertEqual(LampAgentRemoteHandshake.addresses(fromQRPayload: try XCTUnwrap(LampAgentRemoteHandshake.qrPayload(for: code))), [])
    }

    func testAPairingQRsAddressesAreReadWithCare() throws {
        let base = try XCTUnwrap(LampAgentRemoteHandshake.qrPayload(for: code))
        // One that does not parse is left out; a repeat is read once; no
        // more than the limit are taken.
        let crowded = base + "&at=-flag&at=100.64.0.1&at=100.64.0.1"
            + (2...9).map { "&at=100.64.0.\($0)" }.joined()
        XCTAssertEqual(
            LampAgentRemoteHandshake.addresses(fromQRPayload: crowded).map(\.host),
            ["100.64.0.1", "100.64.0.2", "100.64.0.3", "100.64.0.4"]
        )
        // Not this QR at all: the slide remote's, carrying an address.
        let slides = try XCTUnwrap(LampPresentationRemotePairing.qrPayload(for: code)) + "&at=100.64.0.1"
        XCTAssertEqual(LampAgentRemoteHandshake.addresses(fromQRPayload: slides), [])
    }

    func testASnapshotRoundTrips() throws {
        let credential = try XCTUnwrap(LampAgentRemoteCredential.device(.generate()))
        let (device, host, _) = try connect(device: credential, hostAccepts: [credential])
        let summary = LampAgentRemoteChatSummary(
            id: UUID().uuidString, title: "Romans 5", subtitle: "Reader", kind: LampAgentRemoteChatSummary.reader,
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

    /// A message carries where the device is reading as ids, and a refusal
    /// carries a code the device can act on.
    func testASendCarriesItsReadingAndARefusalItsCode() throws {
        let credential = try XCTUnwrap(LampAgentRemoteCredential.device(.generate()))
        let (device, host, _) = try connect(device: credential, hostAccepts: [credential])
        let reading = LampAgentRemoteReading(verse: 45_005_020, chapter: 45_005_000, translationID: "BSB")
        var request = try device.seal(.send("Why abound?", to: "chat", reading: reading))
        let sent = try XCTUnwrap(host.open(from: &request).first)
        XCTAssertEqual(sent.reading, reading)

        var refusal = try host.seal(.failed(LampAgentRemoteFailure.busy, "A reply is still being written.", requestID: sent.requestID))
        let failed = try XCTUnwrap(device.open(from: &refusal).first)
        XCTAssertEqual(failed.errorCode, LampAgentRemoteFailure.busy)
        XCTAssertEqual(failed.requestID, sent.requestID)
    }

    /// A writing chat is listed with its writing, a message to it carries the
    /// words selected on the device, and one begun on a writing names it.
    func testAWritingChatCarriesItsWritingAndSelection() throws {
        let credential = try XCTUnwrap(LampAgentRemoteCredential.device(.generate()))
        let (device, host, _) = try connect(device: credential, hostAccepts: [credential])
        let summary = LampAgentRemoteChatSummary(
            id: "writing:abc", title: "On grace", kind: LampAgentRemoteChatSummary.writing, writingID: "abc",
            provider: "claude", providerName: "Claude", acceptsMessages: true
        )
        var listed = try host.seal(.chats([summary]))
        XCTAssertEqual(try device.open(from: &listed).first?.chats?.first?.writingID, "abc")

        var request = try device.seal(.send("Tighten this", to: summary.id, selection: "grace upon grace"))
        XCTAssertEqual(try host.open(from: &request).first?.selection, "grace upon grace")

        var begin = try device.seal(.startChat(.writing("abc", firstMessage: "Read it through", selection: "upon")))
        let begun = try XCTUnwrap(host.open(from: &begin).first?.newChat)
        XCTAssertEqual(begun, LampAgentRemoteNewChat(
            kind: LampAgentRemoteChatSummary.writing, writingID: "abc", selection: "upon", firstMessage: "Read it through"
        ))
    }

    /// What an older device sends has none of the writing fields, and still
    /// reads as a reader chat.
    func testAStartChatWithoutWritingFieldsIsAReaderChat() throws {
        let old = #"{"kind":"reader","firstMessage":"Hello"}"#
        let chat = try JSONDecoder().decode(LampAgentRemoteNewChat.self, from: Data(old.utf8))
        XCTAssertEqual(chat.kind, LampAgentRemoteChatSummary.reader)
        XCTAssertNil(chat.writingID)
        XCTAssertNil(chat.selection)
    }

    /// A writing turn names the writing's revision on the device, and the
    /// host is behind only where its copy is older or missing.
    func testAWritingTurnCarriesItsRevision() throws {
        let credential = try XCTUnwrap(LampAgentRemoteCredential.device(.generate()))
        let (device, host, _) = try connect(device: credential, hostAccepts: [credential])
        var request = try device.seal(.send("Tighten this", to: "writing:abc", writingRevision: 1_800_000_000))
        XCTAssertEqual(try host.open(from: &request).first?.writingRevision, 1_800_000_000)
        var begin = try device.seal(.startChat(.writing("abc", firstMessage: "Read it", writingRevision: 7)))
        XCTAssertEqual(try host.open(from: &begin).first?.newChat?.writingRevision, 7)

        let saved = Date(timeIntervalSince1970: 1_800_000_000.75)
        XCTAssertEqual(LampAgentRemoteWritingRevision.of(lastModified: saved), 1_800_000_000)
        XCTAssertFalse(LampAgentRemoteWritingRevision.hostIsBehind(host: saved, device: 1_800_000_000))
        XCTAssertFalse(LampAgentRemoteWritingRevision.hostIsBehind(host: saved, device: 1_799_999_999))
        XCTAssertTrue(LampAgentRemoteWritingRevision.hostIsBehind(host: saved, device: 1_800_000_001))
        XCTAssertTrue(LampAgentRemoteWritingRevision.hostIsBehind(host: nil, device: 1))
        XCTAssertFalse(LampAgentRemoteWritingRevision.hostIsBehind(host: nil, device: nil))
    }

    /// A save in the same second as the host's copy is fetched; only a
    /// copy dated earlier is refused.
    func testASaveInTheSameSecondIsFetched() {
        let second = Date(timeIntervalSince1970: 1_800_000_000.2)
        let a = LampAgentRemoteWritingRevision.digest(of: LampPersonalWritingFile.Row(id: "w", moduleID: "m", title: "t", contentJSON: "A", created: 0))
        let b = LampAgentRemoteWritingRevision.digest(of: LampPersonalWritingFile.Row(id: "w", moduleID: "m", title: "t", contentJSON: "B", created: 0))
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(LampAgentRemoteWritingRevision.hostShouldFetch(host: second, hostDigest: a, device: 1_800_000_000, deviceDigest: b))
        XCTAssertFalse(LampAgentRemoteWritingRevision.hostIsBehind(host: second, device: 1_800_000_000))
        XCTAssertFalse(LampAgentRemoteWritingRevision.hostShouldFetch(host: second, hostDigest: b, device: 1_800_000_000, deviceDigest: b))
        XCTAssertFalse(LampAgentRemoteWritingRevision.hostShouldFetch(host: second, hostDigest: a, device: 1_800_000_000, deviceDigest: nil))
        XCTAssertFalse(LampAgentRemoteWritingRevision.hostShouldFetch(host: second, hostDigest: a, device: 1_799_999_999, deviceDigest: b))
        XCTAssertTrue(LampAgentRemoteWritingRevision.hostShouldFetch(host: second, hostDigest: a, device: 1_800_000_001, deviceDigest: a))
    }

    /// A body that is only Markdown digests alike kept bare or wrapped in a
    /// paragraph, as a writing the Mac holds as plain text is.
    func testAPlainBodyDigestsAlikeBareOrWrapped() throws {
        let writing = LampDevotional(
            id: "w", moduleID: "m", moduleName: "Writing", title: "t", subtitle: nil, author: nil, date: nil,
            tags: [], category: nil, seriesName: nil, seriesOrder: nil, keyScriptures: [], summary: nil,
            content: "Grace *upon* grace.", contentJSON: nil, footnotes: nil, mediaJSON: nil,
            created: nil, lastModified: nil, isEditable: true
        )
        let bare = LampPersonalWritingFile.Row(id: "w", moduleID: "m", title: "t", contentJSON: "Grace *upon* grace.", created: 0)
        XCTAssertEqual(LampAgentRemoteWritingRevision.digest(of: writing), LampAgentRemoteWritingRevision.digest(of: bare))
        let other = LampPersonalWritingFile.Row(id: "w", moduleID: "m", title: "t", contentJSON: "Grace upon grace.", created: 0)
        XCTAssertNotEqual(LampAgentRemoteWritingRevision.digest(of: bare), LampAgentRemoteWritingRevision.digest(of: other))
    }
}
