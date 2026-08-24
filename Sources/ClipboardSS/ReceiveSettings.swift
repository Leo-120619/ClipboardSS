import AppKit

/// Persistent receive-folder preference. Files always finalize promptly; UI prompts run later.
enum ReceiveSettings {
    enum Mode: String { case unset, defaultFolder, askEveryTime }
    static let modeKey = "receiveDestinationMode"
    static let pathKey = "receiveDestinationPath"

    static var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .unset }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }
    static var path: String? {
        get { UserDefaults.standard.string(forKey: pathKey) }
        set { UserDefaults.standard.set(newValue, forKey: pathKey) }
    }
    static func resolvedDirectory() -> URL {
        if mode == .defaultFolder, let path, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        if let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            return url
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }
    @MainActor
    static func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
