import ClipboardCore
import Foundation
import Testing
@testable import ClipboardSS

@MainActor
@Suite("App model launch at login", .serialized)
struct AppModelLaunchAtLoginTests {
    @Test("first launch defaults launch at login on and registers it")
    func firstLaunchDefaultsLaunchAtLoginOnAndRegistersIt() throws {
        defer { UserDefaults.standard.removeObject(forKey: AppModel.launchAtLoginDefaultsKey) }
        UserDefaults.standard.removeObject(forKey: AppModel.launchAtLoginDefaultsKey)
        let fixture = try AppModelLaunchAtLoginFixture()

        #expect(fixture.model.launchAtLoginEnabled)
        #expect(fixture.launchAtLogin.isEnabled)
        #expect(fixture.launchAtLogin.registerCount == 1)
    }

    @Test("disabling launch at login persists and unregisters it")
    func disablingLaunchAtLoginPersistsAndUnregistersIt() throws {
        defer { UserDefaults.standard.removeObject(forKey: AppModel.launchAtLoginDefaultsKey) }
        UserDefaults.standard.removeObject(forKey: AppModel.launchAtLoginDefaultsKey)
        let fixture = try AppModelLaunchAtLoginFixture()

        fixture.model.setLaunchAtLoginEnabled(false)

        #expect(!fixture.model.launchAtLoginEnabled)
        #expect(!fixture.launchAtLogin.isEnabled)
        #expect(fixture.launchAtLogin.unregisterCount == 1)
        #expect(!UserDefaults.standard.bool(forKey: AppModel.launchAtLoginDefaultsKey))
    }

    @Test("stored disabled preference stays off on relaunch")
    func storedDisabledPreferenceStaysOffOnRelaunch() throws {
        defer { UserDefaults.standard.removeObject(forKey: AppModel.launchAtLoginDefaultsKey) }
        UserDefaults.standard.set(false, forKey: AppModel.launchAtLoginDefaultsKey)
        let fixture = try AppModelLaunchAtLoginFixture()

        #expect(!fixture.model.launchAtLoginEnabled)
        #expect(!fixture.launchAtLogin.isEnabled)
        #expect(fixture.launchAtLogin.registerCount == 0)
    }
}

@MainActor
private struct AppModelLaunchAtLoginFixture {
    let store: ClipStore
    let pasteboard: LaunchAtLoginFakePasteboard
    let launchAtLogin: FakeLaunchAtLoginController
    let model: AppModel

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try ClipStore(storageDirectory: directory)
        let pasteboard = LaunchAtLoginFakePasteboard()
        let launchAtLogin = FakeLaunchAtLoginController()
        self.store = store
        self.pasteboard = pasteboard
        self.launchAtLogin = launchAtLogin
        self.model = AppModel(
            store: store,
            writer: ClipboardWriter(pasteboard: pasteboard, store: store),
            screenshotCaptureService: ScreenshotCaptureService(),
            ocrService: OCRService(),
            launchAtLogin: launchAtLogin,
            pasteboard: pasteboard
        )
    }
}

private final class FakeLaunchAtLoginController: LaunchAtLoginControlling {
    var isEnabled = false
    var registerCount = 0
    var unregisterCount = 0

    func setEnabled(_ enabled: Bool) throws {
        isEnabled = enabled
        if enabled {
            registerCount += 1
        } else {
            unregisterCount += 1
        }
    }
}

private final class LaunchAtLoginFakePasteboard: PasteboardClient {
    var changeCount = 0
    var snapshot = ClipboardSnapshot(text: nil, imageData: nil)

    func currentChangeCount() -> Int {
        changeCount
    }

    func readSnapshot() -> ClipboardSnapshot {
        snapshot
    }

    func clearContents() {}

    func writeText(_ text: String) {}

    func writeImageData(_ data: Data) {}
}
