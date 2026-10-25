import CryptoKit
import Foundation

/// The shared, versioned contract used by a Lamp presenter and its remotes.
///
/// Messages are JSON wrapped in four-byte, big-endian length-prefixed frames.
/// Only the fresh pairing challenge uses the public frame codec; pairing proof
/// and session traffic use authenticated encryption. Both codecs keep framing
/// independent from Network.framework and make fragmented or coalesced TCP
/// reads deterministic on every platform.
public enum LampPresentationRemoteProtocol {
    public static let currentVersion = 2
    public static let bonjourServiceType = "_lamp-present._tcp"
    public static let maximumFrameLength = 4 * 1_024 * 1_024
}

public struct LampPresentationRemoteMessage: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case hello
        case pair
        case accepted
        case rejected
        case command
        case state
        case ping
        case pong
    }

    public var protocolVersion: Int
    public var kind: Kind
    public var clientName: String?
    public var pairingCode: String?
    public var pairingChallenge: String?
    public var command: LampPresentationRemoteCommand?
    public var state: LampPresentationRemoteState?
    public var errorMessage: String?
    /// A code of this device's own, minted by the presenter when it first
    /// pairs so the device is not asked for the QR code again.
    ///
    /// Only ever sent inside `accepted`, which is already sealed under the
    /// session code, so it is never in the clear. A device sends it back as
    /// `pairingCode` on a later connection.
    ///
    /// It is that device's key for every session it ever has, so this
    /// channel has no forward secrecy: someone who later obtained a code
    /// could read recordings of that remote's past sessions. For moving
    /// between slides that is a fair trade for not pairing every time. It
    /// would not be one for anything worth recording, so this channel should
    /// not be reused for anything else without changing that.
    public var deviceCode: String?
    /// The presenter's long-lived secret, shared with every device it has
    /// paired so that a returning device can recognise it. Also only ever
    /// sent inside `accepted`.
    public var presenterSecret: String?
    /// Lets a device that has paired before recognise this presenter without
    /// the presenter broadcasting anything that stays the same between
    /// connections. Carried on the public challenge; see
    /// `LampPresentationRemotePairing.presenterHint(secret:challenge:)`.
    public var presenterHint: String?

    public init(
        protocolVersion: Int = LampPresentationRemoteProtocol.currentVersion,
        kind: Kind,
        clientName: String? = nil,
        pairingCode: String? = nil,
        pairingChallenge: String? = nil,
        command: LampPresentationRemoteCommand? = nil,
        state: LampPresentationRemoteState? = nil,
        errorMessage: String? = nil,
        deviceCode: String? = nil,
        presenterSecret: String? = nil,
        presenterHint: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.kind = kind
        self.clientName = clientName
        self.pairingCode = pairingCode
        self.pairingChallenge = pairingChallenge
        self.command = command
        self.state = state
        self.errorMessage = errorMessage
        self.deviceCode = deviceCode
        self.presenterSecret = presenterSecret
        self.presenterHint = presenterHint
    }

    public static func hello(
        clientName: String? = nil,
        pairingChallenge: String? = nil,
        presenterHint: String? = nil
    ) -> Self {
        .init(
            kind: .hello,
            clientName: clientName,
            pairingChallenge: pairingChallenge,
            presenterHint: presenterHint
        )
    }

    public static func pair(code: String, challenge: String) -> Self {
        .init(kind: .pair, pairingCode: code, pairingChallenge: challenge)
    }

    public static func accepted(
        deviceCode: String? = nil,
        presenterSecret: String? = nil
    ) -> Self {
        .init(kind: .accepted, deviceCode: deviceCode, presenterSecret: presenterSecret)
    }

    public static func rejected(_ message: String) -> Self {
        .init(kind: .rejected, errorMessage: message)
    }

    public static func command(_ command: LampPresentationRemoteCommand) -> Self {
        .init(kind: .command, command: command)
    }

    public static func state(_ state: LampPresentationRemoteState) -> Self {
        .init(kind: .state, state: state)
    }
}

public struct LampPresentationRemoteCommand: Codable, Equatable, Sendable {
    public enum Action: String, Codable, CaseIterable, Sendable {
        case next
        case previous
        case first
        case last
        case goTo = "go-to"
        case toggleBlackout = "toggle-blackout"
        case showBlackout = "show-blackout"
        case hideBlackout = "hide-blackout"
        case toggleNotes = "toggle-notes"
    }

    public var action: Action
    public var slideIndex: Int?

    public init(action: Action, slideIndex: Int? = nil) {
        self.action = action
        self.slideIndex = slideIndex
    }
}

public struct LampPresentationRemoteSlideReference: Codable, Equatable, Identifiable, Sendable {
    public var index: Int
    public var id: String
    public var title: String

    public init(index: Int, id: String, title: String) {
        self.index = index
        self.id = id
        self.title = title
    }
}

public struct LampPresentationRemoteState: Codable, Equatable, Sendable {
    public var deckID: String
    public var deckTitle: String
    public var aspectRatio: LampPresentationAspectRatio
    public var theme: LampPresentationTheme
    public var currentSlideIndex: Int
    public var slideCount: Int
    public var slideReferences: [LampPresentationRemoteSlideReference]
    public var currentSlide: LampPresentationSlide?
    public var nextSlide: LampPresentationSlide?
    public var elapsedSeconds: Int
    public var isBlackout: Bool
    public var canGoPrevious: Bool
    public var canGoNext: Bool

    public init(
        deckID: String,
        deckTitle: String,
        aspectRatio: LampPresentationAspectRatio,
        theme: LampPresentationTheme,
        currentSlideIndex: Int,
        slideCount: Int,
        slideReferences: [LampPresentationRemoteSlideReference],
        currentSlide: LampPresentationSlide?,
        nextSlide: LampPresentationSlide?,
        elapsedSeconds: Int,
        isBlackout: Bool,
        canGoPrevious: Bool,
        canGoNext: Bool
    ) {
        self.deckID = deckID
        self.deckTitle = deckTitle
        self.aspectRatio = aspectRatio
        self.theme = theme
        self.currentSlideIndex = currentSlideIndex
        self.slideCount = slideCount
        self.slideReferences = slideReferences
        self.currentSlide = currentSlide
        self.nextSlide = nextSlide
        self.elapsedSeconds = elapsedSeconds
        self.isBlackout = isBlackout
        self.canGoPrevious = canGoPrevious
        self.canGoNext = canGoNext
    }
}

public enum LampPresentationRemoteFrameError: Error, Equatable, Sendable {
    case frameTooLarge(Int)
    case invalidMessage
}

public enum LampPresentationRemoteFrameCodec {
    public static func encode(
        _ message: LampPresentationRemoteMessage,
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> Data {
        encoder.outputFormatting.insert(.sortedKeys)
        let payload = try encoder.encode(message)
        guard payload.count <= LampPresentationRemoteProtocol.maximumFrameLength else {
            throw LampPresentationRemoteFrameError.frameTooLarge(payload.count)
        }

        let length = UInt32(payload.count)
        let header = Data([
            UInt8((length >> 24) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff),
        ])
        return header + payload
    }

    /// Removes and decodes every complete frame, leaving a partial frame in
    /// `buffer` for the next transport read.
    public static func decodeFrames(
        from buffer: inout Data,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> [LampPresentationRemoteMessage] {
        var messages: [LampPresentationRemoteMessage] = []

        while buffer.count >= 4 {
            let bytes = buffer.prefix(4)
            let frameLength = bytes.reduce(0) { ($0 << 8) | Int($1) }
            guard frameLength <= LampPresentationRemoteProtocol.maximumFrameLength else {
                throw LampPresentationRemoteFrameError.frameTooLarge(frameLength)
            }
            guard buffer.count >= frameLength + 4 else { break }

            let payload = Data(buffer.dropFirst(4).prefix(frameLength))
            buffer.removeFirst(frameLength + 4)
            guard let message = try? decoder.decode(LampPresentationRemoteMessage.self, from: payload) else {
                throw LampPresentationRemoteFrameError.invalidMessage
            }
            messages.append(message)
        }

        return messages
    }
}

/// Session-scoped pairing material suitable for QR transfer or manual entry.
///
/// The alphabet excludes commonly confused characters while preserving five
/// bits of entropy per character. A 16-character code therefore carries 80
/// bits of random key material.
public enum LampPresentationRemotePairing {
    public static let codeLength = 16
    public static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    public static func generateCode() -> String {
        String((0..<codeLength).compactMap { _ in alphabet.randomElement() })
    }

    public static func sanitizedCode(_ code: String) -> String {
        let allowed = Set(alphabet)
        return String(
            code.uppercased()
                .filter { allowed.contains($0) }
                .prefix(codeLength)
        )
    }

    public static func normalizedCode(_ code: String) -> String? {
        let sanitized = sanitizedCode(code)
        return sanitized.count == codeLength ? sanitized : nil
    }

    public static func displayCode(_ code: String) -> String {
        let sanitized = sanitizedCode(code)
        return stride(from: 0, to: sanitized.count, by: 4)
            .map { offset in
                let start = sanitized.index(sanitized.startIndex, offsetBy: offset)
                let end = sanitized.index(start, offsetBy: min(4, sanitized.distance(from: start, to: sanitized.endIndex)))
                return String(sanitized[start..<end])
            }
            .joined(separator: "–")
    }

    public static func qrPayload(for code: String) -> String? {
        guard let code = normalizedCode(code) else { return nil }
        var components = URLComponents()
        components.scheme = "lampbible"
        components.host = "presentation-remote"
        components.queryItems = [
            URLQueryItem(name: "v", value: String(LampPresentationRemoteProtocol.currentVersion)),
            URLQueryItem(name: "code", value: code),
        ]
        return components.url?.absoluteString
    }

    public static func code(fromQRPayload payload: String) -> String? {
        guard let components = URLComponents(string: payload),
              components.scheme?.lowercased() == "lampbible",
              components.host?.lowercased() == "presentation-remote",
              components.queryItems?.first(where: { $0.name == "v" })?.value
                == String(LampPresentationRemoteProtocol.currentVersion),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            return nil
        }
        return normalizedCode(code)
    }

    public static func generateChallenge(byteCount: Int = 24) -> String {
        let bytes = (0..<max(16, byteCount)).map { _ in UInt8.random(in: .min ... .max) }
        return Data(bytes).base64EncodedString()
    }

    /// A presenter's long-lived secret, 32 random bytes.
    ///
    /// It identifies the presenter to the devices it has paired and nothing
    /// else: it is never a key for traffic, and knowing it does not let
    /// anyone connect. It belongs in the presenter's keychain, never in the
    /// library — a synced file of pairing material would hand every remote's
    /// key to the sync server.
    public static func generatePresenterSecret(byteCount: Int = 32) -> String {
        Data((0..<max(16, byteCount)).map { _ in UInt8.random(in: .min ... .max) })
            .base64EncodedString()
    }

    /// What a presenter puts on its public challenge so that a device it has
    /// paired can tell which saved code to offer.
    ///
    /// It is an HMAC over the challenge, which is fresh for every connection,
    /// so the hint is different every time: someone watching the network sees
    /// no value that would let them say "that is the same Mac as yesterday".
    /// A device that holds the secret recomputes it; a device that does not
    /// learns nothing, because the secret cannot be recovered from the hint.
    ///
    /// **Matching a hint is recognition, not authentication.** It only
    /// decides which code to try. What proves a device may connect is still
    /// the pairing proof, sealed under that code and bound to this same fresh
    /// challenge.
    public static func presenterHint(secret: String, challenge: String) -> String? {
        guard let key = presenterKey(secret), !challenge.isEmpty else { return nil }
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(challenge.utf8),
            using: key
        )
        return Data(code).base64EncodedString()
    }

    /// Whether `hint` is the one this secret makes for this challenge.
    ///
    /// Compared through CryptoKit, which takes the same time whether or not
    /// it matches, so the comparison itself says nothing about the secret.
    public static func presenterMatches(
        secret: String,
        hint: String,
        challenge: String
    ) -> Bool {
        guard let key = presenterKey(secret),
              !challenge.isEmpty,
              let offered = Data(base64Encoded: hint)
        else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            offered,
            authenticating: Data(challenge.utf8),
            using: key
        )
    }

    private static func presenterKey(_ secret: String) -> SymmetricKey? {
        guard let data = Data(base64Encoded: secret), data.count >= 16 else { return nil }
        return SymmetricKey(data: data)
    }
}

/// A device a presenter has paired and will recognise again.
///
/// `deviceCode` is that device's key for every frame it sends, so this record
/// is as sensitive as a password: it belongs in the presenter's keychain, and
/// never in the library, which syncs.
public struct LampPresentationTrustedRemote: Codable, Equatable, Sendable, Identifiable {
    /// The code minted for this device, which is also its frame key.
    public var deviceCode: String
    /// What the device called itself when it paired, to be shown in a list
    /// someone forgets a remote from. Chosen by the device, so it is a label,
    /// never something to decide anything by.
    public var clientName: String?
    public var pairedAt: Date

    public var id: String { deviceCode }

    public init(deviceCode: String, clientName: String? = nil, pairedAt: Date = Date()) {
        self.deviceCode = deviceCode
        self.clientName = clientName
        self.pairedAt = pairedAt
    }
}

public enum LampPresentationRemoteSecureFrameError: Error, Equatable, Sendable {
    case invalidPairingCode
    case frameTooLarge(Int)
    case authenticationFailed
    case invalidMessage
}

/// Authenticated encryption for post-discovery pairing and presenter traffic.
///
/// Bonjour remains discovery-only. Knowledge of the session's 80-bit pairing
/// code is required to authenticate and decrypt each ChaCha20-Poly1305 frame.
public enum LampPresentationRemoteSecureFrameCodec {
    private static let authenticationContext = Data("lamp-presentation-remote-v2".utf8)
    private static let maximumEncryptedFrameLength =
        LampPresentationRemoteProtocol.maximumFrameLength + 128

    public static func encode(
        _ message: LampPresentationRemoteMessage,
        pairingCode: String,
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> Data {
        let key = try key(for: pairingCode)
        encoder.outputFormatting.insert(.sortedKeys)
        let payload = try encoder.encode(message)
        guard payload.count <= LampPresentationRemoteProtocol.maximumFrameLength else {
            throw LampPresentationRemoteSecureFrameError.frameTooLarge(payload.count)
        }

        let sealed = try ChaChaPoly.seal(
            payload,
            using: key,
            authenticating: authenticationContext
        )
        let encrypted = sealed.combined
        guard encrypted.count <= maximumEncryptedFrameLength else {
            throw LampPresentationRemoteSecureFrameError.frameTooLarge(encrypted.count)
        }
        return frame(encrypted)
    }

    public static func decodeFrames(
        from buffer: inout Data,
        pairingCode: String,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> [LampPresentationRemoteMessage] {
        let key = try key(for: pairingCode)
        var messages: [LampPresentationRemoteMessage] = []

        while buffer.count >= 4 {
            let frameLength = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard frameLength <= maximumEncryptedFrameLength else {
                throw LampPresentationRemoteSecureFrameError.frameTooLarge(frameLength)
            }
            guard buffer.count >= frameLength + 4 else { break }

            let encrypted = Data(buffer.dropFirst(4).prefix(frameLength))
            buffer.removeFirst(frameLength + 4)
            let payload: Data
            do {
                let sealed = try ChaChaPoly.SealedBox(combined: encrypted)
                payload = try ChaChaPoly.open(
                    sealed,
                    using: key,
                    authenticating: authenticationContext
                )
            } catch {
                throw LampPresentationRemoteSecureFrameError.authenticationFailed
            }

            guard let message = try? decoder.decode(LampPresentationRemoteMessage.self, from: payload) else {
                throw LampPresentationRemoteSecureFrameError.invalidMessage
            }
            messages.append(message)
        }

        return messages
    }

    private static func key(for pairingCode: String) throws -> SymmetricKey {
        guard let code = LampPresentationRemotePairing.normalizedCode(pairingCode) else {
            throw LampPresentationRemoteSecureFrameError.invalidPairingCode
        }
        let material = Data("lamp-presentation-remote-key-v2:\(code)".utf8)
        return SymmetricKey(data: SHA256.hash(data: material))
    }

    private static func frame(_ payload: Data) -> Data {
        let length = UInt32(payload.count)
        return Data([
            UInt8((length >> 24) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff),
        ]) + payload
    }
}
