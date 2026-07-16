import Testing
import Foundation
import ClipboardCore
@testable import ClipboardSS

@Suite("Device liveness")
struct AppModelLivenessTests {
    private let macId = UUID()
    private let pcId = UUID()

    @Test("a device visible over mDNS is online without probing")
    func mdnsPeerIsOnlineWithoutProbe() async {
        let probed = Probed()

        let online = await AppModel.computeOnlineDeviceIds(
            devices: [PairedDevice(id: macId, name: "Mac", host: "10.0.0.9")],
            mdnsPeers: [Peer(id: macId, name: "Mac", host: "192.168.0.4", port: 51888)],
            probe: { host in
                await probed.record(host)
                return nil
            }
        )

        #expect(online == [macId])
        #expect(await probed.hosts.isEmpty)
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
            probe: { [pcId] host in
                host == "192.168.0.20" ? Peer(id: pcId, name: "PC", host: host, port: 51888) : nil
            }
        )

        #expect(online == [macId, pcId])
    }

    @Test("liveness is independent of the manual connected (pause) flag")
    func pausedDeviceStillReportsTrueLiveness() async {
        let online = await AppModel.computeOnlineDeviceIds(
            devices: [PairedDevice(id: macId, name: "Mac", host: "10.0.0.9", connected: false)],
            mdnsPeers: [Peer(id: macId, name: "Mac", host: "10.0.0.9", port: 51888)],
            probe: { _ in nil }
        )

        #expect(online == [macId])
    }
}

private actor Probed {
    var hosts: [String] = []
    func record(_ host: String) { hosts.append(host) }
}
