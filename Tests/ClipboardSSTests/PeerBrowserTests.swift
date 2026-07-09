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
                "v": "1",
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
                "v": "1",
            ],
            identityId: identityId
        )

        #expect(peer == Peer(id: androidId, name: "Android Device", host: "Android Device", port: 0))
    }

    @Test("ignores the local device")
    func ignoresLocalDevice() throws {
        let identityId = try #require(UUID(uuidString: "8fb5790c-4533-47bb-90af-827291247fe1"))

        let peer = PeerBrowser.peer(
            serviceName: "Leonardo's MacBook",
            txt: [
                "deviceName": "Leonardo's MacBook",
                "deviceId": identityId.uuidString.lowercased(),
                "v": "1",
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
