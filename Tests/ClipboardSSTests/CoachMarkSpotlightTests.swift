import CoreGraphics
import Testing
@testable import ClipboardSS

@Suite("Coach mark spotlight")
struct CoachMarkSpotlightTests {
    @Test("frame returns nil when target is not registered")
    func frameReturnsNilWhenTargetIsNotRegistered() {
        let windowSize = CGSize(width: 720, height: 680)

        for target in CoachMarkSpotlight.Target.allCases {
            #expect(CoachMarkSpotlight.frame(for: target, in: windowSize) == nil)
        }
    }

    @Test("resolved target frame is padded and clamped to the window")
    func resolvedTargetFrameIsPaddedAndClampedToWindow() {
        let resolvedFrame = CGRect(x: 481, y: 22, width: 84, height: 32)
        let frame = CoachMarkSpotlight.frame(
            for: .screenshotButton,
            in: CGSize(width: 720, height: 680),
            resolvedTargets: [.screenshotButton: resolvedFrame]
        )

        let unwrapped = try! #require(frame)
        #expect(unwrapped.minX == resolvedFrame.minX - CoachMarkSpotlight.resolvedTargetPadding)
        #expect(unwrapped.minY == resolvedFrame.minY - CoachMarkSpotlight.resolvedTargetPadding)
        #expect(unwrapped.width == resolvedFrame.width + CoachMarkSpotlight.resolvedTargetPadding * 2)
        #expect(unwrapped.height == resolvedFrame.height + CoachMarkSpotlight.resolvedTargetPadding * 2)
    }

    @Test("resolved frame respects an explicit padding")
    func resolvedFrameRespectsExplicitPadding() {
        let resolvedFrame = CGRect(x: 200, y: 200, width: 38, height: 38)
        let frame = CoachMarkSpotlight.frame(
            for: .pasteButton,
            in: CGSize(width: 560, height: 520),
            resolvedTargets: [.pasteButton: resolvedFrame],
            padding: 12
        )

        let unwrapped = try! #require(frame)
        #expect(unwrapped.midX == resolvedFrame.midX)
        #expect(unwrapped.midY == resolvedFrame.midY)
        #expect(unwrapped.width == resolvedFrame.width + 12 * 2)
        #expect(unwrapped.height == resolvedFrame.height + 12 * 2)
    }

    @Test("resolved frame is clamped inside the window")
    func resolvedFrameIsClampedInsideWindow() {
        let outOfBounds = CGRect(x: 700, y: 660, width: 80, height: 80)
        let windowSize = CGSize(width: 720, height: 680)
        let frame = CoachMarkSpotlight.frame(
            for: .closeButton,
            in: windowSize,
            resolvedTargets: [.closeButton: outOfBounds]
        )

        let unwrapped = try! #require(frame)
        #expect(unwrapped.maxX <= windowSize.width)
        #expect(unwrapped.maxY <= windowSize.height)
        #expect(unwrapped.minX >= 0)
        #expect(unwrapped.minY >= 0)
    }

    @Test("clip card action coach targets register only for prominent clips")
    func clipCardActionCoachTargetsRegisterOnlyForProminentClips() {
        #expect(CoachMarkSpotlight.shouldRegisterClipCardTarget(.clipContent, isProminentClip: true))
        #expect(CoachMarkSpotlight.shouldRegisterClipCardTarget(.pasteButton, isProminentClip: true))
        #expect(!CoachMarkSpotlight.shouldRegisterClipCardTarget(.pasteButton, isProminentClip: false))
        #expect(!CoachMarkSpotlight.shouldRegisterClipCardTarget(.pinButton, isProminentClip: false))
    }

    @Test("tour has a step for every button and click behavior")
    func tourHasStepForEveryButtonAndClickBehavior() {
        let targets = Set(CoachMarkStep.steps.map(\.spotlightTarget))

        #expect(targets.contains(.clipContent))
        #expect(targets.contains(.pasteButton))
        #expect(targets.contains(.copyButton))
        #expect(targets.contains(.pinButton))
        #expect(targets.contains(.deleteButton))
        #expect(targets.contains(.screenTextButton))
        #expect(targets.contains(.screenshotButton))
        #expect(targets.contains(.preferencesButton))
        #expect(targets.contains(.closeButton))
        #expect(CoachMarkStep.steps.contains { $0.title.localizedCaseInsensitiveContains("single-click") })
        #expect(CoachMarkStep.steps.contains { $0.title.localizedCaseInsensitiveContains("double-click") })
    }

    @Test("action button steps use circle spotlights, content steps use rounded rects")
    func actionButtonStepsUseCircleSpotlights() {
        let circleTargets: Set<CoachMarkSpotlight.Target> = [
            .pasteButton, .copyButton, .pinButton, .deleteButton, .preferencesButton, .closeButton
        ]

        for step in CoachMarkStep.steps {
            if circleTargets.contains(step.spotlightTarget) {
                #expect(step.shape == .circle, "\(step.spotlightTarget) should use a circle spotlight")
            } else {
                if case .roundedRect = step.shape {
                    // expected
                } else {
                    Issue.record("\(step.spotlightTarget) should use a roundedRect spotlight")
                }
            }
            #expect(step.spotlightPadding >= 8)
        }
    }

    @Test("app model step count follows the tour")
    func appModelStepCountFollowsTheTour() {
        #expect(AppModel.coachMarkStepCount == CoachMarkStep.steps.count)
    }
}
