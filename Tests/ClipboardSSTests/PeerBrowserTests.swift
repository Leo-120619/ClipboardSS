import ClipboardCore
import Foundation
import Testing
@testable import ClipboardSS

@MainActor
@Suite("Peer browser")
struct PeerBrowserTests {
    @Test("parses Android Bonjour records with a device name")
    func parsesAndroidBonjourRecordWithDeviceName() throws {
        let identityId = UUID()
        let androidId = try #require(UUID(uuidString: "367c33ad-2707-4c1f-b9dc-5ff7f482bd00"))

        let peer = PeerBrowser.peer(
            serviceName: "367c33ad-2707-4c1f-b9dc-5ff7f482bd00",
            txt: [
                "deviceName": "Android Device",
                "deviceId": androidId.uuidString.lowercased(),
                "v": "2",
            ],
            identityId: identityId
        )

        #expect(peer == Peer(id: androidId, name: "Android Device", host: androidId.uuidString.lowercased(), port: 0))
    }

    @Test("uses service name when Android Bonjour TXT record omits device name")
    func usesServiceNameWhenAndroidBonjourRecordOmitsDeviceName() throws {
        let identityId = UUID()
        let androidId = try #require(UUID(uuidString: "367c33ad-2707-4c1f-b9dc-5ff7f482bd00"))

        let peer = PeerBrowser.peer(
            serviceName: "Android Device",
            txt: [
                "deviceId": androidId.uuidString.lowercased(),
                "v": "2",
            ],
            identityId: identityId
        )

        #expect(peer == Peer(id: androidId, name: "Android Device", host: "Android Device", port: 0))
    }

    @Test("lists a v1 peer but marks it as needing an update")
    func listsV1PeerAsNeedingUpdate() throws {
        let oldId = try #require(UUID(uuidString: "367c33ad-2707-4c1f-b9dc-5ff7f482bd00"))

        let peer = try #require(PeerBrowser.peer(
            serviceName: "Old Phone",
            txt: ["deviceName": "Old Phone", "deviceId": oldId.uuidString.lowercased(), "v": "1"],
            identityId: UUID()
        ))

        #expect(peer.protocolVersion == 1)
        #expect(peer.needsUpdate)
    }

    @Test("a v2 peer does not need an update")
    func v2PeerIsCurrent() throws {
        let peer = try #require(PeerBrowser.peer(
            serviceName: "Phone",
            txt: ["deviceId": UUID().uuidString.lowercased(), "v": "2"],
            identityId: UUID()
        ))
        #expect(!peer.needsUpdate)
    }

    @Test("ignores the local device")
    func ignoresLocalDevice() throws {
        let identityId = try #require(UUID(uuidString: "8fb5790c-4533-47bb-90af-827291247fe1"))

        let peer = PeerBrowser.peer(
            serviceName: "Leonardo's MacBook",
            txt: [
                "deviceName": "Leonardo's MacBook",
                "deviceId": identityId.uuidString.lowercased(),
                "v": "2",
            ],
            identityId: identityId
        )

        #expect(peer == nil)
    }

    @Test("retains last seen peers during browse-result grace period")
    func retainsLastSeenPeersDuringGracePeriod() throws {
        let peer = Peer(id: UUID(), name: "Android", host: "Android", port: 0)
        let now = Date()

        let peers = PeerBrowser.peersForPublish(
            current: [],
            lastSeen: [peer.id: (peer: peer, lastSeen: now.addingTimeInterval(-4))],
            now: now,
            gracePeriod: 10
        )

        #expect(peers == [peer])
    }

    @Test("drops stale peers after browse-result grace period")
    func dropsStalePeersAfterGracePeriod() throws {
        let peer = Peer(id: UUID(), name: "Android", host: "Android", port: 0)
        let now = Date()

        let peers = PeerBrowser.peersForPublish(
            current: [],
            lastSeen: [peer.id: (peer: peer, lastSeen: now.addingTimeInterval(-12))],
            now: now,
            gracePeriod: 10
        )

        #expect(peers.isEmpty)
    }
}

@Suite("Needs-update resolution")
struct DeviceNeedsUpdateTests {
    @Test("a paired device needs an update when mDNS or a probe reports an older protocol")
    func needsUpdateFromMdnsOrProbe() {
        let id = UUID()
        let old = Peer(id: id, name: "Old", host: "old", port: 0, protocolVersion: 1)
        let current = Peer(id: id, name: "New", host: "new", port: 0)
        #expect(AppModel.deviceNeedsUpdate(id, mdnsPeers: [old], outdatedDeviceIds: []))
        #expect(AppModel.deviceNeedsUpdate(id, mdnsPeers: [], outdatedDeviceIds: [id]))
        #expect(!AppModel.deviceNeedsUpdate(id, mdnsPeers: [current], outdatedDeviceIds: []))
    }
}
