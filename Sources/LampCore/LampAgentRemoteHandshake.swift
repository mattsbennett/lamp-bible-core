import CryptoKit
import Foundation

public enum LampAgentRemoteError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case malformedHandshake
    /// No key the host holds made the device's proof: a device it has
    /// forgotten, a pairing code that has expired, or someone guessing.
    case unknownDevice
    case authenticationFailed
    case frameTooLarge(Int)
    case invalidMessage
    case counterExhausted
}

/// What a host says first, in the clear, the moment a device connects.
public struct LampAgentRemoteHello: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    /// The host's X25519 public key for this connection only, base64.
    public var ephemeralKey: String
    /// 32 random bytes, base64, fresh for this connection.
    public var nonce: String
    /// Lets a device that has paired before tell which saved key to use,
    /// without the host sending anything that stays the same between
    /// connections. See `LampAgentRemoteHandshake.hostHint(secret:nonce:)`.
    public var hostHint: String?

    public init(protocolVersion: Int = LampAgentRemoteProtocol.currentVersion, ephemeralKey: String, nonce: String, hostHint: String? = nil) {
        self.protocolVersion = protocolVersion
        self.ephemeralKey = ephemeralKey
        self.nonce = nonce
        self.hostHint = hostHint
    }
}

/// The device's answer, also in the clear: its own key for this connection,
/// and proof that it holds a key the host gave it.
public struct LampAgentRemoteAuth: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var ephemeralKey: String
    public var nonce: String
    /// An HMAC over the handshake under a key derived from both the
    /// connection's shared secret and the device's long-lived key, so it
    /// proves the device holds that key without letting anyone who watched
    /// the handshake test guesses at it.
    public var proof: String

    public init(protocolVersion: Int = LampAgentRemoteProtocol.currentVersion, ephemeralKey: String, nonce: String, proof: String) {
        self.protocolVersion = protocolVersion
        self.ephemeralKey = ephemeralKey
        self.nonce = nonce
        self.proof = proof
    }
}

/// The key a host mints for a device when it pairs, by which that device
/// proves itself on every later connection.
///
/// As sensitive as a password: the device keeps it in its Keychain, on that
/// device only, and the host in its own. Never in the library, which syncs.
public struct LampAgentRemoteDeviceCredential: Codable, Equatable, Sendable, Identifiable {
    public var deviceID: String
    /// 32 random bytes, base64.
    public var deviceKey: String

    public var id: String { deviceID }

    public init(deviceID: String, deviceKey: String) {
        self.deviceID = deviceID
        self.deviceKey = deviceKey
    }

    public static func generate() -> Self {
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return Self(deviceID: UUID().uuidString, deviceKey: key.base64EncodedString())
    }
}

/// A key both sides hold before a connection opens: the code a device read
/// from the host's pairing QR, or the device key it was given then.
public struct LampAgentRemoteCredential: Sendable {
    public enum Kind: Equatable, Sendable {
        case pairing
        case device(id: String)
    }

    public let kind: Kind
    let key: SymmetricKey

    /// A pairing code, in the presentation remote's alphabet: 80 bits.
    public static func pairing(code: String) -> Self? {
        guard let code = LampPresentationRemotePairing.normalizedCode(code) else { return nil }
        let material = Data("lamp-agent-remote-pair-v1:\(code)".utf8)
        return Self(kind: .pairing, key: SymmetricKey(data: SHA256.hash(data: material)))
    }

    public static func device(_ credential: LampAgentRemoteDeviceCredential) -> Self? {
        guard let data = Data(base64Encoded: credential.deviceKey), data.count >= 32 else { return nil }
        return Self(kind: .device(id: credential.deviceID), key: SymmetricKey(data: data))
    }
}

/// How a connection agrees its keys.
///
/// Each side makes an X25519 key pair for this connection alone and throws
/// it away after, so the connection's keys can't be recovered later from
/// anything either side keeps: a device key stolen next year does not open
/// a recording of today's chat. That is what the presentation remote gave
/// up for convenience, and a chat, which carries a person's writing and
/// drives tools on their Mac, can't.
///
/// The shared secret alone would let anyone in between agree keys with each
/// side, so the device's long-lived key is mixed into the derivation: only
/// someone who holds it can make the proof the host checks, and only a host
/// that holds it can seal the `accepted` that the device opens. The host
/// tries each key it holds against the proof, so the device never names
/// itself in the clear.
///
/// Messages: host `hello` → device `auth` → host sealed `accepted`, then
/// sealed messages both ways.
///
/// Two rules the code here can't enforce, so each side must:
/// - **A pairing code pairs once.** The host stops offering it as a
///   candidate after the `accepted` that hands out a device key, and after a
///   few failed proofs while its QR is showing, and shows a new one.
/// - **The device trusts nothing before `accepted`.** Its first sealed
///   message from the host must be `accepted`; anything else, or a frame
///   that fails to open, is a failed connection.
public enum LampAgentRemoteHandshake {
    static let context = Data("lamp-agent-remote-v1".utf8)
    static let nonceLength = 32

    /// The host's half of a connection that has just opened.
    public struct HostStart: Sendable {
        public let hello: LampAgentRemoteHello
        let privateKey: Curve25519.KeyAgreement.PrivateKey
    }

    /// What the host sends first. `hostSecret` is its long-lived secret,
    /// from which the hint is made; nil before any device has paired.
    public static func hostStart(hostSecret: String?) -> HostStart {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let nonce = randomBytes(nonceLength).base64EncodedString()
        let hello = LampAgentRemoteHello(
            ephemeralKey: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            nonce: nonce,
            hostHint: hostSecret.flatMap { hostHint(secret: $0, nonce: nonce) }
        )
        return HostStart(hello: hello, privateKey: privateKey)
    }

    /// The device's answer to a host's hello, and the channel it will use
    /// once the host's `accepted` opens under it.
    public static func respond(
        to hello: LampAgentRemoteHello,
        with credential: LampAgentRemoteCredential
    ) throws -> (auth: LampAgentRemoteAuth, channel: LampAgentRemoteSecureChannel) {
        guard hello.protocolVersion == LampAgentRemoteProtocol.currentVersion else {
            throw LampAgentRemoteError.unsupportedVersion(hello.protocolVersion)
        }
        let hostKey = try publicKey(hello.ephemeralKey)
        let hostNonce = try nonce(hello.nonce)
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let clientNonce = randomBytes(nonceLength)
        let transcript = transcriptHash(
            hostKey: hostKey.rawRepresentation, hostNonce: hostNonce,
            clientKey: privateKey.publicKey.rawRepresentation, clientNonce: clientNonce
        )
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: hostKey)
        let keys = derive(shared: shared, credential: credential.key, transcript: transcript)
        let proof = HMAC<SHA256>.authenticationCode(for: transcript, using: keys.confirm)
        let auth = LampAgentRemoteAuth(
            ephemeralKey: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            nonce: clientNonce.base64EncodedString(),
            proof: Data(proof).base64EncodedString()
        )
        return (auth, LampAgentRemoteSecureChannel(sendKey: keys.deviceToHost, receiveKey: keys.hostToDevice))
    }

    /// The host's check of a device's answer, against every key it would
    /// accept: each paired device's, and the pairing code while its QR is
    /// showing. Returns the one that made the proof.
    public static func accept(
        _ auth: LampAgentRemoteAuth,
        start: HostStart,
        candidates: [LampAgentRemoteCredential]
    ) throws -> (credential: LampAgentRemoteCredential, channel: LampAgentRemoteSecureChannel) {
        guard auth.protocolVersion == LampAgentRemoteProtocol.currentVersion else {
            throw LampAgentRemoteError.unsupportedVersion(auth.protocolVersion)
        }
        let clientKey = try publicKey(auth.ephemeralKey)
        let clientNonce = try nonce(auth.nonce)
        guard let proof = Data(base64Encoded: auth.proof) else { throw LampAgentRemoteError.malformedHandshake }
        let transcript = transcriptHash(
            hostKey: start.privateKey.publicKey.rawRepresentation, hostNonce: try nonce(start.hello.nonce),
            clientKey: clientKey.rawRepresentation, clientNonce: clientNonce
        )
        let shared = try start.privateKey.sharedSecretFromKeyAgreement(with: clientKey)
        for credential in candidates {
            let keys = derive(shared: shared, credential: credential.key, transcript: transcript)
            // Compared through CryptoKit, in the same time whether or not it
            // matches.
            if HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: transcript, using: keys.confirm) {
                return (credential, LampAgentRemoteSecureChannel(sendKey: keys.hostToDevice, receiveKey: keys.deviceToHost))
            }
        }
        throw LampAgentRemoteError.unknownDevice
    }

    // MARK: - Recognising a host

    /// A host's long-lived secret, 32 random bytes. It identifies the host to
    /// the devices it has paired, and is never a key for traffic.
    public static func generateHostSecret() -> String {
        randomBytes(32).base64EncodedString()
    }

    /// An HMAC of the hello's fresh nonce under the host's secret: different
    /// on every connection, so nobody watching can tell it is the same Mac as
    /// yesterday, while a device holding the secret can. Recognition only:
    /// what proves anything is the handshake.
    public static func hostHint(secret: String, nonce: String) -> String? {
        guard let key = secretKey(secret), !nonce.isEmpty else { return nil }
        return Data(HMAC<SHA256>.authenticationCode(for: Data(nonce.utf8), using: key)).base64EncodedString()
    }

    public static func hostMatches(secret: String, hint: String, nonce: String) -> Bool {
        guard let key = secretKey(secret), !nonce.isEmpty, let offered = Data(base64Encoded: hint) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(offered, authenticating: Data(nonce.utf8), using: key)
    }

    // MARK: - Pairing QR

    public static func qrPayload(for code: String) -> String? {
        guard let code = LampPresentationRemotePairing.normalizedCode(code) else { return nil }
        var components = URLComponents()
        components.scheme = "lampbible"
        components.host = "agent-remote"
        components.queryItems = [
            URLQueryItem(name: "v", value: String(LampAgentRemoteProtocol.currentVersion)),
            URLQueryItem(name: "code", value: code),
        ]
        return components.url?.absoluteString
    }

    public static func code(fromQRPayload payload: String) -> String? {
        guard let components = URLComponents(string: payload),
              components.scheme?.lowercased() == "lampbible",
              components.host?.lowercased() == "agent-remote",
              components.queryItems?.first(where: { $0.name == "v" })?.value
                == String(LampAgentRemoteProtocol.currentVersion),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        else { return nil }
        return LampPresentationRemotePairing.normalizedCode(code)
    }

    // MARK: - Derivation

    struct Keys {
        let deviceToHost: SymmetricKey
        let hostToDevice: SymmetricKey
        let confirm: SymmetricKey
    }

    /// Everything both sides said in the handshake, so a key agreed over one
    /// exchange can't be passed off as another's.
    static func transcriptHash(hostKey: Data, hostNonce: Data, clientKey: Data, clientNonce: Data) -> Data {
        var hash = SHA256()
        hash.update(data: context)
        hash.update(data: Data([UInt8(LampAgentRemoteProtocol.currentVersion)]))
        hash.update(data: hostKey)
        hash.update(data: hostNonce)
        hash.update(data: clientKey)
        hash.update(data: clientNonce)
        return Data(hash.finalize())
    }

    /// HKDF over the shared secret, salted with the transcript under the
    /// long-lived key, so the keys need both the connection's secret and
    /// that key.
    static func derive(shared: SharedSecret, credential: SymmetricKey, transcript: Data) -> Keys {
        let salt = Data(HMAC<SHA256>.authenticationCode(for: transcript, using: credential))
        let material = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: context + Data(" keys".utf8),
            outputByteCount: 96
        ).withUnsafeBytes { Data($0) }
        return Keys(
            deviceToHost: SymmetricKey(data: material.prefix(32)),
            hostToDevice: SymmetricKey(data: material.dropFirst(32).prefix(32)),
            confirm: SymmetricKey(data: material.suffix(32))
        )
    }

    static func publicKey(_ base64: String) throws -> Curve25519.KeyAgreement.PublicKey {
        guard let data = Data(base64Encoded: base64),
              let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: data)
        else { throw LampAgentRemoteError.malformedHandshake }
        return key
    }

    static func nonce(_ base64: String) throws -> Data {
        guard let data = Data(base64Encoded: base64), data.count == nonceLength else {
            throw LampAgentRemoteError.malformedHandshake
        }
        return data
    }

    static func secretKey(_ secret: String) -> SymmetricKey? {
        guard let data = Data(base64Encoded: secret), data.count >= 16 else { return nil }
        return SymmetricKey(data: data)
    }

    static func randomBytes(_ count: Int) -> Data {
        SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }
}

/// Sealing and opening a connection's messages after the handshake.
///
/// One key each way, and a counter each way as the nonce, so a frame
/// replayed, dropped or put out of order fails to open rather than being
/// read twice or in the wrong place. A frame that fails to open leaves the
/// connection untrustworthy: close it.
///
/// A class, with its counters behind a lock, because the nonce must never
/// repeat under a key: two copies of a value sealing on their own would each
/// count from the same place, and two messages sealed under one nonce give
/// each other away. Every reference to a channel shares its one count.
public final class LampAgentRemoteSecureChannel: @unchecked Sendable {
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private let lock = NSLock()
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    private static let associatedData = Data("lamp-agent-remote-v1 frame".utf8)
    private static let maximumSealedFrameLength = LampAgentRemoteProtocol.maximumFrameLength + 64

    init(sendKey: SymmetricKey, receiveKey: SymmetricKey) {
        self.sendKey = sendKey
        self.receiveKey = receiveKey
    }

    public func seal(_ message: LampAgentRemoteMessage) throws -> Data {
        let payload = try LampAgentRemoteFraming.encodeJSON(message)
        guard payload.count <= LampAgentRemoteProtocol.maximumFrameLength else {
            throw LampAgentRemoteError.frameTooLarge(payload.count)
        }
        // Taken and sealed under the lock, so frames go out in the order of
        // their counters, which is the order the other side opens them in.
        lock.lock()
        defer { lock.unlock() }
        guard sendCounter < .max else { throw LampAgentRemoteError.counterExhausted }
        let nonce = try Self.nonce(sendCounter)
        sendCounter += 1
        let sealed = try ChaChaPoly.seal(payload, using: sendKey, nonce: nonce, authenticating: Self.associatedData)
        // The nonce is the counter both sides keep, so only the ciphertext
        // and tag travel.
        return LampAgentRemoteFraming.frame(sealed.ciphertext + sealed.tag)
    }

    /// Opens every complete frame in `buffer`, leaving a partial one there
    /// for the next read.
    public func open(from buffer: inout Data) throws -> [LampAgentRemoteMessage] {
        lock.lock()
        defer { lock.unlock() }
        var messages: [LampAgentRemoteMessage] = []
        while let frame = try LampAgentRemoteFraming.nextFrame(from: &buffer, limit: Self.maximumSealedFrameLength) {
            guard frame.count >= 16 else { throw LampAgentRemoteError.authenticationFailed }
            let payload: Data
            do {
                let box = try ChaChaPoly.SealedBox(
                    nonce: Self.nonce(receiveCounter),
                    ciphertext: frame.dropLast(16),
                    tag: frame.suffix(16)
                )
                payload = try ChaChaPoly.open(box, using: receiveKey, authenticating: Self.associatedData)
            } catch {
                throw LampAgentRemoteError.authenticationFailed
            }
            guard receiveCounter < .max else { throw LampAgentRemoteError.counterExhausted }
            receiveCounter += 1
            guard let message = try? LampAgentRemoteFraming.decoder.decode(LampAgentRemoteMessage.self, from: payload) else {
                throw LampAgentRemoteError.invalidMessage
            }
            messages.append(message)
        }
        return messages
    }

    private static func nonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }
}

/// Length-prefixed frames, and the JSON in them.
public enum LampAgentRemoteFraming {
    static let decoder = JSONDecoder()

    static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        return try encoder.encode(value)
    }

    /// A handshake message, framed, in the clear.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let payload = try encodeJSON(value)
        guard payload.count <= LampAgentRemoteProtocol.maximumFrameLength else {
            throw LampAgentRemoteError.frameTooLarge(payload.count)
        }
        return frame(payload)
    }

    /// The next handshake message in `buffer`, or nil until all of it has
    /// arrived. Takes one frame only, since what follows it is sealed.
    public static func decode<T: Decodable>(_ type: T.Type, from buffer: inout Data) throws -> T? {
        guard let payload = try nextFrame(from: &buffer, limit: LampAgentRemoteProtocol.maximumFrameLength) else {
            return nil
        }
        guard let value = try? decoder.decode(type, from: payload) else {
            throw LampAgentRemoteError.malformedHandshake
        }
        return value
    }

    static func frame(_ payload: Data) -> Data {
        let length = UInt32(payload.count)
        return Data([
            UInt8((length >> 24) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff),
        ]) + payload
    }

    static func nextFrame(from buffer: inout Data, limit: Int) throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length <= limit else { throw LampAgentRemoteError.frameTooLarge(length) }
        guard buffer.count >= length + 4 else { return nil }
        let payload = Data(buffer.dropFirst(4).prefix(length))
        buffer.removeFirst(length + 4)
        return payload
    }
}
