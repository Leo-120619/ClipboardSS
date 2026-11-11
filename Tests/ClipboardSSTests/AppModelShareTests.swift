import ClipboardCore
import CryptoKit
import Foundation
import Testing
@testable import ClipboardSS

@MainActor
@Suite("App model shares")
struct AppModelShareTests {
    @Test("a drop is kept while no paired device is reachable")
    func dropIsKeptWhenNoDeviceReachable() async throws {
        let fixture = try await ShareFixture()
        let drop = try fixture.makeDrop()

        fixture.model.enqueueShares(ShareInbox.pendingDrops(in: fixture.outbox))

        #expect(FileManager.default.fileExists(atPath: drop.path))
        #expect(fixture.model.transfers.isEmpty)
    }

    @Test("a queued drop is sent once its device comes online")
    func dropIsSentWhenDeviceComesOnline() async throws {
        let fixture = try await ShareFixture()
        let drop = try fixture.makeDrop()
        fixture.model.enqueueShares(ShareInbox.pendingDrops(in: fixture.outbox))

        await fixture.goOnline([fixture.deviceId])

        #expect(!FileManager.default.fileExists(atPath: drop.path))
        #expect(fixture.model.transfers.map(\.fileName) == ["photo.png"])
    }

    @Test("a drop older than 24 hours is discarded instead of sent")
    func dropOlderThan24hIsDiscarded() async throws {
        let fixture = try await ShareFixture()
        let drop = try fixture.makeDrop()
        await fixture.goOnline([fixture.deviceId])

        fixture.model.enqueueShares(
            ShareInbox.pendingDrops(in: fixture.outbox),
            now: Date().addingTimeInterval(25 * 60 * 60)
        )

        #expect(!FileManager.default.fileExists(atPath: drop.path))
        #expect(fixture.model.transfers.isEmpty)
        #expect(fixture.stagedEntries().isEmpty)
    }

    @Test("the staging folder is removed once the send finishes")
    func stagingFolderIsRemovedAfterSend() async throws {
        let fixture = try await ShareFixture()
        _ = try fixture.makeDrop()
        await fixture.goOnline([fixture.deviceId])

        fixture.model.enqueueShares(ShareInbox.pendingDrops(in: fixture.outbox))
        #expect(fixture.model.transfers.count == 1)

        for _ in 0..<200 where fixture.model.transfers.contains { $0.isActive } {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!fixture.model.transfers.contains { $0.isActive })
        #expect(fixture.stagedEntries().isEmpty)
    }

    @Test("a device that answered 426 keeps the drop queued")
    func outdatedDeviceKeepsDropQueued() async throws {
        let fixture = try await ShareFixture()
        let drop = try fixture.makeDrop()
        await fixture.model.applyLiveness(LivenessReport(upgradeRequired: [fixture.deviceId]))
        #expect(fixture.model.deviceNeedsUpdate(fixture.deviceId))

        fixture.model.enqueueShares(ShareInbox.pendingDrops(in: fixture.outbox))

        #expect(FileManager.default.fileExists(atPath: drop.path))
        #expect(fixture.model.transfers.isEmpty)
        #expect(fixture.model.pendingShares.count == 1)
    }

    @Test("cancelling the picker discards only the drops it showed")
    func cancelRemovesOnlyShownDrops() async throws {
        let fixture = try await ShareFixture(deviceCount: 2)
        await fixture.goOnline(fixture.deviceIds)
        let shown = try fixture.makeDrop()
        fixture.model.enqueueShares(ShareInbox.pendingDrops(in: fixture.outbox))
        let late = try fixture.makeDrop()
        fixture.model.enqueueShares(ShareInbox.pendingDrops(in: fixture.outbox))
        #expect(fixture.model.pendingSend?.shareDrops == [AppModel.shareKey(shown)])

        fixture.model.cancelPendingSend()

        #expect(!FileManager.default.fileExists(atPath: shown.path))
        #expect(FileManager.default.fileExists(atPath: late.path))
        #expect(fixture.model.pendingSend?.shareDrops == [AppModel.shareKey(late)])
    }

    @Test("nine shared files go to one device one at a time, and every one is sent")
    func nineFilesAreSentOneAtATime() async throws {
        let transport = CountingTransport()
        let fixture = try await ShareFixture(transport: transport)
        let names = (1...9).map { "photo\($0).png" }
        let drop = try fixture.makeDrop(names: names)
        await fixture.goOnline([fixture.deviceId])

        fixture.model.enqueueShares(ShareInbox.pendingDrops(in: fixture.outbox))
        #expect(fixture.model.transfers.count == 9)
        try await fixture.waitForTransfersToSettle()

        // The receiver accepts at most 8 sessions per device; one at a time never exceeds it.
        #expect(transport.maxConcurrentSends == 1)
        #expect(Set(transport.offeredPaths) == ["/v1/file/offer"])
        #expect(transport.offeredPaths.count == 9)
        #expect(!FileManager.default.fileExists(atPath: drop.path))
    }

    @Test("a share whose device drops out before its files are handed off stays in the outbox")
    func queuedShareIsKeptWhenDeviceDropsBeforeHandOff() async throws {
        let transport = CountingTransport(delay: .milliseconds(50))
        let fixture = try await ShareFixture(transport: transport)
        let first = try fixture.makeDrop(names: ["a.png"])
        await fixture.goOnline([fixture.deviceId])
        fixture.model.enqueueShares(ShareInbox.pendingDrops(in: fixture.outbox))
        let second = try fixture.makeDrop(names: ["b.png", "c.png"])
        fixture.model.enqueueShares(ShareInbox.pendingDrops(in: fixture.outbox))
        #expect(fixture.model.transfers.count == 3)

        await fixture.goOnline([])
        try await fixture.waitForTransfersToSettle()

        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.appendingPathComponent("b.png").path))
        #expect(FileManager.default.fileExists(atPath: second.appendingPathComponent("c.png").path))
        #expect(fixture.model.pendingShares.map { AppModel.shareKey($0.directory) } == [AppModel.shareKey(second)])
        #expect(transport.offeredPaths.count == 1)

        await fixture.goOnline([fixture.deviceId])
        try await fixture.waitForTransfersToSettle()
        #expect(transport.offeredPaths.count == 3)
        #expect(!FileManager.default.fileExists(atPath: second.path))
    }

    @Test("quitting after some files of a share were staged keeps the unsent ones for the next launch")
    func partlySentShareSurvivesRestart() async throws {
        let transport = CountingTransport(held: true)
        defer { transport.release() }
        let fixture = try await ShareFixture(transport: transport)
        let drop = try fixture.makeDrop(names: ["a.png", "b.png", "c.png"])
        await fixture.goOnline([fixture.deviceId])
        fixture.model.enqueueShares(ShareInbox.pendingDrops(in: fixture.outbox))
        // a.png is staged and in flight; b.png and c.png wait in the queue. The app quits now.
        #expect(!FileManager.default.fileExists(atPath: drop.appendingPathComponent("a.png").path))

        let relaunched = ShareInbox.pendingDrops(in: fixture.outbox)
        #expect(relaunched.map { AppModel.shareKey($0.directory) } == [AppModel.shareKey(drop)])
        #expect(relaunched.first?.fileURLs.map(\.lastPathComponent) == ["b.png", "c.png"])

        let restartTransport = CountingTransport()
        let restarted = try await ShareFixture(transport: restartTransport)
        await restarted.goOnline([restarted.deviceId])
        restarted.model.enqueueShares(relaunched)
        #expect(restarted.model.transfers.map(\.fileName).sorted() == ["b.png", "c.png"])
        try await restarted.waitForTransfersToSettle()
        #expect(restartTransport.offeredPaths.count == 2)
        #expect(!FileManager.default.fileExists(atPath: drop.path))
    }

    @Test("a cancelled queued file of a share is not re-sent after a restart")
    func cancelledQueuedShareFileIsDroppedFromManifest() async throws {
        let transport = CountingTransport(held: true)
        defer { transport.release() }
        let fixture = try await ShareFixture(transport: transport)
        let drop = try fixture.makeDrop(names: ["a.png", "b.png", "c.png"])
        await fixture.goOnline([fixture.deviceId])
        fixture.model.enqueueShares(ShareInbox.pendingDrops(in: fixture.outbox))
        let cancelled = try #require(fixture.model.transfers.first { $0.fileName == "b.png" })

        fixture.model.cancelTransfer(id: cancelled.id)

        let relaunched = ShareInbox.pendingDrops(in: fixture.outbox)
        #expect(relaunched.map { AppModel.shareKey($0.directory) } == [AppModel.shareKey(drop)])
        #expect(relaunched.first?.fileURLs.map(\.lastPathComponent) == ["c.png"])
    }

    @Test("cancelling the last queued file of a share removes the drop instead of leaving an empty manifest")
    func cancellingLastQueuedShareFileRemovesDrop() async throws {
        let transport = CountingTransport(held: true)
        defer { transport.release() }
        let fixture = try await ShareFixture(transport: transport)
        let drop = try fixture.makeDrop(names: ["a.png", "b.png"])
        await fixture.goOnline([fixture.deviceId])
        fixture.model.enqueueShares(ShareInbox.pendingDrops(in: fixture.outbox))
        let cancelled = try #require(fixture.model.transfers.first { $0.fileName == "b.png" })

        fixture.model.cancelTransfer(id: cancelled.id)

        #expect(!FileManager.default.fileExists(atPath: drop.path))
        #expect(ShareInbox.pendingDrops(in: fixture.outbox).isEmpty)
    }

    @Test("a picked device that is unreachable never sends the drop to another device")
    func failedPickDoesNotAutoSendElsewhere() async throws {
        let fixture = try await ShareFixture(deviceCount: 2)
        await fixture.goOnline(fixture.deviceIds)
        let drop = try fixture.makeDrop()
        fixture.model.enqueueShares(ShareInbox.pendingDrops(in: fixture.outbox))
        #expect(fixture.model.pendingSend != nil)
        await fixture.goOnline([fixture.deviceIds[1]])

        fixture.model.completePendingSend(to: fixture.deviceIds[0])

        #expect(fixture.model.transfers.isEmpty)
        #expect(FileManager.default.fileExists(atPath: drop.path))
        #expect(fixture.model.lastError == fixture.model.unreachableMessage(for: fixture.deviceIds[0]))
        // Another device coming and going does not send it either.
        await fixture.goOnline([])
        await fixture.goOnline([fixture.deviceIds[1]])
        #expect(fixture.model.transfers.isEmpty)
        #expect(fixture.model.pendingSend == nil)

        // Once the picked device is back, the drop goes to it.
        await fixture.goOnline([fixture.deviceIds[0]])
        #expect(fixture.model.transfers.map(\.fileName) == ["photo.png"])
        #expect(!FileManager.default.fileExists(atPath: drop.path))
    }

    @Test("a share for a clock-skewed device says the clock is out of sync")
    func clockSkewedTargetReportsClockMessage() async throws {
        let fixture = try await ShareFixture()
        await fixture.model.applyLiveness(LivenessReport(clockSkew: [fixture.deviceId]))
        _ = try fixture.makeDrop()

        fixture.model.enqueueShares(ShareInbox.pendingDrops(in: fixture.outbox))

        #expect(fixture.model.lastError == ProtocolMismatch.clockOutOfSyncMessage(deviceNames: ["Device 0"]))
        #expect(fixture.model.pendingShares.count == 1)
    }

    @Test("picking a device sends only the drops the picker showed")
    func completeSendsOnlyShownDrops() async throws {
        let fixture = try await ShareFixture(deviceCount: 2)
        await fixture.goOnline(fixture.deviceIds)
        let shown = try fixture.makeDrop()
        fixture.model.enqueueShares(ShareInbox.pendingDrops(in: fixture.outbox))
        let late = try fixture.makeDrop()
        fixture.model.enqueueShares(ShareInbox.pendingDrops(in: fixture.outbox))

        fixture.model.completePendingSend(to: fixture.deviceIds[0])

        #expect(!FileManager.default.fileExists(atPath: shown.path))
        #expect(fixture.model.transfers.count == 1)
        #expect(FileManager.default.fileExists(atPath: late.path))
        #expect(fixture.model.pendingSend?.shareDrops == [AppModel.shareKey(late)])
    }
}

@MainActor
private struct ShareFixture {
    let model: AppModel
    let outbox: URL
    let deviceIds: [UUID]
    var deviceId: UUID { deviceIds[0] }

    /// Devices use a TEST-NET address; sends go through the fake transport in
    /// `makeTestAppModel`, so nothing touches the network.
    init(deviceCount: Int = 1, transport: PeerTransport = TestPeerTransport()) async throws {
        deviceIds = (0..<deviceCount).map { _ in UUID() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppModelShareTests-\(UUID().uuidString)", isDirectory: true)
        let store = try ClipStore(storageDirectory: directory)
        model = try makeTestAppModel(store: store, pasteboard: ShareFakePasteboard(), transport: transport)
        outbox = directory.appendingPathComponent("ShareOutbox", isDirectory: true)
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        for (index, id) in deviceIds.enumerated() {
            try await model.pairingCoordinator.pairedStore.addDevice(
                PairedDevice(id: id, name: "Device \(index)", host: "192.0.2.\(index + 1)"),
                key: SymmetricKey(size: .bits256)
            )
        }
        await model.refreshPairedDevices()
    }

    /// Lands a full liveness pass in which `ids` answered a valid pong at their stored host,
    /// through the same entry point production pings use.
    func goOnline(_ ids: [UUID]) async {
        var report = LivenessReport()
        for (index, id) in deviceIds.enumerated() where ids.contains(id) {
            report.verifiedHosts[id] = "192.0.2.\(index + 1)"
        }
        await model.applyLiveness(report)
    }

    func stagedEntries() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: model.shareStagingDirectory.path)) ?? []
    }

    func waitForTransfersToSettle() async throws {
        for _ in 0..<400 where model.transfers.contains(where: { $0.isActive }) {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!model.transfers.contains { $0.isActive })
    }

    func makeDrop(names: [String] = ["photo.png"]) throws -> URL {
        let drop = outbox.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: drop, withIntermediateDirectories: true)
        for name in names {
            try Data("png".utf8).write(to: drop.appendingPathComponent(name))
        }
        let manifest = ShareManifest(id: drop.lastPathComponent, fileNames: names)
        try JSONEncoder().encode(manifest).write(to: drop.appendingPathComponent("manifest.json"))
        return drop
    }
}

private final class ShareFakePasteboard: PasteboardClient {
    func currentChangeCount() -> Int { 0 }
    func readSnapshot() -> ClipboardSnapshot { ClipboardSnapshot(text: nil, imageData: nil) }
    func clearContents() {}
    func writeText(_ text: String) {}
    func writeImageData(_ data: Data) {}
}

/// Fails every request after `delay` (and, when `held`, only once `release()` is called),
/// recording how many sends overlap and which
/// file-transfer paths were offered.
private final class CountingTransport: PeerTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let delay: Duration
    private var inFlight = 0
    private var _max = 0
    private var _offered: [String] = []
    private var held: Bool

    init(delay: Duration = .milliseconds(5), held: Bool = false) {
        self.delay = delay
        self.held = held
    }

    /// Lets held requests finish.
    func release() { lock.withLock { held = false } }

    var maxConcurrentSends: Int { lock.withLock { _max } }
    var offeredPaths: [String] { lock.withLock { _offered } }

    func send(_ data: Data, to peer: Peer, timeout: TimeInterval) async throws -> Data {
        let line = String(decoding: data.prefix(64), as: UTF8.self).split(separator: " ")
        let path = line.count > 1 ? String(line[1]) : ""
        lock.withLock {
            inFlight += 1
            _max = max(_max, inFlight)
            if path == "/v1/file/offer" { _offered.append(path) }
        }
        defer { lock.withLock { inFlight -= 1 } }
        while lock.withLock({ held }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: delay)
        throw URLError(.cannotConnectToHost)
    }
}
