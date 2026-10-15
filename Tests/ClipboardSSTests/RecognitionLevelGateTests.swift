import Testing
import Vision
@testable import ClipboardSS

@Suite("Recognition level gate")
struct RecognitionLevelGateTests {
    @Test("uses fast recognition until the accurate model has warmed up")
    func usesFastUntilWarm() {
        let gate = RecognitionLevelGate()

        #expect(gate.level == .fast)
        #expect(gate.claimWarmUp())
        #expect(gate.level == .fast)

        gate.warmUpFinished(succeeded: true)

        #expect(gate.level == .accurate)
    }

    @Test("only one caller gets to run the warm-up")
    func warmUpIsClaimedOnce() {
        let gate = RecognitionLevelGate()

        #expect(gate.claimWarmUp())
        #expect(gate.claimWarmUp() == false)
        gate.warmUpFinished(succeeded: true)
        #expect(gate.claimWarmUp() == false)
    }

    @Test("stays on fast recognition when the accurate model fails to load")
    func failedWarmUpStaysFast() {
        let gate = RecognitionLevelGate()

        _ = gate.claimWarmUp()
        gate.warmUpFinished(succeeded: false)

        #expect(gate.level == .fast)
        #expect(gate.claimWarmUp() == false)
    }

    @Test("an accurate failure after warm-up falls back to fast for good")
    func accurateFailureAfterWarmUp() {
        let gate = RecognitionLevelGate()
        _ = gate.claimWarmUp()
        gate.warmUpFinished(succeeded: true)

        gate.accurateFailed()

        #expect(gate.level == .fast)
    }
}
