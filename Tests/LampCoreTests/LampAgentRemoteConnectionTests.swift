import Foundation
import Testing
@testable import LampCore

/// A host's and a device's sides of a connection, run against each other
/// with nothing between them but the bytes each sends.
struct LampAgentRemoteConnectionTests {
    /// The host's keys and open pairing window, as a host app keeps them.
    private struct Host {
        var devices: [LampAgentRemoteDeviceCredential] = []
        var revoked: Set<String> = []
        var pairing: LampAgentRemotePairingWindow?
        let secret = LampAgentRemoteHandshake.generateHostSecret()
        var trusted: [LampAgentRemoteCredential] { devices.compactMap(LampAgentRemoteCredential.device) }
    }

    /// One connection played out: bytes go each way until neither has more.
    private struct Wire {
        var host: LampAgentRemoteHostConnection
        var device: LampAgentRemoteDeviceConnection
        var hostEffects: [LampAgentRemoteHostConnection.Effect] = []
        var deviceEffects: [LampAgentRemoteDeviceConnection.Effect] = []

        init(_ host: inout Host, remembered: [LampAgentRemoteRememberedHost], pendingCode: String? = nil) {
            self.host = LampAgentRemoteHostConnection(hostSecret: host.devices.isEmpty ? nil : host.secret)
            self.device = LampAgentRemoteDeviceConnection(
                remembered: remembered, hostName: "Mac", clientName: "iPhone", pendingCode: pendingCode
            )
            deliverToDevice(self.host.opening, &host)
        }

        mutating func deliverToDevice(_ data: Data, _ keys: inout Host) {
            for effect in device.receive(data) { deviceDid(effect, &keys) }
        }

        mutating func deviceDid(_ effect: LampAgentRemoteDeviceConnection.Effect, _ keys: inout Host) {
            deviceEffects.append(effect)
            if case .send(let data) = effect {
                for effect in host.receive(data, trusted: keys.trusted, revoked: keys.revoked, pairing: &keys.pairing) {
                    hostDid(effect, &keys)
                }
            }
        }

        mutating func hostDid(_ effect: LampAgentRemoteHostConnection.Effect, _ keys: inout Host) {
            hostEffects.append(effect)
            switch effect {
            case .send(let data):
                deliverToDevice(data, &keys)
            case .pairedByCode:
                let minted = LampAgentRemoteDeviceCredential.generate()
                keys.devices.append(minted)
                for effect in host.completePairing(minted, hostSecret: keys.secret) { hostDid(effect, &keys) }
            case .close:
                for effect in device.closed(byHost: true, reason: nil) { deviceEffects.append(effect) }
            default:
                break
            }
        }

        mutating func pair(_ code: String, _ keys: inout Host) {
            for effect in device.pair(code: code) { deviceDid(effect, &keys) }
        }

        var remembered: LampAgentRemoteRememberedHost? {
            deviceEffects.lazy.compactMap { if case .remember(let host) = $0 { return host } else { return nil } }.first
        }

        var hostReceived: [LampAgentRemoteMessage.Kind] {
            hostEffects.compactMap { if case .received(let message) = $0 { return message.kind } else { return nil } }
        }
    }

    @Test func adevicePairsByCodeAndIsRememberedThenComesBackByItsKey() throws {
        var keys = Host()
        keys.pairing = LampAgentRemotePairingWindow()
        var first = Wire(&keys, remembered: [])
        #expect(first.deviceEffects == [.needsCode(nil)])
        first.pair(try #require(keys.pairing?.code), &keys)
        let remembered = try #require(first.remembered)
        #expect(first.device.isConnected && first.deviceEffects.last == .connected)
        #expect(first.hostReceived == [.introduce, .listChats])
        #expect(keys.pairing?.isClosed == true && keys.devices.count == 1)
        #expect(remembered.deviceID == keys.devices[0].deviceID && remembered.hostSecret == keys.secret)
        #expect(first.device.hostSecret == keys.secret)

        // The next connection: recognised by the hint, answered with the key,
        // and let straight in, with nothing new to remember.
        var again = Wire(&keys, remembered: [remembered])
        #expect(again.hostEffects.contains(.acceptedDevice(remembered.deviceID)))
        #expect(again.device.isConnected && again.remembered == nil)
        #expect(again.deviceEffects.contains(.watchSavedKey))
        #expect(again.device.hostSecret == keys.secret)
        #expect(again.hostReceived == [.introduce, .listChats])

        // Sealed messages each way once connected.
        for effect in again.host.seal(.chats([])) { again.hostDid(effect, &keys) }
        #expect(again.deviceEffects.contains { if case .received(let m) = $0 { return m.kind == .chats } else { return false } })
    }

    @Test func aforgottenDeviceIsTurnedAwayAndSetsTheKeyAside() throws {
        var keys = Host()
        keys.pairing = LampAgentRemotePairingWindow()
        var first = Wire(&keys, remembered: [])
        first.pair(try #require(keys.pairing?.code), &keys)
        let remembered = try #require(first.remembered)

        // Forgotten on the host since its keys were read: refused, and the
        // device drops the key and asks to pair again.
        keys.revoked.insert(remembered.deviceID)
        let again = Wire(&keys, remembered: [remembered])
        #expect(again.hostEffects.last == .close)
        #expect(!again.device.isConnected)
        let afterOffer = again.deviceEffects.filter { $0 != .watchSavedKey }
        #expect(afterOffer.suffix(2) == [.keyRefused(remembered.id), .pairAgain])

        // A host with no devices left gives no hint to be recognised by, so
        // the device asks for a code rather than offering the old key.
        keys.revoked = []
        keys.devices = []
        let later = Wire(&keys, remembered: [remembered])
        #expect(later.deviceEffects == [.needsCode(nil)])
    }

    @Test func acodePairsOnceAndAWrongOneCountsAgainstTheWindow() throws {
        var keys = Host()
        keys.pairing = LampAgentRemotePairingWindow(allowedFailures: 2)
        let code = try #require(keys.pairing?.code)
        var first = Wire(&keys, remembered: [])
        first.pair(code, &keys)
        #expect(first.device.isConnected)

        // The same code again: spent.
        var reused = Wire(&keys, remembered: [])
        reused.pair(code, &keys)
        #expect(reused.hostEffects.last == .close && reused.deviceEffects.last == .needsCode(.codeRefused))

        // Wrong codes close a fresh window after its allowance.
        keys.pairing = LampAgentRemotePairingWindow(allowedFailures: 2)
        let right = try #require(keys.pairing?.code)
        for _ in 0..<2 {
            var guess = Wire(&keys, remembered: [])
            guess.pair(LampPresentationRemotePairing.generateCode(), &keys)
            #expect(guess.hostEffects.last == .close)
        }
        var late = Wire(&keys, remembered: [])
        late.pair(right, &keys)
        #expect(late.hostEffects.last == .close && !late.device.isConnected)
    }

    @Test func acodeScannedBeforeTheHelloAnswersIt() throws {
        var keys = Host()
        keys.pairing = LampAgentRemotePairingWindow()
        let wire = Wire(&keys, remembered: [], pendingCode: keys.pairing?.code)
        #expect(wire.device.isConnected && wire.remembered != nil)
    }

    @Test func anUnprovenConnectionIsBoundedInSizeAndTime() {
        var pairing: LampAgentRemotePairingWindow?
        var host = LampAgentRemoteHostConnection(hostSecret: nil, now: Date(timeIntervalSince1970: 0))
        #expect(!host.hasExpired(now: Date(timeIntervalSince1970: 10)))
        #expect(host.hasExpired(now: Date(timeIntervalSince1970: 11)))
        // A frame header promising a large handshake, and the bytes to go
        // past the limit, before any proof.
        let flood = Data([0, 0x7F, 0xFF, 0xFF]) + Data(count: LampAgentRemoteHostConnection.handshakeBytes)
        #expect(host.receive(flood, trusted: [], pairing: &pairing) == [.close])
        #expect(host.receive(Data([1]), trusted: [], pairing: &pairing).isEmpty)
    }

    @Test func adeviceTrustsNothingBeforeAccepted() throws {
        var keys = Host()
        keys.pairing = LampAgentRemotePairingWindow()
        // A host that seals something other than `accepted` first.
        let host = LampAgentRemoteHandshake.hostStart(hostSecret: nil)
        var device = LampAgentRemoteDeviceConnection(remembered: [], hostName: "Mac", clientName: "iPhone")
        _ = device.receive(try LampAgentRemoteFraming.encode(host.hello))
        guard case .send(let authFrame) = device.pair(code: try #require(keys.pairing?.code)).first else {
            Issue.record("no answer"); return
        }
        var buffer = authFrame
        let auth = try #require(try LampAgentRemoteFraming.decode(LampAgentRemoteAuth.self, from: &buffer))
        let accepted = try LampAgentRemoteHandshake.accept(auth, start: host, candidates: [try #require(keys.pairing?.credential)])
        #expect(device.receive(try accepted.channel.seal(.chats([]))) == [.failed(.unreadable)])

        // And bytes while it waits for a code end it too.
        var waiting = LampAgentRemoteDeviceConnection(remembered: [], hostName: "Mac", clientName: "iPhone")
        _ = waiting.receive(try LampAgentRemoteFraming.encode(LampAgentRemoteHandshake.hostStart(hostSecret: nil).hello))
        #expect(waiting.receive(Data([1, 2, 3])) == [.failed(.unreadable)])
    }

    @Test func whatIsSealedInAnswerLeavesAfterWhatWasSealedBefore() throws {
        // `accepted` and a ping in one read: the opening requests and the
        // pong are all sent before `connected` is heard.
        var keys = Host()
        keys.pairing = LampAgentRemotePairingWindow()
        let host = LampAgentRemoteHandshake.hostStart(hostSecret: nil)
        var device = LampAgentRemoteDeviceConnection(remembered: [], hostName: "Mac", clientName: "iPhone")
        _ = device.receive(try LampAgentRemoteFraming.encode(host.hello))
        guard case .send(let authFrame) = device.pair(code: try #require(keys.pairing?.code)).first else {
            Issue.record("no answer"); return
        }
        var buffer = authFrame
        let auth = try #require(try LampAgentRemoteFraming.decode(LampAgentRemoteAuth.self, from: &buffer))
        let accepted = try LampAgentRemoteHandshake.accept(auth, start: host, candidates: [try #require(keys.pairing?.credential)])
        let minted = LampAgentRemoteDeviceCredential.generate()
        let both = try accepted.channel.seal(.accepted(pairing: minted, hostSecret: "secret"))
            + accepted.channel.seal(.ping)
        let effects = device.receive(both)
        let firstOther = effects.firstIndex { if case .send = $0 { false } else { true } } ?? effects.count
        #expect(effects[..<firstOther].count == 3)
        #expect(effects[firstOther...].allSatisfy { if case .send = $0 { false } else { true } })
        #expect(effects.contains(.connected))
    }

    @Test func nothingIsReadAfterAnAcceptedThatCannotBeTaken() throws {
        var keys = Host()
        keys.pairing = LampAgentRemotePairingWindow()
        let host = LampAgentRemoteHandshake.hostStart(hostSecret: nil)
        var device = LampAgentRemoteDeviceConnection(remembered: [], hostName: "Mac", clientName: "iPhone")
        _ = device.receive(try LampAgentRemoteFraming.encode(host.hello))
        guard case .send(let authFrame) = device.pair(code: try #require(keys.pairing?.code)).first else {
            Issue.record("no answer"); return
        }
        var buffer = authFrame
        let auth = try #require(try LampAgentRemoteFraming.decode(LampAgentRemoteAuth.self, from: &buffer))
        let accepted = try LampAgentRemoteHandshake.accept(auth, start: host, candidates: [try #require(keys.pairing?.credential)])
        // Paired by code, but no key in `accepted`, then a message after it.
        let frames = try accepted.channel.seal(.accepted()) + accepted.channel.seal(.chats([]))
        #expect(device.receive(frames) == [.failed(.unreadable)])
    }

    @Test func awindowAllowingNoWrongCodesIsClosedFromTheStart() {
        #expect(LampAgentRemotePairingWindow(allowedFailures: 0).credential == nil)
    }
}
