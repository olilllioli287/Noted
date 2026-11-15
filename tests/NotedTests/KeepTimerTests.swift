import Foundation
import Testing
@testable import ShotLineKit

struct KeepTimerTests {
    @Test func newlyHungCaptureHasFullDelay() {
        let now = Date()
        #expect(Line.keepRemaining(hungAt: now, delay: 600, now: now) == 600)
    }

    @Test func halfElapsedDelayHasHalfRemaining() {
        let now = Date()
        #expect(Line.keepRemaining(hungAt: now.addingTimeInterval(-300), delay: 600, now: now) == 300)
    }

    @Test func elapsedDelayHasNoTimeRemaining() {
        let now = Date()
        #expect(Line.keepRemaining(hungAt: now.addingTimeInterval(-700), delay: 600, now: now) == 0)
    }
}
