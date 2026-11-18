import AppKit

/// Carries the list of shared items from the sandboxed share extension to the host app
/// through a uniquely named pasteboard, which both sides can reach without a shared
/// container. The extension posts the items and passes the returned id in the
/// `clipboardss://share?id=…` URL; the host takes them exactly once.
public enum ShareHandoff {
    /// One shared item: a file or folder by `path`, or in-memory `data` with a suggested `name`.
    public struct Item: Codable, Equatable, Sendable {
        public var path: String?
        public var name: String?
        public var data: Data?

        public init(path: String) {
            self.path = path
        }

        public init(name: String, data: Data) {
            self.name = name
            self.data = data
        }
    }

    private static let payloadType = NSPasteboard.PasteboardType("com.local.ClipboardSS.share-handoff")

    private static func pasteboard(id: String) -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("com.local.ClipboardSS.share.\(id)"))
    }

    /// Extension side: posts `items` and returns the id the host needs to take them.
    public static func post(_ items: [Item]) throws -> String {
        let id = UUID().uuidString.lowercased()
        let payload = try JSONEncoder().encode(items)
        let board = pasteboard(id: id)
        board.clearContents()
        let entry = NSPasteboardItem()
        entry.setData(payload, forType: payloadType)
        guard board.writeObjects([entry]) else { throw ShareHandoffError.postFailed }
        return id
    }

    /// Host side: returns the items posted under `id` and releases the pasteboard, or nil
    /// when `id` is not a handoff id or nothing is waiting under it.
    public static func take(id: String) -> [Item]? {
        guard UUID(uuidString: id) != nil else { return nil }
        let board = pasteboard(id: id.lowercased())
        defer { board.releaseGlobally() }
        guard let payload = board.pasteboardItems?.first?.data(forType: payloadType),
              let items = try? JSONDecoder().decode([Item].self, from: payload),
              !items.isEmpty else {
            return nil
        }
        return items
    }
}

public enum ShareHandoffError: Error {
    case postFailed
}
