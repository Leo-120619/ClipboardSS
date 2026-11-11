import ClipboardCore
import Foundation
import Testing
@testable import ClipboardSS

@MainActor
@Suite("App model snippets")
struct AppModelSnippetTests {
    @Test("a snippet cannot take a built-in shortcut")
    func rejectsBuiltInShortcut() throws {
        let fixture = try AppModelSnippetFixture()
        fixture.model.addSnippet()
        var snippet = fixture.model.snippets[0]
        snippet.text = "hello"
        snippet.shortcut = fixture.model.clipboardShortcut

        fixture.model.updateSnippet(snippet)

        #expect(fixture.model.snippets[0].shortcut == nil)
        #expect(fixture.model.snippets[0].text == "hello", "the rest of the edit is kept")
        #expect(fixture.model.lastError?.contains("clipboard window") == true)
    }

    @Test("a snippet cannot take another snippet's shortcut")
    func rejectsDuplicateSnippetShortcut() throws {
        let fixture = try AppModelSnippetFixture()
        let optionL = KeyboardShortcut(keyCode: 37, modifiers: [.option])
        fixture.model.addSnippet()
        fixture.model.addSnippet()
        var first = fixture.model.snippets[0]
        first.name = "Name"
        first.shortcut = optionL
        fixture.model.updateSnippet(first)
        #expect(fixture.model.lastError == nil)

        var second = fixture.model.snippets[1]
        second.shortcut = optionL
        fixture.model.updateSnippet(second)

        #expect(fixture.model.snippets[0].shortcut == optionL)
        #expect(fixture.model.snippets[1].shortcut == nil)
        #expect(fixture.model.lastError?.contains("Name") == true)
    }

    @Test("re-saving a snippet with its own shortcut is not a conflict")
    func ownShortcutIsNotAConflict() throws {
        let fixture = try AppModelSnippetFixture()
        let optionL = KeyboardShortcut(keyCode: 37, modifiers: [.option])
        fixture.model.addSnippet()
        var snippet = fixture.model.snippets[0]
        snippet.shortcut = optionL
        fixture.model.updateSnippet(snippet)

        snippet = fixture.model.snippets[0]
        snippet.text = "typing"
        fixture.model.updateSnippet(snippet)

        #expect(fixture.model.snippets[0].shortcut == optionL)
        #expect(fixture.model.lastError == nil)
    }

    @Test("snippet changes are persisted and reported")
    func changesArePersistedAndReported() throws {
        let fixture = try AppModelSnippetFixture()
        var reported: [[TextSnippet]] = []
        fixture.model.onSnippetsChanged = { reported.append($0) }

        fixture.model.addSnippet()
        let id = fixture.model.snippets[0].id
        fixture.model.deleteSnippet(id)

        #expect(reported.count == 2)
        #expect(reported[1].isEmpty)
        #expect(fixture.store.load().isEmpty)
    }
}

@MainActor
private struct AppModelSnippetFixture {
    let model: AppModel
    let store: TextSnippetStore

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let clipStore = try ClipStore(storageDirectory: directory)
        let defaults = try #require(UserDefaults(suiteName: "AppModelSnippetTests-\(UUID().uuidString)"))
        store = TextSnippetStore(defaults: defaults)
        model = try makeTestAppModel(
            store: clipStore,
            pasteboard: SnippetFakePasteboard(),
            snippetStore: store
        )
    }
}

private final class SnippetFakePasteboard: PasteboardClient {
    func currentChangeCount() -> Int { 0 }
    func readSnapshot() -> ClipboardSnapshot { ClipboardSnapshot(text: nil, imageData: nil) }
    func clearContents() {}
    func writeText(_ text: String) {}
    func writeImageData(_ data: Data) {}
}
