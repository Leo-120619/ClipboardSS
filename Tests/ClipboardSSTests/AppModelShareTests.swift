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

        fixture.model.updateOnlineDeviceIds([fixture.deviceId])

        #expect(!FileManager.default.fileExists(atPath: drop.path))
        #expect(fixture.model.transfers.map(\.fileName) == ["photo.png"])
    }

    @Test("a drop older than 24 hours is discarded instead of sent")
    func dropOlderThan24hIsDiscarded() async throws {
        let fixture = try await ShareFixture()
        let drop = try fixture.makeDrop()
        fixture.model.updateOnlineDeviceIds([fixture.deviceId])

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
        fixture.model.updateOnlineDeviceIds([fixture.deviceId])

        fixture.model.enqueueShares(ShareInbox.pendingDrops(in: fixture.outbox))
        #expect(fixture.model.transfers.count == 1)

        for _ in 0..<200 where fixture.model.transfers.contains { $0.isActive } {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!fixture.model.transfers.contains { $0.isActive })
        #expect(fixture.stagedEntries().isEmpty)
    }

    @Test("a reachable device that needs an update keeps the drop queued")
    func outdatedDeviceKeepsDropQueued() async throws {
        let fixture = try await ShareFixture()
        let drop = try fixture.makeDrop()
        fixture.model.recordProtocolStatus(fixture.deviceId, needsUpdate: true)
        fixture.model.updateOnlineDeviceIds([fixture.deviceId])

        fixture.model.enqueueShares(ShareInbox.pendingDrops(in: fixture.outbox))

        #expect(FileManager.default.fileExists(atPath: drop.path))
        #expect(fixture.model.transfers.isEmpty)
        #expect(fixture.model.pendingShares.count == 1)
    }

    @Test("cancelling the picker discards only the drops it showed")
    func cancelRemovesOnlyShownDrops() async throws {
        let fixture = try await ShareFixture(deviceCount: 2)
        fixture.model.updateOnlineDeviceIds(Set(fixture.deviceIds))
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

    @Test("picking a device sends only the drops the picker showed")
    func completeSendsOnlyShownDrops() async throws {
        let fixture = try await ShareFixture(deviceCount: 2)
        fixture.model.updateOnlineDeviceIds(Set(fixture.deviceIds))
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
    init(deviceCount: Int = 1) async throws {
        deviceIds = (0..<deviceCount).map { _ in UUID() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppModelShareTests-\(UUID().uuidString)", isDirectory: true)
        let store = try ClipStore(storageDirectory: directory)
        model = try makeTestAppModel(store: store, pasteboard: ShareFakePasteboard())
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

    func stagedEntries() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: model.shareStagingDirectory.path)) ?? []
    }

    func makeDrop() throws -> URL {
        let drop = outbox.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: drop, withIntermediateDirectories: true)
        try Data("png".utf8).write(to: drop.appendingPathComponent("photo.png"))
        let manifest = ShareManifest(id: drop.lastPathComponent, fileNames: ["photo.png"])
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
