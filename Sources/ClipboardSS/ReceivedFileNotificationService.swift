import AppKit
import Foundation
import UserNotifications

@MainActor
final class ReceivedFileNotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    func initialize() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func showReceivedFile(at url: URL) {
        let content = UNMutableNotificationContent()
        content.title = "File received"
        content.body = url.lastPathComponent
        content.sound = .default
        content.userInfo = ["path": url.path]
        center.add(UNNotificationRequest(identifier: "received-file-\(UUID().uuidString)", content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let path = response.notification.request.content.userInfo["path"] as? String
        completionHandler()
        Task { @MainActor in
            NSApplication.shared.activate(ignoringOtherApps: true)
            if let path, FileManager.default.fileExists(atPath: path) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
