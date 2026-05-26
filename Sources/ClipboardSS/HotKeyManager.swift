import AppKit
import Carbon

@MainActor
final class HotKeyManager {
    private enum HotKeyID: UInt32 {
        case clipboard = 1
        case screenshot = 2
        case screenText = 3
    }

    private static let hotKeySignature = OSType(0x434C5053)

    private var clipboardCallback: (() -> Void)?
    private var screenshotCallback: (() -> Void)?
    private var screenTextCallback: (() -> Void)?
    private var eventHandler: EventHandlerRef?
    private var registeredHotKeys: [UInt32: EventHotKeyRef] = [:]

    var clipboardShortcut = KeyboardShortcut.savedClipboardShortcut {
        didSet {
            KeyboardShortcut.save(clipboardShortcut, keyPrefix: "clipboard")
            registerHotKeys()
        }
    }

    var screenshotShortcut = KeyboardShortcut.savedScreenshotShortcut {
        didSet {
            KeyboardShortcut.save(screenshotShortcut, keyPrefix: "screenshot")
            registerHotKeys()
        }
    }

    var screenTextShortcut = KeyboardShortcut.savedScreenTextShortcut {
        didSet {
            KeyboardShortcut.save(screenTextShortcut, keyPrefix: "screenText")
            registerHotKeys()
        }
    }

    func start(
        clipboardCallback: @escaping () -> Void,
        screenshotCallback: @escaping () -> Void,
        screenTextCallback: @escaping () -> Void = {}
    ) {
        self.clipboardCallback = clipboardCallback
        self.screenshotCallback = screenshotCallback
        self.screenTextCallback = screenTextCallback
        installEventHandlerIfNeeded()
        registerHotKeys()
    }

    func stop() {
        unregisterHotKeys()

        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        eventHandler = nil
        clipboardCallback = nil
        screenshotCallback = nil
        screenTextCallback = nil
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else {
                    return noErr
                }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else {
                    return status
                }

                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in
                    manager.handleRegisteredHotKey(id: hotKeyID.id)
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

        if status != noErr {
            eventHandler = nil
        }
    }

    private func registerHotKeys() {
        guard eventHandler != nil else { return }

        unregisterHotKeys()
        register(clipboardShortcut, id: .clipboard)
        if let screenshotShortcut {
            register(screenshotShortcut, id: .screenshot)
        }
        if let screenTextShortcut {
            register(screenTextShortcut, id: .screenText)
        }
    }

    private func register(_ shortcut: KeyboardShortcut, id: HotKeyID) {
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: id.rawValue)
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.carbonModifierFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr, let hotKeyRef {
            registeredHotKeys[id.rawValue] = hotKeyRef
        }
    }

    private func unregisterHotKeys() {
        for hotKeyRef in registeredHotKeys.values {
            UnregisterEventHotKey(hotKeyRef)
        }
        registeredHotKeys.removeAll()
    }

    private func handleRegisteredHotKey(id: UInt32) {
        if id == HotKeyID.clipboard.rawValue {
            clipboardCallback?()
            return
        }

        if id == HotKeyID.screenshot.rawValue {
            screenshotCallback?()
            return
        }

        if id == HotKeyID.screenText.rawValue {
            screenTextCallback?()
        }
    }
}

struct KeyboardShortcut: Equatable, Hashable {
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags

    static let defaultClipboard = KeyboardShortcut(keyCode: 9, modifiers: [.control, .option])
    static let controlOptionV = KeyboardShortcut(keyCode: 9, modifiers: [.control, .option])
    static let controlShiftSpace = KeyboardShortcut(keyCode: 49, modifiers: [.control, .shift])
    static let controlOptionSpace = KeyboardShortcut(keyCode: 49, modifiers: [.control, .option])
    static let commandShiftV = KeyboardShortcut(keyCode: 9, modifiers: [.command, .shift])
    static let optionCommandV = KeyboardShortcut(keyCode: 9, modifiers: [.option, .command])
    static let controlCommandS = KeyboardShortcut(keyCode: 1, modifiers: [.control, .command])

    var modifierRawValue: UInt {
        modifiers.rawValue
    }

    var carbonModifierFlags: UInt32 {
        var flags = UInt32(0)
        if modifiers.contains(.command) {
            flags |= UInt32(cmdKey)
        }
        if modifiers.contains(.option) {
            flags |= UInt32(optionKey)
        }
        if modifiers.contains(.control) {
            flags |= UInt32(controlKey)
        }
        if modifiers.contains(.shift) {
            flags |= UInt32(shiftKey)
        }
        return flags
    }

    static func == (lhs: KeyboardShortcut, rhs: KeyboardShortcut) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers.rawValue == rhs.modifiers.rawValue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers.rawValue)
    }

    var displayName: String {
        let modifierText = [
            modifiers.contains(.control) ? "Control" : nil,
            modifiers.contains(.option) ? "Option" : nil,
            modifiers.contains(.shift) ? "Shift" : nil,
            modifiers.contains(.command) ? "Command" : nil
        ]
        .compactMap { $0 }
        .joined(separator: " + ")

        let key = Self.keyName(for: keyCode)
        return modifierText.isEmpty ? key : "\(modifierText) + \(key)"
    }

    static func keyName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 0: "A"
        case 1: "S"
        case 2: "D"
        case 3: "F"
        case 4: "H"
        case 5: "G"
        case 6: "Z"
        case 7: "X"
        case 8: "C"
        case 9: "V"
        case 11: "B"
        case 12: "Q"
        case 13: "W"
        case 14: "E"
        case 15: "R"
        case 16: "Y"
        case 17: "T"
        case 18: "1"
        case 19: "2"
        case 20: "3"
        case 21: "4"
        case 22: "6"
        case 23: "5"
        case 24: "="
        case 25: "9"
        case 26: "7"
        case 27: "-"
        case 28: "8"
        case 29: "0"
        case 30: "]"
        case 31: "O"
        case 32: "U"
        case 33: "["
        case 34: "I"
        case 35: "P"
        case 36: "Return"
        case 37: "L"
        case 38: "J"
        case 39: "'"
        case 40: "K"
        case 41: ";"
        case 42: "\\"
        case 43: ","
        case 44: "/"
        case 45: "N"
        case 46: "M"
        case 47: "."
        case 48: "Tab"
        case 49: "Space"
        case 50: "`"
        case 51: "Delete"
        case 53: "Escape"
        case 65: "."
        case 67: "*"
        case 69: "+"
        case 71: "Clear"
        case 75: "/"
        case 76: "Enter"
        case 78: "-"
        case 81: "="
        case 82: "0"
        case 83: "1"
        case 84: "2"
        case 85: "3"
        case 86: "4"
        case 87: "5"
        case 88: "6"
        case 89: "7"
        case 91: "8"
        case 92: "9"
        case 96: "F5"
        case 97: "F6"
        case 98: "F7"
        case 99: "F3"
        case 100: "F8"
        case 101: "F9"
        case 103: "F11"
        case 105: "F13"
        case 107: "F14"
        case 109: "F10"
        case 111: "F12"
        case 113: "F15"
        case 115: "Home"
        case 116: "Page Up"
        case 117: "Forward Delete"
        case 118: "F4"
        case 119: "End"
        case 120: "F2"
        case 121: "Page Down"
        case 122: "F1"
        case 123: "Left Arrow"
        case 124: "Right Arrow"
        case 125: "Down Arrow"
        case 126: "Up Arrow"
        default: "Key \(keyCode)"
        }
    }

    func matches(_ event: NSEvent) -> Bool {
        let relevantFlags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        return event.keyCode == keyCode && relevantFlags == modifiers
    }

    static var savedClipboardShortcut: KeyboardShortcut {
        load(keyPrefix: "clipboard") ?? .defaultClipboard
    }

    static var savedScreenshotShortcut: KeyboardShortcut? {
        load(keyPrefix: "screenshot")
    }

    static var savedScreenTextShortcut: KeyboardShortcut? {
        load(keyPrefix: "screenText")
    }

    static func load(keyPrefix: String) -> KeyboardShortcut? {
        let defaults = UserDefaults.standard
        guard
            let keyCode = defaults.object(forKey: "\(keyPrefix)ShortcutKeyCode") as? NSNumber,
            let modifiers = defaults.object(forKey: "\(keyPrefix)ShortcutModifiers") as? NSNumber
        else {
            return nil
        }

        return KeyboardShortcut(
            keyCode: keyCode.uint16Value,
            modifiers: NSEvent.ModifierFlags(rawValue: modifiers.uintValue)
        )
    }

    static func save(_ shortcut: KeyboardShortcut?, keyPrefix: String) {
        let defaults = UserDefaults.standard
        guard let shortcut else {
            defaults.removeObject(forKey: "\(keyPrefix)ShortcutKeyCode")
            defaults.removeObject(forKey: "\(keyPrefix)ShortcutModifiers")
            return
        }

        defaults.set(shortcut.keyCode, forKey: "\(keyPrefix)ShortcutKeyCode")
        defaults.set(shortcut.modifierRawValue, forKey: "\(keyPrefix)ShortcutModifiers")
    }
}
