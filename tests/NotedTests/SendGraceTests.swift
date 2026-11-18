import Foundation
import Testing
@testable import Noted

/// 展開中從右欄拖出截圖之後的「剛送出寬限」：6 秒，每送出一張就重新算。
struct SendGraceTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func notActiveBeforeAnythingIsSent() {
        #expect(!SendGrace().isActive(at: t0))
    }

    @Test func activeForSixSecondsThenEnds() {
        var g = SendGrace()
        g.sent(at: t0)
        #expect(g.isActive(at: t0.addingTimeInterval(5.9)))
        #expect(!g.isActive(at: t0.addingTimeInterval(6.0)))
    }

    @Test func eachSendRestartsTheCountdown() {
        var g = SendGrace()
        g.sent(at: t0)
        g.sent(at: t0.addingTimeInterval(4))                      // 第二張：從這時候重新算 6 秒
        #expect(g.isActive(at: t0.addingTimeInterval(9.9)), "第二張送出後倒數要重算，不是第 6 秒就結束")
        #expect(!g.isActive(at: t0.addingTimeInterval(10.0)))
    }

    @Test func endingEarlyStopsItAtOnce() {
        var g = SendGrace()
        g.sent(at: t0)
        g.end()                                                    // 滑鼠回到面板
        #expect(!g.isActive(at: t0.addingTimeInterval(1)))
    }
}
