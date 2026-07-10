import ClipboardCore
import CryptoKit
import Foundation
@testable import ClipboardSS

@MainActor
func makeTestAppModel(
    store: ClipStore,
    pasteboard: PasteboardClient,
    launchAtLogin: LaunchAtLoginControlling = LaunchAtLoginController()
) throws -> AppModel {
    let identity = DeviceIdentity(id: UUID(), name: "Test Mac")
    let pairedStore = try PairedDeviceStore(
        storageURL: store.storageDirectory.appendingPathComponent("paired-devices.json"),
        keyStorage: TestPairKeyStorage()
    )
    let transport = TestPeerTransport()
    let pairingCoordinator = PairingCoordinator(
        identity: identity,
        pairedStore: pairedStore,
        transport: transport
    )
    let clipReceiver = ClipReceiver(store: store, pasteboard: pasteboard)
    let clipServer = try ClipServer(
        identity: identity,
        receiver: clipReceiver,
        pairingCoordinator: pairingCoordinator
    )
    let peerBrowser = PeerBrowser(identityId: identity.id)
    let clipSender = ClipSender(
        identity: identity,
        pairedStore: pairedStore,
        transport: transport,
        storageDirectory: store.storageDirectory
    )
    let fileSender = FileSender(
        identity: identity,
        pairedStore: pairedStore,
        transport: transport
    )
    let downloadsDir = store.storageDirectory.appendingPathComponent("Downloads", isDirectory: true)
    let fileReceiver = FileReceiver(
        pairedStore: pairedStore,
        transfersDirectory: store.storageDirectory.appendingPathComponent("Transfers", isDirectory: true),
        destinationProvider: { downloadsDir }
    )

    return AppModel(
        store: store,
        writer: ClipboardWriter(pasteboard: pasteboard, store: store),
        screenshotCaptureService: ScreenshotCaptureService(),
        ocrService: OCRService(),
        launchAtLogin: launchAtLogin,
        pasteboard: pasteboard,
        pairingCoordinator: pairingCoordinator,
        peerBrowser: peerBrowser,
        clipSender: clipSender,
        clipServer: clipServer,
        fileSender: fileSender,
        fileReceiver: fileReceiver
    )
}

private final class TestPairKeyStorage: PairKeyStorage, @unchecked Sendable {
    private var keys: [UUID: SymmetricKey] = [:]

    func storeKey(_ key: SymmetricKey, for deviceId: UUID) throws {
        keys[deviceId] = key
    }

    func getKey(for deviceId: UUID) throws -> SymmetricKey? {
        keys[deviceId]
    }

    func deleteKey(for deviceId: UUID) throws {
        keys[deviceId] = nil
    }
}

private struct TestPeerTransport: PeerTransport {
    func send(_ data: Data, to peer: Peer) async throws -> Data {
        Data()
    }
}
