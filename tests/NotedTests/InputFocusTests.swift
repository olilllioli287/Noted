import Foundation
import Testing
@testable import ShotLineKit

/// 什麼時候才把輸入框的游標還回去：前景還是同一個 App、Noted 不在前景、焦點已經不在輸入框。
struct InputFocusTests {
    private func decide(front: pid_t? = 100, remembered: pid_t = 100, me: pid_t = 1,
                        text: Bool = false, target: Bool = false, force: Bool = false,
                        window: Bool? = nil, element: Bool? = nil, first: Bool = false, role: String = "AXTextArea") -> InputFocus.Action {
        InputFocus.decide(rememberedPID: remembered, frontPID: front, myPID: me,
                          currentIsText: text, currentIsTarget: target, force: force,
                          windowFocused: window, elementFocused: element, isFirstCheck: first, role: role)
    }

    @Test func focusLostInSameFrontAppIsRestored() { #expect(decide().isSet) }
    @Test func otherAppInFrontIsLeftAlone() { #expect(!decide(front: 200).isSet) }
    @Test func noFrontAppIsLeftAlone() { #expect(!decide(front: nil).isSet) }
    @Test func notedInFrontIsLeftAlone() { #expect(!decide(front: 1, remembered: 1, me: 1).isSet) }
    @Test func alreadyOnTheRememberedFieldIsLeftAlone() { #expect(!decide(text: true, target: true, force: true).isSet) }
    @Test func anotherTextFieldKeepsItsFocusWhenOnlyRemembered() { #expect(!decide(text: true).isSet) }
    @Test func fieldUnderTheDropIsGivenBackEvenFromAnotherTextField() { #expect(decide(text: true, force: true).isSet) }

    // 鍵盤其實沒送到的情況：焦點元素就是記住的，但視窗或元素的 AXFocused 是否
    @Test func targetFocusedButWindowNotFocusedIsRestored() { #expect(decide(target: true, window: false, element: true).isSet) }
    @Test func targetFocusedButElementNotFocusedIsRestored() { #expect(decide(target: true, window: true, element: false).isSet) }
    @Test func everythingFocusedLaterChecksLeaveItAlone() { #expect(!decide(target: true, window: true, element: true).isSet) }
    @Test func unreadableFocusFlagsAreNotTreatedAsLost() { #expect(!decide(target: true).isSet) }
    @Test func firstCheckSetsOnceEvenWhenAlreadyFocused() { #expect(decide(target: true, window: true, element: true, first: true).isSet) }
    @Test func firstCheckLeavesNativeTextFieldAlone() { #expect(!decide(target: true, window: true, element: true, first: true, role: "AXTextField").isSet) }
    @Test func firstCheckStillNeedsTheRightFrontApp() { #expect(!decide(front: 200, target: true, first: true).isSet) }
}
