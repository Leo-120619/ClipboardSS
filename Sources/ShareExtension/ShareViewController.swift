import Cocoa
import ClipboardCore
import UniformTypeIdentifiers

/// Principal view controller for the macOS share extension. It stages shared
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

        let drop: (id: String, directory: URL)
        do {
            drop = try ShareInbox.createDrop()
        } catch {
            finish(error: "Couldn't prepare the shared item.")
            return
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var collected: [URL] = []

        for provider in providers {
            group.enter()
            loadFile(from: provider, into: drop.directory) { url in
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
                try ShareInbox.finalizeDrop(id: drop.id, names: collected.map(\.lastPathComponent))
                self.openHost(dropId: drop.id)
                self.finish(error: nil)
            } catch {
                self.finish(error: "Couldn't hand off to ClipboardSS.")
            }
        }
    }

    /// Materialises a provider's payload directly inside the final outbox drop.
    private func loadFile(from provider: NSItemProvider, into dropDirectory: URL, completion: @escaping (URL?) -> Void) {
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
                completion(Self.copyIntoDrop(source, dropDirectory: dropDirectory))
            }
            return
        }

        // Otherwise ask the provider to write a file representation (images from Photos, etc.).
        let typeIdentifier = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .item) == true }
            ?? provider.registeredTypeIdentifiers.first
            ?? UTType.data.identifier
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
            guard let url else { completion(nil); return }
            completion(Self.copyIntoDrop(url, dropDirectory: dropDirectory))
        }
    }

    /// Copies a (possibly security-scoped) provider file into the final outbox drop.
    private static func copyIntoDrop(_ source: URL, dropDirectory: URL) -> URL? {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let name = source.lastPathComponent.isEmpty ? "file" : source.lastPathComponent
        var dest = dropDirectory.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            let ext = (name as NSString).pathExtension
            let stem = (name as NSString).deletingPathExtension
            let candidate = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
            dest = dropDirectory.appendingPathComponent(candidate)
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
