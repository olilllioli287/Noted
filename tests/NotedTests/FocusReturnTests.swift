import Testing
@testable import ShotLineKit

struct FocusReturnTests {
    @Test func targetAlreadyInFrontLeavesActivationAlone() {
        #expect(FocusReturn.activationPlan(targetPID: 20, frontPID: 20, myPID: 10) == .leaveAlone)
    }

    @Test func differentFrontAppBringsTargetForward() {
        #expect(FocusReturn.activationPlan(targetPID: 20, frontPID: 30, myPID: 10) == .bringForward)
    }

    @Test func ownProcessIsIgnored() {
        #expect(FocusReturn.activationPlan(targetPID: 10, frontPID: 20, myPID: 10) == .ignore)
    }

    @Test func missingFrontAppBringsTargetForward() {
        #expect(FocusReturn.activationPlan(targetPID: 20, frontPID: nil, myPID: 10) == .bringForward)
    }

    @Test func targetInFrontButNotedHoldsKeyboardStillGetsHandOver() {
        #expect(FocusReturn.activationPlan(targetPID: 20, frontPID: 20, myPID: 10, notedHoldsKeyboard: true) == .bringForward)
    }

    @Test func ownProcessIsIgnoredEvenWhenHoldingKeyboard() {
        #expect(FocusReturn.activationPlan(targetPID: 10, frontPID: 10, myPID: 10, notedHoldsKeyboard: true) == .ignore)
    }
}
