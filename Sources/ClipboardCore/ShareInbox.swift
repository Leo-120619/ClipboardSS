import Foundation

/// Bridges the macOS Share Extension (sandboxed) and the host app (not sandboxed).
///
/// The extension copies the shared files into a per-drop folder inside the shared
/// app-group container and writes a `manifest.json` last (so the host only ever sees
/// complete drops). The host polls the outbox, stages the files locally, deletes the
/// drop folder, and hands the staged URLs to its normal file-send flow.
public enum ShareInbox {
    /// App-group identifier shared by the app target and the ShareExtension target.
    public static let appGroupIdentifier = "group.com.local.ClipboardSS"

    /// Custom URL scheme the extension opens to foreground the host app.
    public static let urlScheme = "clipboardss"

    /// Resolves the shared app-group container. Falls back to the well-known path so a
    /// non-sandboxed host without a resolvable entitlement can still read it.
    public static func containerURL() -> URL? {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return url
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Group Containers/\(appGroupIdentifier)", isDirectory: true)
    }

    /// Directory holding one subfolder per pending share drop.
    public static func outboxDirectory() -> URL? {
        containerURL()?.appendingPathComponent("ShareOutbox", isDirectory: true)
    }

    private static let manifestName = "manifest.json"

    // MARK: - Extension side

    /// Writes a drop into the outbox. `sources` are readable file URLs whose bytes are
    /// copied into a fresh `<uuid>` folder; `manifest.json` is written last.
    /// Returns the drop id on success.
    @discardableResult
    public static func writeDrop(sources: [URL]) throws -> String {
        guard let outbox = outboxDirectory() else {
            throw ShareInboxError.containerUnavailable
        }
        let id = UUID().uuidString.lowercased()
        let dropDir = outbox.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dropDir, withIntermediateDirectories: true)

        var storedNames: [String] = []
        for source in sources {
            let name = uniqueName(source.lastPathComponent, existing: storedNames)
            let dest = dropDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: source, to: dest)
            storedNames.append(name)
        }

        let manifest = ShareManifest(id: id, fileNames: storedNames)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: dropDir.appendingPathComponent(manifestName), options: .atomic)
        return id
    }

    // MARK: - Host side

    /// A complete drop the host can consume: its folder plus the resolved file URLs.
    public struct PendingDrop {
        public let directory: URL
        public let fileURLs: [URL]
    }

    /// Returns every complete drop currently sitting in the outbox.
    public static func pendingDrops() -> [PendingDrop] {
        guard let outbox = outboxDirectory(),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: outbox,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        var drops: [PendingDrop] = []
        for dir in entries where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let manifestURL = dir.appendingPathComponent(manifestName)
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(ShareManifest.self, from: data) else {
                continue
            }
            let urls = manifest.fileNames.map { dir.appendingPathComponent($0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !urls.isEmpty else { continue }
            drops.append(PendingDrop(directory: dir, fileURLs: urls))
        }
        return drops
    }

    /// Removes a consumed drop folder from the outbox.
    public static func remove(_ drop: PendingDrop) {
        try? FileManager.default.removeItem(at: drop.directory)
    }

    // MARK: - Helpers

    private static func uniqueName(_ name: String, existing: [String]) -> String {
        let base = name.isEmpty ? "file" : name
        guard existing.contains(base) else { return base }
        let ext = (base as NSString).pathExtension
        let stem = (base as NSString).deletingPathExtension
        var i = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem)-\(i)" : "\(stem)-\(i).\(ext)"
            if !existing.contains(candidate) { return candidate }
            i += 1
        }
    }
}

public struct ShareManifest: Codable {
    public let id: String
    public let fileNames: [String]

    public init(id: String, fileNames: [String]) {
        self.id = id
        self.fileNames = fileNames
    }
}

public enum ShareInboxError: Error {
    case containerUnavailable
}
