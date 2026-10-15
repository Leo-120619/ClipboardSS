import Foundation
import XCTest
@testable import ClipboardSS

final class ReceiveBatchDestinationTests: XCTestCase {
    private let downloads = URL(fileURLWithPath: "/Users/test/Downloads", isDirectory: true)
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testFirstFileOfABatchHasNoAnswerYet() {
        var batch = ReceiveBatchDestination(window: 60)
        XCTAssertNil(batch.decision(now: start))
    }

    func testLaterFilesOfTheSameBatchReuseTheFirstFolder() {
        var batch = ReceiveBatchDestination(window: 60)
        batch.record(.folder(downloads), now: start)

        XCTAssertEqual(batch.decision(now: start.addingTimeInterval(5)), .folder(downloads))
        XCTAssertEqual(batch.decision(now: start.addingTimeInterval(30)), .folder(downloads))
    }

    func testACancelledPickerIsNotReopenedForTheRestOfTheBatch() {
        var batch = ReceiveBatchDestination(window: 60)
        batch.record(.declined, now: start)

        XCTAssertEqual(batch.decision(now: start.addingTimeInterval(1)), .declined)
    }

    func testEachReadExtendsTheBatchSoSlowTransfersStayGrouped() {
        var batch = ReceiveBatchDestination(window: 60)
        batch.record(.folder(downloads), now: start)

        // Three files, each 50s after the previous: still one batch.
        XCTAssertEqual(batch.decision(now: start.addingTimeInterval(50)), .folder(downloads))
        XCTAssertEqual(batch.decision(now: start.addingTimeInterval(100)), .folder(downloads))
    }

    func testAnUnrelatedFileAfterTheWindowAsksAgain() {
        var batch = ReceiveBatchDestination(window: 60)
        batch.record(.folder(downloads), now: start)

        XCTAssertNil(batch.decision(now: start.addingTimeInterval(61)))
        // The stale answer is dropped, not resurrected by a later read.
        XCTAssertNil(batch.decision(now: start.addingTimeInterval(62)))
    }
}
