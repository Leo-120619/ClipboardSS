import ClipboardCore
import CryptoKit
import Foundation
@testable import ClipboardSS

@MainActor
func makeTestAppModel(
    store: ClipStore,
    pasteboard: PasteboardClient,
    launchAtLogin: LaunchAtLoginControlling = LaunchAtLoginController(),
    screenTextCaptureService: any ScreenTextCapturing = ScreenTextCaptureService(),
    screenshotCaptureService: any ScreenshotCapturing = ScreenshotCaptureService(),
    snippetStore: TextSnippetStore = TextSnippetStore(
        defaults: UserDefaults(suiteName: "AppModelTests-\(UUID().uuidString)") ?? .standard
    ),
    clipboardMonitor: ClipboardMonitor? = nil
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
    let clipReceiver = ClipReceiver(store: store, pasteboard: pasteboard, monitor: clipboardMonitor)
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
        localDeviceId: identity.id,
        transfersDirectory: store.storageDirectory.appendingPathComponent("Transfers", isDirectory: true),
        destinationProvider: { downloadsDir }
    )

    return AppModel(
        store: store,
        writer: ClipboardWriter(pasteboard: pasteboard, store: store),
        screenshotCaptureService: screenshotCaptureService,
        ocrService: OCRService(),
        screenTextCaptureService: screenTextCaptureService,
        launchAtLogin: launchAtLogin,
        pasteboard: pasteboard,
        snippetStore: snippetStore,
        pairingCoordinator: pairingCoordinator,
        peerBrowser: peerBrowser,
        clipSender: clipSender,
        clipServer: clipServer,
        fileSender: fileSender,
        fileReceiver: fileReceiver,
        clipboardMonitor: clipboardMonitor
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
    func send(_ data: Data, to peer: Peer, timeout: TimeInterval) async throws -> Data {
        Data()
    }
}
