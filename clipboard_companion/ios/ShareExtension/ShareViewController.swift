import Social
import MobileCoreServices

final class ShareViewController: SLComposeServiceViewController {
  private let appGroup = "group.com.leolml.clipboardCompanion"

  override func isContentValid() -> Bool { true }

  override func didSelectPost() {
    let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
      .flatMap { $0.attachments ?? [] }
    let batchID = UUID().uuidString
    guard let root = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroup
    ) else {
      finishWithError("Shared storage is unavailable.")
      return
    }
    let directory = root.appendingPathComponent("IncomingShares/\(batchID)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let group = DispatchGroup()
    let lock = NSLock()
    var attachments: [[String: Any]] = []
    var skipped = 0
    for (index, provider) in providers.enumerated() {
      guard let type = provider.registeredTypeIdentifiers.first else {
        skipped += 1
        continue
      }
      group.enter()
      provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
        defer { group.leave() }
        guard let url else { lock.lock(); skipped += 1; lock.unlock(); return }
        do {
          let rawName = url.lastPathComponent.isEmpty ? "shared-\(index)" : url.lastPathComponent
          let name = self.safeName(rawName)
          let destination = self.uniqueURL(in: directory, named: name)
          try FileManager.default.copyItem(at: url, to: destination)
          let values = try? destination.resourceValues(forKeys: [.fileSizeKey])
          lock.lock()
          attachments.append([
            "path": destination.path,
            "name": destination.lastPathComponent,
            "mimeType": self.mimeType(for: type),
            "size": values?.fileSize ?? 0,
          ])
          lock.unlock()
        } catch {
          lock.lock(); skipped += 1; lock.unlock()
        }
      }
    }
    group.notify(queue: .main) {
      guard !attachments.isEmpty else {
        try? FileManager.default.removeItem(at: directory)
        self.finishWithError("None of the selected files could be read.")
        return
      }
      let manifest: [String: Any] = [
        "id": batchID, "attachments": attachments, "skippedCount": skipped,
      ]
      let data = try? JSONSerialization.data(withJSONObject: manifest)
      try? data?.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
      UserDefaults(suiteName: self.appGroup)?.set(batchID, forKey: "pendingShareBatchID")
      let url = URL(string: "clipboardcompanion://incoming-share")!
      self.extensionContext?.open(url) { _ in
        self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
      }
    }
  }

  override func configurationItems() -> [Any]! { [] }

  private func finishWithError(_ message: String) {
    let error = NSError(domain: "ClipboardCompanionShare", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: message])
    extensionContext?.cancelRequest(withError: error)
  }

  private func safeName(_ name: String) -> String {
    String(name.map { "/:\\?%*|\"<>".contains($0) ? "_" : $0 }.prefix(180))
  }

  private func mimeType(for identifier: String) -> String {
    UTTypeCopyPreferredTagWithClass(
      identifier as CFString,
      kUTTagClassMIMEType
    )?.takeRetainedValue() as String? ?? "application/octet-stream"
  }

  private func uniqueURL(in directory: URL, named name: String) -> URL {
    var result = directory.appendingPathComponent(name)
    var suffix = 2
    let ext = result.pathExtension
    let stem = result.deletingPathExtension().lastPathComponent
    while FileManager.default.fileExists(atPath: result.path) {
      let candidate = ext.isEmpty ? "\(stem) (\(suffix))" : "\(stem) (\(suffix)).\(ext)"
      result = directory.appendingPathComponent(candidate)
      suffix += 1
    }
    return result
  }
}
