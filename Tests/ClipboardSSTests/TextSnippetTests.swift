import AppKit
import ClipboardCore
import Foundation
import Testing
@testable import ClipboardSS

@Suite("Text snippets")
struct TextSnippetTests {
    @Test("snippets with shortcuts round-trip through the store")
    func snippetsRoundTrip() throws {
        let suiteName = "TextSnippetTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TextSnippetStore(defaults: defaults)
        let optionL = KeyboardShortcut(keyCode: 37, modifiers: [.option])
        let snippets = [
            TextSnippet(name: "Name", text: "Leonardo", shortcut: optionL),
            TextSnippet(name: "No shortcut", text: "hello")
        ]

        store.save(snippets)

        let loaded = store.load()
        #expect(loaded == snippets)
        #expect(loaded[0].shortcut == optionL)
        #expect(loaded[0].shortcut?.displayName == "Option + L")
        #expect(loaded[1].shortcut == nil)
    }

    @Test("an empty store loads no snippets")
    func emptyStoreLoadsNothing() throws {
        let suiteName = "TextSnippetTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(TextSnippetStore(defaults: defaults).load().isEmpty)
    }

    @Test("only snippets with both text and a shortcut become hot keys")
    func hotKeysSkipIncompleteSnippets() {
        let optionL = KeyboardShortcut(keyCode: 37, modifiers: [.option])
        let optionJ = KeyboardShortcut(keyCode: 38, modifiers: [.option])
        let ready = TextSnippet(name: "Name", text: "Leonardo", shortcut: optionL)
        let snippets = [
            ready,
            TextSnippet(name: "No text", text: "", shortcut: optionJ),
            TextSnippet(name: "No shortcut", text: "hello")
        ]

        #expect(TextSnippet.hotKeys(for: snippets) == [SnippetHotKey(id: ready.id, shortcut: optionL)])
    }

    @Test("restore only happens when nobody else wrote to the pasteboard")
    func restoreDecision() {
        #expect(SnippetPaster.shouldRestore(currentChangeCount: 5, writtenChangeCount: 5))
        #expect(!SnippetPaster.shouldRestore(currentChangeCount: 6, writtenChangeCount: 5))
        #expect(!SnippetPaster.shouldRestore(currentChangeCount: 5, writtenChangeCount: nil))
    }

    @Test("file promises are not saved or restored")
    func promisedTypesAreSkipped() {
        #expect(SnippetPaster.isPromisedType(NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url")))
        #expect(SnippetPaster.isPromisedType(NSPasteboard.PasteboardType("NSFilesPromisePboardType")))
        #expect(!SnippetPaster.isPromisedType(.string))
        #expect(!SnippetPaster.isPromisedType(.fileURL))
    }
}

@MainActor
@Suite("Snippet paster")
struct SnippetPasterTests {
    @Test("pastes the snippet after modifiers are released and restores the clipboard")
    func pastesThenRestores() async throws {
        let fixture = SnippetPasterFixture()
        defer { fixture.release() }
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("original", forType: .string)
        fixture.modifiersDown = true

        fixture.paster.paste("snippet")

        #expect(fixture.pasteboard.string(forType: .string) == "snippet")
        #expect(fixture.ignoredWrites == 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.pasteCount == 0, "Command-V must wait for the hot key's modifiers")

        fixture.modifiersDown = false
        try await fixture.waitUntil { fixture.pasteCount == 1 }
        #expect(fixture.pasteboard.string(forType: .string) == "snippet", "pasteboard still holds the snippet when Command-V goes out")

        try await fixture.waitUntil { fixture.pasteboard.string(forType: .string) == "original" }
        #expect(fixture.ignoredWrites == 2)
    }

    @Test("marks the snippet write as transient so clipboard managers skip it")
    func snippetWriteIsTransient() {
        let fixture = SnippetPasterFixture()
        defer { fixture.release() }
        fixture.modifiersDown = true

        fixture.paster.paste("snippet")

        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        #expect(fixture.pasteboard.types?.contains(transient) == true)
        #expect(fixture.pasteboard.string(forType: .string) == "snippet")
    }

    @Test("sends Command-V anyway once the modifier wait times out")
    func timesOutModifierWait() async throws {
        let fixture = SnippetPasterFixture()
        defer { fixture.release() }
        fixture.modifiersDown = true

        fixture.paster.paste("snippet")

        try await fixture.waitUntil(timeout: SnippetPaster.modifierReleaseTimeout + 1) { fixture.pasteCount == 1 }
    }

    @Test("leaves a copy the user made during the paste alone")
    func userCopyIsNotOverwritten() async throws {
        let fixture = SnippetPasterFixture()
        defer { fixture.release() }
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("original", forType: .string)

        fixture.paster.paste("snippet")
        try await fixture.waitUntil { fixture.pasteCount == 1 }
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("user copy", forType: .string)

        try await Task.sleep(for: .seconds(SnippetPaster.restoreDelay + 0.3))
        #expect(fixture.pasteboard.string(forType: .string) == "user copy")
        #expect(fixture.ignoredWrites == 1, "the user's copy must stay visible to the clipboard monitor")
    }

    @Test("two quick pastes restore the clipboard from before the first")
    func quickPastesKeepOriginal() async throws {
        let fixture = SnippetPasterFixture()
        defer { fixture.release() }
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("original", forType: .string)

        fixture.paster.paste("first")
        try await fixture.waitUntil { fixture.pasteCount == 1 }
        fixture.paster.paste("second")
        try await fixture.waitUntil { fixture.pasteCount == 2 }
        #expect(fixture.pasteboard.string(forType: .string) == "second")

        try await fixture.waitUntil { fixture.pasteboard.string(forType: .string) == "original" }
    }
}

@MainActor
private final class SnippetPasterFixture {
    let pasteboard: NSPasteboard
    let paster: SnippetPaster
    var modifiersDown = false
    var pasteCount = 0
    var ignoredWrites = 0

    init() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("SnippetPasterTests-\(UUID().uuidString)"))
        self.pasteboard = pasteboard
        var sendPaste: () -> Void = {}
        var modifiersAreDown: () -> Bool = { false }
        paster = SnippetPaster(
            pasteboard: pasteboard,
            sendPaste: { sendPaste() },
            modifiersAreDown: { modifiersAreDown() }
        )
        sendPaste = { [unowned self] in self.pasteCount += 1 }
        modifiersAreDown = { [unowned self] in self.modifiersDown }
        paster.onPasteboardWritten = { [unowned self] in self.ignoredWrites += 1 }
    }

    func release() {
        pasteboard.releaseGlobally()
    }

    func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                Issue.record("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
