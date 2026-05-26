import AppKit
import SwiftUI

struct ShortcutRecorderView: View {
    let title: String
    @Binding var shortcut: KeyboardShortcut?
    let allowClear: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 150, alignment: .leading)
            ShortcutRecorderField(shortcut: $shortcut)
                .frame(width: 220, height: 30)
            if allowClear {
                Button {
                    shortcut = nil
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .disabled(shortcut == nil)
                .help("Clear shortcut")
            }
        }
    }
}

private struct ShortcutRecorderField: NSViewRepresentable {
    @Binding var shortcut: KeyboardShortcut?

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.onShortcutChanged = { shortcut in
            self.shortcut = shortcut
        }
        return button
    }

    func updateNSView(_ nsView: ShortcutRecorderButton, context: Context) {
        nsView.shortcut = shortcut
        nsView.onShortcutChanged = { shortcut in
            self.shortcut = shortcut
        }
    }
}

private final class ShortcutRecorderButton: NSButton {
    var shortcut: KeyboardShortcut? {
        didSet {
            updateTitle()
        }
    }
    var onShortcutChanged: ((KeyboardShortcut) -> Void)?
    private var isRecording = false {
        didSet {
            updateTitle()
        }
    }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        beginRecording()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == 53 {
            isRecording = false
            return
        }

        let modifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard !modifiers.isEmpty, !Self.isModifierOnlyKey(event.keyCode) else {
            NSSound.beep()
            return
        }

        onShortcutChanged?(KeyboardShortcut(keyCode: event.keyCode, modifiers: modifiers))
        isRecording = false
    }

    @objc private func beginRecording() {
        isRecording = true
        window?.makeFirstResponder(self)
    }

    private func updateTitle() {
        title = if isRecording {
            "Press shortcut"
        } else {
            shortcut?.displayName ?? "None"
        }
        toolTip = "Click, then press the shortcut keys"
        setAccessibilityLabel(title)
    }

    private static func isModifierOnlyKey(_ keyCode: UInt16) -> Bool {
        [54, 55, 56, 58, 59, 60, 61, 62, 63].contains(keyCode)
    }
}
