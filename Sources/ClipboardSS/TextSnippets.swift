import AppKit
import Foundation

/// A saved piece of text that is pasted into the frontmost app when its global
/// shortcut is pressed (for example Option + L pastes your name).
struct TextSnippet: Identifiable, Equatable, Codable {
    var id: UUID
    var name: String
    var text: String
    var keyCode: UInt16?
    var modifierRawValue: UInt?

    init(
        id: UUID = UUID(),
        name: String = "",
        text: String = "",
        shortcut: KeyboardShortcut? = nil
    ) {
        self.id = id
        self.name = name
        self.text = text
        self.shortcut = shortcut
    }

    var shortcut: KeyboardShortcut? {
        get {
            guard let keyCode, let modifierRawValue else { return nil }
            return KeyboardShortcut(
                keyCode: keyCode,
                modifiers: NSEvent.ModifierFlags(rawValue: modifierRawValue)
            )
        }
        set {
            keyCode = newValue?.keyCode
            modifierRawValue = newValue?.modifierRawValue
        }
    }

    /// The global hot keys that should be registered for these snippets.
    /// Snippets without a shortcut or without text are skipped.
    static func hotKeys(for snippets: [TextSnippet]) -> [SnippetHotKey] {
        snippets.compactMap { snippet in
            guard !snippet.text.isEmpty, let shortcut = snippet.shortcut else { return nil }
            return SnippetHotKey(id: snippet.id, shortcut: shortcut)
        }
    }
}

/// A snippet's global shortcut, ready to be registered as a hot key.
struct SnippetHotKey: Equatable {
    let id: UUID
    let shortcut: KeyboardShortcut
}

/// Persists snippets as JSON in user defaults.
struct TextSnippetStore {
    static let defaultsKey = "textSnippets"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [TextSnippet] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([TextSnippet].self, from: data)) ?? []
    }

    func save(_ snippets: [TextSnippet]) {
        guard let data = try? JSONEncoder().encode(snippets) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// Pastes text into the frontmost app by putting it on the pasteboard, sending
/// Command-V once the hot key's modifier keys are released, and then restoring
/// whatever was on the pasteboard before (unless something else wrote to the
/// pasteboard in the meantime).
@MainActor
final class SnippetPaster {
    /// Called right after this paster writes to the pasteboard, so the clipboard
    /// monitor can skip the change instead of saving it as a new clip.
    var onPasteboardWritten: (() -> Void)?

    /// How long to wait for the user to release the hot key's modifiers before
    /// sending Command-V anyway.
    static let modifierReleaseTimeout: TimeInterval = 1.0
    static let modifierPollInterval: TimeInterval = 0.02
    /// How long after Command-V the original clipboard is put back.
    static let restoreDelay: TimeInterval = 0.6

    private let pasteboard: NSPasteboard
    private let sendPaste: () -> Void
    private let modifiersAreDown: () -> Bool
    private var pendingPaste: DispatchWorkItem?
    private var pendingRestore: DispatchWorkItem?
    private var savedItems: [[NSPasteboard.PasteboardType: Data]]?
    private var writtenChangeCount: Int?

    init(
        pasteboard: NSPasteboard = .general,
        sendPaste: @escaping () -> Void = { PasteEventSender.sendPasteShortcut() },
        modifiersAreDown: @escaping () -> Bool = { SnippetPaster.hardwareModifiersAreDown() }
    ) {
        self.pasteboard = pasteboard
        self.sendPaste = sendPaste
        self.modifiersAreDown = modifiersAreDown
    }

    func paste(_ text: String) {
        guard !text.isEmpty else { return }

        pendingPaste?.cancel()
        pendingPaste = nil

        // If a previous snippet paste is still waiting to restore, keep the
        // original clipboard from before the first paste.
        if let pendingRestore {
            pendingRestore.cancel()
            self.pendingRestore = nil
        } else {
            savedItems = Self.copyItems(from: pasteboard)
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        writtenChangeCount = pasteboard.changeCount
        onPasteboardWritten?()

        waitForModifierRelease(deadline: Date().addingTimeInterval(Self.modifierReleaseTimeout))
    }

    /// Command-V must not go out while the user is still holding the hot key's
    /// modifiers, or the target app receives e.g. Command-Option-V instead.
    private func waitForModifierRelease(deadline: Date) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.modifiersAreDown(), Date() < deadline {
                self.waitForModifierRelease(deadline: deadline)
                return
            }
            self.pendingPaste = nil
            self.sendPaste()
            self.scheduleRestore()
        }
        pendingPaste = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.modifierPollInterval, execute: work)
    }

    private func scheduleRestore() {
        let restore = DispatchWorkItem { [weak self] in
            self?.restoreClipboard()
        }
        pendingRestore = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDelay, execute: restore)
    }

    private func restoreClipboard() {
        pendingRestore = nil
        guard let savedItems else { return }
        self.savedItems = nil

        // Something else (most likely the user copying) wrote to the pasteboard
        // after the snippet. Leave their clipboard alone.
        guard Self.shouldRestore(currentChangeCount: pasteboard.changeCount, writtenChangeCount: writtenChangeCount) else {
            return
        }

        pasteboard.clearContents()
        let items = savedItems.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types {
                item.setData(data, forType: type)
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
        onPasteboardWritten?()
    }

    nonisolated static func shouldRestore(currentChangeCount: Int, writtenChangeCount: Int?) -> Bool {
        currentChangeCount == writtenChangeCount
    }

    nonisolated static func hardwareModifiersAreDown() -> Bool {
        !NSEvent.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
    }

    private static func copyItems(from pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types where !isPromisedType(type) {
                if let data = item.data(forType: type) {
                    types[type] = data
                }
            }
            return types
        }
    }

    /// File promises are fulfilled by the owning app on demand; their raw
    /// bytes are meaningless once copied, so they are not saved or restored.
    nonisolated static func isPromisedType(_ type: NSPasteboard.PasteboardType) -> Bool {
        type.rawValue.hasPrefix("com.apple.pasteboard.promised")
            || type.rawValue == "NSFilesPromisePboardType"
            || type.rawValue == "com.apple.NSFilePromiseItemMetaData"
    }
}
