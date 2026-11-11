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
    /// Devices that answered `400 stale` (clock out of sync) and no valid pong.
    var clockSkew: Set<UUID> = []

    var onlineIds: Set<UUID> { Set(verifiedHosts.keys) }

    mutating func merge(_ other: LivenessReport) {
        verifiedHosts.merge(other.verifiedHosts) { current, _ in current }
        upgradeRequired.formUnion(other.upgradeRequired)
        upgradeRequired.subtract(verifiedHosts.keys)
        clockSkew.formUnion(other.clockSkew)
        clockSkew.subtract(verifiedHosts.keys)
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
    /// Devices found by the last "Scan network" (subnet sweep), offered for pairing next to mDNS peers.
    @Published private(set) var sweptPeers: [Peer] = []
    @Published private(set) var scanInProgress = false
    @Published private(set) var pairedDevices: [PairedDevice] = []
    /// Live reachability per paired device. In-memory only: it is rebuilt from scratch
    /// on every refresh, so unpaired devices drop out on their own.
    @Published private(set) var onlineDeviceIds: Set<UUID> = [] {
        // Every online transition (full liveness pass or reconnect, both via
        // `applyLiveness`) retries queued shares.
        didSet {
            if !onlineDeviceIds.isSubset(of: oldValue) { processPendingShares() }
        }
    }
    /// Paired devices that answered a ping with 426 (or, found only by the reconnect sweep,
    /// advertised an older `v` on `/v1/id`). A valid pong clears the flag.
    @Published private(set) var outdatedDeviceIds: Set<UUID> = []
    /// Paired devices whose last ping was refused as stale: their clock disagrees with ours.
    /// Shown as "Clock out of sync"; never makes a device online or moves its host.
    @Published private(set) var clockSkewDeviceIds: Set<UUID> = []
    @Published private(set) var transfers: [FileTransferState] = []
    @Published var pendingSend: PendingSend? {
        // However the picker closes (button or sheet binding), offer any shares still waiting.
        didSet {
            if pendingSend == nil, oldValue != nil { processPendingShares() }
        }
    }

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
    /// Receive-folder preference and folder picker; replaced in tests.
    var receiveModeProvider: () -> ReceiveSettings.Mode = { ReceiveSettings.mode }
    var chooseReceiveDirectory: () -> URL? = { ReceiveSettings.chooseDirectory() }
    /// True while a receive prompt is on screen. Its modal loop keeps delivering events,
    /// so files finishing meanwhile wait in `receivesAwaitingPrompt` for its answer.
    private var isShowingReceivePrompt = false
    private var receivesAwaitingPrompt: [String] = []
    private var sendTokens: [UUID: CancellationToken] = [:]
    private var livenessTask: Task<Void, Never>?
    /// Where shared files are staged while they are being sent.
    let shareStagingDirectory: URL
    /// Share-extension drops waiting for a reachable, up-to-date device. A drop leaves the
    /// outbox only once its files are handed to `FileSender`.
    private(set) var pendingShares: [ShareInbox.PendingDrop] = []
    /// Staging folder per send, removed when that send finishes.
    private var shareStagingBySend: [UUID: URL] = [:]
    /// Files waiting for their turn, per device. Each device gets one send at a time (the
    /// receiver caps concurrent sessions per device, and Dart and Windows send serially too).
    private var sendQueues: [UUID: [QueuedFileSend]] = [:]
    /// Devices with a send in flight; its completion starts the next queued one.
    private var sendingDevices: Set<UUID> = []
    /// Outbox drops whose files sit in a send queue, by share key. A drop leaves the outbox
    /// once its last file is handed to `FileSender`.
    private var sharesInFlight: [String: ShareInFlight] = [:]
    /// Drops the user sent to a device that could not take them: they go only to that
    /// device, once it is back, and are never auto-sent elsewhere.
    private var shareTargetHolds: [String: UUID] = [:]
    private var hasCompletedLivenessPass = false
    nonisolated static let shareMaxAge: TimeInterval = 24 * 60 * 60
    nonisolated static let shareQueuedMessage =
        "No paired device is reachable. Shared files will be sent when one comes online."
    private static let livenessInterval = Duration.seconds(5)
    nonisolated static let coachMarksCompletedDefaultsKey = "hasCompletedCoachMarks"
    nonisolated static let launchAtLoginDefaultsKey = "launchAtLoginEnabled"
    nonisolated static let coachMarkStepCount = CoachMarkStep.steps.count
    private let writer: ClipboardWriter
    private let screenshotCaptureService: any ScreenshotCapturing
    private let ocrService: any ScreenshotTextRecognizing
    private let screenTextCaptureService: any ScreenTextCapturing
    private let launchAtLogin: LaunchAtLoginControlling
    private let pasteboard: PasteboardClient
    private let clipboardMonitor: ClipboardMonitor?
    /// Why the last shortcut change was refused, shown in Preferences.
    @Published var shortcutMessage: String?
    /// Shortcuts the system refused to register (another app may own them).
    @Published var hotKeyRegistrationFailures: [KeyboardShortcut] = []
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
    /// Called once per clip queued for sending to paired devices.
    var onClipBroadcast: ((ClipItem) -> Void)?
    /// Called when queued shares need the user: a device must be picked, or none is reachable.
    var onShareNeedsAttention: (() -> Void)?

    init(
        store: ClipStore,
        writer: ClipboardWriter,
        screenshotCaptureService: any ScreenshotCapturing,
        ocrService: any ScreenshotTextRecognizing,
        screenTextCaptureService: any ScreenTextCapturing = ScreenTextCaptureService(),
        launchAtLogin: LaunchAtLoginControlling = LaunchAtLoginController(),
        pasteboard: PasteboardClient,
        snippetStore: TextSnippetStore = TextSnippetStore(),
        pairingCoordinator: PairingCoordinator,
        peerBrowser: PeerBrowser,
        clipSender: ClipSender,
        clipServer: ClipServer,
        fileSender: FileSender,
        fileReceiver: FileReceiver,
        clipboardMonitor: ClipboardMonitor? = nil
    ) {
        self.store = store
        self.clipboardMonitor = clipboardMonitor
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
        self.shareStagingDirectory = store.storageDirectory.appendingPathComponent("ShareStaging", isDirectory: true)
        self.clipboardShortcut = .savedClipboardShortcut
        self.screenshotShortcut = .savedScreenshotShortcut
        self.screenTextShortcut = .savedScreenTextShortcut
        self.launchAtLoginEnabled = UserDefaults.standard.object(forKey: Self.launchAtLoginDefaultsKey)
            as? Bool ?? true
        let forceCoachMarks = ProcessInfo.processInfo.environment["CLIPBOARDSS_FORCE_COACH_MARKS"] == "1"
        self.showCoachMarks = forceCoachMarks || !UserDefaults.standard.bool(forKey: Self.coachMarksCompletedDefaultsKey)
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
    /// nil rebuilds the whole set (so unpaired devices drop out). Returns false when a
    /// stored-host update failed (its error is left in `lastError`).
    @discardableResult
    func applyLiveness(_ report: LivenessReport, scope: Set<UUID>? = nil) async -> Bool {
        var stored = true
        let updates = Self.hostUpdates(devices: pairedDevices, report: report)
        for (id, host) in updates {
            do {
                try await pairingCoordinator.pairedStore.updateHost(id, host: host)
            } catch {
                stored = false
                lastError = error.localizedDescription
            }
        }
        if !updates.isEmpty { await refreshPairedDevices() }

        let outdated = outdatedDeviceIds.subtracting(report.onlineIds).union(report.upgradeRequired)
        if outdated != outdatedDeviceIds { outdatedDeviceIds = outdated }

        let skewed = scope.map { clockSkewDeviceIds.subtracting($0).union(report.clockSkew) } ?? report.clockSkew
        if skewed != clockSkewDeviceIds { clockSkewDeviceIds = skewed }

        let online = scope.map { onlineDeviceIds.subtracting($0).union(report.onlineIds) } ?? report.onlineIds
        if online != onlineDeviceIds { onlineDeviceIds = online }

        // After the first full pass, shares queued for still-offline devices report it.
        if scope == nil, !hasCompletedLivenessPass {
            hasCompletedLivenessPass = true
            processPendingShares(reportUnreachable: true)
        }
        return stored
    }

    func isDeviceOnline(_ id: UUID) -> Bool {
        onlineDeviceIds.contains(id)
    }

    /// True when the device advertises an older wire protocol: it is listed, but nothing is sent to it.
    func deviceNeedsUpdate(_ id: UUID) -> Bool {
        Self.deviceNeedsUpdate(
            id,
            mdnsPeers: peerBrowser.peers,
            outdatedDeviceIds: outdatedDeviceIds,
            verifiedOnlineIds: onlineDeviceIds
        )
    }

    /// An unauthenticated mDNS `v < 2` counts only for devices that have not proved v2 with
    /// a valid pong (`verifiedOnlineIds`), so a LAN impostor cannot block a live device.
    nonisolated static func deviceNeedsUpdate(
        _ id: UUID,
        mdnsPeers: [Peer],
        outdatedDeviceIds: Set<UUID>,
        verifiedOnlineIds: Set<UUID> = []
    ) -> Bool {
        outdatedDeviceIds.contains(id)
            || (!verifiedOnlineIds.contains(id) && mdnsPeers.contains { $0.id == id && $0.needsUpdate })
    }

    /// True when the device's last ping was refused as stale (clocks out of sync).
    func deviceClockSkewed(_ id: UUID) -> Bool {
        clockSkewDeviceIds.contains(id)
    }

    /// Why a device cannot be sent to right now, for reconnect and file-send errors.
    func unreachableMessage(for id: UUID) -> String {
        if deviceNeedsUpdate(id) { return ProtocolMismatch.updateOtherDeviceMessage }
        if deviceClockSkewed(id), let device = pairedDevices.first(where: { $0.id == id }) {
            return ProtocolMismatch.clockOutOfSyncMessage(deviceNames: [device.name])
        }
        return "That device is not reachable right now."
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

        let stored = await applyLiveness(report, scope: [id])
        guard report.verifiedHosts[id] != nil else {
            if reportError { lastError = unreachableMessage(for: id) }
            return false
        }
        // Keep a failed stored-host update visible.
        if stored { lastError = nil }
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

    /// Republishes the store's clips. Never broadcasts: deleting, expiring or
    /// re-ordering clips is not a new copy.
    func refresh() {
        let items = store.items
        guard items != clips else { return }
        clips = items
    }

    /// Sends a clip that was just captured locally (a genuine copy or a new
    /// screenshot) to paired devices.
    func broadcastCaptured(_ clip: ClipItem) {
        onClipBroadcast?(clip)
        Task { await broadcast(clip: clip) }
    }

    func showPairingCode() -> String {
        pairingCoordinator.startHosting()
    }

    func stopHostingCode() {
        pairingCoordinator.stopHosting()
    }

    /// Unpaired-or-paired devices the user can pick to pair with: mDNS peers plus the last sweep.
    var pairingCandidates: [Peer] {
        Self.composeJoinCandidates(mdnsPeers: peerBrowser.peers, sweptPeers: sweptPeers)
    }

    /// Sweeps the local subnet for devices mDNS missed, so the user can pick one to pair with.
    func scanForDevices() {
        guard !scanInProgress else { return }
        scanInProgress = true
        Task {
            defer { scanInProgress = false }
            sweptPeers = await SubnetSweeper.sweep()
        }
    }

    /// Starts pairing with the one device the user selected. On success both screens show a
    /// number; the user then calls `confirmJoin()` or `cancelJoin()`.
    func joinWithCode(_ code: String, peer: Peer) {
        guard code.count == 6, code.allSatisfy(\.isNumber) else {
            lastError = "Enter a 6-digit pairing code."
            return
        }

        joinInProgress = true
        lastError = nil

        Task {
            defer { joinInProgress = false }
            do {
                try await pairingCoordinator.startPairing(with: peer, code: code)
            } catch {
                lastError = Self.joinErrorMessage(error)
            }
        }
    }

    /// The user confirmed the numbers match on this device.
    func confirmJoin() {
        joinInProgress = true
        lastError = nil
        Task {
            defer { joinInProgress = false }
            do {
                try await pairingCoordinator.confirmPairing()
                await refreshPairedDevices()
                await refreshDeviceLiveness()
            } catch PairingError.cancelled {
                // The user cancelled here; nothing to report.
            } catch {
                lastError = Self.joinErrorMessage(error)
            }
        }
    }

    func cancelJoin() {
        pairingCoordinator.cancelPairing()
    }

    func confirmHostedPairing() {
        pairingCoordinator.confirmHostedPairing()
    }

    func cancelHostedPairing() {
        pairingCoordinator.cancelHostedPairing()
    }

    static func joinErrorMessage(_ error: Error) -> String {
        switch error {
        case PairingError.alreadyPaired: alreadyPairedMessage
        case PairingError.timedOut: "The other device did not confirm in time. Show a new code and try again."
        case PairingError.rejected: "The other device did not accept. Check the code, or show a new one, and try again."
        default: "Could not reach that device. Make sure it is showing a code on the same Wi-Fi."
        }
    }

    nonisolated static func composeSendTargets(
        mdnsPeers: [Peer],
        pairedDevices: [PairedDevice],
        outdatedDeviceIds: Set<UUID> = [],
        verifiedOnlineIds: Set<UUID> = []
    ) -> [Peer] {
        var byId: [UUID: Peer] = [:]
        // Unpaired mDNS peers only count as visible; ClipSender has no key for them.
        let pairedIds = Set(pairedDevices.map(\.id))
        for peer in mdnsPeers where !pairedIds.contains(peer.id) {
            byId[peer.id] = peer
        }
        // Paired devices go to their stored (ping-verified) host, never an mDNS-claimed one.
        // An older mDNS `v` keeps them from being sent to, unless a valid pong proved v2.
        let mdnsOutdated = Set(mdnsPeers.filter(\.needsUpdate).map(\.id)).subtracting(verifiedOnlineIds)
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
                report.clockSkew.remove(device.id)
                return report
            case .upgradeRequired:
                report.upgradeRequired.insert(device.id)
            case .clockSkew:
                report.clockSkew.insert(device.id)
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
            outdatedDeviceIds: outdatedDeviceIds,
            verifiedOnlineIds: onlineDeviceIds
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

    /// Sends a file to a paired device; the Devices view calls it per row.
    func sendFile(url: URL, to deviceId: UUID) {
        sendFiles([url], to: deviceId)
    }

    /// Reconnects once, then queues `urls` (in order) for the device's send queue.
    func sendFiles(_ urls: [URL], to deviceId: UUID) {
        Task {
            guard await reconnectDevice(deviceId, reportError: false) else {
                lastError = unreachableMessage(for: deviceId)
                return
            }
            for url in urls { startFileSend(url: url, to: deviceId) }
        }
    }

    /// Queues a file for the device; it is handed to `FileSender` when its turn comes.
    @discardableResult
    private func startFileSend(url: URL, to deviceId: UUID) -> Bool {
        guard !deviceNeedsUpdate(deviceId), resolvePeer(for: deviceId) != nil else {
            lastError = unreachableMessage(for: deviceId)
            return false
        }
        enqueueFileSend(url: url, to: deviceId, shareKey: nil)
        return true
    }

    /// One file waiting its turn in a device's send queue. A share file (`shareKey` set) is
    /// still in the outbox and is staged only when its turn comes.
    private struct QueuedFileSend {
        let uiId: UUID
        let url: URL
        let shareKey: String?
    }

    /// An outbox drop with files queued: how many are not yet handed off, and whether the
    /// user picked the device.
    private struct ShareInFlight {
        /// The drop as its manifest now reads: only the files still waiting in the queue.
        var drop: ShareInbox.PendingDrop
        var remaining: Int
        let pickedByUser: Bool
    }

    private func enqueueFileSend(url: URL, to deviceId: UUID, shareKey: String?) {
        let uiId = UUID()
        sendTokens[uiId] = CancellationToken()
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
        sendQueues[deviceId, default: []].append(QueuedFileSend(uiId: uiId, url: url, shareKey: shareKey))
        pumpSendQueue(deviceId)
    }

    /// Starts the device's next queued send unless one is already in flight.
    private func pumpSendQueue(_ deviceId: UUID) {
        guard !sendingDevices.contains(deviceId) else { return }
        while let job = sendQueues[deviceId]?.first {
            sendQueues[deviceId]?.removeFirst()
            if sendQueues[deviceId]?.isEmpty == true { sendQueues[deviceId] = nil }
            if startQueuedSend(job, to: deviceId) { return }
        }
    }

    /// Hands one queued file to `FileSender`. Returns false when it ended without a send
    /// (cancelled, unreadable, or the device is no longer reachable).
    private func startQueuedSend(_ job: QueuedFileSend, to deviceId: UUID) -> Bool {
        let uiId = job.uiId
        guard let token = sendTokens[uiId], !token.isCancelled else {
            completeSend(uiId: uiId, status: .cancelled)
            if let key = job.shareKey {
                retainUnsentShareFiles(key, leaving: job.url)
                shareFileHandedOff(key)
            }
            return false
        }
        guard !deviceNeedsUpdate(deviceId), let peer = resolvePeer(for: deviceId) else {
            failBeforeHandOff(job, to: deviceId)
            return false
        }
        var url = job.url
        if let key = job.shareKey {
            defer { shareFileHandedOff(key) }
            // Drop the file from the manifest before moving it: a crash in between must not
            // leave a manifest naming a missing file, which would reject the whole drop.
            retainUnsentShareFiles(key, leaving: job.url)
            guard let staged = stageSharedFile(job.url) else {
                completeSend(uiId: uiId, status: .failed(FileSendError.fileUnreadable.localizedDescription))
                return false
            }
            shareStagingBySend[uiId] = staged.deletingLastPathComponent()
            url = staged
        }

        sendingDevices.insert(deviceId)
        let sender = fileSender
        let mime = Self.mimeType(for: url)
        let finish: @Sendable (FileTransferState.Status) async -> Void = { [weak self] status in
            await MainActor.run {
                guard let self else { return }
                self.completeSend(uiId: uiId, status: status)
                self.sendingDevices.remove(deviceId)
                self.pumpSendQueue(deviceId)
            }
        }
        Task.detached { [weak self] in
            do {
                let outcome = try await sender.sendFile(
                    at: url,
                    to: peer,
                    mimeType: mime,
                    progress: { p in Task { @MainActor in self?.setTransferProgress(uiId: uiId, progress: p) } },
                    isCancelled: { token.isCancelled }
                )
                await finish(outcome == .delivered ? .completed : .unconfirmed)
            } catch is CancellationError {
                await finish(.cancelled)
            } catch let error as FileSendError where error == .cancelled {
                await finish(.cancelled)
            } catch {
                await finish(.failed(error.localizedDescription))
            }
        }
        return true
    }

    /// The device went away (or became outdated) while files waited for it. A plain file
    /// fails; a share's unsent files go back to the outbox queue, so the drop is not lost.
    private func failBeforeHandOff(_ job: QueuedFileSend, to deviceId: UUID) {
        let message = unreachableMessage(for: deviceId)
        lastError = message
        guard let key = job.shareKey, let inFlight = sharesInFlight.removeValue(forKey: key) else {
            completeSend(uiId: job.uiId, status: .failed(message))
            return
        }
        let siblings = sendQueues[deviceId]?.filter { $0.shareKey == key } ?? []
        sendQueues[deviceId]?.removeAll { $0.shareKey == key }
        if sendQueues[deviceId]?.isEmpty == true { sendQueues[deviceId] = nil }
        let jobs = [job] + siblings
        let ids = Set(jobs.map(\.uiId))
        ids.forEach { sendTokens[$0] = nil }
        transfers.removeAll { ids.contains($0.id) }

        let remaining = jobs.map(\.url)
        let drop = remaining.count == inFlight.drop.fileURLs.count
            ? inFlight.drop
            : ShareInbox.retain(remaining, in: inFlight.drop)
        pendingShares.append(drop)
        if inFlight.pickedByUser { shareTargetHolds[key] = deviceId }
    }

    /// A file of a queued drop left the queue (staged or cancelled): rewrites the drop's
    /// manifest to list only its files still waiting, so a relaunch re-sends just those. After
    /// the last file the folder is removed by `shareFileHandedOff`, so no empty manifest is written.
    private func retainUnsentShareFiles(_ key: String, leaving url: URL) {
        guard var inFlight = sharesInFlight[key] else { return }
        let unsent = inFlight.drop.fileURLs.filter { $0 != url }
        guard !unsent.isEmpty, unsent.count != inFlight.drop.fileURLs.count else { return }
        inFlight.drop = ShareInbox.retain(unsent, in: inFlight.drop)
        sharesInFlight[key] = inFlight
    }

    /// One file of a queued drop left the queue; the drop leaves the outbox after its last.
    private func shareFileHandedOff(_ key: String) {
        guard var inFlight = sharesInFlight[key] else { return }
        inFlight.remaining -= 1
        if inFlight.remaining > 0 {
            sharesInFlight[key] = inFlight
        } else {
            sharesInFlight[key] = nil
            ShareInbox.remove(inFlight.drop)
        }
    }

    /// Cancels a send: a queued one ends now, an in-flight one at its next chunk
    /// (receiver-side transfers finish on their own in v1).
    func cancelTransfer(id: UUID) {
        for (deviceId, queue) in sendQueues {
            guard let index = queue.firstIndex(where: { $0.uiId == id }) else { continue }
            let job = queue[index]
            sendQueues[deviceId]?.remove(at: index)
            if sendQueues[deviceId]?.isEmpty == true { sendQueues[deviceId] = nil }
            completeSend(uiId: id, status: .cancelled)
            if let key = job.shareKey {
                retainUnsentShareFiles(key, leaving: job.url)
                shareFileHandedOff(key)
            }
            return
        }
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
            sendFiles(files, to: reachable[0].id)
        default:
            pendingSend = PendingSend(files: files)
        }
    }

    func completePendingSend(to deviceId: UUID) {
        guard let pending = pendingSend else { return }
        if pending.isShare {
            let shown = Set(pending.shareDrops)
            if !sendPendingShares(to: deviceId, only: shown, pickedByUser: true) {
                // Keep the drops for the device the user chose; never auto-send them elsewhere.
                for drop in pendingShares where shown.contains(Self.shareKey(drop)) {
                    shareTargetHolds[Self.shareKey(drop)] = deviceId
                }
            }
        } else {
            sendFiles(pending.files, to: deviceId)
        }
        pendingSend = nil
    }

    /// Dismisses the device picker. Cancelling a share discards the drops it showed: the user
    /// chose not to send them. Drops that arrived while it was open are offered next.
    func cancelPendingSend() {
        if let pending = pendingSend, pending.isShare {
            let shown = Set(pending.shareDrops)
            let discarded = pendingShares.filter { shown.contains(Self.shareKey($0)) }
            discarded.forEach(ShareInbox.remove)
            pendingShares.removeAll { shown.contains(Self.shareKey($0)) }
            shown.forEach { shareTargetHolds[$0] = nil }
        }
        pendingSend = nil
    }

    /// Identity of an outbox drop: its folder name, unique within the one outbox. Full paths
    /// are unreliable keys because listings may spell `/var` as `/private/var`.
    nonisolated static func shareKey(_ directory: URL) -> String {
        directory.lastPathComponent
    }

    private nonisolated static func shareKey(_ drop: ShareInbox.PendingDrop) -> String {
        shareKey(drop.directory)
    }

    /// Queues complete drops from the share extension. Drops already queued are ignored, so
    /// callers can pass the whole outbox on every poll.
    func enqueueShares(_ drops: [ShareInbox.PendingDrop], now: Date = Date()) {
        let known = Set(pendingShares.map(Self.shareKey)).union(sharesInFlight.keys)
        let fresh = drops.filter { !known.contains(Self.shareKey($0)) }
        guard !fresh.isEmpty else { return }
        pendingShares.append(contentsOf: fresh)
        processPendingShares(now: now, reportUnreachable: hasCompletedLivenessPass)
    }

    /// Sends queued shares when exactly one reachable, up-to-date device exists, asks which
    /// device when several do, and otherwise leaves them queued. Drops held for a device the
    /// user picked go only to that device.
    func processPendingShares(now: Date = Date(), reportUnreachable: Bool = false) {
        discardExpiredShares(now: now)
        guard !pendingShares.isEmpty, pendingSend == nil else { return }

        let reachable = pairedDevices.filter { resolvePeer(for: $0.id) != nil }
        let targets = reachable.filter { !deviceNeedsUpdate($0.id) }
        let targetIds = Set(targets.map(\.id))

        let ready = Dictionary(grouping: shareTargetHolds.filter { targetIds.contains($0.value) }, by: \.value)
        for (deviceId, holds) in ready {
            sendPendingShares(to: deviceId, only: Set(holds.map(\.key)), pickedByUser: true)
        }
        let free = pendingShares.filter { shareTargetHolds[Self.shareKey($0)] == nil }
        guard !free.isEmpty else {
            if reportUnreachable, let held = shareTargetHolds.values.first {
                lastError = unreachableMessage(for: held)
                onShareNeedsAttention?()
            }
            return
        }

        switch targets.count {
        case 0:
            guard reportUnreachable else { return }
            lastError = noShareTargetMessage(reachable: reachable)
            onShareNeedsAttention?()
        case 1:
            sendPendingShares(to: targets[0].id, only: Set(free.map(Self.shareKey)))
        default:
            pendingSend = PendingSend(
                files: free.flatMap(\.fileURLs),
                shareDrops: free.map(Self.shareKey)
            )
            onShareNeedsAttention?()
        }
    }

    /// Why queued shares cannot go anywhere: an outdated device, a paired device whose clock
    /// is out of sync, or nothing reachable at all.
    private func noShareTargetMessage(reachable: [PairedDevice]) -> String {
        let paired = pairedDevices.filter(\.connected)
        if !reachable.isEmpty || paired.contains(where: { deviceNeedsUpdate($0.id) }) {
            return ProtocolMismatch.updateOtherDeviceMessage
        }
        if let skewed = paired.first(where: { deviceClockSkewed($0.id) }) {
            return unreachableMessage(for: skewed.id)
        }
        return Self.shareQueuedMessage
    }

    private func discardExpiredShares(now: Date) {
        let expired = pendingShares.filter { now.timeIntervalSince($0.createdAt) > Self.shareMaxAge }
        guard !expired.isEmpty else { return }
        expired.forEach(ShareInbox.remove)
        let expiredDirs = Set(expired.map(Self.shareKey))
        pendingShares.removeAll { expiredDirs.contains(Self.shareKey($0)) }
        expiredDirs.forEach { shareTargetHolds[$0] = nil }
    }

    /// Queues shares (all, or only the drops in `only`) on the device's send queue; each file
    /// is staged when its turn comes, and each outbox drop is removed only after its last
    /// file is handed to `FileSender`. An unreachable or outdated device leaves the queue
    /// untouched and returns false.
    @discardableResult
    private func sendPendingShares(to deviceId: UUID, only: Set<String>? = nil, pickedByUser: Bool = false) -> Bool {
        guard resolvePeer(for: deviceId) != nil, !deviceNeedsUpdate(deviceId) else {
            lastError = unreachableMessage(for: deviceId)
            return false
        }
        let selected: (ShareInbox.PendingDrop) -> Bool = { only?.contains(Self.shareKey($0)) ?? true }
        let shares = pendingShares.filter(selected)
        pendingShares.removeAll(where: selected)
        for share in shares {
            let key = Self.shareKey(share)
            shareTargetHolds[key] = nil
            sharesInFlight[key] = ShareInFlight(drop: share, remaining: share.fileURLs.count, pickedByUser: pickedByUser)
            for source in share.fileURLs {
                enqueueFileSend(url: source, to: deviceId, shareKey: key)
            }
        }
        return true
    }

    /// Moves (or copies) a shared file into its own `ShareStaging/<uuid>/` folder.
    private func stageSharedFile(_ source: URL) -> URL? {
        // Re-checked at use: the file may have been swapped for a symlink since it was listed.
        guard ShareInbox.isRegularFile(source) else { return nil }
        let destDir = shareStagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dest = destDir.appendingPathComponent(source.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            do {
                try FileManager.default.moveItem(at: source, to: dest)
            } catch {
                try FileManager.default.copyItem(at: source, to: dest)
            }
            return dest
        } catch {
            try? FileManager.default.removeItem(at: destDir)
            return nil
        }
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
                postProcessReceivedFile(transferId: transferId)
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

    /// Applies the receive-folder preference to a finished file, then notifies once.
    /// Works by transfer id: prompts run a modal loop during which `transfers` can change.
    private func postProcessReceivedFile(transferId: String) {
        guard !isShowingReceivePrompt else {
            receivesAwaitingPrompt.append(transferId)
            return
        }
        switch receiveModeProvider() {
        case .unset:
            isShowingReceivePrompt = true
            askForReceivePreference()
            isShowingReceivePrompt = false
        case .askEveryTime:
            var decision = receiveBatch.decision(now: Date())
            if decision == nil {
                isShowingReceivePrompt = true
                let answer: ReceiveBatchDestination.Decision =
                    chooseReceiveDirectory().map { .folder($0) } ?? .declined
                // Timed from when the picker closes, not from when it opened.
                receiveBatch.record(answer, now: Date())
                isShowingReceivePrompt = false
                decision = answer
            }
            if case let .folder(folder) = decision {
                moveReceivedFile(transferId: transferId, to: folder)
            }
        case .defaultFolder:
            break
        }
        notifyReceivedFile(transferId: transferId)

        // Files that finished while the prompt was up reuse its answer.
        let waiting = receivesAwaitingPrompt
        receivesAwaitingPrompt = []
        for id in waiting {
            postProcessReceivedFile(transferId: id)
        }
    }

    private func askForReceivePreference() {
        let alert = NSAlert()
        alert.messageText = "Where should received files be saved?"
        alert.informativeText = "They are currently saved to \(ReceiveSettings.resolvedDirectory().path)."
        alert.addButton(withTitle: "Keep saving here")
        alert.addButton(withTitle: "Choose a folder…")
        alert.addButton(withTitle: "Ask every time")
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            if let folder = chooseReceiveDirectory() {
                ReceiveSettings.path = folder.path
                ReceiveSettings.mode = .defaultFolder
            }
        case .alertThirdButtonReturn: ReceiveSettings.mode = .askEveryTime
        default: ReceiveSettings.mode = .defaultFolder
        }
    }

    /// Moves a received file into `folder`, renaming it if the name is already taken there.
    private func moveReceivedFile(transferId: String, to folder: URL) {
        guard let i = index(ofKey: transferId), let source = transfers[i].destinationURL else { return }
        guard source.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL else { return }
        let destination = FileReceiver.uniqueDestination(directory: folder, fileName: source.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            transfers[i].destinationURL = destination
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func notifyReceivedFile(transferId: String) {
        guard let i = index(ofKey: transferId),
              let finalURL = transfers[i].destinationURL,
              notifiedReceiveIds.insert(transferId).inserted else { return }
        onReceivedFileCompleted?(finalURL)
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
        if let staging = shareStagingBySend.removeValue(forKey: uiId) {
            try? FileManager.default.removeItem(at: staging)
        }
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

    func cleanupExpiredClips() throws {
        try store.cleanupExpiredClips()
    }

    func copy(_ clip: ClipItem) {
        do {
            try writer.copy(clip)
            clipboardMonitor?.ignoreCurrentChange()
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func paste(_ clip: ClipItem, mode: PasteRequest) {
        do {
            try writer.copy(clip)
            clipboardMonitor?.ignoreCurrentChange()
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
        guard !isCapturingScreenshot else { return }
        isCapturingScreenshot = true
        lastError = nil

        Task {
            do {
                let tempURL = try await screenshotCaptureService.captureRegion()
                let imageData = try Self.consumeTemporaryFile(at: tempURL)
                let clip = try store.addImageData(imageData, fileExtension: "png", previewText: "Screenshot")
                broadcastCaptured(clip)
                refresh()
                // OCR and the review read the stored copy; the temp PNG is already gone.
                let imageURL = clip.resolvedImageURL(baseDirectory: store.storageDirectory)
                let blocks = try await ocrService.recognizeText(in: imageURL)
                screenshotReview = ScreenshotReview(imageURL: imageURL, selection: OCRSelectionState(blocks: blocks))
            } catch {
                lastError = error.localizedDescription
            }

            isCapturingScreenshot = false
        }
    }

    /// Reads a capture's temporary file and deletes it, whether or not the read succeeds.
    private static func consumeTemporaryFile(at url: URL) throws -> Data {
        defer { try? FileManager.default.removeItem(at: url) }
        return try Data(contentsOf: url)
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
        guard acceptShortcut(shortcut, for: .clipboard) else { return }
        clipboardShortcut = shortcut
        onClipboardShortcutChanged?(shortcut)
    }

    func setScreenshotShortcut(_ shortcut: KeyboardShortcut?) {
        guard acceptShortcut(shortcut, for: .screenshot) else { return }
        screenshotShortcut = shortcut
        onScreenshotShortcutChanged?(shortcut)
    }

    func setScreenTextShortcut(_ shortcut: KeyboardShortcut?) {
        guard acceptShortcut(shortcut, for: .screenText) else { return }
        screenTextShortcut = shortcut
        onScreenTextShortcutChanged?(shortcut)
    }

    private enum BuiltInShortcut { case clipboard, screenshot, screenText }

    /// Checks a new built-in shortcut against Command-V, the other built-ins and the
    /// snippets. Sets `shortcutMessage` to the reason when it is refused.
    private func acceptShortcut(_ shortcut: KeyboardShortcut?, for slot: BuiltInShortcut) -> Bool {
        guard let shortcut else {
            shortcutMessage = nil
            return true
        }
        let name = shortcut.displayName
        let taken: [(BuiltInShortcut, KeyboardShortcut?, String)] = [
            (.clipboard, clipboardShortcut, "opens the clipboard window"),
            (.screenshot, screenshotShortcut, "is the screenshot shortcut"),
            (.screenText, screenTextShortcut, "is the screen text shortcut"),
        ]
        var conflict: String?
        if shortcut.isReservedSystemShortcut {
            conflict = "\(name) is the system Paste shortcut. Choose a different shortcut."
        } else if let other = taken.first(where: { $0.0 != slot && $0.1 == shortcut }) {
            conflict = "\(name) already \(other.2). Choose a different shortcut."
        } else if let snippet = snippets.first(where: { $0.shortcut == shortcut }) {
            let snippetName = snippet.name.isEmpty ? "a snippet" : "the snippet “\(snippet.name)”"
            conflict = "\(name) is already used by \(snippetName). Choose a different shortcut."
        }
        shortcutMessage = conflict
        return conflict == nil
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
        if shortcut.isReservedSystemShortcut {
            return "\(name) is the system Paste shortcut. Choose a different shortcut."
        }
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
            clipboardMonitor?.ignoreCurrentChange()
            broadcastCaptured(clip)
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
