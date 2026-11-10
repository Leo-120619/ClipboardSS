import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let imagesChannelName = "clipboard_companion/images"
  private let shareChannelName = "clipboard_companion/incoming_share"
  private let storageChannelName = "clipboard_companion/storage"
  private let appGroup = "group.com.leolml.clipboardCompanion"
  private var shareChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let imagesChannel = FlutterMethodChannel(
      name: imagesChannelName,
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    imagesChannel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "copyImageToClipboard":
        let args = call.arguments as? [String: Any]
        self?.copyImageToClipboard(
          imageBase64: args?["imageBase64"] as? String,
          extension: args?["extension"] as? String,
          result: result
        )
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    let storageChannel = FlutterMethodChannel(
      name: storageChannelName,
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    storageChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "freeSpace":
        // Free bytes on the volume holding `path` (incoming file-transfer quota).
        let path = (call.arguments as? [String: Any])?["path"] as? String ?? NSTemporaryDirectory()
        let values = try? URL(fileURLWithPath: path).resourceValues(
          forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        if let bytes = values?.volumeAvailableCapacityForImportantUsage {
          result(NSNumber(value: bytes))
        } else {
          result(FlutterError(code: "freeSpace", message: "unavailable", details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    let channel = FlutterMethodChannel(
      name: shareChannelName,
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    shareChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "getInitialShare": result(self?.pendingShare())
      case "completeShare":
        let id = (call.arguments as? [String: Any])?["id"] as? String
        self?.completeShare(id: id)
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
    deliverPendingShare()
    // Shares made while the app is running arrive when it is brought back to the front.
    NotificationCenter.default.addObserver(
      forName: UIScene.didActivateNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.deliverPendingShare()
    }
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if url.scheme == "clipboardcompanion" {
      deliverPendingShare()
      return true
    }
    return super.application(app, open: url, options: options)
  }

  /// Hands Flutter the oldest pending batch. Flutter shows one batch at a time and
  /// ignores a batch it already holds, so redelivering the same one is harmless.
  private func deliverPendingShare() {
    if let share = pendingShare() { shareChannel?.invokeMethod("incomingShare", arguments: share) }
  }

  /// Every batch folder with a manifest is a pending share (the extension writes the
  /// manifest last). Returns the oldest so batches are handled in the order shared.
  private func pendingShare() -> [String: Any]? {
    guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    else { return nil }
    let inbox = root.appendingPathComponent("IncomingShares", isDirectory: true)
    let folders = (try? FileManager.default.contentsOfDirectory(
      at: inbox, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
    )) ?? []
    let batches: [(date: Date, value: [String: Any])] = folders.compactMap { folder in
      let manifest = folder.appendingPathComponent("manifest.json")
      guard let data = try? Data(contentsOf: manifest),
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return nil }
      let date = (try? FileManager.default.attributesOfItem(atPath: manifest.path))?[.modificationDate]
        as? Date ?? .distantPast
      return (date, value)
    }
    return batches.min { $0.date < $1.date }?.value
  }

  private func completeShare(id: String?) {
    guard let id, UUID(uuidString: id) != nil,
          let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    else { return }
    try? FileManager.default.removeItem(at: root.appendingPathComponent("IncomingShares/\(id)"))
    // Key written by older extension builds; batches are now found by folder.
    UserDefaults(suiteName: appGroup)?.removeObject(forKey: "pendingShareBatchID")
    deliverPendingShare()
  }

  private func copyImageToClipboard(imageBase64: String?, extension ext: String?, result: @escaping FlutterResult) {
    guard let imageBase64, !imageBase64.isEmpty, let data = Data(base64Encoded: imageBase64) else {
      result(FlutterError(code: "missing_image", message: "No image bytes were supplied.", details: nil))
      return
    }

    let pasteboardType: String
    switch ext?.lowercased() {
    case "jpg", "jpeg":
      pasteboardType = "public.jpeg"
    case "webp":
      pasteboardType = "org.webmproject.webp"
    default:
      pasteboardType = "public.png"
    }

    UIPasteboard.general.setData(data, forPasteboardType: pasteboardType)
    result(nil)
  }
}
