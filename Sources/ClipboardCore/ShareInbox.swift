import Foundation

/// Hands items from the macOS Share Extension (sandboxed) to the host app (not sandboxed).
///
/// The extension cannot write anywhere the host may read: the app is signed without a Team
/// ID, so macOS denies it the app-group container. It therefore only posts *what* was shared
/// (`ShareHandoff`) and opens the host, which copies the files (zipping folders) into a
/// per-drop folder of its own outbox and writes a `manifest.json` last, so only complete
/// drops are ever sent. The drop stays in the outbox until its files are handed to the
/// normal file-send flow, which lets a share survive a relaunch.
public enum ShareInbox {
    /// Custom URL scheme the extension opens to foreground the host app.
    public static let urlScheme = "clipboardss"

    private static let manifestName = "manifest.json"

    /// A drop that never became valid (no manifest, or one naming files that are not there)
    /// is removed once its folder is this old, so the poll stops re-parsing it.
    public static let rejectedDropMaxAge: TimeInterval = 24 * 60 * 60

    // MARK: - Building a drop

    /// Creates an empty drop in `outbox`. Call `finalizeDrop` only after all files have been
    /// staged in this directory; writing its manifest last is the completeness barrier.
    public static func createDrop(in outbox: URL) throws -> (id: String, directory: URL) {
        let id = UUID().uuidString.lowercased()
        let dropDir = outbox.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dropDir, withIntermediateDirectories: true)
        return (id, dropDir)
    }

    /// Marks a fully staged drop complete by writing `manifest.json` last.
    public static func finalizeDrop(id: String, names: [String], in outbox: URL) throws {
        let dropDir = outbox.appendingPathComponent(id, isDirectory: true)
        let manifest = ShareManifest(id: id, fileNames: names)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: dropDir.appendingPathComponent(manifestName), options: .atomic)
    }

    /// Builds a complete drop in `outbox` from items the share extension handed over: files
    /// are copied, folders are zipped, and in-memory items are written out. Any failure
    /// removes the partial drop and throws, so a share is never sent with items missing.
    /// Returns the drop id.
    @discardableResult
    public static func importItems(_ items: [ShareHandoff.Item], into outbox: URL) throws -> String {
        let drop = try createDrop(in: outbox)
        do {
            var names: [String] = []
            for item in items {
                if let path = item.path {
                    let source = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                    if FolderArchiver.isDirectory(source) {
                        names.append(try FolderArchiver.zip(source, into: drop.directory).lastPathComponent)
                    } else {
                        let name = uniqueName(source.lastPathComponent, existing: names)
                        try FileManager.default.copyItem(at: source, to: drop.directory.appendingPathComponent(name))
                        names.append(name)
                    }
                } else if let data = item.data {
                    let name = uniqueName(safeFileName(item.name), existing: names)
                    try data.write(to: drop.directory.appendingPathComponent(name))
                    names.append(name)
                }
            }
            guard !names.isEmpty else { throw ShareInboxError.nothingToShare }
            try finalizeDrop(id: drop.id, names: names, in: outbox)
            return drop.id
        } catch {
            try? FileManager.default.removeItem(at: drop.directory)
            throw error
        }
    }

    // MARK: - Host side

    /// A complete drop the host can consume: its folder plus the resolved file URLs.
    public struct PendingDrop {
        public let directory: URL
        public let fileURLs: [URL]
        /// When the drop was finalized (its manifest's modification date).
        public let createdAt: Date

        public init(directory: URL, fileURLs: [URL], createdAt: Date) {
            self.directory = directory
            self.fileURLs = fileURLs
            self.createdAt = createdAt
        }
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

    /// A single, non-empty path component for an in-memory item's suggested name.
    private static func safeFileName(_ name: String?) -> String {
        let last = ((name ?? "") as NSString).lastPathComponent
        return last.isEmpty || last == "." || last == ".." || last == "/" ? "file" : last
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
    case nothingToShare
}
