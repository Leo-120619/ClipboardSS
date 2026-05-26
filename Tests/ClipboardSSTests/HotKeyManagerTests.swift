import AppKit
import Carbon
import Testing
@testable import ClipboardSS

@Suite("Hot key manager")
struct HotKeyManagerTests {
    @Test("converts AppKit modifiers to Carbon hot key modifiers")
    func convertsModifiersForCarbonRegistration() {
        let shortcut = KeyboardShortcut(keyCode: 49, modifiers: [.control, .shift, .command, .option])

        #expect(shortcut.carbonModifierFlags == UInt32(controlKey | shiftKey | cmdKey | optionKey))
    }

    @Test("default clipboard shortcut avoids common macOS system shortcuts")
    func defaultClipboardShortcutAvoidsCommonSystemShortcuts() {
        #expect(KeyboardShortcut.defaultClipboard == .controlOptionV)
    }

    @Test("screen text shortcut is persisted separately from screenshot capture")
    func screenTextShortcutPersistsSeparatelyFromScreenshotCapture() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "screenTextShortcutKeyCode")
        defaults.removeObject(forKey: "screenTextShortcutModifiers")
        defaults.removeObject(forKey: "screenshotShortcutKeyCode")
        defaults.removeObject(forKey: "screenshotShortcutModifiers")

        KeyboardShortcut.save(.controlOptionSpace, keyPrefix: "screenText")

        #expect(KeyboardShortcut.savedScreenTextShortcut == .controlOptionSpace)
        #expect(KeyboardShortcut.savedScreenshotShortcut == nil)

        KeyboardShortcut.save(nil, keyPrefix: "screenText")
    }

    @Test("arbitrary shortcuts persist and display common key names")
    func arbitraryShortcutsPersistAndDisplayCommonKeyNames() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "clipboardShortcutKeyCode")
        defaults.removeObject(forKey: "clipboardShortcutModifiers")
        let shortcut = KeyboardShortcut(keyCode: 8, modifiers: [.command, .option])

        KeyboardShortcut.save(shortcut, keyPrefix: "clipboard")

        #expect(KeyboardShortcut.savedClipboardShortcut == shortcut)
        #expect(KeyboardShortcut.savedClipboardShortcut.displayName == "Option + Command + C")

        KeyboardShortcut.save(nil, keyPrefix: "clipboard")
    }

    @Test("optional shortcuts clear from user defaults")
    func optionalShortcutsClearFromUserDefaults() {
        KeyboardShortcut.save(.controlCommandS, keyPrefix: "screenshot")

        KeyboardShortcut.save(nil, keyPrefix: "screenshot")

        #expect(KeyboardShortcut.savedScreenshotShortcut == nil)
    }
}
