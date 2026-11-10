import Foundation

public struct ClipboardSnapshot: Equatable, Sendable {
    public var text: String?
    public var imageData: Data?
    /// True when the source app marked the item as concealed, transient or
    /// auto-generated (nspasteboard.org markers), e.g. a copied password.
    /// Such items must never be stored or synced.
    public var isSensitive: Bool

    public init(text: String?, imageData: Data?, isSensitive: Bool = false) {
        self.text = text
        self.imageData = imageData
        self.isSensitive = isSensitive
    }
}

public protocol PasteboardClient: AnyObject {
    func currentChangeCount() -> Int
    func readSnapshot() -> ClipboardSnapshot
    func clearContents()
    func writeText(_ text: String)
    func writeImageData(_ data: Data)
}

public enum ClipboardWriterError: Error, Equatable {
    case imageDataMissing(UUID)
}

public final class ClipboardWriter {
    private let pasteboard: PasteboardClient
    private let store: ClipStore

    public init(pasteboard: PasteboardClient, store: ClipStore) {
        self.pasteboard = pasteboard
        self.store = store
    }

    public func copy(_ clip: ClipItem) throws {
        pasteboard.clearContents()

        switch clip.type {
        case .text:
            pasteboard.writeText(clip.text ?? "")
        case .image:
            let url = clip.resolvedImageURL(baseDirectory: store.storageDirectory)
            guard let data = try? Data(contentsOf: url) else {
                throw ClipboardWriterError.imageDataMissing(clip.id)
            }
            pasteboard.writeImageData(data)
        }

        try store.markCopied(clip.id)
    }
}

public final class ClipboardMonitor {
    private let pasteboard: PasteboardClient
    private let store: ClipStore
    private var lastChangeCount: Int?

    public init(pasteboard: PasteboardClient, store: ClipStore) {
        self.pasteboard = pasteboard
        self.store = store
    }

    /// Treats the pasteboard's current contents as already seen, so the next
    /// `poll()` does not record them. Used when the app itself writes to the
    /// pasteboard temporarily (for example when pasting a text snippet).
    public func ignoreCurrentChange() {
        lastChangeCount = pasteboard.currentChangeCount()
    }

    public func poll() throws {
        let currentChangeCount = pasteboard.currentChangeCount()
        guard currentChangeCount != lastChangeCount else {
            return
        }

        lastChangeCount = currentChangeCount
        let snapshot = pasteboard.readSnapshot()
        guard !snapshot.isSensitive else {
            return
        }

        if let imageData = snapshot.imageData, !imageData.isEmpty {
            try store.addImageData(imageData, fileExtension: "png", previewText: "Image")
            return
        }

        if let text = snapshot.text, !text.isEmpty {
            try store.addText(text)
        }
    }
}
