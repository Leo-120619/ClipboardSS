import AppKit
import ClipboardCore
import SwiftUI
import UniformTypeIdentifiers

/// Outcome of pinging paired devices: who answered a valid pong, and where.
struct LivenessReport: Equatable, Sendable {
    /// Devices that answered a valid pong, keyed to the host that answered.
    var verifiedHosts: [UUID: String] = [:]
    /// Devices that answered 426 and no valid pong.
    var upgradeRequired: Set<UUID> = []

    var onlineIds: Set<UUID> { Set(verifiedHosts.keys) }

    mutating func merge(_ other: LivenessReport) {
        verifiedHosts.merge(other.verifiedHosts) { current, _ in current }
        upgradeRequired.formUnion(other.upgradeRequired)
        upgradeRequired.subtract(verifiedHosts.keys)
    }
}

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
    @Published private(set) var snippets: [TextSnippet]
    @Published var launchAtLoginEnabled: Bool
    @Published var showCoachMarks: Bool
    @Published var currentCoachMarkIndex = 0
    @Published var showDevices = false
    @Published var joinInProgress = false
    @Published private(set) var pairedDevices: [PairedDevice] = []
    /// Live reachability per paired device. In-memory only: it is rebuilt from scratch
    /// on every refresh, so unpaired devices drop out on their own.
    @Published private(set) var onlineDeviceIds: Set<UUID> = []
    /// Paired devices that answered a ping with 426 (or, found only by the reconnect sweep,
    /// advertised an older `v` on `/v1/id`). A valid pong clears the flag.
    @Published private(set) var outdatedDeviceIds: Set<UUID> = []
    @Published private(set) var transfers: [FileTransferState] = []
    @Published var pendingSend: PendingSend?

    let store: ClipStore
    let pairingCoordinator: PairingCoordinator
    let peerBrowser: PeerBrowser
    private let clipSender: ClipSender
    private let clipServer: ClipServer
    private let fileSender: FileSender
    private let fileReceiver: FileReceiver
    private var notifiedReceiveIds: Set<String> = []
    /// Folder answer shared by the files of one multi-file share.
    private var receiveBatch = ReceiveBatchDestination()
    private var sendTokens: [UUID: CancellationToken] = [:]
    private var livenessTask: Task<Void, Never>?
    private static let livenessInterval = Duration.seconds(5)
    nonisolated static let coachMarksCompletedDefaultsKey = "hasCompletedCoachMarks"
    nonisolated static let launchAtLoginDefaultsKey = "launchAtLoginEnabled"
    nonisolated static let coachMarkStepCount = CoachMarkStep.steps.count
    private let writer: ClipboardWriter
    private let screenshotCaptureService: ScreenshotCaptureService
    private let ocrService: OCRService
    private let screenTextCaptureService: any ScreenTextCapturing
    private let launchAtLogin: LaunchAtLoginControlling
    private let pasteboard: PasteboardClient
    private var lastBroadcastClipID: UUID?
    var onClipboardShortcutChanged: ((KeyboardShortcut) -> Void)?
    var onScreenshotShortcutChanged: ((KeyboardShortcut?) -> Void)?
    var onScreenTextShortcutChanged: ((KeyboardShortcut?) -> Void)?
    var onSnippetsChanged: (([TextSnippet]) -> Void)?
    var onSnippetPasteRequested: ((String) -> Void)?
    private let snippetStore: TextSnippetStore
    var onPasteRequested: ((PasteRequest) -> Void)?
    var onPreferencesRequested: (() -> Void)?
    var onCloseRequested: (() -> Void)?
    var onScreenTextSelectionReady: ((ScreenTextCapture) -> Void)?
    var onReceivedFileCompleted: ((URL) -> Void)?

    init(
        store: ClipStore,
        writer: ClipboardWriter,
        screenshotCaptureService: ScreenshotCaptureService,
        ocrService: OCRService,
        screenTextCaptureService: any ScreenTextCapturing = ScreenTextCaptureService(),
        launchAtLogin: LaunchAtLoginControlling = LaunchAtLoginController(),
        pasteboard: PasteboardClient,
        snippetStore: TextSnippetStore = TextSnippetStore(),
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
        self.snippetStore = snippetStore
        self.snippets = snippetStore.load()
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
            Task { @MainActor in
                await self?.refreshPairedDevices()
                await self?.refreshDeviceLiveness()
            }
        }
        clipServer.start()
        peerBrowser.start()
        Task {
            await refreshPairedDevices()
            startLivenessRefresh()
        }
    }

    func refreshPairedDevices() async {
        pairedDevices = await pairingCoordinator.pairedStore.devices
    }

    /// Polls paired-device reachability on its own cadence. Kept off the app's 0.75s
    /// clipboard poll: network probes are far too expensive to run at that rate.
    private func startLivenessRefresh() {
        livenessTask?.cancel()
        livenessTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDeviceLiveness()
                try? await Task.sleep(for: Self.livenessInterval)
            }
        }
    }

    func stopLivenessRefresh() {
        livenessTask?.cancel()
        livenessTask = nil
        onlineDeviceIds = []
    }

    /// Rebuilds `onlineDeviceIds` from authenticated pings. Devices are pinged
    /// concurrently with a short timeout, trying the mDNS address before the stored one.
    func refreshDeviceLiveness() async {
        let report = await Self.computeLiveness(
            devices: pairedDevices,
            mdnsPeers: peerBrowser.peers,
            ping: pingDevice
        )
        await applyLiveness(report)
    }

    /// Pings one paired device at one host over `POST /v1/ping` (500 ms timeout).
    private var pingDevice: @Sendable (PairedDevice, String) async -> PingOutcome {
        let pairedStore = pairingCoordinator.pairedStore
        let localDeviceId = pairingCoordinator.identity.id
        return { device, host in
            guard let key = try? await pairedStore.getKey(for: device.id) else { return .unverified }
            return await LivenessPing.ping(host: host, deviceId: device.id, localDeviceId: localDeviceId, pairKey: key) {
                try await SubnetSweeper.exchange($0, host: host, timeoutMs: 500)
            }
        }
    }

    /// The only place a paired device becomes online, has its stored host changed, or has
    /// its outdated flag changed, and only from ping results: `/v1/id` and mDNS nominate
    /// hosts but never prove identity. `scope` limits the online rebuild to those devices;
    /// nil rebuilds the whole set (so unpaired devices drop out).
    private func applyLiveness(_ report: LivenessReport, scope: Set<UUID>? = nil) async {
        let updates = Self.hostUpdates(devices: pairedDevices, report: report)
        for (id, host) in updates {
            do {
                try await pairingCoordinator.pairedStore.updateHost(id, host: host)
            } catch {
                lastError = error.localizedDescription
            }
        }
        if !updates.isEmpty { await refreshPairedDevices() }

        let outdated = outdatedDeviceIds.subtracting(report.onlineIds).union(report.upgradeRequired)
        if outdated != outdatedDeviceIds { outdatedDeviceIds = outdated }

        let online = scope.map { onlineDeviceIds.subtracting($0).union(report.onlineIds) } ?? report.onlineIds
        if online != onlineDeviceIds { onlineDeviceIds = online }
    }

    func isDeviceOnline(_ id: UUID) -> Bool {
        onlineDeviceIds.contains(id)
    }

    /// True when the device advertises an older wire protocol: it is listed, but nothing is sent to it.
    func deviceNeedsUpdate(_ id: UUID) -> Bool {
        Self.deviceNeedsUpdate(id, mdnsPeers: peerBrowser.peers, outdatedDeviceIds: outdatedDeviceIds)
    }

    nonisolated static func deviceNeedsUpdate(_ id: UUID, mdnsPeers: [Peer], outdatedDeviceIds: Set<UUID>) -> Bool {
        outdatedDeviceIds.contains(id) || mdnsPeers.contains { $0.id == id && $0.needsUpdate }
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

    func setDeviceConnected(_ id: UUID, _ connected: Bool) {
        Task {
            do {
                if connected { onlineDeviceIds.remove(id) }
                try await pairingCoordinator.pairedStore.setConnected(id, connected)
                await refreshPairedDevices()
                if connected {
                    _ = await reconnectDevice(id)
                } else {
                    lastError = nil
                }
            } catch { lastError = error.localizedDescription }
        }
    }

    nonisolated static func isDeviceConnectionActive(enabled: Bool, online: Bool) -> Bool {
        enabled && online
    }

    func isDeviceConnected(_ id: UUID) -> Bool {
        guard let device = pairedDevices.first(where: { $0.id == id }) else { return false }
        return Self.isDeviceConnectionActive(enabled: device.connected, online: isDeviceOnline(id))
    }

    nonisolated static func resolveVerifiedPeer(
        device: PairedDevice,
        online: Bool,
        mdnsPeers: [Peer],
        outdatedDeviceIds: Set<UUID> = []
    ) -> Peer? {
        guard isDeviceConnectionActive(enabled: device.connected, online: online) else { return nil }
        // Never the mDNS-claimed address: only a pong moves the stored host.
        guard let host = device.host, !host.isEmpty else { return nil }
        return storedHostPeer(device, host: host, outdatedDeviceIds: outdatedDeviceIds)
    }

    /// A peer at the device's stored host (the last host that answered a valid pong),
    /// carrying an older protocol version when it is in `outdatedDeviceIds`.
    nonisolated static func storedHostPeer(_ device: PairedDevice, host: String, outdatedDeviceIds: Set<UUID>) -> Peer {
        Peer(
            id: device.id,
            name: device.name,
            host: host,
            port: 51888,
            protocolVersion: outdatedDeviceIds.contains(device.id) ? 1 : ClipEnvelope.currentVersion
        )
    }

    /// Pings the device at its mDNS and stored addresses; failing that, sweeps the subnet
    /// for hosts claiming its id on `/v1/id` and pings those. Only a valid pong makes it
    /// online or moves its stored host.
    @discardableResult
    func reconnectDevice(_ id: UUID, reportError: Bool = true) async -> Bool {
        guard let device = pairedDevices.first(where: { $0.id == id }), device.connected else {
            return false
        }

        let ping = pingDevice
        let tried = Self.candidateHosts(for: device, mdnsPeers: peerBrowser.peers)
        var report = await Self.verify(device, hosts: tried, ping: ping)
        if report.verifiedHosts[id] == nil {
            let claimed = await SubnetSweeper.sweep().filter { $0.id == id }
            report.merge(await Self.verify(device, hosts: claimed.map(\.host).filter { !tried.contains($0) }, ping: ping))
            // A v1 peer cannot answer a ping; its advertised version is the only signal.
            if report.verifiedHosts[id] == nil, claimed.contains(where: \.needsUpdate) {
                report.upgradeRequired.insert(id)
            }
        }

        await applyLiveness(report, scope: [id])
        guard report.verifiedHosts[id] != nil else {
            if reportError {
                lastError = deviceNeedsUpdate(id)
                    ? ProtocolMismatch.updateOtherDeviceMessage
                    : "That device is not reachable right now."
            }
            return false
        }
        lastError = nil
        return true
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
            switch await tryPairing(with: mdnsCandidates, code: code) {
            case .paired: return
            case .alreadyPaired:
                lastError = Self.alreadyPairedMessage
                return
            case .notAccepted: break
            }

            let sweptCandidates = Self.composeJoinCandidates(
                mdnsPeers: mdnsCandidates,
                sweptPeers: await SubnetSweeper.sweep()
            )
            switch await tryPairing(with: sweptCandidates, code: code) {
            case .paired: return
            case .alreadyPaired:
                lastError = Self.alreadyPairedMessage
                return
            case .notAccepted: break
            }

            lastError = "No device accepted that code. Make sure the other device is showing a code on the same Wi-Fi."
        }
    }

    nonisolated static func composeSendTargets(
        mdnsPeers: [Peer],
        pairedDevices: [PairedDevice],
        outdatedDeviceIds: Set<UUID> = []
    ) -> [Peer] {
        var byId: [UUID: Peer] = [:]
        // Unpaired mDNS peers only count as visible; ClipSender has no key for them.
        let pairedIds = Set(pairedDevices.map(\.id))
        for peer in mdnsPeers where !pairedIds.contains(peer.id) {
            byId[peer.id] = peer
        }
        // Paired devices go to their stored (ping-verified) host, never an mDNS-claimed one;
        // an older mDNS `v` still keeps them from being sent to.
        let mdnsOutdated = Set(mdnsPeers.filter(\.needsUpdate).map(\.id))
        for device in pairedDevices where device.connected {
            if let host = device.host, !host.isEmpty {
                byId[device.id] = storedHostPeer(device, host: host, outdatedDeviceIds: outdatedDeviceIds.union(mdnsOutdated))
            }
        }
        return Array(byId.values)
    }

    /// Hosts to ping for a device: its current mDNS address(es), then the stored one.
    nonisolated static func candidateHosts(for device: PairedDevice, mdnsPeers: [Peer]) -> [String] {
        var hosts = mdnsPeers.filter { $0.id == device.id }.map(\.host)
        if let host = device.host, !host.isEmpty, !hosts.contains(host) {
            hosts.append(host)
        }
        return hosts
    }

    /// Pings `hosts` in order and stops at the first valid pong.
    nonisolated static func verify(
        _ device: PairedDevice,
        hosts: [String],
        ping: @Sendable (PairedDevice, String) async -> PingOutcome
    ) async -> LivenessReport {
        var report = LivenessReport()
        for host in hosts {
            switch await ping(device, host) {
            case .alive:
                report.verifiedHosts[device.id] = host
                report.upgradeRequired.remove(device.id)
                return report
            case .upgradeRequired:
                report.upgradeRequired.insert(device.id)
            case .unverified:
                continue
            }
        }
        return report
    }

    /// Resolves which paired devices are reachable right now, and where. mDNS and the
    /// stored address only nominate hosts; a device is online only at a host that answered
    /// a valid pong (see `LivenessPing`). Independent of `PairedDevice.connected`, which
    /// is a local pause switch rather than a statement about reachability.
    nonisolated static func computeLiveness(
        devices: [PairedDevice],
        mdnsPeers: [Peer],
        ping: @escaping @Sendable (PairedDevice, String) async -> PingOutcome
    ) async -> LivenessReport {
        await withTaskGroup(of: LivenessReport.self) { group in
            for device in devices {
                let hosts = candidateHosts(for: device, mdnsPeers: mdnsPeers)
                guard !hosts.isEmpty else { continue }
                group.addTask { await verify(device, hosts: hosts, ping: ping) }
            }
            var report = LivenessReport()
            for await partial in group { report.merge(partial) }
            return report
        }
    }

    /// Stored-host changes a report calls for: devices whose pong came from a host other
    /// than the one stored.
    nonisolated static func hostUpdates(devices: [PairedDevice], report: LivenessReport) -> [UUID: String] {
        var updates: [UUID: String] = [:]
        for device in devices {
            if let host = report.verifiedHosts[device.id], host != device.host {
                updates[device.id] = host
            }
        }
        return updates
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
        let targets = Self.composeSendTargets(
            mdnsPeers: peerBrowser.peers,
            pairedDevices: pairedDevices,
            outdatedDeviceIds: outdatedDeviceIds
        )
        do {
            let result = try await clipSender.broadcast(clip: clip, to: targets)
            if result.needsUpdateCount > 0 {
                lastError = ProtocolMismatch.updateOtherDeviceMessage
            } else if !result.clockOutOfSyncPeerNames.isEmpty {
                lastError = ProtocolMismatch.clockOutOfSyncMessage(deviceNames: result.clockOutOfSyncPeerNames)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - File transfer

    /// Resolves the reachable `Peer` for a paired device (mDNS first, then stored host).
    func resolvePeer(for deviceId: UUID) -> Peer? {
        guard let device = pairedDevices.first(where: { $0.id == deviceId }) else { return nil }
        return Self.resolveVerifiedPeer(
            device: device,
            online: isDeviceOnline(deviceId),
            mdnsPeers: peerBrowser.peers,
            outdatedDeviceIds: outdatedDeviceIds
        )
    }

    /// Sends a file to a paired device. If the device is a single paired peer this is what
    /// drag-and-drop calls; the Devices view calls it per row.
    func sendFile(url: URL, to deviceId: UUID) {
        Task {
            guard await reconnectDevice(deviceId, reportError: false) else {
                lastError = deviceNeedsUpdate(deviceId)
                    ? ProtocolMismatch.updateOtherDeviceMessage
                    : "That device is not reachable right now."
                return
            }
            startFileSend(url: url, to: deviceId)
        }
    }

    private func startFileSend(url: URL, to deviceId: UUID) {
        guard !deviceNeedsUpdate(deviceId) else {
            lastError = ProtocolMismatch.updateOtherDeviceMessage
            return
        }
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
                postProcessReceivedFile(at: i)
                if let finalURL = transfers[i].destinationURL,
                   notifiedReceiveIds.insert(transferId).inserted {
                    onReceivedFileCompleted?(finalURL)
                }
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

    private func postProcessReceivedFile(at index: Int) {
        switch ReceiveSettings.mode {
        case .unset:
            let alert = NSAlert()
            alert.messageText = "Where should received files be saved?"
            alert.informativeText = "They are currently saved to \(ReceiveSettings.resolvedDirectory().path)."
            alert.addButton(withTitle: "Keep saving here")
            alert.addButton(withTitle: "Choose a folder…")
            alert.addButton(withTitle: "Ask every time")
            switch alert.runModal() {
            case .alertSecondButtonReturn:
                if let folder = ReceiveSettings.chooseDirectory() {
                    ReceiveSettings.path = folder.path
                    ReceiveSettings.mode = .defaultFolder
                }
            case .alertThirdButtonReturn: ReceiveSettings.mode = .askEveryTime
            default: ReceiveSettings.mode = .defaultFolder
            }
        case .askEveryTime:
            guard let source = transfers[index].destinationURL,
                  case let .folder(folder) = batchReceiveDestination() else { return }
            let destination = folder.appendingPathComponent(source.lastPathComponent)
            do {
                try FileManager.default.moveItem(at: source, to: destination)
                transfers[index].destinationURL = destination
            } catch { lastError = error.localizedDescription }
        case .defaultFolder: break
        }
    }

    /// Asks where to save once per share: files that arrive back-to-back reuse the
    /// first answer instead of opening a folder picker each.
    private func batchReceiveDestination() -> ReceiveBatchDestination.Decision {
        if let decision = receiveBatch.decision(now: Date()) { return decision }
        let decision: ReceiveBatchDestination.Decision =
            ReceiveSettings.chooseDirectory().map { .folder($0) } ?? .declined
        // Timed from when the picker closes, not from when it opened.
        receiveBatch.record(decision, now: Date())
        return decision
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

    static let alreadyPairedMessage = "Remove the existing pairing on the other device first"

    private enum JoinOutcome { case paired, alreadyPaired, notAccepted }

    private func tryPairing(with candidates: [Peer], code: String) async -> JoinOutcome {
        for peer in candidates {
            do {
                try await pairingCoordinator.startPairing(with: peer, code: code)
                await refreshPairedDevices()
                await refreshDeviceLiveness()
                return .paired
            } catch PairingError.alreadyPaired {
                // The target accepted the code but already knows this device; its code is now spent.
                return .alreadyPaired
            } catch {
                continue
            }
        }
        return .notAccepted
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
        guard !isSelectingScreenText else { return }
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

    func addSnippet() {
        snippets.append(TextSnippet())
        saveSnippets()
    }

    func updateSnippet(_ snippet: TextSnippet) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        var snippet = snippet
        let previousShortcut = snippets[index].shortcut
        if let shortcut = snippet.shortcut, shortcut != previousShortcut,
           let conflict = snippetShortcutConflict(shortcut, excluding: snippet.id) {
            lastError = conflict
            snippet.shortcut = previousShortcut
        }
        snippets[index] = snippet
        saveSnippets()
    }

    /// Explains why `shortcut` cannot be given to the snippet with `id`, or nil
    /// if it is free. Built-in shortcuts and other snippets' shortcuts are taken.
    func snippetShortcutConflict(_ shortcut: KeyboardShortcut, excluding id: UUID) -> String? {
        let name = shortcut.displayName
        if shortcut == clipboardShortcut {
            return "\(name) already opens the clipboard window. Choose a different shortcut."
        }
        if shortcut == screenshotShortcut {
            return "\(name) is already the screenshot shortcut. Choose a different shortcut."
        }
        if shortcut == screenTextShortcut {
            return "\(name) is already the screen text shortcut. Choose a different shortcut."
        }
        if let other = snippets.first(where: { $0.id != id && $0.shortcut == shortcut }) {
            let otherName = other.name.isEmpty ? "another snippet" : "the snippet “\(other.name)”"
            return "\(name) is already used by \(otherName). Choose a different shortcut."
        }
        return nil
    }

    func deleteSnippet(_ id: UUID) {
        snippets.removeAll { $0.id == id }
        saveSnippets()
    }

    /// Returns false when the paste could not be performed and `lastError`
    /// explains why, so the caller can bring the window forward to show it.
    @discardableResult
    func pasteSnippet(_ id: UUID) -> Bool {
        guard let snippet = snippets.first(where: { $0.id == id }), !snippet.text.isEmpty else { return true }
        guard AppPermission.accessibility.isGranted else {
            lastError = AppPermission.accessibility.deniedMessage
            return false
        }
        onSnippetPasteRequested?(snippet.text)
        return true
    }

    private func saveSnippets() {
        snippetStore.save(snippets)
        onSnippetsChanged?(snippets)
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
