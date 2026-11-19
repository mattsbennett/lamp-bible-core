import Foundation

/// A pairing QR on screen: its code, good for one device, and closed after
/// a few proofs that fail under it, so a code read over a shoulder cannot be
/// guessed at for as long as the window stays open.
public struct LampAgentRemotePairingWindow: Equatable, Sendable {
    public let code: String
    public private(set) var failuresLeft: Int
    public private(set) var isClosed = false

    public static let allowedFailures = 5

    public init(code: String = LampPresentationRemotePairing.generateCode(), allowedFailures: Int = Self.allowedFailures) {
        self.code = code
        self.failuresLeft = allowedFailures
    }

    /// The pairing key a device may prove itself with, while the window is
    /// open.
    public var credential: LampAgentRemoteCredential? {
        isClosed ? nil : LampAgentRemoteCredential.pairing(code: code)
    }

    /// A device paired under the code: it is spent.
    public mutating func paired() {
        isClosed = true
    }

    /// A proof that matched no key while the window was open.
    public mutating func failed() {
        guard !isClosed else { return }
        failuresLeft -= 1
        if failuresLeft <= 0 { isClosed = true }
    }
}

/// A host a device has paired with, remembered so it need not pair again:
/// the key the host minted for the device, and the host's secret, by which
/// the device recognises it. The device keeps these in its keychain.
public struct LampAgentRemoteRememberedHost: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// What the host was called when it was paired: a label to forget it by,
    /// never something to decide anything by.
    public var name: String
    public var deviceID: String
    public var deviceKey: String
    public var hostSecret: String
    public var pairedAt: Date

    public init(id: String, name: String, deviceID: String, deviceKey: String, hostSecret: String, pairedAt: Date) {
        self.id = id
        self.name = name
        self.deviceID = deviceID
        self.deviceKey = deviceKey
        self.hostSecret = hostSecret
        self.pairedAt = pairedAt
    }

    public var credential: LampAgentRemoteDeviceCredential {
        LampAgentRemoteDeviceCredential(deviceID: deviceID, deviceKey: deviceKey)
    }

    /// The remembered host whose secret made `hint` for this connection's
    /// nonce. Recognition only: it says which key to answer with, and the
    /// handshake is what proves anything.
    public static func recognising(_ hosts: [Self], hint: String?, nonce: String) -> Self? {
        guard let hint, !hint.isEmpty else { return nil }
        return hosts.first { LampAgentRemoteHandshake.hostMatches(secret: $0.hostSecret, hint: hint, nonce: nonce) }
    }
}

/// A device's side of one connection to a host, as bytes in and effects out:
/// the handshake, pairing, and sealing and opening what follows. No
/// networking and no storage, so both sides can be run against each other.
///
/// The host speaks first. A host the device remembers is answered with the
/// key it gave the device; any other waits for a pairing code from its QR. A
/// remembered key the host turns away (by closing, or by not answering) is
/// forgotten and the device pairs again: that is what forgetting the device
/// on the host comes to. A connection lost to the network is not a refusal,
/// and keeps the key.
///
/// Effects come in the order to act on them. Every `send` must go out before
/// anything after it is acted on: what is sealed on hearing `connected` takes
/// the next number, and must leave after the opening requests.
public struct LampAgentRemoteDeviceConnection {
    /// Why something did not work, for the device to say in its own words.
    public enum Problem: Equatable, Sendable {
        /// The host no longer recognises this device.
        case refused
        /// The host did not accept the pairing code.
        case codeRefused
        /// The host speaks another version of the protocol.
        case otherVersion
        /// The host's reply could not be read.
        case unreadable
        /// The host could not be reached, with the network's own reason.
        case unreachable(String?)
    }

    public enum Effect: Equatable {
        /// Bytes for the host.
        case send(Data)
        /// Ask for the host's pairing code, saying why if anything.
        case needsCode(Problem?)
        /// A remembered key is on offer: give the host a few seconds to
        /// answer, then call `savedKeyTimedOut`.
        case watchSavedKey
        case connected
        /// A message from the host, after `connected`.
        case received(LampAgentRemoteMessage)
        /// Keep this host, in place of anything kept before with the same
        /// secret.
        case remember(LampAgentRemoteRememberedHost)
        /// Forget the remembered host with this id.
        case forget(String)
        /// The remembered key was turned away and is forgotten: connect again
        /// to pair by code.
        case pairAgain
        case failed(Problem)
        /// An established connection ended.
        case lost
    }

    public enum Stage {
        case awaitingHello
        /// No key to answer with yet: the hello is held while someone scans
        /// the host's code.
        case awaitingCode(LampAgentRemoteHello)
        case awaitingAccepted(LampAgentRemoteSecureChannel, offered: LampAgentRemoteRememberedHost?)
        case connected(LampAgentRemoteSecureChannel)
        case closed
    }

    /// The hosts this device remembers, as its keychain held them when the
    /// connection began.
    public let remembered: [LampAgentRemoteRememberedHost]
    /// The name the host goes by, to remember it under.
    public let hostName: String
    public let clientName: String
    /// A code scanned before this connection's hello arrived: the connection
    /// it was scanned for closed while waiting, and this one answers with it.
    public var pendingCode: String?

    public private(set) var stage: Stage = .awaitingHello
    /// The connected host's secret: which host this is, whatever it is
    /// called on the network now — a host renamed, or a name two share, is
    /// told apart by it. Set once `accepted` arrives.
    public private(set) var hostSecret: String?
    private var buffer = Data()
    private let now: () -> Date

    public init(
        remembered: [LampAgentRemoteRememberedHost],
        hostName: String,
        clientName: String,
        pendingCode: String? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.remembered = remembered
        self.hostName = hostName
        self.clientName = clientName
        self.pendingCode = pendingCode
        self.now = now
    }

    public var isConnected: Bool {
        if case .connected = stage { return true }
        return false
    }

    public var isWaitingForCode: Bool {
        if case .awaitingCode = stage { return true }
        return false
    }

    /// The remembered host whose key is on offer, until it is answered.
    public var offered: LampAgentRemoteRememberedHost? {
        if case let .awaitingAccepted(_, offered) = stage { return offered }
        return nil
    }

    public mutating func receive(_ data: Data) -> [Effect] {
        buffer.append(data)
        var effects: [Effect] = []
        do {
            while true {
                switch stage {
                case .awaitingHello:
                    guard let hello = try LampAgentRemoteFraming.decode(LampAgentRemoteHello.self, from: &buffer) else {
                        return effects
                    }
                    effects += self.hello(hello)
                case .awaitingCode:
                    // The host has nothing to say until it is answered, so
                    // anything more is not a host worth waiting on, nor bytes
                    // worth keeping.
                    guard buffer.isEmpty else {
                        stage = .closed
                        buffer = Data()
                        return effects + [.failed(.unreadable)]
                    }
                    return effects
                case .closed:
                    buffer = Data()
                    return effects
                case let .awaitingAccepted(channel, offered):
                    var messages = try channel.open(from: &buffer)
                    guard !messages.isEmpty else { return effects }
                    // Nothing is trusted before `accepted`.
                    let first = messages.removeFirst()
                    guard first.kind == .accepted else {
                        stage = .closed
                        return effects + [.failed(.unreadable)]
                    }
                    effects += accepted(first, offered: offered, channel: channel)
                    effects += messages.flatMap { handle($0, channel: channel) }
                case let .connected(channel):
                    let messages = try channel.open(from: &buffer)
                    return effects + messages.flatMap { handle($0, channel: channel) }
                }
            }
        } catch LampAgentRemoteError.unsupportedVersion {
            stage = .closed
            return effects + [.failed(.otherVersion)]
        } catch {
            return effects + unreadable()
        }
    }

    /// The code from the host's QR, or typed.
    public mutating func pair(code: String) -> [Effect] {
        guard let credential = LampAgentRemoteCredential.pairing(code: code) else { return [] }
        guard case let .awaitingCode(hello) = stage else {
            pendingCode = code
            return []
        }
        return answer(hello, with: credential, offered: nil)
    }

    /// A message for the host, sealed, once connected.
    public mutating func seal(_ message: LampAgentRemoteMessage) -> [Effect] {
        guard case let .connected(channel) = stage, let frame = try? channel.seal(message) else { return [] }
        return [.send(frame)]
    }

    /// The remembered key got no answer in time. A host that can't make the
    /// key's proof closes the connection; one that says nothing is taken the
    /// same way.
    public mutating func savedKeyTimedOut() -> [Effect] {
        guard let offered else { return [] }
        return refuse(offered)
    }

    /// The connection ended. `byHost` is the host closing it (cleanly, or by
    /// a reset) rather than the network losing it.
    public mutating func closed(byHost: Bool, reason: String?) -> [Effect] {
        let was = stage
        stage = .closed
        switch was {
        case .connected:
            return [.lost]
        case let .awaitingAccepted(_, offered):
            if byHost, let offered { return refuse(offered) }
            if byHost { return [.needsCode(.codeRefused)] }
            return [.failed(.unreachable(reason))]
        case .awaitingCode:
            // Waiting on a code is not an error: the next connection asks
            // again, or answers with the code once it is scanned.
            return []
        case .awaitingHello:
            return [.failed(.unreachable(reason))]
        case .closed:
            return []
        }
    }

    // MARK: - Steps

    private mutating func hello(_ hello: LampAgentRemoteHello) -> [Effect] {
        if let saved = LampAgentRemoteRememberedHost.recognising(remembered, hint: hello.hostHint, nonce: hello.nonce),
           let credential = LampAgentRemoteCredential.device(saved.credential) {
            return answer(hello, with: credential, offered: saved) + [.watchSavedKey]
        }
        if let pendingCode, let credential = LampAgentRemoteCredential.pairing(code: pendingCode) {
            self.pendingCode = nil
            return answer(hello, with: credential, offered: nil)
        }
        stage = .awaitingCode(hello)
        return [.needsCode(nil)]
    }

    private mutating func answer(
        _ hello: LampAgentRemoteHello,
        with credential: LampAgentRemoteCredential,
        offered: LampAgentRemoteRememberedHost?
    ) -> [Effect] {
        do {
            let (auth, channel) = try LampAgentRemoteHandshake.respond(to: hello, with: credential)
            stage = .awaitingAccepted(channel, offered: offered)
            return [.send(try LampAgentRemoteFraming.encode(auth))]
        } catch LampAgentRemoteError.unsupportedVersion {
            stage = .closed
            return [.failed(.otherVersion)]
        } catch {
            stage = .closed
            return [.failed(.unreadable)]
        }
    }

    private mutating func accepted(
        _ message: LampAgentRemoteMessage,
        offered: LampAgentRemoteRememberedHost?,
        channel: LampAgentRemoteSecureChannel
    ) -> [Effect] {
        var effects: [Effect] = []
        hostSecret = offered?.hostSecret
        if offered == nil {
            // Paired by code: the host's key for this device comes with it.
            guard let deviceID = message.deviceID, let deviceKey = message.deviceKey,
                  let hostSecret = message.hostSecret, !hostSecret.isEmpty else {
                stage = .closed
                return [.failed(.unreadable)]
            }
            self.hostSecret = hostSecret
            let earlier = remembered.first { $0.hostSecret == hostSecret }
            effects.append(.remember(LampAgentRemoteRememberedHost(
                id: earlier?.id ?? UUID().uuidString,
                name: hostName,
                deviceID: deviceID,
                deviceKey: deviceKey,
                hostSecret: hostSecret,
                pairedAt: now()
            )))
        }
        stage = .connected(channel)
        // The opening requests are sealed, and so numbered, first, and
        // `connected` comes after them.
        for request in [LampAgentRemoteMessage.introduce(clientName: clientName), .listChats()] {
            if let frame = try? channel.seal(request) { effects.append(.send(frame)) }
        }
        return effects + [.connected]
    }

    private func handle(_ message: LampAgentRemoteMessage, channel: LampAgentRemoteSecureChannel) -> [Effect] {
        if message.kind == .ping {
            return (try? channel.seal(.pong)).map { [.send($0)] } ?? []
        }
        return [.received(message)]
    }

    private mutating func unreadable() -> [Effect] {
        let was = stage
        stage = .closed
        if case let .awaitingAccepted(_, offered) = was, let offered {
            return refuse(offered)
        }
        return [.failed(.unreadable)]
    }

    private mutating func refuse(_ offered: LampAgentRemoteRememberedHost) -> [Effect] {
        stage = .closed
        return [.forget(offered.id), .pairAgain]
    }
}

/// A host's side of one connection from a device: the hello, the device's
/// proof checked against every key the host would accept, `accepted`, and
/// sealed messages after — with the limits on a connection that has not yet
/// proved itself. No networking and no storage: the host carries the bytes,
/// keeps the keys, and asks this what to do.
///
/// Nothing a device sends is handled before it has proved itself and been
/// sent `accepted`; a device paired by code is held until the host has kept
/// the key it mints for it (`completePairing`).
public struct LampAgentRemoteHostConnection {
    /// An unproven connection has this long to prove itself, and may say this
    /// much before it has; and a host keeps only so many waiting at once.
    public static let handshakeDeadline: TimeInterval = 10
    public static let handshakeBytes = 16 * 1_024
    public static let unprovenLimit = 6

    public enum Effect: Equatable {
        case send(Data)
        /// Proved with the open pairing code: mint the device a key, keep it,
        /// then call `completePairing`.
        case pairedByCode
        /// Proved with a paired device's key, and sent `accepted`.
        case acceptedDevice(String)
        /// A message from the proven device.
        case received(LampAgentRemoteMessage)
        /// End the connection.
        case close
    }

    public enum Stage {
        case awaitingProof
        /// Proved by code, with its key being kept.
        case pairing(LampAgentRemoteSecureChannel)
        case connected(LampAgentRemoteSecureChannel, deviceID: String)
        case closed
    }

    /// The hello, framed, for the host to send the moment the connection
    /// opens.
    public let opening: Data
    public private(set) var stage: Stage = .awaitingProof
    private let start: LampAgentRemoteHandshake.HostStart
    private let openedAt: Date
    private var buffer = Data()

    /// `hostSecret` is nil while no device has paired.
    public init(hostSecret: String?, now: Date = Date()) {
        start = LampAgentRemoteHandshake.hostStart(hostSecret: hostSecret)
        opening = (try? LampAgentRemoteFraming.encode(start.hello)) ?? Data()
        openedAt = now
    }

    public var deviceID: String? {
        if case let .connected(_, id) = stage { return id }
        return nil
    }

    /// Proved, whether or not its key has yet been kept.
    public var isProven: Bool {
        switch stage {
        case .pairing, .connected: true
        case .awaitingProof, .closed: false
        }
    }

    /// Whether an unproven connection has had its time.
    public func hasExpired(now: Date) -> Bool {
        guard case .awaitingProof = stage else { return false }
        return now.timeIntervalSince(openedAt) > Self.handshakeDeadline
    }

    /// Bytes from the device. `trusted` is every paired device's key,
    /// `revoked` the devices forgotten since those were read, and `pairing`
    /// the open pairing window, which a proof that fits nothing counts
    /// against and a pairing spends.
    public mutating func receive(
        _ data: Data,
        trusted: [LampAgentRemoteCredential],
        revoked: Set<String> = [],
        pairing: inout LampAgentRemotePairingWindow?
    ) -> [Effect] {
        buffer.append(data)
        switch stage {
        case .closed:
            buffer = Data()
            return []
        case .awaitingProof:
            guard buffer.count <= Self.handshakeBytes else { return close() }
            do {
                guard let auth = try LampAgentRemoteFraming.decode(LampAgentRemoteAuth.self, from: &buffer) else { return [] }
                let candidates = trusted.filter {
                    if case .device(let id) = $0.kind { return !revoked.contains(id) }
                    return false
                } + (pairing?.credential.map { [$0] } ?? [])
                let accepted: (credential: LampAgentRemoteCredential, channel: LampAgentRemoteSecureChannel)
                do {
                    accepted = try LampAgentRemoteHandshake.accept(auth, start: start, candidates: candidates)
                } catch {
                    pairing?.failed()
                    return close()
                }
                switch accepted.credential.kind {
                case .pairing:
                    pairing?.paired()
                    stage = .pairing(accepted.channel)
                    return [.pairedByCode]
                case .device(let id):
                    stage = .connected(accepted.channel, deviceID: id)
                    guard let frame = try? accepted.channel.seal(.accepted()) else { return close() }
                    return [.send(frame), .acceptedDevice(id)] + opened()
                }
            } catch {
                return close()
            }
        case .pairing:
            // A device says nothing until it has `accepted`.
            return buffer.count <= Self.handshakeBytes ? [] : close()
        case .connected:
            return opened()
        }
    }

    /// The key minted for a device paired by code has been kept: it is sent
    /// with the host's secret inside `accepted`, and the device let in.
    public mutating func completePairing(_ credential: LampAgentRemoteDeviceCredential, hostSecret: String) -> [Effect] {
        guard case let .pairing(channel) = stage,
              let frame = try? channel.seal(.accepted(pairing: credential, hostSecret: hostSecret)) else { return [] }
        stage = .connected(channel, deviceID: credential.deviceID)
        return [.send(frame)] + opened()
    }

    /// A message for the proven device, sealed.
    public mutating func seal(_ message: LampAgentRemoteMessage) -> [Effect] {
        guard case let .connected(channel, _) = stage, let frame = try? channel.seal(message) else { return [] }
        return [.send(frame)]
    }

    public mutating func close() -> [Effect] {
        stage = .closed
        buffer = Data()
        return [.close]
    }

    private mutating func opened() -> [Effect] {
        guard case let .connected(channel, _) = stage else { return [] }
        do {
            return try channel.open(from: &buffer).map { .received($0) }
        } catch {
            return close()
        }
    }
}
