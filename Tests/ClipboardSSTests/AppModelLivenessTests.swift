import Testing
import Foundation
import ClipboardCore
@testable import ClipboardSS

@Suite("Device liveness")
struct AppModelLivenessTests {
    private let macId = UUID()
    private let pcId = UUID()

    @Test("disconnect is shown only for an enabled device that is online")
    func connectionDisplayContract() {
        #expect(AppModel.isDeviceConnectionActive(enabled: true, online: true))
        #expect(!AppModel.isDeviceConnectionActive(enabled: true, online: false))
        #expect(!AppModel.isDeviceConnectionActive(enabled: false, online: true))
    }

    @Test("reconnection selects the matching device at its refreshed address")
    func reconnectionSelectsMatchingPeer() {
        let peer = AppModel.matchingReconnectPeer(
            deviceId: macId,
            mdnsPeers: [Peer(id: pcId, name: "Other", host: "10.0.0.8", port: 51888)],
            sweptPeers: [Peer(id: macId, name: "Mac", host: "10.0.0.42", port: 51888)]
        )

        #expect(peer?.host == "10.0.0.42")
    }

    @Test("file target resolution rejects offline and paused devices")
    func verifiedFileTarget() {
        let enabled = PairedDevice(id: macId, name: "Mac", host: "10.0.0.9")
        let paused = PairedDevice(id: macId, name: "Mac", host: "10.0.0.9", connected: false)

        #expect(AppModel.resolveVerifiedPeer(device: enabled, online: false, mdnsPeers: []) == nil)
        #expect(AppModel.resolveVerifiedPeer(device: paused, online: true, mdnsPeers: []) == nil)
        #expect(AppModel.resolveVerifiedPeer(device: enabled, online: true, mdnsPeers: [])?.host == "10.0.0.9")
    }

    @Test("a device visible over mDNS is online only after its address responds")
    func mdnsPeerIsProbed() async {
        let probed = Probed()

        let online = await AppModel.computeOnlineDeviceIds(
            devices: [PairedDevice(id: macId, name: "Mac", host: "10.0.0.9")],
            mdnsPeers: [Peer(id: macId, name: "Mac", host: "192.168.0.4", port: 51888)],
            probe: { [macId] host in
                await probed.record(host)
                return Peer(id: macId, name: "Mac", host: host, port: 51888)
            }
        )

        #expect(online == [macId])
        #expect(await probed.hosts == ["192.168.0.4"])
    }

    @Test("a stale mDNS address falls back to the stored address")
    func staleMdnsFallsBackToStoredHost() async {
        let probed = Probed()
        let online = await AppModel.computeOnlineDeviceIds(
            devices: [PairedDevice(id: macId, name: "Mac", host: "10.0.0.9")],
            mdnsPeers: [Peer(id: macId, name: "Mac", host: "10.0.0.8", port: 51888)],
            probe: { [macId] host in
                await probed.record(host)
                return host == "10.0.0.9" ? Peer(id: macId, name: "Mac", host: host, port: 51888) : nil
            }
        )

        #expect(online == [macId])
        #expect(await probed.hosts == ["10.0.0.8", "10.0.0.9"])
    }

    @Test("a probe returning the matching device id marks it online")
    func probeMatchIsOnline() async {
        let online = await AppModel.computeOnlineDeviceIds(
            devices: [PairedDevice(id: pcId, name: "PC", host: "192.168.0.20")],
            mdnsPeers: [],
            probe: { [pcId] host in Peer(id: pcId, name: "PC", host: host, port: 51888) }
        )

        #expect(online == [pcId])
    }

    @Test("a probe that fails or times out marks the device offline")
    func probeFailureIsOffline() async {
        let online = await AppModel.computeOnlineDeviceIds(
            devices: [PairedDevice(id: pcId, name: "PC", host: "192.168.0.20")],
            mdnsPeers: [],
            probe: { _ in nil }
        )

        #expect(online.isEmpty)
    }

    @Test("a host answering with a different device id is offline")
    func probeIdMismatchIsOffline() async {
        let online = await AppModel.computeOnlineDeviceIds(
            devices: [PairedDevice(id: pcId, name: "PC", host: "192.168.0.20")],
            mdnsPeers: [],
            probe: { host in Peer(id: UUID(), name: "Other", host: host, port: 51888) }
        )

        #expect(online.isEmpty)
    }

    @Test("a device with no stored host is offline and is not probed")
    func noHostIsOfflineWithoutProbe() async {
        let probed = Probed()

        let online = await AppModel.computeOnlineDeviceIds(
            devices: [PairedDevice(id: pcId, name: "Legacy", host: nil)],
            mdnsPeers: [],
            probe: { host in
                await probed.record(host)
                return nil
            }
        )

        #expect(online.isEmpty)
        #expect(await probed.hosts.isEmpty)
    }

    @Test("liveness is reported per device across a mixed set")
    func mixedSet() async {
        let offId = UUID()

        let online = await AppModel.computeOnlineDeviceIds(
            devices: [
                PairedDevice(id: macId, name: "Mac", host: "10.0.0.9"),
                PairedDevice(id: pcId, name: "PC", host: "192.168.0.20"),
                PairedDevice(id: offId, name: "Off", host: "192.168.0.30")
            ],
            mdnsPeers: [Peer(id: macId, name: "Mac", host: "10.0.0.9", port: 51888)],
            probe: { [macId, pcId] host in
                if host == "10.0.0.9" { return Peer(id: macId, name: "Mac", host: host, port: 51888) }
                return host == "192.168.0.20" ? Peer(id: pcId, name: "PC", host: host, port: 51888) : nil
            }
        )

        #expect(online == [macId, pcId])
    }

    @Test("liveness is independent of the manual connected (pause) flag")
    func pausedDeviceStillReportsTrueLiveness() async {
        let online = await AppModel.computeOnlineDeviceIds(
            devices: [PairedDevice(id: macId, name: "Mac", host: "10.0.0.9", connected: false)],
            mdnsPeers: [Peer(id: macId, name: "Mac", host: "10.0.0.9", port: 51888)],
            probe: { [macId] host in Peer(id: macId, name: "Mac", host: host, port: 51888) }
        )

        #expect(online == [macId])
    }
}

private actor Probed {
    var hosts: [String] = []
    func record(_ host: String) { hosts.append(host) }
}
