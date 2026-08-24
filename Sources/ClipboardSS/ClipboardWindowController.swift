import AppKit
import SwiftUI

@MainActor
final class ClipboardWindowController {
    private static let frameAutosaveName = "ClipboardWindow"
    private let window: ClipboardWindow
    private let model: AppModel
    private var previousApplication: NSRunningApplication?

    init(model: AppModel) {
        self.model = model
        self.window = ClipboardWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 680),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.title = "ClipboardSS"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: ClipboardRootView(model: model))
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        window.onEscape = { [weak self] in
            self?.hide()
        }
    }

    func show() {
        show(activating: false)
    }

    private func show(activating: Bool) {
        rememberPreviousApplication()
        model.refresh()
        if activating {
            NSApplication.shared.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    func toggle() {
        if window.isVisible {
            window.orderOut(nil)
        } else {
            show()
        }
    }

    func hide() {
        window.saveFrame(usingName: Self.frameAutosaveName)
        window.orderOut(nil)
    }

    func showPreferences() {
        show(activating: true)
        model.showPreferences = true
    }

    func showDevices() {
        show(activating: true)
        model.showDevices = true
    }

    func performPaste(_ request: PasteRequest) {
        guard AppPermission.accessibility.isGranted else {
            model.lastError = AppPermission.accessibility.deniedMessage
            return
        }

        let targetApplication = previousApplication
        hide()
        targetApplication?.activate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            PasteEventSender.sendPasteShortcut()

            guard request == .keepClipboardOpenAfterPaste else {
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self?.window.orderFrontRegardless()
            }
        }
    }

    private func rememberPreviousApplication() {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            return
        }

        if frontmostApplication.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApplication = frontmostApplication
        }
    }
}

private final class ClipboardWindow: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

private enum PasteEventSender {
    static func sendPasteShortcut() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode = CGKeyCode(9)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
