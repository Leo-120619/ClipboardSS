import AppKit
import Carbon
import ClipboardCore
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

    @Test("Command-V is reserved; other V shortcuts are not")
    func commandVIsReserved() {
        #expect(KeyboardShortcut(keyCode: 9, modifiers: [.command]).isReservedSystemShortcut)
        #expect(!KeyboardShortcut.controlOptionV.isReservedSystemShortcut)
        #expect(!KeyboardShortcut.commandShiftV.isReservedSystemShortcut)
    }
}

@MainActor
@Suite("Hot key registration")
struct HotKeyRegistrationTests {
    @Test("never registers Command-V or the same shortcut twice")
    func skipsReservedAndDuplicateShortcuts() {
        let registrar = FakeHotKeyRegistrar()
        let manager = HotKeyManager(registrar: registrar, defaults: Self.makeDefaults())
        manager.start(clipboardCallback: {}, screenshotCallback: {})
        defer { manager.stop() }

        manager.screenshotShortcut = manager.clipboardShortcut
        manager.screenTextShortcut = KeyboardShortcut(keyCode: 9, modifiers: [.command])

        #expect(registrar.registered.filter { $0 == manager.clipboardShortcut }.count == 1)
        #expect(!registrar.registered.contains(KeyboardShortcut(keyCode: 9, modifiers: [.command])))
    }

    @Test("shortcuts the system refuses are reported")
    func registrationFailuresAreReported() {
        let registrar = FakeHotKeyRegistrar()
        registrar.refused = [.controlCommandS]
        let manager = HotKeyManager(registrar: registrar, defaults: Self.makeDefaults())
        var reported: [[KeyboardShortcut]] = []
        manager.onRegistrationFailuresChanged = { reported.append($0) }
        manager.start(clipboardCallback: {}, screenshotCallback: {})
        defer { manager.stop() }

        manager.screenshotShortcut = .controlCommandS

        #expect(manager.registrationFailures == [.controlCommandS])
        #expect(reported.last == [.controlCommandS])

        manager.screenshotShortcut = nil
        #expect(manager.registrationFailures.isEmpty)
        #expect(reported.last == [])
    }

    @Test("the model refuses a shortcut that is Command-V or already taken")
    func modelRejectsCollidingShortcuts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try makeTestAppModel(store: ClipStore(storageDirectory: directory), pasteboard: HotKeyFakePasteboard())
        let previousScreenshot = model.screenshotShortcut
        var forwarded: [KeyboardShortcut?] = []
        model.onScreenshotShortcutChanged = { forwarded.append($0) }

        model.setScreenshotShortcut(model.clipboardShortcut)
        #expect(model.screenshotShortcut == previousScreenshot)
        #expect(model.shortcutMessage != nil)

        model.setScreenshotShortcut(KeyboardShortcut(keyCode: 9, modifiers: [.command]))
        #expect(model.screenshotShortcut == previousScreenshot)
        #expect(forwarded.isEmpty)

        let free = KeyboardShortcut(keyCode: 105, modifiers: [.control, .option, .shift, .command])
        model.setScreenshotShortcut(free)
        #expect(model.screenshotShortcut == free)
        #expect(model.shortcutMessage == nil)
        #expect(model.snippetShortcutConflict(KeyboardShortcut(keyCode: 9, modifiers: [.command]), excluding: UUID()) != nil)
    }

    private static func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "HotKeyRegistrationTests-\(UUID().uuidString)") ?? .standard
    }
}

@MainActor
private final class FakeHotKeyRegistrar: HotKeyRegistering {
    var refused: Set<KeyboardShortcut> = []
    private(set) var registered: [KeyboardShortcut] = []

    func register(_ shortcut: KeyboardShortcut, id: UInt32) -> Bool {
        guard !refused.contains(shortcut) else { return false }
        registered.append(shortcut)
        return true
    }

    func unregisterAll() {
        registered.removeAll()
    }
}

private final class HotKeyFakePasteboard: PasteboardClient {
    func currentChangeCount() -> Int { 0 }
    func readSnapshot() -> ClipboardSnapshot { ClipboardSnapshot(text: nil, imageData: nil) }
    func clearContents() {}
    func writeText(_ text: String) {}
    func writeImageData(_ data: Data) {}
}
