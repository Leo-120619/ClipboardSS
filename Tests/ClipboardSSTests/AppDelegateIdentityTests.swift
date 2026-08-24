import Foundation
import Testing
@testable import ClipboardSS

@Suite("App delegate identity")
struct AppDelegateIdentityTests {
    @Test("corrupt stored device ID is regenerated instead of crashing")
    @MainActor
    func corruptStoredDeviceIDIsRegenerated() throws {
        let suiteName = "ClipboardSS.AppDelegateIdentityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("not-a-uuid", forKey: "deviceId")

        let identityId = AppDelegate.loadDeviceIdentityId(defaults: defaults)

        #expect(defaults.string(forKey: "deviceId") == identityId.uuidString.lowercased())
    }
}
