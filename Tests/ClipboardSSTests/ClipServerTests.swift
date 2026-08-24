import Foundation
import Network
import Testing
@testable import ClipboardSS

@Suite("ClipServer Bonjour TXT sanitization")
struct ClipServerTests {
    @Test("passes through plain ASCII names unchanged")
    func passesThroughAsciiNames() {
        #expect(ClipServer.bonjourSafeTXTValue("Android Device") == "Android Device")
    }

    @Test("replaces curly quotes with straight ASCII equivalents")
    func replacesCurlyQuotes() {
        // macOS computer names commonly use U+2019 (RIGHT SINGLE QUOTATION MARK),
        // which some Android mDNS/NsdManager stacks fail to parse in TXT records,
        // silently hiding the service from discovery.
        #expect(ClipServer.bonjourSafeTXTValue("Leonardo\u{2019}s MacBook") == "Leonardo's MacBook")
    }

    @Test("strips other non-ASCII characters rather than emitting raw UTF-8")
    func stripsOtherNonAsciiCharacters() {
        #expect(ClipServer.bonjourSafeTXTValue("Café ☕") == "Caf ")
    }

    @Test("identity response JSON contains id, name, v")
    func identityResponseJSON() throws {
        let json = ClipServer.identityResponseBody(
            id: UUID(uuidString: "8fb5790c-4533-47bb-90af-827291247fe1")!,
            name: "Mac"
        )
        let obj = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        #expect(obj["deviceId"] as? String == "8FB5790C-4533-47BB-90AF-827291247FE1")
        #expect(obj["deviceName"] as? String == "Mac")
        #expect(obj["v"] as? Int == 1)
    }

    @Test("remoteHost extracts ipv4 without zone")
    func remoteHostParsing() {
        let ep = NWEndpoint.hostPort(host: .ipv4(IPv4Address("192.168.0.9")!), port: 51888)
        #expect(ClipServer.remoteHost(from: ep) == "192.168.0.9")
    }

    @Test("listener retry delay backs off and caps")
    func listenerRetryDelay() {
        #expect(ClipServer.retryDelaySeconds(failureCount: 1) == 1)
        #expect(ClipServer.retryDelaySeconds(failureCount: 2) == 2)
        #expect(ClipServer.retryDelaySeconds(failureCount: 3) == 4)
        #expect(ClipServer.retryDelaySeconds(failureCount: 8) == 30)
    }
}
