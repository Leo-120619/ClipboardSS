import Testing
@testable import ClipboardSS

@Suite("Subnet sweeper")
struct SubnetSweeperTests {
    @Test("enumerates a /24 excluding own address, network, broadcast")
    func enumerate24() {
        let hosts = SubnetSweeper.hostAddresses(ownIPv4: "192.168.0.4", netmask: "255.255.255.0")
        #expect(hosts.count == 253)
        #expect(hosts.contains("192.168.0.9"))
        #expect(!hosts.contains("192.168.0.4"))
        #expect(!hosts.contains("192.168.0.0"))
        #expect(!hosts.contains("192.168.0.255"))
    }

    @Test("wider-than-/24 mask is capped to the local /24")
    func capWideMask() {
        let hosts = SubnetSweeper.hostAddresses(ownIPv4: "10.0.5.7", netmask: "255.255.0.0")
        #expect(hosts.count == 253)
        #expect(hosts.allSatisfy { $0.hasPrefix("10.0.5.") })
    }
}
