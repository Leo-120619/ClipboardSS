import AppKit
import ClipboardCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var windowController: ClipboardWindowController?
    private var screenTextOverlayController: ScreenTextOverlayController?
    private var model: AppModel?
    private var hotKeyManager: HotKeyManager?
    private var monitorTimer: Timer?
    private var clipboardMonitor: ClipboardMonitor?
    private var shareStagingDirectory: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.applicationIconImage = ClipboardSSLogo.image(size: NSSize(width: 128, height: 128))

        // Foreground activations from the share extension arrive as GetURL apple events.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        do {
            let store = try ClipStore(storageDirectory: Self.defaultStorageDirectory())
            let pasteboard = SystemPasteboardClient()
            let writer = ClipboardWriter(pasteboard: pasteboard, store: store)
            let screenTextOverlayController = ScreenTextOverlayController()

            let identity = DeviceIdentity(
                id: Self.loadDeviceIdentityId(),
                name: Host.current().localizedName ?? "Mac"
            )
            let pairedStore = try PairedDeviceStore(
                storageURL: store.storageDirectory.appendingPathComponent("paired-devices.json"),
                keyStorage: KeychainPairKeyStorage()
            )
            let transport = NWPeerTransport()
            let pairingCoordinator = PairingCoordinator(
                identity: identity,
                pairedStore: pairedStore,
                transport: transport
            )
            let clipReceiver = ClipReceiver(store: store, pasteboard: pasteboard)

            let transferEventSink = FileTransferEventSink()
            let fileReceiver = FileReceiver(
                pairedStore: pairedStore,
                transfersDirectory: store.storageDirectory.appendingPathComponent("Transfers", isDirectory: true),
                destinationProvider: { Self.downloadsDirectory() },
                onEvent: { [transferEventSink] event in transferEventSink.emit(event) }
            )

            let clipServer = try ClipServer(
                identity: identity,
                receiver: clipReceiver,
                pairingCoordinator: pairingCoordinator,
                fileReceiver: fileReceiver
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

            let model = AppModel(
                store: store,
                writer: writer,
                screenshotCaptureService: ScreenshotCaptureService(),
                ocrService: OCRService(),
                screenTextCaptureService: ScreenTextCaptureService(),
                pasteboard: pasteboard,
                pairingCoordinator: pairingCoordinator,
                peerBrowser: peerBrowser,
                clipSender: clipSender,
                clipServer: clipServer,
                fileSender: fileSender,
                fileReceiver: fileReceiver
            )
            transferEventSink.setHandler { [weak model] event in
                Task { @MainActor in model?.handleReceiveEvent(event) }
            }
            let monitor = ClipboardMonitor(pasteboard: pasteboard, store: store)
            let windowController = ClipboardWindowController(model: model)
            let hotKeyManager = HotKeyManager()

            self.model = model
            self.screenTextOverlayController = screenTextOverlayController
            self.clipboardMonitor = monitor
            self.windowController = windowController
            self.hotKeyManager = hotKeyManager

            model.onClipboardShortcutChanged = { [weak hotKeyManager] shortcut in
                hotKeyManager?.clipboardShortcut = shortcut
            }
            model.onScreenshotShortcutChanged = { [weak hotKeyManager] shortcut in
                hotKeyManager?.screenshotShortcut = shortcut
            }
            model.onScreenTextShortcutChanged = { [weak hotKeyManager] shortcut in
                hotKeyManager?.screenTextShortcut = shortcut
            }
            model.onPasteRequested = { [weak windowController] request in
                windowController?.performPaste(request)
            }
            model.onPreferencesRequested = { [weak windowController] in
                windowController?.showPreferences()
            }
            model.onCloseRequested = { [weak windowController] in
                windowController?.hide()
            }
            model.onScreenTextSelectionReady = { [weak model, weak screenTextOverlayController] capture in
                screenTextOverlayController?.present(capture: capture) { text in
                    model?.copyText(text)
                }
            }

            let stagingDir = store.storageDirectory.appendingPathComponent("ShareStaging", isDirectory: true)
            try? FileManager.default.removeItem(at: stagingDir)
            try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            self.shareStagingDirectory = stagingDir

            configureStatusItem()
            model.startNetworking()
            hotKeyManager.start {
                windowController.toggle()
            } screenshotCallback: {
                model.captureScreenshot()
            } screenTextCallback: {
                model.startScreenTextSelection()
            }

            monitorTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.pollClipboard()
                }
            }

            processShareOutbox()

            if model.showCoachMarks {
                windowController.show()
            }
        } catch {
            NSAlert(error: error).runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyManager?.stop()
        monitorTimer?.invalidate()
    }

    private func pollClipboard() {
        do {
            try clipboardMonitor?.poll()
            try model?.cleanupExpiredClips()
            model?.collectTransferGarbage()
            model?.refresh()
            processShareOutbox()
        } catch {
            print("Background clipboard polling failed: \(error.localizedDescription)")
        }
    }

    /// Handles a `clipboardss://` open triggered by the share extension. The payload is
    /// irrelevant — any activation means "drain the share outbox".
    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent: NSAppleEventDescriptor) {
        processShareOutbox()
    }

    /// Drains complete drops written by the share extension: stages each file locally,
    /// removes the app-group drop folder, and hands the files to the normal send flow.
    private func processShareOutbox() {
        guard let model else { return }
        let drops = ShareInbox.pendingDrops()
        guard !drops.isEmpty else { return }

        let staging = shareStagingDirectory ?? FileManager.default.temporaryDirectory
        var stagedURLs: [URL] = []
        for drop in drops {
            for source in drop.fileURLs {
                let destDir = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
                let dest = destDir.appendingPathComponent(source.lastPathComponent)
                do {
                    do {
                        try FileManager.default.moveItem(at: source, to: dest)
                    } catch {
                        try FileManager.default.copyItem(at: source, to: dest)
                    }
                    stagedURLs.append(dest)
                } catch {
                    // Skip files we can't stage; keep going with the rest.
                }
            }
            ShareInbox.remove(drop)
        }
        guard !stagedURLs.isEmpty else { return }

        model.handleDroppedFiles(stagedURLs)
        // Surface the window when the user must choose a device or when nothing is reachable.
        if model.pendingSend != nil || model.lastError != nil {
            NSApplication.shared.activate(ignoringOtherApps: true)
            windowController?.show()
        }
    }

    private func configureStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = ClipboardSSLogo.menuBarImage()

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Clipboard", action: #selector(openClipboard), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Select Screen Text", action: #selector(selectScreenText), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Devices", action: #selector(openDevices), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Preferences", action: #selector(openPreferences), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ClipboardSS", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu

        self.statusItem = statusItem
    }

    @objc private func openClipboard() {
        windowController?.show()
    }

    @objc private func openPreferences() {
        windowController?.showPreferences()
    }

    @objc private func openDevices() {
        windowController?.showDevices()
    }

    @objc private func selectScreenText() {
        model?.startScreenTextSelection()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    /// Loads the persistent device identity UUID, regenerating (and persisting) a
    /// fresh one if none is stored or the stored value is corrupt. Persisted as a
    /// lowercase canonical UUID string under the "deviceId" key.
    static func loadDeviceIdentityId(defaults: UserDefaults = .standard) -> UUID {
        if let stored = defaults.string(forKey: "deviceId"),
           let uuid = UUID(uuidString: stored) {
            return uuid
        }
        let newId = UUID()
        defaults.set(newId.uuidString.lowercased(), forKey: "deviceId")
        return newId
    }

    static func downloadsDirectory() -> URL {
        if let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            return url
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    private static func defaultStorageDirectory() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["CLIPBOARDSS_STORAGE_DIR"], !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("ClipboardSS", isDirectory: true)
    }
}
