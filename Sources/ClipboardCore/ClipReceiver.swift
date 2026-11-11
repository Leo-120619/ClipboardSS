import Foundation

public enum ReceiveResult: Equatable, Sendable {
    case added(ClipItem)
    case duplicate
}

@MainActor
public final class ClipReceiver {
    private let store: ClipStore
    private let pasteboard: PasteboardClient
    /// Told to skip the pasteboard change each receive makes, so a received
    /// clip is not captured again as a local copy and echoed back.
    private let monitor: ClipboardMonitor?

    public init(store: ClipStore, pasteboard: PasteboardClient, monitor: ClipboardMonitor? = nil) {
        self.store = store
        self.pasteboard = pasteboard
        self.monitor = monitor
    }

    public func receive(_ payload: ClipPayload) throws -> ReceiveResult {
        let initialCount = store.items.count
        let addedClip: ClipItem

        switch payload.type {
        case .text:
            guard let text = payload.text else {
                throw NSError(domain: "ClipReceiver", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing text payload"])
            }
            addedClip = try store.addText(text)
            
            pasteboard.clearContents()
            pasteboard.writeText(text)
            monitor?.ignoreCurrentChange()
            
        case .image:
            guard let base64 = payload.imageBase64, let data = Data(base64Encoded: base64) else {
                throw NSError(domain: "ClipReceiver", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing or invalid image payload"])
            }
            guard ImageDataValidator.isDecodableImage(data) else {
                throw NSError(domain: "ClipReceiver", code: 3, userInfo: [NSLocalizedDescriptionKey: "Image payload is not a decodable image"])
            }
            let ext = payload.imageExtension ?? "png"
            addedClip = try store.addImageData(data, fileExtension: ext, previewText: payload.previewText)
            
            pasteboard.clearContents()
            pasteboard.writeImageData(data)
            monitor?.ignoreCurrentChange()
        }
        
        if initialCount == store.items.count {
            return .duplicate
        } else {
            return .added(addedClip)
        }
    }
}
