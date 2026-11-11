import Foundation

/// Bridges the macOS Share Extension (sandboxed) and the host app (not sandboxed).
///
/// The extension stages shared files in a per-drop folder inside the shared
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

    /// A drop that never became valid (no manifest, or one naming files that are not there)
    /// is removed once its folder is this old, so the poll stops re-parsing it.
    public static let rejectedDropMaxAge: TimeInterval = 24 * 60 * 60

    // MARK: - Extension side

    /// Creates an empty outbox drop. Call `finalizeDrop` only after all files have been
    /// staged in this directory; writing its manifest last is the completeness barrier.
    public static func createDrop() throws -> (id: String, directory: URL) {
        guard let outbox = outboxDirectory() else {
            throw ShareInboxError.containerUnavailable
        }
        let id = UUID().uuidString.lowercased()
        let dropDir = outbox.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dropDir, withIntermediateDirectories: true)
        return (id, dropDir)
    }

    /// Marks a fully staged drop complete by writing `manifest.json` last.
    public static func finalizeDrop(id: String, names: [String]) throws {
        guard let outbox = outboxDirectory() else {
            throw ShareInboxError.containerUnavailable
        }
        let dropDir = outbox.appendingPathComponent(id, isDirectory: true)
        let manifest = ShareManifest(id: id, fileNames: names)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: dropDir.appendingPathComponent(manifestName), options: .atomic)
    }

    /// Writes a drop into the outbox. Existing callers supply extension-owned staging
    /// URLs, so files are moved rather than copied (with a copy fallback).
    /// Returns the drop id on success.
    @discardableResult
    public static func writeDrop(sources: [URL]) throws -> String {
        let drop = try createDrop()

        var storedNames: [String] = []
        for source in sources {
            let name = uniqueName(source.lastPathComponent, existing: storedNames)
            let dest = drop.directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            do {
                try FileManager.default.moveItem(at: source, to: dest)
            } catch {
                try FileManager.default.copyItem(at: source, to: dest)
            }
            storedNames.append(name)
        }

        try finalizeDrop(id: drop.id, names: storedNames)
        return drop.id
    }

    // MARK: - Host side

    /// A complete drop the host can consume: its folder plus the resolved file URLs.
    public struct PendingDrop {
        public let directory: URL
        public let fileURLs: [URL]
        /// When the extension finalized the drop (its manifest's modification date).
        public let createdAt: Date

        public init(directory: URL, fileURLs: [URL], createdAt: Date) {
            self.directory = directory
            self.fileURLs = fileURLs
            self.createdAt = createdAt
        }
    }

    /// Returns every complete drop currently sitting in the outbox.
    public static func pendingDrops() -> [PendingDrop] {
        guard let outbox = outboxDirectory() else { return [] }
        return pendingDrops(in: outbox)
    }

    /// Returns every complete drop in `outbox`. Rejected or incomplete drops whose folder is
    /// older than `rejectedDropMaxAge` are removed.
    public static func pendingDrops(in outbox: URL, now: Date = Date()) -> [PendingDrop] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
                at: outbox,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        var drops: [PendingDrop] = []
        for dir in entries where isRegularDirectory(dir) {
            let manifestURL = dir.appendingPathComponent(manifestName)
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(ShareManifest.self, from: data) else {
                discardIfStale(dir, now: now)
                continue
            }
            // A manifest naming anything but plain files inside the drop is not ours: skip it.
            let urls = manifest.fileNames.map { resolveFile(named: $0, in: dir) }
            guard !urls.isEmpty, !urls.contains(nil) else {
                discardIfStale(dir, now: now)
                continue
            }
            let createdAt = (try? FileManager.default.attributesOfItem(atPath: manifestURL.path))?[.modificationDate]
                as? Date ?? Date()
            drops.append(PendingDrop(directory: dir, fileURLs: urls.compactMap { $0 }, createdAt: createdAt))
        }
        return drops
    }

    /// Rewrites a partly sent drop's manifest to list only `fileURLs` (the files still to send),
    /// keeping its date, so a later re-read finds a complete drop of just those files.
    public static func retain(_ fileURLs: [URL], in drop: PendingDrop) -> PendingDrop {
        let manifestURL = drop.directory.appendingPathComponent(manifestName)
        let manifest = ShareManifest(id: drop.directory.lastPathComponent, fileNames: fileURLs.map(\.lastPathComponent))
        if let data = try? JSONEncoder().encode(manifest), (try? data.write(to: manifestURL, options: .atomic)) != nil {
            try? FileManager.default.setAttributes([.modificationDate: drop.createdAt], ofItemAtPath: manifestURL.path)
        }
        return PendingDrop(directory: drop.directory, fileURLs: fileURLs, createdAt: drop.createdAt)
    }

    /// Removes a consumed drop folder from the outbox.
    public static func remove(_ drop: PendingDrop) {
        try? FileManager.default.removeItem(at: drop.directory)
    }

    // MARK: - Helpers

    /// Removes a drop folder that is still not valid after `rejectedDropMaxAge`. Its age is
    /// the newer of the folder's creation and modification dates, so a drop the extension
    /// is still writing is never touched.
    private static func discardIfStale(_ dir: URL, now: Date) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: dir.path) else { return }
        let dates = [attributes[.creationDate], attributes[.modificationDate]].compactMap { $0 as? Date }
        guard let newest = dates.max(), now.timeIntervalSince(newest) > rejectedDropMaxAge else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    /// True when `url` itself (not a symlink target) is a regular file.
    public static func isRegularFile(_ url: URL) -> Bool {
        let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        return type == .typeRegular
    }

    private static func isRegularDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    /// Accepts only a single path component that names a regular file (not a symlink)
    /// directly inside `dir`.
    private static func resolveFile(named name: String, in dir: URL) -> URL? {
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\0") else {
            return nil
        }
        let url = dir.appendingPathComponent(name, isDirectory: false)
        guard url.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path,
              isRegularFile(url) else {
            return nil
        }
        return url
    }

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
