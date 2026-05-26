import AppKit
import ApplicationServices
import CoreGraphics

enum AppPermission {
    case accessibility
    case screenRecording

    private static let installedAppPath = "/Applications/ClipboardSS.app"

    var settingsURL: URL? {
        let anchor = switch self {
        case .accessibility:
            "Privacy_Accessibility"
        case .screenRecording:
            "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    var manualAddPath: String {
        Self.manualAddPath(bundleURL: Bundle.main.bundleURL)
    }

    static func manualAddPath(bundleURL: URL?) -> String {
        guard let bundleURL, bundleURL.pathExtension == "app" else {
            return installedAppPath
        }

        return bundleURL.path
    }

    var deniedMessage: String {
        switch self {
        case .accessibility:
            "Accessibility access is required to paste into other apps. Add \(manualAddPath) in System Settings > Privacy & Security > Accessibility."
        case .screenRecording:
            "Screen Recording access is required to capture screenshots. Add \(manualAddPath) in System Settings > Privacy & Security > Screen & System Audio Recording, then enable it."
        }
    }

    var isGranted: Bool {
        switch self {
        case .accessibility:
            AXIsProcessTrusted()
        case .screenRecording:
            CGPreflightScreenCaptureAccess()
        }
    }

    @discardableResult
    func requestAccess() -> Bool {
        switch self {
        case .accessibility:
            let options = [
                "AXTrustedCheckOptionPrompt": true
            ] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        case .screenRecording:
            return CGRequestScreenCaptureAccess()
        }
    }

    func openSettings() {
        if let settingsURL {
            NSWorkspace.shared.open(settingsURL)
        }
    }
}
