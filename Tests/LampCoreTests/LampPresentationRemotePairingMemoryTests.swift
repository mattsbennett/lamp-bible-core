import Foundation
import Testing
@testable import LampCore

/// Remembering a device that has paired once.
///
/// A presenter that recognises a returning remote has turned a one-time QR
/// code into a lasting secret, so what is tested here is mostly what must
/// *not* happen: nothing that stays the same between connections goes out in
/// the clear, a hint tells an onlooker nothing, and recognising a device is
/// never the same as letting it in.
@Suite("Remembered remote pairing")
struct LampPresentationRemotePairingMemoryTests {
    @Test("A presenter's hint changes with every challenge")
    func hintChangesPerChallenge() throws {
        let secret = LampPresentationRemotePairing.generatePresenterSecret()
        let hints = (0..<8).map { _ in
            LampPresentationRemotePairing.presenterHint(
                secret: secret,
                challenge: LampPresentationRemotePairing.generateChallenge()
            )
        }
        #expect(hints.allSatisfy { $0 != nil })
        #expect(
            Set(hints.compactMap { $0 }).count == hints.count,
            "a hint that repeated would let an onlooker link two sightings of one Mac"
        )
    }

    @Test("A device that holds the secret recognises the presenter")
    func aPairedDeviceRecognisesIt() throws {
        let secret = LampPresentationRemotePairing.generatePresenterSecret()
        let challenge = LampPresentationRemotePairing.generateChallenge()
        let hint = try #require(
            LampPresentationRemotePairing.presenterHint(secret: secret, challenge: challenge)
        )
        #expect(LampPresentationRemotePairing.presenterMatches(
            secret: secret, hint: hint, challenge: challenge
        ))
    }

    @Test("Another presenter's secret does not match")
    func anotherPresenterDoesNotMatch() throws {
        let challenge = LampPresentationRemotePairing.generateChallenge()
        let mine = LampPresentationRemotePairing.generatePresenterSecret()
        let theirs = LampPresentationRemotePairing.generatePresenterSecret()
        let hint = try #require(
            LampPresentationRemotePairing.presenterHint(secret: mine, challenge: challenge)
        )
        #expect(!LampPresentationRemotePairing.presenterMatches(
            secret: theirs, hint: hint, challenge: challenge
        ))
    }

    /// The hint is bound to the challenge it was made for, so a hint seen on
    /// one connection proves nothing on the next.
    @Test("A hint from one challenge does not match another")
    func aHintIsBoundToItsChallenge() throws {
        let secret = LampPresentationRemotePairing.generatePresenterSecret()
        let first = LampPresentationRemotePairing.generateChallenge()
        let second = LampPresentationRemotePairing.generateChallenge()
        let hint = try #require(
            LampPresentationRemotePairing.presenterHint(secret: secret, challenge: first)
        )
        #expect(!LampPresentationRemotePairing.presenterMatches(
            secret: secret, hint: hint, challenge: second
        ))
    }

    @Test("Rubbish offered as a hint is refused rather than crashing")
    func rubbishIsRefused() throws {
        let secret = LampPresentationRemotePairing.generatePresenterSecret()
        let challenge = LampPresentationRemotePairing.generateChallenge()
        for hint in ["", "not base64 at all!!", "AAAA", String(repeating: "A", count: 10_000)] {
            #expect(!LampPresentationRemotePairing.presenterMatches(
                secret: secret, hint: hint, challenge: challenge
            ))
        }
        #expect(LampPresentationRemotePairing.presenterHint(secret: secret, challenge: "") == nil)
        #expect(LampPresentationRemotePairing.presenterHint(secret: "", challenge: challenge) == nil)
    }

    /// A device code is a frame key, so it has to be the same shape as the
    /// session code the codec already takes.
    @Test("A minted device code is usable as a frame key")
    func aDeviceCodeIsAFrameKey() throws {
        let deviceCode = LampPresentationRemotePairing.generateCode()
        #expect(LampPresentationRemotePairing.normalizedCode(deviceCode) == deviceCode)

        let message = LampPresentationRemoteMessage.command(.init(action: .next))
        let frame = try LampPresentationRemoteSecureFrameCodec.encode(
            message, pairingCode: deviceCode
        )
        var buffer = frame
        let decoded = try LampPresentationRemoteSecureFrameCodec.decodeFrames(
            from: &buffer, pairingCode: deviceCode
        )
        #expect(decoded == [message])
    }

    /// What is minted at first pairing travels inside `accepted`, which is
    /// already sealed under the session code. This is the one test that would
    /// fail if either were ever moved onto a public frame.
    @Test("What is minted at pairing is only readable under the session code")
    func mintedMaterialIsSealed() throws {
        let sessionCode = LampPresentationRemotePairing.generateCode()
        let deviceCode = LampPresentationRemotePairing.generateCode()
        let secret = LampPresentationRemotePairing.generatePresenterSecret()
        let accepted = LampPresentationRemoteMessage.accepted(
            deviceCode: deviceCode, presenterSecret: secret
        )
        let frame = try LampPresentationRemoteSecureFrameCodec.encode(
            accepted, pairingCode: sessionCode
        )

        #expect(
            !String(decoding: frame, as: UTF8.self).contains(deviceCode),
            "the device's code must not be readable in the frame that carries it"
        )
        #expect(!String(decoding: frame, as: UTF8.self).contains(secret))

        var mine = frame
        let decoded = try LampPresentationRemoteSecureFrameCodec.decodeFrames(
            from: &mine, pairingCode: sessionCode
        )
        #expect(decoded.first?.deviceCode == deviceCode)
        #expect(decoded.first?.presenterSecret == secret)

        var theirs = frame
        #expect(throws: LampPresentationRemoteSecureFrameError.authenticationFailed) {
            _ = try LampPresentationRemoteSecureFrameCodec.decodeFrames(
                from: &theirs, pairingCode: LampPresentationRemotePairing.generateCode()
            )
        }
    }

    /// Both ways, so neither app needs a version bump: an older peer's
    /// messages still decode here, and what this one sends still decodes
    /// where the new fields are unknown.
    @Test("An older peer's messages still decode, and this one's still read")
    func bothDirectionsDecode() throws {
        let old = Data(#"{"kind":"accepted","protocolVersion":2}"#.utf8)
        let decoded = try JSONDecoder().decode(LampPresentationRemoteMessage.self, from: old)
        #expect(decoded.kind == .accepted)
        #expect(decoded.deviceCode == nil)
        #expect(decoded.presenterSecret == nil)
        #expect(decoded.presenterHint == nil)

        // An old build ignores keys it does not know, which is what makes the
        // new fields safe to add without a version bump.
        let newer = Data(
            #"{"kind":"hello","protocolVersion":2,"presenterHint":"abc","somethingLater":1}"#.utf8
        )
        let read = try JSONDecoder().decode(LampPresentationRemoteMessage.self, from: newer)
        #expect(read.presenterHint == "abc")
    }

    @Test("A remembered remote carries what a person needs to recognise it")
    func aTrustedRemoteIsRecognisable() throws {
        let remote = LampPresentationTrustedRemote(
            deviceCode: LampPresentationRemotePairing.generateCode(),
            clientName: "Matthew's iPhone"
        )
        let data = try JSONEncoder().encode(remote)
        let back = try JSONDecoder().decode(LampPresentationTrustedRemote.self, from: data)
        #expect(back == remote)
        #expect(back.id == remote.deviceCode)
    }
}
