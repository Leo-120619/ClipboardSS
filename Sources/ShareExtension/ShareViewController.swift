import Cocoa
import ClipboardCore
import UniformTypeIdentifiers

/// Principal view controller for the macOS share extension. It copies the shared
/// file(s) into the app-group outbox, opens the host app via its URL scheme so the
/// user can pick a device, then dismisses itself.
final class ShareViewController: NSViewController {
    private let statusLabel = NSTextField(labelWithString: "Sending to ClipboardSS…")

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 96))

        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16)
        ])
        self.view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        process()
    }

    private func process() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else {
            finish(error: "Nothing to share.")
            return
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardSSShare-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let group = DispatchGroup()
        let lock = NSLock()
        var collected: [URL] = []

        for provider in providers {
            group.enter()
            loadFile(from: provider, into: staging) { url in
                if let url {
                    lock.lock(); collected.append(url); lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            guard !collected.isEmpty else {
                self.finish(error: "Couldn't read the shared item.")
                return
            }
            do {
                let id = try ShareInbox.writeDrop(sources: collected)
                try? FileManager.default.removeItem(at: staging)
                self.openHost(dropId: id)
                self.finish(error: nil)
            } catch {
                self.finish(error: "Couldn't hand off to ClipboardSS.")
            }
        }
    }

    /// Materialises a provider's payload as a readable file inside `staging`.
    private func loadFile(from provider: NSItemProvider, into staging: URL, completion: @escaping (URL?) -> Void) {
        // Prefer an explicit file URL (Finder, most document apps).
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let sourceURL: URL?
                if let url = item as? URL {
                    sourceURL = url
                } else if let data = item as? Data {
                    sourceURL = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    sourceURL = nil
                }
                guard let source = sourceURL else { completion(nil); return }
                completion(Self.copyIntoStaging(source, staging: staging))
            }
            return
        }

        // Otherwise ask the provider to write a file representation (images from Photos, etc.).
        let typeIdentifier = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .item) == true }
            ?? provider.registeredTypeIdentifiers.first
            ?? UTType.data.identifier
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
            guard let url else { completion(nil); return }
            completion(Self.copyIntoStaging(url, staging: staging))
        }
    }

    /// Copies a (possibly security-scoped) source file into `staging` and returns the copy.
    private static func copyIntoStaging(_ source: URL, staging: URL) -> URL? {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let name = source.lastPathComponent.isEmpty ? "file" : source.lastPathComponent
        var dest = staging.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            let ext = (name as NSString).pathExtension
            let stem = (name as NSString).deletingPathExtension
            let candidate = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
            dest = staging.appendingPathComponent(candidate)
            counter += 1
        }
        do {
            try FileManager.default.copyItem(at: source, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    private func openHost(dropId: String) {
        guard let url = URL(string: "\(ShareInbox.urlScheme)://share?id=\(dropId)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func finish(error: String?) {
        if let error {
            statusLabel.stringValue = error
            let nsError = NSError(domain: "com.local.ClipboardSS.ShareExtension", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: error])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.extensionContext?.cancelRequest(withError: nsError)
            }
        } else {
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }
}
