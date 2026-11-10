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

    @Test("wider-than-/22 mask is capped to the local /22")
    func capWideMask() {
        let hosts = SubnetSweeper.hostAddresses(ownIPv4: "10.0.5.7", netmask: "255.255.0.0")
        #expect(hosts.count == 1021)
        #expect(hosts.first == "10.0.4.1")
        #expect(hosts.last == "10.0.7.254")
        #expect(hosts.contains("10.0.6.0"), "inner .0 addresses are valid hosts in a /22")
        #expect(!hosts.contains("10.0.5.7"))
        #expect(!hosts.contains("10.0.4.0"))
        #expect(!hosts.contains("10.0.7.255"))
        #expect(!hosts.contains("10.0.8.1"))
    }

    @Test("a /23 netmask covers both halves")
    func enumerate23() {
        let hosts = SubnetSweeper.hostAddresses(ownIPv4: "192.168.2.10", netmask: "255.255.254.0")
        #expect(hosts.count == 509)
        #expect(hosts.contains("192.168.3.5"))
        #expect(!hosts.contains("192.168.3.255"))
    }

    @Test("a narrower-than-/24 netmask stays inside its subnet")
    func enumerate25() {
        let hosts = SubnetSweeper.hostAddresses(ownIPv4: "192.168.0.200", netmask: "255.255.255.128")
        #expect(hosts.count == 125)
        #expect(hosts.first == "192.168.0.129")
        #expect(hosts.last == "192.168.0.254")
        #expect(!hosts.contains("192.168.0.5"))
    }

    @Test("the primary interface wins over en0")
    func primaryInterfaceIsPreferred() {
        let candidates = [
            SubnetSweeper.InterfaceAddress(name: "en0", ip: "192.168.0.4", mask: "255.255.255.0"),
            SubnetSweeper.InterfaceAddress(name: "en7", ip: "10.1.2.3", mask: "255.255.255.0"),
        ]
        #expect(SubnetSweeper.selectInterface(candidates, primaryInterface: "en7")?.name == "en7")
        // No primary known (or it has no IPv4 address): fall back to the first candidate.
        #expect(SubnetSweeper.selectInterface(candidates, primaryInterface: nil)?.name == "en0")
        #expect(SubnetSweeper.selectInterface(Array(candidates.reversed()), primaryInterface: "utun3")?.name == "en7")
        #expect(SubnetSweeper.selectInterface([], primaryInterface: "en0") == nil)
    }
}
