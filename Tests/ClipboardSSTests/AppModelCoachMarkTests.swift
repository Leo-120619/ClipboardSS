import ClipboardCore
import Foundation
import Testing
@testable import ClipboardSS

@MainActor
@Suite("App model coach marks", .serialized)
struct AppModelCoachMarkTests {
    @Test("first run shows coach marks when completion key is absent")
    func firstRunShowsCoachMarksWhenCompletionKeyIsAbsent() throws {
        defer { UserDefaults.standard.removeObject(forKey: AppModel.coachMarksCompletedDefaultsKey) }
        UserDefaults.standard.removeObject(forKey: AppModel.coachMarksCompletedDefaultsKey)

        let fixture = try AppModelCoachMarkFixture()

        #expect(fixture.model.showCoachMarks)
        #expect(fixture.model.currentCoachMarkIndex == 0)
    }

    @Test("completing coach marks persists completion and hides overlay")
    func completingCoachMarksPersistsCompletionAndHidesOverlay() throws {
        defer { UserDefaults.standard.removeObject(forKey: AppModel.coachMarksCompletedDefaultsKey) }
        UserDefaults.standard.removeObject(forKey: AppModel.coachMarksCompletedDefaultsKey)
        let fixture = try AppModelCoachMarkFixture()

        fixture.model.completeCoachMarks()

        #expect(!fixture.model.showCoachMarks)
        #expect(UserDefaults.standard.bool(forKey: AppModel.coachMarksCompletedDefaultsKey))
    }

    @Test("completed coach marks stay hidden on relaunch")
    func completedCoachMarksStayHiddenOnRelaunch() throws {
        defer { UserDefaults.standard.removeObject(forKey: AppModel.coachMarksCompletedDefaultsKey) }
        UserDefaults.standard.set(true, forKey: AppModel.coachMarksCompletedDefaultsKey)

        let fixture = try AppModelCoachMarkFixture()

        #expect(!fixture.model.showCoachMarks)
    }

    @Test("restarting coach marks shows the tour from the first step")
    func restartingCoachMarksShowsTourFromFirstStep() throws {
        defer { UserDefaults.standard.removeObject(forKey: AppModel.coachMarksCompletedDefaultsKey) }
        UserDefaults.standard.set(true, forKey: AppModel.coachMarksCompletedDefaultsKey)
        let fixture = try AppModelCoachMarkFixture()

        fixture.model.advanceCoachMark()
        fixture.model.restartCoachMarks()

        #expect(fixture.model.showCoachMarks)
        #expect(fixture.model.currentCoachMarkIndex == 0)
    }
}

@MainActor
private struct AppModelCoachMarkFixture {
    let store: ClipStore
    let pasteboard: CoachMarkFakePasteboard
    let model: AppModel

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try ClipStore(storageDirectory: directory)
        let pasteboard = CoachMarkFakePasteboard()
        self.store = store
        self.pasteboard = pasteboard
        self.model = try makeTestAppModel(store: store, pasteboard: pasteboard)
    }
}

private final class CoachMarkFakePasteboard: PasteboardClient {
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
