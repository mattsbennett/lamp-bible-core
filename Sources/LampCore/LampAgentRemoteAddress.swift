import Foundation

/// Where a device reaches a Mac's agent chats when Bonjour cannot find it:
/// across a tailnet, which carries no multicast, so a phone and a Mac on one
/// see nothing of each other but can still connect by address.
///
/// The Mac listens on `defaultPort` when it can, so an address typed once
/// keeps working; it shows its address in the form `text` writes, and a
/// device reads what is typed with `parse`. Nothing is trusted for being
/// reachable: the handshake that follows is the same as over the local
/// network, and a device that has not paired is refused.
public struct LampAgentRemoteAddress: Equatable, Hashable, Sendable {
    /// Lamp's own, below the range systems hand out for outgoing connections.
    public static let defaultPort: UInt16 = 47_381

    /// A name or an address, an IPv6 one without brackets.
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16 = Self.defaultPort) {
        self.host = host
        self.port = port
    }

    /// As it is shown and typed: the port left off when it is Lamp's own,
    /// and an IPv6 address bracketed only when a port follows it.
    public var text: String {
        let isV6 = host.contains(":")
        guard port != Self.defaultPort else { return host }
        return isV6 ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// What was typed, or nil for something that is not an address:
    /// `host`, `host:port`, an IPv6 address bare or as `[v6]` or `[v6]:port`.
    /// Surrounding spaces are ignored; a port left off is Lamp's own.
    public static func parse(_ typed: String) -> LampAgentRemoteAddress? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 300 else { return nil }
        let host: Substring
        var port = defaultPort
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            host = text[text.index(after: text.startIndex)..<close]
            let rest = text[text.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":"), let parsed = Self.port(rest.dropFirst()) else { return nil }
                port = parsed
            }
            guard isIPv6(host) else { return nil }
        } else if text.filter({ $0 == ":" }).count > 1 {
            // Bare IPv6: its colons leave no room for a port.
            host = Substring(text)
            guard isIPv6(host) else { return nil }
        } else if let colon = text.firstIndex(of: ":") {
            host = text[..<colon]
            guard let parsed = Self.port(text[text.index(after: colon)...]) else { return nil }
            port = parsed
            guard isHostName(host) else { return nil }
        } else {
            host = Substring(text)
            guard isHostName(host) else { return nil }
        }
        return LampAgentRemoteAddress(host: String(host), port: port)
    }

    /// Whether an address is one Tailscale gives its devices: IPv4 in
    /// 100.64.0.0/10, IPv6 in fd7a:115c:a1e0::/48. Tailscale documents both
    /// ranges; this reads nothing of Tailscale's own.
    public static func isTailnet(_ address: String) -> Bool {
        if address.contains(":") {
            var bytes = in6_addr()
            let bare = address.split(separator: "%", maxSplits: 1).first.map(String.init) ?? address
            guard inet_pton(AF_INET6, bare, &bytes) == 1 else { return false }
            let prefix = withUnsafeBytes(of: &bytes) { Array($0.prefix(6)) }
            return prefix == [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]
        }
        var bytes = in_addr()
        guard inet_pton(AF_INET, address, &bytes) == 1 else { return false }
        let octets = withUnsafeBytes(of: &bytes) { Array($0) }
        return octets[0] == 100 && (octets[1] & 0xC0) == 64
    }

    private static func port(_ text: Substring) -> UInt16? {
        guard !text.isEmpty, text.count <= 5, text.allSatisfy(\.isASCIIDigit),
              let value = UInt16(text), value > 0 else { return nil }
        return value
    }

    /// A DNS name or an IPv4 address: letters, digits, hyphens and dots,
    /// with no empty label and none that starts or ends with a hyphen.
    private static func isHostName(_ text: Substring) -> Bool {
        guard !text.isEmpty, text.count <= 253 else { return false }
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        // A single trailing dot is a fully qualified name.
        let named = labels.last?.isEmpty == true && labels.count > 1 ? labels.dropLast() : labels[...]
        return named.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isASCIIDigit || $0.isASCIILetter || $0 == "-" }
        }
    }

    /// An IPv6 address, with at most one zone after a `%`: an interface's
    /// name, letters, digits, dots, hyphens and underscores.
    private static func isIPv6(_ text: Substring) -> Bool {
        let parts = text.split(separator: "%", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return false }
        if parts.count == 2 {
            let zone = parts[1]
            guard !zone.isEmpty, zone.count <= 32,
                  zone.allSatisfy({ $0.isASCIIDigit || $0.isASCIILetter || "._-".contains($0) })
            else { return false }
        }
        var bytes = in6_addr()
        return inet_pton(AF_INET6, String(parts[0]), &bytes) == 1
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
    var isASCIILetter: Bool { isASCII && isLetter }
}
