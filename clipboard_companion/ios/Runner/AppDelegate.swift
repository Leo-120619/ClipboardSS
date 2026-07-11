import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let imagesChannelName = "clipboard_companion/images"
  private let shareChannelName = "clipboard_companion/incoming_share"
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
    if let share = pendingShare() { channel.invokeMethod("incomingShare", arguments: share) }
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if url.scheme == "clipboardcompanion", let share = pendingShare() {
      shareChannel?.invokeMethod("incomingShare", arguments: share)
      return true
    }
    return super.application(app, open: url, options: options)
  }

  private func pendingShare() -> [String: Any]? {
    guard let defaults = UserDefaults(suiteName: appGroup),
          let id = defaults.string(forKey: "pendingShareBatchID"),
          let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup),
          let data = try? Data(contentsOf: root.appendingPathComponent("IncomingShares/\(id)/manifest.json")),
          let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return value
  }

  private func completeShare(id: String?) {
    guard let id,
          let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    else { return }
    try? FileManager.default.removeItem(at: root.appendingPathComponent("IncomingShares/\(id)"))
    let defaults = UserDefaults(suiteName: appGroup)
    if defaults?.string(forKey: "pendingShareBatchID") == id {
      defaults?.removeObject(forKey: "pendingShareBatchID")
    }
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
