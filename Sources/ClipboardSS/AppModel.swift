import AppKit
import ClipboardCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var clips: [ClipItem]
    @Published var searchText = ""
    @Published var selectedFilter: ClipFilter = .all
    @Published var lastError: String?
    @Published var isCapturingScreenshot = false
    @Published var isSelectingScreenText = false
    @Published var screenshotReview: ScreenshotReview?
    @Published var editingImage: NSImage?
    @Published var editingClipID: UUID?
    @Published var clipboardHasImage = false
    @Published var showPreferences = false
    @Published var clipboardShortcut: KeyboardShortcut
    @Published var screenshotShortcut: KeyboardShortcut?
    @Published var screenTextShortcut: KeyboardShortcut?
    @Published var launchAtLoginEnabled: Bool
    @Published var showCoachMarks: Bool
    @Published var currentCoachMarkIndex = 0
    @Published var showDevices = false
    @Published var joinInProgress = false
    @Published private(set) var pairedDevices: [PairedDevice] = []
    @Published private(set) var transfers: [FileTransferState] = []
    @Published var pendingSend: PendingSend?

    let store: ClipStore
    let pairingCoordinator: PairingCoordinator
    let peerBrowser: PeerBrowser
    private let clipSender: ClipSender
    private let clipServer: ClipServer
    private let fileSender: FileSender
    private let fileReceiver: FileReceiver
    private var sendTokens: [UUID: CancellationToken] = [:]
    nonisolated static let coachMarksCompletedDefaultsKey = "hasCompletedCoachMarks"
    nonisolated static let launchAtLoginDefaultsKey = "launchAtLoginEnabled"
    nonisolated static let coachMarkStepCount = CoachMarkStep.steps.count
    private let writer: ClipboardWriter
    private let screenshotCaptureService: ScreenshotCaptureService
    private let ocrService: OCRService
    private let screenTextCaptureService: ScreenTextCaptureService
    private let launchAtLogin: LaunchAtLoginControlling
    private let pasteboard: PasteboardClient
    private var lastBroadcastClipID: UUID?
    var onClipboardShortcutChanged: ((KeyboardShortcut) -> Void)?
    var onScreenshotShortcutChanged: ((KeyboardShortcut?) -> Void)?
    var onScreenTextShortcutChanged: ((KeyboardShortcut?) -> Void)?
    var onPasteRequested: ((PasteRequest) -> Void)?
    var onPreferencesRequested: (() -> Void)?
    var onCloseRequested: (() -> Void)?
    var onScreenTextSelectionReady: ((ScreenTextCapture) -> Void)?

    init(
        store: ClipStore,
        writer: ClipboardWriter,
        screenshotCaptureService: ScreenshotCaptureService,
        ocrService: OCRService,
        screenTextCaptureService: ScreenTextCaptureService = ScreenTextCaptureService(),
        launchAtLogin: LaunchAtLoginControlling = LaunchAtLoginController(),
        pasteboard: PasteboardClient,
        pairingCoordinator: PairingCoordinator,
        peerBrowser: PeerBrowser,
        clipSender: ClipSender,
        clipServer: ClipServer,
        fileSender: FileSender,
        fileReceiver: FileReceiver
    ) {
        self.store = store
        self.writer = writer
        self.screenshotCaptureService = screenshotCaptureService
        self.ocrService = ocrService
        self.screenTextCaptureService = screenTextCaptureService
        self.launchAtLogin = launchAtLogin
        self.pasteboard = pasteboard
        self.pairingCoordinator = pairingCoordinator
        self.peerBrowser = peerBrowser
        self.clipSender = clipSender
        self.clipServer = clipServer
        self.fileSender = fileSender
        self.fileReceiver = fileReceiver
        self.clips = store.items
        self.clipboardShortcut = .savedClipboardShortcut
        self.screenshotShortcut = .savedScreenshotShortcut
        self.screenTextShortcut = .savedScreenTextShortcut
        self.launchAtLoginEnabled = UserDefaults.standard.object(forKey: Self.launchAtLoginDefaultsKey)
            as? Bool ?? true
        let forceCoachMarks = ProcessInfo.processInfo.environment["CLIPBOARDSS_FORCE_COACH_MARKS"] == "1"
        self.showCoachMarks = forceCoachMarks || !UserDefaults.standard.bool(forKey: Self.coachMarksCompletedDefaultsKey)
        self.clipboardHasImage = pasteboard.readSnapshot().imageData != nil
        applyLaunchAtLoginPreference()
    }

    /// Starts the local clip server and peer discovery, and keeps `pairedDevices`
    /// in sync with the paired-device store (including devices that pair us while
    /// this app is the target of an incoming request).
    func startNetworking() {
        pairingCoordinator.onPairedDevicesChanged = { [weak self] in
            Task { @MainActor in await self?.refreshPairedDevices() }
        }
        clipServer.start()
        peerBrowser.start()
        Task { await refreshPairedDevices() }
    }

    func refreshPairedDevices() async {
        pairedDevices = await pairingCoordinator.pairedStore.devices
    }

    func unpairDevice(_ id: UUID) {
        Task {
            do {
                try await pairingCoordinator.pairedStore.removeDevice(id: id)
                await refreshPairedDevices()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func requestDevices() {
        showDevices = true
    }

    var filteredClips: [ClipItem] {
        store.clips(matching: searchText, filter: selectedFilter)
    }

    var latestClip: ClipItem? {
        clips.first
    }

    var historyClips: [ClipItem] {
        Array(filteredClips.dropFirst(filteredClips.first?.id == latestClip?.id ? 1 : 0))
    }

    func refresh() {
        let previousLatestID = clips.first?.id
        clips = store.items
        clipboardHasImage = pasteboard.readSnapshot().imageData != nil
        guard let latest = clips.first, latest.id != previousLatestID, latest.id != lastBroadcastClipID else {
            return
        }
        lastBroadcastClipID = latest.id
        Task { await broadcast(clip: latest) }
    }

    func showPairingCode() -> String {
        pairingCoordinator.startHosting()
    }

    func stopHostingCode() {
        pairingCoordinator.stopHosting()
    }

    func joinWithCode(_ code: String) {
        guard code.count == 6, code.allSatisfy(\.isNumber) else {
            lastError = "Enter a 6-digit pairing code."
            return
        }

        joinInProgress = true
        lastError = nil

        Task {
            defer { joinInProgress = false }

            let mdnsCandidates = peerBrowser.peers
            if await tryPairing(with: mdnsCandidates, code: code) {
                return
            }

            let sweptCandidates = Self.composeJoinCandidates(
                mdnsPeers: mdnsCandidates,
                sweptPeers: await SubnetSweeper.sweep()
            )
            if await tryPairing(with: sweptCandidates, code: code) {
                return
            }

            lastError = "No device accepted that code. Make sure the other device is showing a code on the same Wi-Fi."
        }
    }

    nonisolated static func composeSendTargets(mdnsPeers: [Peer], pairedDevices: [PairedDevice]) -> [Peer] {
        var byId: [UUID: Peer] = [:]
        for device in pairedDevices {
            if let host = device.host {
                byId[device.id] = Peer(id: device.id, name: device.name, host: host, port: 51888)
            }
        }
        for peer in mdnsPeers {
            byId[peer.id] = peer
        }
        return Array(byId.values)
    }

    nonisolated static func composeJoinCandidates(mdnsPeers: [Peer], sweptPeers: [Peer]) -> [Peer] {
        var seen: Set<UUID> = []
        var result: [Peer] = []
        for peer in mdnsPeers + sweptPeers {
            guard seen.insert(peer.id).inserted else { continue }
            result.append(peer)
        }
        return result
    }

    private func broadcast(clip: ClipItem) async {
        let targets = Self.composeSendTargets(mdnsPeers: peerBrowser.peers, pairedDevices: pairedDevices)
        do {
            _ = try await clipSender.broadcast(clip: clip, to: targets)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - File transfer

    /// Resolves the reachable `Peer` for a paired device (mDNS first, then stored host).
    func resolvePeer(for deviceId: UUID) -> Peer? {
        Self.composeSendTargets(mdnsPeers: peerBrowser.peers, pairedDevices: pairedDevices)
            .first { $0.id == deviceId }
    }

    /// Sends a file to a paired device. If the device is a single paired peer this is what
    /// drag-and-drop calls; the Devices view calls it per row.
    func sendFile(url: URL, to deviceId: UUID) {
        guard let peer = resolvePeer(for: deviceId) else {
            lastError = "That device is not reachable right now."
            return
        }

        let uiId = UUID()
        let token = CancellationToken()
        sendTokens[uiId] = token
        transfers.insert(
            FileTransferState(
                id: uiId,
                key: uiId.uuidString,
                fileName: url.lastPathComponent,
                direction: .sending,
                progress: 0,
                status: .inProgress,
                destinationURL: nil
            ),
            at: 0
        )

        let sender = fileSender
        let mime = Self.mimeType(for: url)
        Task.detached { [weak self] in
            do {
                try await sender.sendFile(
                    at: url,
                    to: peer,
                    mimeType: mime,
                    progress: { p in Task { @MainActor in self?.setTransferProgress(uiId: uiId, progress: p) } },
                    isCancelled: { token.isCancelled }
                )
                await MainActor.run { self?.completeSend(uiId: uiId, status: .completed) }
            } catch is CancellationError {
                await MainActor.run { self?.completeSend(uiId: uiId, status: .cancelled) }
            } catch let error as FileSendError where error == .cancelled {
                await MainActor.run { self?.completeSend(uiId: uiId, status: .cancelled) }
            } catch {
                await MainActor.run { self?.completeSend(uiId: uiId, status: .failed(error.localizedDescription)) }
            }
        }
    }

    /// Cancels an in-flight send (receiver-side transfers finish on their own in v1).
    func cancelTransfer(id: UUID) {
        sendTokens[id]?.cancel()
    }

    /// Routes dropped files: send straight to the sole reachable paired device, or present
    /// a picker when several are reachable.
    func handleDroppedFiles(_ urls: [URL]) {
        let files = urls.filter { !$0.hasDirectoryPath }
        guard !files.isEmpty else { return }

        let reachable = pairedDevices.filter { resolvePeer(for: $0.id) != nil }
        switch reachable.count {
        case 0:
            lastError = "No reachable paired device to send to."
        case 1:
            for url in files { sendFile(url: url, to: reachable[0].id) }
        default:
            pendingSend = PendingSend(files: files)
        }
    }

    func completePendingSend(to deviceId: UUID) {
        let files = pendingSend?.files ?? []
        pendingSend = nil
        for url in files { sendFile(url: url, to: deviceId) }
    }

    var reachablePairedDevices: [PairedDevice] {
        pairedDevices.filter { resolvePeer(for: $0.id) != nil }
    }

    /// Applies an event emitted by the `FileReceiver` (already hopped to the main actor).
    func handleReceiveEvent(_ event: FileTransferReceiveEvent) {
        switch event {
        case let .started(transferId, fileName, _):
            if index(ofKey: transferId) == nil {
                transfers.insert(
                    FileTransferState(
                        id: UUID(),
                        key: transferId,
                        fileName: fileName,
                        direction: .receiving,
                        progress: 0,
                        status: .inProgress,
                        destinationURL: nil
                    ),
                    at: 0
                )
            }
        case let .progress(transferId, received, total):
            if let i = index(ofKey: transferId), total > 0 {
                transfers[i].progress = Double(received) / Double(total)
            }
        case let .completed(transferId, url):
            if let i = index(ofKey: transferId) {
                transfers[i].progress = 1.0
                transfers[i].status = .completed
                transfers[i].destinationURL = url
            }
        case let .failed(transferId, reason):
            if let i = index(ofKey: transferId) {
                transfers[i].status = .failed(reason)
            }
        case let .cancelled(transferId):
            if let i = index(ofKey: transferId) {
                transfers[i].status = .cancelled
            }
        }
    }

    func clearFinishedTransfers() {
        transfers.removeAll { !$0.isActive }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Periodically reaps idle receiver sessions; wired to the app's poll timer.
    func collectTransferGarbage() {
        Task { await fileReceiver.garbageCollect() }
    }

    private func index(ofKey key: String) -> Int? {
        transfers.firstIndex { $0.key == key }
    }

    private func setTransferProgress(uiId: UUID, progress: Double) {
        if let i = transfers.firstIndex(where: { $0.id == uiId }), transfers[i].isActive {
            transfers[i].progress = progress
        }
    }

    private func completeSend(uiId: UUID, status: FileTransferState.Status) {
        sendTokens[uiId] = nil
        guard let i = transfers.firstIndex(where: { $0.id == uiId }) else { return }
        if status == .completed { transfers[i].progress = 1.0 }
        transfers[i].status = status
    }

    static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension), let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    private func tryPairing(with candidates: [Peer], code: String) async -> Bool {
        for peer in candidates {
            do {
                try await pairingCoordinator.startPairing(with: peer, code: code)
                await refreshPairedDevices()
                return true
            } catch {
                continue
            }
        }
        return false
    }

    func cleanupExpiredClips() throws {
        try store.cleanupExpiredClips()
    }

    func copy(_ clip: ClipItem) {
        do {
            try writer.copy(clip)
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func paste(_ clip: ClipItem, mode: PasteRequest) {
        do {
            try writer.copy(clip)
            refresh()
            onPasteRequested?(mode)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func handleClipSingleClick(_ clip: ClipItem) {
        paste(clip, mode: .keepClipboardOpenAfterPaste)
    }

    func handleClipDoubleClick(_ clip: ClipItem) {
        paste(clip, mode: .closeClipboardAfterPaste)
    }

    func copyText(_ text: String) {
        pasteboard.clearContents()
        pasteboard.writeText(text)
    }

    func togglePinned(_ clip: ClipItem) {
        do {
            try store.setPinned(clip.id, !clip.isPinned)
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func delete(_ clip: ClipItem) {
        do {
            try store.delete(clip.id)
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func captureScreenshot() {
        isCapturingScreenshot = true
        lastError = nil

        Task {
            do {
                let url = try await screenshotCaptureService.captureRegion()
                let imageData = try Data(contentsOf: url)
                _ = try store.addImageData(imageData, fileExtension: "png", previewText: "Screenshot")
                let blocks = try await ocrService.recognizeText(in: url)
                screenshotReview = ScreenshotReview(imageURL: url, selection: OCRSelectionState(blocks: blocks))
                refresh()
            } catch {
                lastError = error.localizedDescription
            }

            isCapturingScreenshot = false
        }
    }

    func startScreenTextSelection() {
        isSelectingScreenText = true
        lastError = nil

        Task {
            do {
                let capture = try await screenTextCaptureService.captureAllDisplays()
                onScreenTextSelectionReady?(capture)
            } catch {
                lastError = error.localizedDescription
            }

            isSelectingScreenText = false
        }
    }

    func setClipboardShortcut(_ shortcut: KeyboardShortcut) {
        clipboardShortcut = shortcut
        onClipboardShortcutChanged?(shortcut)
    }

    func setScreenshotShortcut(_ shortcut: KeyboardShortcut?) {
        screenshotShortcut = shortcut
        onScreenshotShortcutChanged?(shortcut)
    }

    func setScreenTextShortcut(_ shortcut: KeyboardShortcut?) {
        screenTextShortcut = shortcut
        onScreenTextShortcutChanged?(shortcut)
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        launchAtLoginEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.launchAtLoginDefaultsKey)
        applyLaunchAtLoginPreference()
    }

    func requestPreferences() {
        onPreferencesRequested?()
    }

    func requestClose() {
        onCloseRequested?()
    }

    func advanceCoachMark() {
        guard showCoachMarks else { return }

        if currentCoachMarkIndex < Self.coachMarkStepCount - 1 {
            currentCoachMarkIndex += 1
        } else {
            completeCoachMarks()
        }
    }

    func previousCoachMark() {
        guard showCoachMarks else { return }
        currentCoachMarkIndex = max(currentCoachMarkIndex - 1, 0)
    }

    func completeCoachMarks() {
        currentCoachMarkIndex = 0
        showCoachMarks = false
        UserDefaults.standard.set(true, forKey: Self.coachMarksCompletedDefaultsKey)
    }

    func restartCoachMarks() {
        currentCoachMarkIndex = 0
        showCoachMarks = true
    }

    func editClipboardImage() {
        let snapshot = pasteboard.readSnapshot()
        if let data = snapshot.imageData, let image = NSImage(data: data) {
            startEditingImage(image, clipID: nil)
        } else {
            lastError = "No image found in the clipboard to edit."
        }
    }

    func startEditingImage(_ image: NSImage, clipID: UUID?) {
        self.editingClipID = clipID
        self.editingImage = image
    }

    func saveEditedImage(_ image: NSImage) {
        guard let pngData = image.pngData() else {
            lastError = "Failed to convert edited image to PNG."
            return
        }

        do {
            let clip = try store.addImageData(pngData, fileExtension: "png", previewText: "Edited Image")
            try writer.copy(clip)
            self.editingImage = nil
            self.editingClipID = nil
            refresh()
        } catch {
            lastError = "Failed to save edited image: \(error.localizedDescription)"
        }
    }

    private func applyLaunchAtLoginPreference() {
        do {
            try launchAtLogin.setEnabled(launchAtLoginEnabled)
        } catch {
            lastError = "Could not update Launch at Login: \(error.localizedDescription)"
        }
    }
}

extension NSImage {
    func pngData() -> Data? {
        guard
            let tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffRepresentation)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}

struct ScreenshotReview: Identifiable {
    let id = UUID()
    let imageURL: URL
    var selection: OCRSelectionState
}

enum PasteRequest: Equatable {
    case keepClipboardOpenAfterPaste
    case closeClipboardAfterPaste
}
