import Foundation
import Testing
@testable import ClipboardSS

@Suite("App permissions")
struct AppPermissionTests {
    @Test("uses direct privacy settings URLs")
    func directPrivacySettingsURLs() throws {
        #expect(AppPermission.accessibility.settingsURL?.absoluteString.contains("Privacy_Accessibility") == true)
        #expect(AppPermission.screenRecording.settingsURL?.absoluteString.contains("Privacy_ScreenCapture") == true)
    }

    @Test("screen recording guidance names the installed app bundle")
    func screenRecordingGuidanceNamesInstalledBundle() {
        #expect(AppPermission.screenRecording.manualAddPath == "/Applications/ClipboardSS.app")
    }

    @Test("permission guidance uses the running app bundle path")
    func permissionGuidanceUsesRunningAppBundlePath() {
        let bundleURL = URL(fileURLWithPath: "/Users/leolml/Development/Clipboard SS/build/ClipboardSS.app")

        #expect(AppPermission.manualAddPath(bundleURL: bundleURL) == bundleURL.path)
    }

    @Test("permission guidance falls back to installed app outside app bundle")
    func permissionGuidanceFallsBackToInstalledAppOutsideAppBundle() {
        let bundleURL = URL(fileURLWithPath: "/Users/leolml/Development/Clipboard SS/.build/release")

        #expect(AppPermission.manualAddPath(bundleURL: bundleURL) == "/Applications/ClipboardSS.app")
    }
}
