import Cocoa
import ClipboardCore
import UniformTypeIdentifiers

/// Principal view controller for the macOS share extension. It hands the shared files and
/// folders to the host app (`ShareHandoff`), opens it via its URL scheme so it can send
/// them, then dismisses itself.
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

        let group = DispatchGroup()
        let collector = ItemCollector(count: providers.count)
        for (index, provider) in providers.enumerated() {
            group.enter()
            loadItem(from: provider) { item in
                collector.set(item, at: index)
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            // Hand over everything or nothing: a share must not go out with items missing.
            guard let items = collector.allItems() else {
                self.finish(error: "Couldn't read the shared item.")
                return
            }
            do {
                let id = try ShareHandoff.post(items)
                self.openHost(handoffId: id)
                self.finish(error: nil)
            } catch {
                self.finish(error: "Couldn't hand off to ClipboardSS.")
            }
        }
    }

    /// Describes a provider's payload for the host: a file or folder by path, or its bytes.
    private func loadItem(from provider: NSItemProvider, completion: @escaping @Sendable (ShareHandoff.Item?) -> Void) {
        // Prefer an explicit file URL (Finder, most document apps). The host is not
        // sandboxed, so it reads the file or folder in place.
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
                guard let source = sourceURL, source.isFileURL else { completion(nil); return }
                completion(ShareHandoff.Item(path: source.path))
            }
            return
        }

        // Otherwise take the payload's bytes (an image shared from a preview, etc.).
        let typeIdentifier = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .item) == true }
            ?? provider.registeredTypeIdentifiers.first
            ?? UTType.data.identifier
        var name = provider.suggestedName ?? "Shared Item"
        if (name as NSString).pathExtension.isEmpty,
           let ext = UTType(typeIdentifier)?.preferredFilenameExtension {
            name += ".\(ext)"
        }
        let fileName = name
        _ = provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
            guard let data else { completion(nil); return }
            completion(ShareHandoff.Item(name: fileName, data: data))
        }
    }

    private func openHost(handoffId: String) {
        guard let url = URL(string: "\(ShareInbox.urlScheme)://share?id=\(handoffId)") else { return }
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

/// Collects each provider's item in provider order from concurrent completion handlers.
private final class ItemCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ShareHandoff.Item?]

    init(count: Int) {
        items = Array(repeating: nil, count: count)
    }

    func set(_ item: ShareHandoff.Item?, at index: Int) {
        lock.lock(); items[index] = item; lock.unlock()
    }

    /// Every item, or nil when any provider failed to load.
    func allItems() -> [ShareHandoff.Item]? {
        lock.lock(); defer { lock.unlock() }
        let loaded = items.compactMap { $0 }
        return loaded.count == items.count ? loaded : nil
    }
}
