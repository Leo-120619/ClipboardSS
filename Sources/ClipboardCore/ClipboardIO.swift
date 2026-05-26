import Foundation

public struct ClipboardSnapshot: Equatable, Sendable {
    public var text: String?
    public var imageData: Data?

    public init(text: String?, imageData: Data?) {
        self.text = text
        self.imageData = imageData
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

    public func poll() throws {
        let currentChangeCount = pasteboard.currentChangeCount()
        guard currentChangeCount != lastChangeCount else {
            return
        }

        lastChangeCount = currentChangeCount
        let snapshot = pasteboard.readSnapshot()

        if let imageData = snapshot.imageData, !imageData.isEmpty {
            try store.addImageData(imageData, fileExtension: "png", previewText: "Image")
            return
        }

        if let text = snapshot.text, !text.isEmpty {
            try store.addText(text)
        }
    }
}
