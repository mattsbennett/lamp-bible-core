import Testing
@testable import LampCore

struct LampAgentRemoteAddressTests {
    private let port = LampAgentRemoteAddress.defaultPort

    @Test func readsEveryFormItIsTypedIn() {
        #expect(LampAgentRemoteAddress.parse("100.101.102.103") == .init(host: "100.101.102.103"))
        #expect(LampAgentRemoteAddress.parse(" my-mac.tail1234.ts.net \n") == .init(host: "my-mac.tail1234.ts.net"))
        #expect(LampAgentRemoteAddress.parse("my-mac:5000") == .init(host: "my-mac", port: 5000))
        #expect(LampAgentRemoteAddress.parse("fd7a:115c:a1e0::1") == .init(host: "fd7a:115c:a1e0::1"))
        #expect(LampAgentRemoteAddress.parse("[fd7a:115c:a1e0::1]") == .init(host: "fd7a:115c:a1e0::1"))
        #expect(LampAgentRemoteAddress.parse("[fd7a:115c:a1e0::1]:5000") == .init(host: "fd7a:115c:a1e0::1", port: 5000))
        #expect(LampAgentRemoteAddress.parse("my-mac.ts.net.") == .init(host: "my-mac.ts.net."))
        #expect(LampAgentRemoteAddress.parse("[fe80::1%en0]:5000") == .init(host: "fe80::1%en0", port: 5000))
    }

    @Test func refusesWhatIsNotAnAddress() {
        for typed in [
            "", "   ", "my mac", "my-mac:", "my-mac:0", "my-mac:65536", "my-mac:12a",
            "-flag", "a..b", "host-.ts.net", "lamp://my-mac", "my-mac:5000:1",
            "[fd7a::1", "[fd7a::1]5000", "[my-mac]:5000", "fd7a::zz", "[::1]:",
            "[fe80::1%en0%junk]:5000", "fe80::1%", "fe80::1%en 0", "[fe80::1%]:5000",
            String(repeating: "a", count: 64) + ".net",
        ] {
            #expect(LampAgentRemoteAddress.parse(typed) == nil, "\(typed)")
        }
    }

    @Test func writesWhatItReadsBack() {
        for address in [
            LampAgentRemoteAddress(host: "100.101.102.103"),
            LampAgentRemoteAddress(host: "my-mac.tail1234.ts.net", port: 5000),
            LampAgentRemoteAddress(host: "fd7a:115c:a1e0::1"),
            LampAgentRemoteAddress(host: "fd7a:115c:a1e0::1", port: 5000),
        ] {
            #expect(LampAgentRemoteAddress.parse(address.text) == address)
        }
        // Lamp's own port is left off, so the address shown is the short one.
        #expect(LampAgentRemoteAddress(host: "100.101.102.103").text == "100.101.102.103")
        #expect(LampAgentRemoteAddress(host: "fd7a::1", port: 5000).text == "[fd7a::1]:5000")
    }

    @Test func knowsTailscalesRanges() {
        #expect(LampAgentRemoteAddress.isTailnet("100.64.0.1"))
        #expect(LampAgentRemoteAddress.isTailnet("100.127.255.254"))
        #expect(!LampAgentRemoteAddress.isTailnet("100.128.0.1"))
        #expect(!LampAgentRemoteAddress.isTailnet("100.63.255.255"))
        #expect(!LampAgentRemoteAddress.isTailnet("192.168.1.10"))
        #expect(LampAgentRemoteAddress.isTailnet("fd7a:115c:a1e0:ab12::1"))
        #expect(LampAgentRemoteAddress.isTailnet("fd7a:115c:a1e0::1%utun4"))
        #expect(!LampAgentRemoteAddress.isTailnet("fd7a:115c:a1e1::1"))
        #expect(!LampAgentRemoteAddress.isTailnet("fe80::1"))
        #expect(!LampAgentRemoteAddress.isTailnet("not an address"))
    }
}
