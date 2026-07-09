import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let imagesChannelName = "clipboard_companion/images"

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
