import AppKit
import ClipboardCore

final class SystemPasteboardClient: PasteboardClient {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func currentChangeCount() -> Int {
        pasteboard.changeCount
    }

    func readSnapshot() -> ClipboardSnapshot {
        let imageData = pasteboard.data(forType: .png)
            ?? pasteboard.data(forType: .tiff)
            ?? imageDataFromReadableObject()
        let text = pasteboard.string(forType: .string)
        return ClipboardSnapshot(text: text, imageData: imageData)
    }

    func clearContents() {
        pasteboard.clearContents()
    }

    func writeText(_ text: String) {
        pasteboard.setString(text, forType: .string)
    }

    func writeImageData(_ data: Data) {
        if let image = NSImage(data: data) {
            pasteboard.writeObjects([image])
        } else {
            pasteboard.setData(data, forType: .png)
        }
    }

    private func imageDataFromReadableObject() -> Data? {
        let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage]
        return images?.first?.pngData()
    }
}

