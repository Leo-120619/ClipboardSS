import AppKit

enum ClipboardSSLogo {
    static func menuBarImage(size: NSSize = NSSize(width: 18, height: 18)) -> NSImage? {
        let image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "ClipboardSS")
        image?.size = size
        image?.isTemplate = true
        return image
    }

    static func image(size: NSSize? = nil) -> NSImage? {
        let fileManager = FileManager.default
        let candidates = [
            Bundle.main.url(forResource: "clipboard", withExtension: "png"),
            URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent("Assets/clipboard.png"),
            URL(fileURLWithPath: "/Users/leolml/Development/Clipboard SS/Assets/clipboard.png")
        ].compactMap { $0 }

        for url in candidates where fileManager.fileExists(atPath: url.path) {
            if let image = NSImage(contentsOf: url) {
                if let size {
                    image.size = size
                }
                image.isTemplate = false
                return image
            }
        }

        let fallback = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "ClipboardSS")
        fallback?.size = size ?? NSSize(width: 24, height: 24)
        return fallback
    }
}
