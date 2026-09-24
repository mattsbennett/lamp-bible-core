import Foundation
import Testing
@testable import LampCore

@Suite("Presentation remote protocol")
struct LampPresentationRemoteProtocolTests {
    @Test("Presenter state round-trips with semantic slide content")
    func stateRoundTrip() throws {
        let slide = LampPresentationSlide(
            id: "slide-1",
            layout: .scripture,
            blocks: [
                .init(kind: .scripture, text: "The light shines in the darkness."),
                .init(kind: .citation, text: "John 1:5"),
            ],
            speakerNotes: "Pause after darkness."
        )
        let state = LampPresentationRemoteState(
            deckID: "deck-1",
            deckTitle: "Living Light",
            aspectRatio: .widescreen,
            theme: .lampDark,
            currentSlideIndex: 0,
            slideCount: 1,
            slideReferences: [.init(index: 0, id: slide.id, title: "John 1:5")],
            currentSlide: slide,
            nextSlide: nil,
            elapsedSeconds: 92,
            isBlackout: false,
            canGoPrevious: false,
            canGoNext: false
        )

        let frame = try LampPresentationRemoteFrameCodec.encode(.state(state))
        var buffer = frame
        let decoded = try LampPresentationRemoteFrameCodec.decodeFrames(from: &buffer)

        #expect(decoded == [.state(state)])
        #expect(buffer.isEmpty)
    }

    @Test("Fragmented and coalesced TCP reads decode deterministically")
    func framing() throws {
        let first = try LampPresentationRemoteFrameCodec.encode(.hello(clientName: "Matthew’s iPad"))
        let second = try LampPresentationRemoteFrameCodec.encode(
            .command(.init(action: .goTo, slideIndex: 4))
        )
        let bytes = first + second
        var buffer = Data(bytes.prefix(7))

        #expect(try LampPresentationRemoteFrameCodec.decodeFrames(from: &buffer).isEmpty)
        buffer.append(bytes.dropFirst(7))

        let decoded = try LampPresentationRemoteFrameCodec.decodeFrames(from: &buffer)
        #expect(decoded.count == 2)
        #expect(decoded[0] == .hello(clientName: "Matthew’s iPad"))
        #expect(decoded[1].command?.action == .goTo)
        #expect(decoded[1].command?.slideIndex == 4)
        #expect(buffer.isEmpty)
    }

    @Test("Oversized frame headers are rejected before allocation")
    func oversizedFrame() {
        let oversized = UInt32(LampPresentationRemoteProtocol.maximumFrameLength + 1)
        var buffer = Data([
            UInt8((oversized >> 24) & 0xff),
            UInt8((oversized >> 16) & 0xff),
            UInt8((oversized >> 8) & 0xff),
            UInt8(oversized & 0xff),
        ])

        #expect(throws: LampPresentationRemoteFrameError.frameTooLarge(Int(oversized))) {
            try LampPresentationRemoteFrameCodec.decodeFrames(from: &buffer)
        }
    }

    @Test("Pairing codes are high entropy, readable, and QR round-trip")
    func pairingCode() throws {
        let code = LampPresentationRemotePairing.generateCode()
        let displayCode = LampPresentationRemotePairing.displayCode(code)
        let payload = try #require(LampPresentationRemotePairing.qrPayload(for: code))

        #expect(code.count == 16)
        #expect(displayCode.split(separator: "–").map(\.count) == [4, 4, 4, 4])
        #expect(LampPresentationRemotePairing.normalizedCode(displayCode.lowercased()) == code)
        #expect(LampPresentationRemotePairing.code(fromQRPayload: payload) == code)
        #expect(LampPresentationRemotePairing.code(fromQRPayload: "https://example.com") == nil)
    }

    @Test("Secure frames authenticate, fragment, coalesce, and reject a wrong code")
    func secureFraming() throws {
        let code = "ABCD-EFGH-JKLM-NPQR"
        let hello = LampPresentationRemoteMessage.hello(pairingChallenge: "fresh-challenge")
        let pair = LampPresentationRemoteMessage.pair(
            code: "ABCDEFGHJKLMNPQR",
            challenge: "fresh-challenge"
        )
        let first = try LampPresentationRemoteSecureFrameCodec.encode(hello, pairingCode: code)
        let second = try LampPresentationRemoteSecureFrameCodec.encode(pair, pairingCode: code)
        var buffer = Data((first + second).prefix(9))

        #expect(
            try LampPresentationRemoteSecureFrameCodec.decodeFrames(
                from: &buffer,
                pairingCode: code
            ).isEmpty
        )
        buffer.append((first + second).dropFirst(9))
        let decoded = try LampPresentationRemoteSecureFrameCodec.decodeFrames(
            from: &buffer,
            pairingCode: code
        )
        #expect(decoded == [hello, pair])
        #expect(buffer.isEmpty)

        var wrongCodeBuffer = first
        #expect(throws: LampPresentationRemoteSecureFrameError.authenticationFailed) {
            try LampPresentationRemoteSecureFrameCodec.decodeFrames(
                from: &wrongCodeBuffer,
                pairingCode: "2345-6789-ABCD-EFGH"
            )
        }
    }
}
