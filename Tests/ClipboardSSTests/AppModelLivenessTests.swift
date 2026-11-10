import Testing
import Foundation
import CryptoKit
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

    @Test("file target resolution rejects offline and paused devices")
    func verifiedFileTarget() {
        let enabled = PairedDevice(id: macId, name: "Mac", host: "10.0.0.9")
        let paused = PairedDevice(id: macId, name: "Mac", host: "10.0.0.9", connected: false)

        #expect(AppModel.resolveVerifiedPeer(device: enabled, online: false, mdnsPeers: []) == nil)
        #expect(AppModel.resolveVerifiedPeer(device: paused, online: true, mdnsPeers: []) == nil)
        #expect(AppModel.resolveVerifiedPeer(device: enabled, online: true, mdnsPeers: [])?.host == "10.0.0.9")
    }

    @Test("a file target goes to the ping-verified stored host, not an mDNS-claimed address")
    func verifiedFileTargetIgnoresMdnsHost() {
        let device = PairedDevice(id: macId, name: "Mac", host: "10.0.0.9")
        let claimed = Peer(id: macId, name: "Mac", host: "10.0.0.66", port: 51888)
        #expect(AppModel.resolveVerifiedPeer(device: device, online: true, mdnsPeers: [claimed])?.host == "10.0.0.9")
    }

    @Test("a file target resolved from the stored host keeps the older version flag")
    func verifiedFileTargetCarriesProbedVersion() {
        let device = PairedDevice(id: macId, name: "Mac", host: "10.0.0.9")
        let peer = AppModel.resolveVerifiedPeer(device: device, online: true, mdnsPeers: [], outdatedDeviceIds: [macId])
        #expect(peer?.needsUpdate == true)
        #expect(AppModel.resolveVerifiedPeer(device: device, online: true, mdnsPeers: [])?.needsUpdate == false)
    }

    @Test("an impostor answering /v1/id or mDNS with the device id is not marked online")
    func impostorAnsweringIdIsNotMarkedOnline() async {
        // The impostor at 10.0.0.66 advertises the paired id but cannot produce a valid pong.
        let report = await AppModel.computeLiveness(
            devices: [PairedDevice(id: macId, name: "Mac", host: "10.0.0.9")],
            mdnsPeers: [Peer(id: macId, name: "Mac", host: "10.0.0.66", port: 51888)],
            ping: { _, _ in .unverified }
        )

        #expect(report.onlineIds.isEmpty)
    }

    @Test("the stored host is not updated without a valid pong")
    func hostIsNotUpdatedWithoutValidPong() async {
        let device = PairedDevice(id: macId, name: "Mac", host: "10.0.0.9")
        let report = await AppModel.computeLiveness(
            devices: [device],
            mdnsPeers: [Peer(id: macId, name: "Mac", host: "10.0.0.66", port: 51888)],
            ping: { _, host in host == "10.0.0.66" ? .upgradeRequired : .unverified }
        )

        #expect(AppModel.hostUpdates(devices: [device], report: report).isEmpty)
        #expect(report.onlineIds.isEmpty)
    }

    @Test("a valid pong marks the device online and moves its stored host")
    func validPongMarksOnlineAndUpdatesHost() async {
        let device = PairedDevice(id: macId, name: "Mac", host: "10.0.0.9")
        let probed = Probed()
        let report = await AppModel.computeLiveness(
            devices: [device],
            mdnsPeers: [Peer(id: macId, name: "Mac", host: "192.168.0.4", port: 51888)],
            ping: { _, host in
                await probed.record(host)
                return host == "192.168.0.4" ? .alive : .unverified
            }
        )

        #expect(report.onlineIds == [macId])
        #expect(AppModel.hostUpdates(devices: [device], report: report) == [macId: "192.168.0.4"])
        #expect(await probed.hosts == ["192.168.0.4"])
    }

    @Test("a valid pong clears an earlier 426 from another address")
    func validPongClearsUpgradeRequired() async {
        let report = await AppModel.computeLiveness(
            devices: [PairedDevice(id: macId, name: "Mac", host: "10.0.0.9")],
            mdnsPeers: [Peer(id: macId, name: "Mac", host: "10.0.0.66", port: 51888)],
            ping: { _, host in host == "10.0.0.66" ? .upgradeRequired : .alive }
        )

        #expect(report.onlineIds == [macId])
        #expect(report.upgradeRequired.isEmpty)
    }

    @Test("a 426 to every ping reports the device as needing an update, not online")
    func upgradeRequiredIsOutdatedNotOnline() async {
        let report = await AppModel.computeLiveness(
            devices: [PairedDevice(id: pcId, name: "PC", host: "192.168.0.20")],
            mdnsPeers: [],
            ping: { _, _ in .upgradeRequired }
        )

        #expect(report.onlineIds.isEmpty)
        #expect(report.upgradeRequired == [pcId])
    }

    @Test("a stale mDNS address falls back to the stored address")
    func staleMdnsFallsBackToStoredHost() async {
        let probed = Probed()
        let report = await AppModel.computeLiveness(
            devices: [PairedDevice(id: macId, name: "Mac", host: "10.0.0.9")],
            mdnsPeers: [Peer(id: macId, name: "Mac", host: "10.0.0.8", port: 51888)],
            ping: { _, host in
                await probed.record(host)
                return host == "10.0.0.9" ? .alive : .unverified
            }
        )

        #expect(report.onlineIds == [macId])
        #expect(report.verifiedHosts[macId] == "10.0.0.9")
        #expect(await probed.hosts == ["10.0.0.8", "10.0.0.9"])
    }

    @Test("a ping that fails or times out marks the device offline")
    func pingFailureIsOffline() async {
        let report = await AppModel.computeLiveness(
            devices: [PairedDevice(id: pcId, name: "PC", host: "192.168.0.20")],
            mdnsPeers: [],
            ping: { _, _ in .unverified }
        )

        #expect(report.onlineIds.isEmpty)
    }

    @Test("a device with no stored host is offline and is not pinged")
    func noHostIsOfflineWithoutPing() async {
        let probed = Probed()

        let report = await AppModel.computeLiveness(
            devices: [PairedDevice(id: pcId, name: "Legacy", host: nil)],
            mdnsPeers: [],
            ping: { _, host in
                await probed.record(host)
                return .unverified
            }
        )

        #expect(report.onlineIds.isEmpty)
        #expect(await probed.hosts.isEmpty)
    }

    @Test("liveness is reported per device across a mixed set")
    func mixedSet() async {
        let offId = UUID()

        let report = await AppModel.computeLiveness(
            devices: [
                PairedDevice(id: macId, name: "Mac", host: "10.0.0.9"),
                PairedDevice(id: pcId, name: "PC", host: "192.168.0.20"),
                PairedDevice(id: offId, name: "Off", host: "192.168.0.30")
            ],
            mdnsPeers: [Peer(id: macId, name: "Mac", host: "10.0.0.9", port: 51888)],
            ping: { device, host in
                (device.id, host) == (offId, "192.168.0.30") ? .unverified : .alive
            }
        )

        #expect(report.onlineIds == [macId, pcId])
    }

    @Test("liveness is independent of the manual connected (pause) flag")
    func pausedDeviceStillReportsTrueLiveness() async {
        let report = await AppModel.computeLiveness(
            devices: [PairedDevice(id: macId, name: "Mac", host: "10.0.0.9", connected: false)],
            mdnsPeers: [Peer(id: macId, name: "Mac", host: "10.0.0.9", port: 51888)],
            ping: { _, _ in .alive }
        )

        #expect(report.onlineIds == [macId])
    }
}

@Suite("Device liveness: clock skew and mDNS version claims")
@MainActor
struct AppModelLivenessStateTests {
    private func makeModel(deviceId: UUID) async throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppModelLivenessTests-\(UUID().uuidString)", isDirectory: true)
        let model = try makeTestAppModel(store: try ClipStore(storageDirectory: directory), pasteboard: LivenessFakePasteboard())
        try await model.pairingCoordinator.pairedStore.addDevice(
            PairedDevice(id: deviceId, name: "Mac", host: "192.0.2.1"),
            key: SymmetricKey(size: .bits256)
        )
        await model.refreshPairedDevices()
        return model
    }

    @Test("a stale-refused ping is reported as clock skew, not online, host unchanged")
    func clockSkewIsVisible() async throws {
        let id = UUID()
        let report = await AppModel.computeLiveness(
            devices: [PairedDevice(id: id, name: "Mac", host: "192.0.2.1")],
            mdnsPeers: [Peer(id: id, name: "Mac", host: "192.0.2.9", port: 51888)],
            ping: { _, host in host == "192.0.2.9" ? .clockSkew : .unverified }
        )
        #expect(report.clockSkew == [id])
        #expect(report.onlineIds.isEmpty)
        #expect(AppModel.hostUpdates(devices: [PairedDevice(id: id, name: "Mac", host: "192.0.2.1")], report: report).isEmpty)

        let model = try await makeModel(deviceId: id)
        await model.applyLiveness(report)
        #expect(model.deviceClockSkewed(id))
        #expect(!model.isDeviceOnline(id))
        #expect(model.pairedDevices.first?.host == "192.0.2.1")
        #expect(model.unreachableMessage(for: id) == ProtocolMismatch.clockOutOfSyncMessage(deviceNames: ["Mac"]))

        // A later valid pong clears it.
        await model.applyLiveness(LivenessReport(verifiedHosts: [id: "192.0.2.1"]))
        #expect(!model.deviceClockSkewed(id))
    }

    @Test("a valid pong overrides an mDNS v1 claim: not needsUpdate, sent to the stored host")
    func pongBeatsMdnsVersionClaim() async throws {
        let id = UUID()
        let impostor = Peer(id: id, name: "Mac", host: "192.0.2.66", port: 51888, protocolVersion: 1)
        let device = PairedDevice(id: id, name: "Mac", host: "192.0.2.1")

        #expect(AppModel.deviceNeedsUpdate(id, mdnsPeers: [impostor], outdatedDeviceIds: []))
        #expect(!AppModel.deviceNeedsUpdate(id, mdnsPeers: [impostor], outdatedDeviceIds: [], verifiedOnlineIds: [id]))

        let target = AppModel.composeSendTargets(mdnsPeers: [impostor], pairedDevices: [device], verifiedOnlineIds: [id])
            .first { $0.id == id }
        #expect(target?.needsUpdate == false)
        #expect(target?.host == "192.0.2.1")
    }
}

private final class LivenessFakePasteboard: PasteboardClient {
    func currentChangeCount() -> Int { 0 }
    func readSnapshot() -> ClipboardSnapshot { ClipboardSnapshot(text: nil, imageData: nil) }
    func clearContents() {}
    func writeText(_ text: String) {}
    func writeImageData(_ data: Data) {}
}

private actor Probed {
    var hosts: [String] = []
    func record(_ host: String) { hosts.append(host) }
}
